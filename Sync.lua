--[[
	ArtPad - Sync
	Networking. Two addon-message prefixes:

	Live ("ArtPad4"), broadcast to GUILD or the group:
		S<seq>,<seg>,<durMs>,<kind>,<style>,<points>   stroke segment / shape
		T<seq>,<style>,<point>,<text>                  text
		E<id>;<id>;...                                 erase strokes
		C                                              clear canvas
		V<version>                                     version announce

	Catch-up ("ArtPad4S"), for people logging in or leaving a lockdown:
		Q<digest>                    broadcast: per-bucket fingerprint of my canvas
		A<cleared>,<total>,<counts>  whisper: what I could send per differing bucket
		R<bucket mask>               whisper: please send these buckets
		D<packed records>            whisper: one chunk (multi-part via AceComm)
		F                            whisper: done
	(see the catch-up section below)

	The server throttles addon messages per prefix (burst of 10, +1/sec), so
	live drawing is batched: points are collected and flushed as one
	message every 150ms while we have budget, or every second when we don't.
	Receivers replay each segment over its original duration so it still
	looks live.
--]]
local _, ArtPad = ...
local Codec, Strokes, Canvas = ArtPad.Codec, ArtPad.Strokes, ArtPad.Canvas

local Sync = {
	tokens = 10,
	outbox = {},
	pendingErase = {},
	offers = nil,
	lastOffer = {},
	lastSnapshotSent = {},
}
ArtPad.Sync = Sync

local LIVE_PREFIX = "ArtPad4"
local SNAP_PREFIX = "ArtPad4S"
local MAX_TOKENS = 10
local TOKEN_REFILL = 1          -- per second
local MAX_MSG = 250             -- leave some room below the 255 byte limit
local MAX_OUTBOX = 300
local FAST_INTERVAL, SLOW_INTERVAL = 0.15, 1.0
local MAX_PENDING_POINTS = 100
local SIMPLIFY_EPSILON = 1
local OFFER_WINDOW = 3

local function isSecret(v)
	return issecretvalue and issecretvalue(v) or false
end

-- [[ Setup ]]
function Sync:Init()
	LibStub("AceComm-3.0"):Embed(self)
	self:RegisterComm(LIVE_PREFIX, "OnLiveMessage")
	self:RegisterComm(SNAP_PREFIX, "OnSnapMessage")
	self.driver = CreateFrame("Frame")
	self.driver:SetScript("OnUpdate", function(_, elapsed) self:OnUpdate(elapsed) end)
end

-- [[ Channel selection ]]
function Sync:Distribution()
	if ArtPad.settings.Mode == "GUILD" then
		return IsInGuild() and "GUILD" or nil
	end
	if IsInGroup(LE_PARTY_CATEGORY_HOME) then
		return IsInRaid(LE_PARTY_CATEGORY_HOME) and "RAID" or "PARTY"
	elseif IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
		return "INSTANCE_CHAT"
	end
	return nil
end

function Sync:AcceptsDistribution(dist)
	if ArtPad.settings.Mode == "GUILD" then
		return dist == "GUILD"
	end
	return dist == "RAID" or dist == "PARTY" or dist == "INSTANCE_CHAT"
end

-- Midnight blocks addon comms during encounters, M+ and rated PvP.
function Sync:InLockdown()
	local f = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
	if not f then return false end
	local ok, locked = pcall(f)
	if not ok or isSecret(locked) then return true end
	return locked and true or false
end

function Sync:CanSend()
	return self:Distribution() ~= nil and not self:InLockdown()
end

-- [[ Outbox / throttle ]]
function Sync:Queue(msg)
	if not self:Distribution() then return end -- nobody to talk to; draw locally
	if #self.outbox >= MAX_OUTBOX then
		table.remove(self.outbox, 1)
		ArtPad:Debug("outbox full, dropping oldest message")
	end
	self.outbox[#self.outbox + 1] = msg
end

function Sync:OnUpdate(elapsed)
	self.tokens = math.min(MAX_TOKENS, self.tokens + elapsed * TOKEN_REFILL)

	-- Once a second: catch-up timeouts, and catching up after a comms lockdown
	-- (we couldn't hear anyone during the encounter / key / match).
	self.slowTimer = (self.slowTimer or 0) + elapsed
	if self.slowTimer >= 1 then
		self.slowTimer = 0
		self:CheckCatchup(GetTime())
		local locked = self:InLockdown()
		if self.wasLocked and not locked then
			C_Timer.After(5, function() self:RequestSnapshot() end)
		end
		self.wasLocked = locked
	end

	local live = self.live
	if live and #live.pending > 2 then
		local idle = #self.outbox == 0 and self.tokens >= 1
		local interval = self.tokens > 4 and FAST_INTERVAL or SLOW_INTERVAL
		if (idle and GetTime() - live.lastFlush >= interval) or #live.pending / 2 > MAX_PENDING_POINTS then
			self:FlushLive(false)
		end
	end

	if #self.pendingErase > 0 and #self.outbox == 0 then
		self:FlushErase()
	end

	if #self.outbox > 0 and self.tokens >= 1 then
		local dist = self:Distribution()
		if not dist then
			wipe(self.outbox)
		elseif not self:InLockdown() then
			while #self.outbox > 0 and self.tokens >= 1 do
				local msg = table.remove(self.outbox, 1)
				self.tokens = self.tokens - 1
				self:SendCommMessage(LIVE_PREFIX, msg, dist, nil, "ALERT")
			end
		end
	end
end

-- [[ Local drawing -> model + network ]]
local function newStroke(kind)
	local seqStr = Codec.EncodeInt(ArtPad:NextSeq())
	local s = Strokes:New(ArtPad.me .. ":" .. seqStr, ArtPad.me, kind, ArtPad:CurrentStyle(), GetServerTime())
	return s, seqStr
end

function Sync:BeginFreehand(x, y)
	if self.live then self:EndFreehand() end
	local s, seqStr = newStroke("f")
	if not s then return end
	self.live = {
		s = s, seqStr = seqStr, seg = 0,
		pending = { x, y }, times = { GetTime() },
		lastFlush = GetTime(),
	}
end

function Sync:FreehandPoint(x, y)
	local live = self.live
	if not live then return end
	local p = live.pending
	local lx, ly = p[#p - 1], p[#p]
	if lx == x and ly == y then return end
	Canvas:PreviewSegment(live.s, lx, ly, x, y)
	p[#p + 1] = x
	p[#p + 1] = y
	live.times[#live.times + 1] = GetTime()
end

function Sync:EndFreehand()
	if not self.live then return end
	self:FlushLive(true)
	self.live = nil
end

-- Splits points into runs that each encode into one message.
local function splitRuns(pts, room)
	local runs = {}
	local run = { pts[1], pts[2] }
	local size = 4
	for i = 3, #pts - 1, 2 do
		local token = Codec.EncodeStep(run[#run - 1], run[#run], pts[i], pts[i + 1])
		if size + #token > room then
			runs[#runs + 1] = run
			run = { pts[i - 2], pts[i - 1] }
			size = 4
			token = Codec.EncodeStep(run[1], run[2], pts[i], pts[i + 1])
		end
		run[#run + 1] = pts[i]
		run[#run + 1] = pts[i + 1]
		size = size + #token
	end
	runs[#runs + 1] = run
	return runs
end

function Sync:FlushLive(final)
	local live = self.live
	local s = live.s
	local pending, times = live.pending, live.times
	if #pending == 2 and not (final and live.seg == 0) then return end

	local pts = #pending > 2 and Codec.Simplify(pending, SIMPLIFY_EPSILON) or pending
	local duration = (times[#times] - times[1]) * 1000
	-- Header worst case: S + seq + , + seg(3) + , + dur(3) + ,f, + style(9) + ,
	local room = MAX_MSG - (#live.seqStr + 20)
	local runs = splitRuns(pts, room)
	local totalPoints = #pts / 2

	Canvas:ClearPreview()
	for _, run in ipairs(runs) do
		local share = totalPoints > 1 and (#run / 2 - 1) / (totalPoints - 1) or 0
		Strokes:AddRun(s, run)
		Canvas:DrawRunRange(s, run, 1, #run / 2)
		self:Queue(table.concat({
			"S" .. live.seqStr, Codec.EncodeInt(live.seg), Codec.EncodeInt(duration * share),
			"f", s.style, Codec.EncodePoints(run),
		}, ","))
		live.seg = live.seg + 1
	end

	local lx, ly = pending[#pending - 1], pending[#pending]
	live.pending = { lx, ly }
	live.times = { times[#times] }
	live.lastFlush = GetTime()
end

function Sync:CommitShape(kind, x1, y1, x2, y2)
	if x1 == x2 and y1 == y2 then return end
	local s, seqStr = newStroke(kind)
	if not s then return end
	local run = { x1, y1, x2, y2 }
	Strokes:AddRun(s, run)
	Canvas:RenderStroke(s)
	self:Queue(table.concat({ "S" .. seqStr, "A", "A", kind, s.style, Codec.EncodePoints(run) }, ","))
end

function Sync:PlaceText(x, y, text)
	text = Codec.SanitizeText(text)
	if text:match("^%s*$") then return end
	local s, seqStr = newStroke("t")
	if not s then return end
	s.text = text
	Strokes:AddRun(s, { x, y })
	Canvas:RenderStroke(s)
	self:Queue(table.concat({ "T" .. seqStr, s.style, Codec.EncodePoint(x, y), text }, ","))
end

function Sync:EraseAt(x, y)
	for _, s in ipairs(Strokes:HitTest(x, y, ArtPad:EraserRadius())) do
		if Strokes:Remove(s.id) then
			self.pendingErase[#self.pendingErase + 1] = s.id
		end
	end
end

function Sync:QueueErase(ids)
	local msg = "E"
	for _, id in ipairs(ids) do
		if #msg + #id + 1 > MAX_MSG then
			self:Queue(msg)
			msg = "E"
		end
		msg = msg == "E" and (msg .. id) or (msg .. ";" .. id)
	end
	if msg ~= "E" then self:Queue(msg) end
end

function Sync:FlushErase()
	if #self.pendingErase == 0 then return end
	self:QueueErase(self.pendingErase)
	self.pendingErase = {}
end

function Sync:Undo()
	for i = #Strokes.order, 1, -1 do
		local s = Strokes.order[i]
		if s.author == ArtPad.me and not (self.live and self.live.s == s) then
			Strokes:Remove(s.id)
			self:QueueErase({ s.id })
			return true
		end
	end
	return false
end

function Sync:ClearAll()
	if self.live then self:EndFreehand() end
	Strokes:Clear(GetServerTime())
	self:Queue("C")
end

function Sync:AnnounceVersion()
	self:Queue("V" .. tostring(ArtPad.version))
end

-- [[ Receiving live messages ]]
function Sync:ReceivedStroke(sender, seq, seg, dur, kind, style, pts)
	local id = sender .. ":" .. seq
	if Strokes:IsDead(id) or not Strokes.VALID_KINDS[kind] or kind == "t" then return end
	local run = Codec.DecodePoints(pts)
	if not run then return end
	if kind ~= "f" and #run ~= 4 then return end
	local s = Strokes:Get(id)
	if s and kind ~= "f" then return end
	if not s then
		s = Strokes:New(id, sender, kind, style, GetServerTime())
		if not s then return end
	end
	Strokes:AddRun(s, run)
	if kind == "f" then
		Canvas:PlayRun(s, run, Codec.DecodeInt(dur))
	else
		Canvas:RenderStroke(s)
		if Canvas:IsShown() then Canvas:ShowCursor(s, run[3], run[4]) end
	end
	ArtPad:NotifyActivity(sender)
end

function Sync:OnLiveMessage(prefix, msg, dist, sender)
	if isSecret(msg) or isSecret(sender) or isSecret(dist) then return end
	if type(msg) ~= "string" or type(sender) ~= "string" then return end
	sender = ArtPad:NormalizeName(sender)
	if sender == ArtPad.me or not self:AcceptsDistribution(dist) then return end

	local op = msg:sub(1, 1)
	if op == "V" then
		ArtPad:OnPeerVersion(msg:sub(2), sender)
		return
	end
	if not ArtPad:ValidateSender(sender) then return end

	if op == "S" then
		local seq, seg, dur, kind, style, pts = msg:match("^S([^,]+),([^,]+),([^,]+),(%a),([^,]+),(.+)$")
		if seq then
			self:ReceivedStroke(sender, seq, seg, dur, kind, style, pts)
		end
	elseif op == "T" then
		local seq, style, pt, text = msg:match("^T([^,]+),([^,]+),([^,]+),(.+)$")
		if not seq then return end
		local id = sender .. ":" .. seq
		local run = Codec.DecodePoints(pt)
		if Strokes:IsDead(id) or Strokes:Get(id) or not run then return end
		local s = Strokes:New(id, sender, "t", style, GetServerTime())
		if not s then return end
		s.text = Codec.SanitizeText(text)
		Strokes:AddRun(s, run)
		Canvas:RenderStroke(s)
		ArtPad:NotifyActivity(sender)
	elseif op == "E" then
		for id in msg:sub(2):gmatch("[^;]+") do
			Strokes:Remove(id)
		end
	elseif op == "C" then
		Strokes:Clear(GetServerTime())
		ArtPad:Print(Ambiguate(sender, "short") .. " cleared the canvas.")
	end
end

-- [[ Catch-up for people who log in to (or come back to) a big canvas ]]
--[[
	1. Joiner broadcasts Q<since>,<digest>: how up to date it is (newest
	   stroke/erase time it knows of; the canvas is saved between sessions)
	   plus a per-bucket fingerprint of the strokes it has.
	2. Peers whisper an offer A<clearedAt>,<total>,<mode>,<counts>:
	   mode "d" = I have changes newer than <since> (new strokes, erases),
	   mode "f" = nothing new, but some buckets differ (older gaps).
	3. Joiner splits the buckets over up to MAX_SOURCES peers (the throttle
	   is per sender, so more senders = faster) and whispers each one
	   R<mode><since>,<bucket mask>.
	4. Each source streams D<chunk> messages, newest first, then F. Chunks
	   are merged as they arrive, so the canvas fills in progressively.
	5. Another round runs afterwards to fill remaining gaps or replace
	   sources that went quiet, up to MAX_ROUNDS.
--]]
local MAX_SOURCES = 6
local CHUNK_CHARS = 1800
local CATCHUP_TIMEOUT = 30
local MAX_ROUNDS = 3
local SINCE_MARGIN = 10 -- seconds; stroke times differ slightly between clients

function Sync:RequestSnapshot(followUp)
	if self.catchup or self.offers then return end
	local dist = self:Distribution()
	if not dist or self:InLockdown() then return end
	self.rounds = followUp and (self.rounds or 0) + 1 or 1
	local since = 0
	if Strokes:Count() > 0 or next(Strokes.tombstones) then
		since = math.max(0, Strokes:HighWater() - SINCE_MARGIN)
	end
	self.offers = {}
	self:SendCommMessage(SNAP_PREFIX, "Q" .. Codec.EncodeInt(since) .. "," .. Strokes:Digest(), dist, nil, "NORMAL")
	C_Timer.After(OFFER_WINDOW, function() self:PickOffers(since) end)
end

function Sync:PickOffers(since)
	local all = self.offers
	self.offers = nil
	if not all or #all == 0 then
		ArtPad:Debug("canvas is up to date (no offers)")
		return
	end
	for _, offer in ipairs(all) do
		Strokes:ClearBefore(offer.cleared)
	end
	-- New changes first; older gaps get filled in a following round.
	local mode = "f"
	for _, offer in ipairs(all) do
		if offer.mode == "d" then mode = "d" end
	end
	local offers = {}
	for _, offer in ipairs(all) do
		if offer.mode == mode then offers[#offers + 1] = offer end
	end
	table.sort(offers, function(a, b) return a.total > b.total end)

	local sources = {}
	for i = 1, math.min(MAX_SOURCES, #offers) do
		sources[i] = { name = offers[i].name, counts = offers[i].counts, buckets = {}, expected = 0, received = 0 }
	end
	-- Give each differing bucket to the least loaded source that has it.
	for b = 0, Strokes.BUCKETS - 1 do
		local best
		for _, src in ipairs(sources) do
			if src.counts[b] > 0 and (not best or src.expected < best.expected) then
				best = src
			end
		end
		if best then
			best.buckets[b] = true
			best.expected = best.expected + best.counts[b]
		end
	end

	local catchup = { sources = {}, expected = 0, received = 0, added = 0 }
	local now = GetTime()
	for _, src in ipairs(sources) do
		if src.expected > 0 then
			local mask = {}
			for b = 0, Strokes.BUCKETS - 1 do mask[b + 1] = src.buckets[b] and "1" or "0" end
			src.last = now
			catchup.sources[src.name] = src
			catchup.expected = catchup.expected + src.expected
			self:SendCommMessage(SNAP_PREFIX, "R" .. mode .. Codec.EncodeInt(since) .. "," .. table.concat(mask),
				"WHISPER", src.name, "ALERT")
			ArtPad:Debug("requesting", src.expected, "records from", src.name, "mode", mode)
		end
	end
	if catchup.expected > 0 then
		self.catchup = catchup
		self:UpdateCatchupStatus()
	end
end

function Sync:UpdateCatchupStatus()
	local c = self.catchup
	if c then
		ArtPad.UI:SetStatus(("Catching up... %d%%"):format(math.min(99, math.floor(c.received / c.expected * 100))))
	else
		ArtPad.UI:SetStatus(nil)
	end
end

function Sync:FinishCatchup()
	local c = self.catchup
	self.catchup = nil
	local failed = false
	for _, src in pairs(c.sources) do
		if not src.done then failed = true end
	end
	ArtPad:Debug(("catch-up finished: %d strokes added, %d/%d records%s"):format(
		c.added, c.received, c.expected, failed and ", some sources timed out" or ""))
	self:UpdateCatchupStatus()
	-- Check again: fills older gaps after a delta, or replaces silent sources.
	if (failed or c.received > 0) and (self.rounds or 1) < MAX_ROUNDS then
		self:RequestSnapshot(true)
	end
end

function Sync:CheckCatchup(now)
	local c = self.catchup
	if not c then return end
	local pending = false
	for _, src in pairs(c.sources) do
		if not src.done then
			if now - src.last > CATCHUP_TIMEOUT then
				src.timedOut = true
			else
				pending = true
			end
		end
	end
	if not pending then self:FinishCatchup() end
end

function Sync:SendCatchup(target, buckets, since)
	local records = Strokes:Records(buckets, since)
	local header = Codec.EncodeInt(Strokes.clearedAt)
	local chunk, size, chunks = {}, 0, 0
	local function flush()
		if #chunk == 0 then return end
		self:SendCommMessage(SNAP_PREFIX, "D" .. Codec.Pack(header .. "~" .. table.concat(chunk, "~")), "WHISPER", target, "BULK")
		chunks = chunks + 1
		chunk, size = {}, 0
	end
	for _, rec in ipairs(records) do
		chunk[#chunk + 1] = rec
		size = size + #rec + 1
		if size >= CHUNK_CHARS then flush() end
	end
	flush()
	self:SendCommMessage(SNAP_PREFIX, "F", "WHISPER", target, "BULK")
	ArtPad:Debug("sending", #records, "records to", target, "in", chunks, "chunks")
end

function Sync:OnSnapMessage(prefix, msg, dist, sender)
	if isSecret(msg) or isSecret(sender) or isSecret(dist) then return end
	if type(msg) ~= "string" or type(sender) ~= "string" then return end
	sender = ArtPad:NormalizeName(sender)
	if sender == ArtPad.me then return end
	local op = msg:sub(1, 1)
	local now = GetTime()

	if op == "Q" and self:AcceptsDistribution(dist) then
		if self:InLockdown() or now - (self.lastOffer[sender] or 0) < 10 then return end
		local since, digest = msg:match("^Q([^,]+),(.+)$")
		since = Codec.DecodeInt(since or "")
		if not since then return end
		local mode, counts = Strokes:PlanCatchup(digest, since)
		if not mode then return end
		self.lastOffer[sender] = now
		local out = {}
		for b = 0, Strokes.BUCKETS - 1 do
			out[b + 1] = Codec.EncodeFixed(math.min(counts[b], 4095), 2)
		end
		self:SendCommMessage(SNAP_PREFIX, table.concat({ "A" .. Codec.EncodeInt(Strokes.clearedAt),
			Codec.EncodeInt(Strokes:Count()), mode, table.concat(out) }, ","), "WHISPER", sender, "NORMAL")
	elseif op == "A" and dist == "WHISPER" and self.offers then
		local cleared, total, mode, countStr = msg:match("^A([^,]+),([^,]+),([df]),(.+)$")
		cleared, total = Codec.DecodeInt(cleared or ""), Codec.DecodeInt(total or "")
		if not cleared or not total or not countStr or #countStr ~= Strokes.BUCKETS * 2 then return end
		local counts = {}
		for b = 0, Strokes.BUCKETS - 1 do
			counts[b] = Codec.DecodeFixed(countStr:sub(b * 2 + 1, b * 2 + 2)) or 0
		end
		self.offers[#self.offers + 1] = { name = sender, cleared = cleared, total = total, mode = mode, counts = counts }
	elseif op == "R" and dist == "WHISPER" then
		if self:InLockdown() or now - (self.lastSnapshotSent[sender] or 0) < 20 then return end
		local mode, since, mask = msg:match("^R([df])([^,]+),(.+)$")
		since = Codec.DecodeInt(since or "")
		if not since or #mask ~= Strokes.BUCKETS then return end
		self.lastSnapshotSent[sender] = now
		local buckets = {}
		for b = 0, Strokes.BUCKETS - 1 do
			if mask:sub(b + 1, b + 1) == "1" then buckets[b] = true end
		end
		self:SendCatchup(sender, buckets, mode == "d" and since or nil)
	elseif (op == "D" or op == "F") and dist == "WHISPER" then
		local c = self.catchup
		local src = c and c.sources[sender]
		if not src then return end
		src.last = now
		if op == "F" then
			src.done = true
			self:CheckCatchup(now)
			return
		end
		local data = Codec.Unpack(msg:sub(2))
		if not data then
			ArtPad:Debug("could not unpack catch-up data from", sender)
			return
		end
		local added, seen = Strokes:Merge(data)
		src.received = src.received + seen
		c.received = c.received + seen
		c.added = c.added + added
		if added > 0 and not Canvas:IsShown() then
			ArtPad:SetLauncherActive(true)
		end
		self:UpdateCatchupStatus()
	end
end
