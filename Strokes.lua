--[[
	ArtPad - Strokes
	The canvas data model. Every stroke has a globally unique id
	("Author-Realm:seq") so peers can erase, merge and sync without caring
	about the order things arrived in.

	stroke = {
		id, author, kind ("f" freehand, "l" line, "r" rect, "e" ellipse, "a" arrow, "t" text),
		style (encoded), r, g, b, a, w, t (server time),
		runs = { {x,y,x,y,...}, ... }   -- what was sent over the wire
		draw = { ... }                  -- what gets rendered (shapes expand)
		text, minx, miny, maxx, maxy, objs (render objects, owned by Canvas)
	}
--]]
local _, ArtPad = ...
local Codec = ArtPad.Codec

local Strokes = {
	byId = {},
	order = {},
	tombstones = {},
	clearedAt = 0,
}
ArtPad.Strokes = Strokes

Strokes.MAX_STROKES = 3000
Strokes.MAX_TOMBSTONES = 2000
-- Strokes are spread over buckets by id hash so peers can compare canvases
-- cheaply and only resend the buckets that differ.
Strokes.BUCKETS = 32

local huge, min, max, sqrt, cos, sin, pi = math.huge, math.min, math.max, math.sqrt, math.cos, math.sin, math.pi

-- [[ Shape geometry ]]
local function ellipseRun(x1, y1, x2, y2)
	local cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
	local rx, ry = math.abs(x2 - x1) / 2, math.abs(y2 - y1) / 2
	local segments = max(16, min(72, math.floor((rx + ry) / 4)))
	local run = {}
	for i = 0, segments do
		local t = i / segments * 2 * pi
		run[#run + 1] = cx + rx * cos(t)
		run[#run + 1] = cy + ry * sin(t)
	end
	return run
end

function Strokes.ShapeRuns(kind, x1, y1, x2, y2, w)
	if kind == "l" then
		return { { x1, y1, x2, y2 } }
	elseif kind == "r" then
		return { { x1, y1, x2, y1, x2, y2, x1, y2, x1, y1 } }
	elseif kind == "e" then
		return { ellipseRun(x1, y1, x2, y2) }
	elseif kind == "a" then
		local dx, dy = x2 - x1, y2 - y1
		local len = sqrt(dx * dx + dy * dy)
		if len == 0 then return { { x1, y1, x2, y2 } } end
		local head = min(len * 0.4, 14 + (w or 2) * 3)
		local vx, vy = -dx / len, -dy / len
		local c, s = cos(0.5), sin(0.5)
		local lx, ly = x2 + head * (vx * c - vy * s), y2 + head * (vx * s + vy * c)
		local rx, ry = x2 + head * (vx * c + vy * s), y2 + head * (-vx * s + vy * c)
		return { { x1, y1, x2, y2 }, { lx, ly, x2, y2, rx, ry } }
	end
	return {}
end

local VALID_KINDS = { f = true, l = true, r = true, e = true, a = true, t = true }
Strokes.VALID_KINDS = VALID_KINDS

-- [[ Model ]]
function Strokes:Get(id)
	return self.byId[id]
end

function Strokes:Count()
	return #self.order
end

function Strokes:IsDead(id, t)
	return self.tombstones[id] or (t and t < self.clearedAt)
end

function Strokes:New(id, author, kind, style, t)
	if self.byId[id] or not VALID_KINDS[kind] then return nil end
	local r, g, b, a, w = Codec.DecodeStyle(style)
	if not r then return nil end
	local hash = Codec.Hash(id)
	local s = {
		id = id, author = author, kind = kind, style = style,
		hash = hash, bucket = hash % self.BUCKETS,
		r = r, g = g, b = b, a = a, w = w,
		t = t or GetServerTime(),
		runs = {}, draw = {},
		minx = huge, miny = huge, maxx = -huge, maxy = -huge,
	}
	self.byId[id] = s
	self.order[#self.order + 1] = s
	-- Keep memory and sync size bounded: forget the oldest strokes locally.
	while #self.order > self.MAX_STROKES do
		local old = table.remove(self.order, 1)
		self.byId[old.id] = nil
		old.removed = true
		ArtPad.Canvas:ReleaseStroke(old)
	end
	return s
end

local function extendBounds(s, run)
	for i = 1, #run - 1, 2 do
		local x, y = run[i], run[i + 1]
		if x < s.minx then s.minx = x end
		if x > s.maxx then s.maxx = x end
		if y < s.miny then s.miny = y end
		if y > s.maxy then s.maxy = y end
	end
end

function Strokes:AddRun(s, run)
	s.runs[#s.runs + 1] = run
	if s.kind == "f" then
		s.draw[#s.draw + 1] = run
		extendBounds(s, run)
	elseif s.kind == "t" then
		-- Text bounds are set by the canvas once it knows the string size.
		s.minx, s.miny, s.maxx, s.maxy = run[1], run[2], run[1], run[2]
	else
		s.draw = Strokes.ShapeRuns(s.kind, run[1], run[2], run[3], run[4], s.w)
		for _, r in ipairs(s.draw) do extendBounds(s, r) end
	end
	return run
end

-- Tombstones remember erased ids (with erase time) so late segments and
-- catch-up data can't bring them back, and so erases reach people who were offline.
function Strokes:Remove(id, t)
	self.tombstones[id] = math.max(self.tombstones[id] or 0, t or GetServerTime())
	local s = self.byId[id]
	if not s then return false end
	self.byId[id] = nil
	for i = #self.order, 1, -1 do
		if self.order[i] == s then
			table.remove(self.order, i)
			break
		end
	end
	s.removed = true
	ArtPad.Canvas:ReleaseStroke(s)
	return true
end

function Strokes:Clear(t)
	for _, s in ipairs(self.order) do
		s.removed = true
		ArtPad.Canvas:ReleaseStroke(s)
	end
	wipe(self.byId)
	wipe(self.order)
	self.clearedAt = max(self.clearedAt, t or GetServerTime())
	self:PruneTombstones()
end

-- Drops tombstones made redundant by a clear, then the oldest beyond the cap.
function Strokes:PruneTombstones()
	local list = {}
	for id, t in pairs(self.tombstones) do
		if t < self.clearedAt then
			self.tombstones[id] = nil
		else
			list[#list + 1] = id
		end
	end
	if #list > self.MAX_TOMBSTONES then
		table.sort(list, function(a, b) return self.tombstones[a] < self.tombstones[b] end)
		for i = 1, #list - self.MAX_TOMBSTONES do
			self.tombstones[list[i]] = nil
		end
	end
end

-- Remove all strokes older than t (used when a peer cleared after we did).
function Strokes:ClearBefore(t)
	if t <= self.clearedAt then return end
	for i = #self.order, 1, -1 do
		local s = self.order[i]
		if s.t < t then
			table.remove(self.order, i)
			self.byId[s.id] = nil
			s.removed = true
			ArtPad.Canvas:ReleaseStroke(s)
		end
	end
	self.clearedAt = t
	self:PruneTombstones()
end

-- [[ Hit testing ]]
local function distSqToSegment(px, py, ax, ay, bx, by)
	local dx, dy = bx - ax, by - ay
	local len2 = dx * dx + dy * dy
	local t = 0
	if len2 > 0 then
		t = ((px - ax) * dx + (py - ay) * dy) / len2
		if t < 0 then t = 0 elseif t > 1 then t = 1 end
	end
	local cx, cy = ax + t * dx - px, ay + t * dy - py
	return cx * cx + cy * cy
end

function Strokes:HitTest(x, y, radius)
	local hits = {}
	for i = #self.order, 1, -1 do
		local s = self.order[i]
		local pad = radius + s.w / 2
		if x >= s.minx - pad and x <= s.maxx + pad and y >= s.miny - pad and y <= s.maxy + pad then
			if s.kind == "t" then
				hits[#hits + 1] = s
			else
				local pad2 = pad * pad
				local hit = false
				for _, run in ipairs(s.draw) do
					if #run == 2 then
						hit = distSqToSegment(x, y, run[1], run[2], run[1], run[2]) <= pad2
					else
						for j = 3, #run - 1, 2 do
							if distSqToSegment(x, y, run[j - 2], run[j - 1], run[j], run[j + 1]) <= pad2 then
								hit = true
								break
							end
						end
					end
					if hit then break end
				end
				if hit then hits[#hits + 1] = s end
			end
		end
	end
	return hits
end

-- [[ Serialization (persistence + catch-up) ]]
-- "<clearedAt>~<record>~<record>..."
--   stroke record:    id^kind^style^time^runs^text
--   tombstone record: id^-^^time
local function serializeStroke(s)
	return table.concat({ s.id, s.kind, s.style, Codec.EncodeInt(s.t), Codec.EncodeRuns(s.runs), s.text or "" }, "^")
end

function Strokes.BucketOf(id)
	return Codec.Hash(id) % Strokes.BUCKETS
end

-- Newest stroke/erase time we know of: "I'm up to date until about here".
function Strokes:HighWater()
	local t = self.clearedAt
	for _, s in ipairs(self.order) do
		if s.t > t then t = s.t end
	end
	for _, et in pairs(self.tombstones) do
		if et > t then t = et end
	end
	return t
end

-- Calls fn(bucket, time, stroke or nil, id) for every stroke and tombstone.
function Strokes:EachRecord(fn)
	for _, s in ipairs(self.order) do
		if #s.runs > 0 then fn(s.bucket, s.t, s, s.id) end
	end
	for id, t in pairs(self.tombstones) do
		fn(self.BucketOf(id), t, nil, id)
	end
end

-- Serialized records for the given buckets (set of bucket -> true, nil = all)
-- newer than `since` (optional), newest first so catch-up shows the most
-- recent drawing first.
function Strokes:Records(buckets, since)
	local items = {}
	self:EachRecord(function(bucket, t, s, id)
		if (not buckets or buckets[bucket]) and (not since or t > since) then
			items[#items + 1] = { t = t, s = s, id = id }
		end
	end)
	table.sort(items, function(a, b) return a.t > b.t end)
	local records = {}
	for i, item in ipairs(items) do
		records[i] = item.s and serializeStroke(item.s) or (item.id .. "^-^^" .. Codec.EncodeInt(item.t))
	end
	return records
end

function Strokes:Serialize()
	self:PruneTombstones()
	local records = self:Records()
	table.insert(records, 1, Codec.EncodeInt(self.clearedAt))
	return table.concat(records, "~")
end

-- Per-bucket fingerprint of which strokes we have:
-- "<clearedAt>,<3 chars per bucket>" (sum of id hashes, order independent).
function Strokes:Digest()
	local sums = {}
	for b = 0, self.BUCKETS - 1 do sums[b] = 0 end
	for _, s in ipairs(self.order) do
		if #s.runs > 0 then
			sums[s.bucket] = (sums[s.bucket] + s.hash) % 262144
		end
	end
	local out = {}
	for b = 0, self.BUCKETS - 1 do
		out[b + 1] = Codec.EncodeFixed(sums[b], 3)
	end
	return Codec.EncodeInt(self.clearedAt) .. "," .. table.concat(out)
end

-- Decides what we could send to someone with the given digest and high water mark.
-- Returns nil if nothing, else mode and counts[bucket] (records we'd send):
--   "d" (delta): everything newer than `since` - what changed while they were away
--   "f" (full):  whole buckets whose fingerprint differs - fills older gaps
function Strokes:PlanCatchup(digest, since)
	local clearedStr, sumsStr = (digest or ""):match("^([^,]+),(.+)$")
	local theirCleared = Codec.DecodeInt(clearedStr or "")
	if not theirCleared or not sumsStr or #sumsStr ~= self.BUCKETS * 3 then return nil end
	if theirCleared > self.clearedAt then return nil end -- we are the stale one

	-- Buckets with an identical fingerprint hold exactly the same strokes.
	local mine = self:Digest():match(",(.+)$")
	local differs = {}
	for b = 0, self.BUCKETS - 1 do
		local i = b * 3 + 1
		differs[b] = theirCleared < self.clearedAt or sumsStr:sub(i, i + 2) ~= mine:sub(i, i + 2)
	end

	local delta, full = {}, {}
	for b = 0, self.BUCKETS - 1 do delta[b], full[b] = 0, 0 end
	self:EachRecord(function(bucket, t)
		if differs[bucket] then
			full[bucket] = full[bucket] + 1
			if t > since then delta[bucket] = delta[bucket] + 1 end
		end
	end)

	local anyDelta = false
	for b = 0, self.BUCKETS - 1 do
		if delta[b] > 0 then anyDelta = true end
	end
	if anyDelta then return "d", delta end

	local counts, any = full, false
	for b = 0, self.BUCKETS - 1 do
		if counts[b] > 0 then any = true end
	end
	if not any and theirCleared == self.clearedAt then return nil end
	return "f", counts
end

local function split(s, sep)
	local out = {}
	for field in string.gmatch(s .. sep, "(.-)" .. sep:gsub("%p", "%%%0")) do
		out[#out + 1] = field
	end
	return out
end

-- Merges serialized data into the canvas.
-- Returns strokes added and records seen (for progress).
function Strokes:Merge(data)
	if type(data) ~= "string" or data == "" then return 0, 0 end
	local records = split(data, "~")
	local remoteCleared = Codec.DecodeInt(records[1]) or 0
	self:ClearBefore(remoteCleared)
	local added = 0
	for i = 2, #records do
		local f = split(records[i], "^")
		local id, kind, style, t, runs, text = f[1], f[2], f[3], Codec.DecodeInt(f[4] or ""), f[5], f[6]
		if kind == "-" then
			if id and t and t >= self.clearedAt then
				self:Remove(id, t)
			end
		elseif id and id:find(":", 1, true) and t and not self.byId[id] and not self:IsDead(id, t) then
			local author = id:match("^(.*):[^:]+$")
			local s = self:New(id, author, kind, style, t)
			if s then
				local decoded = Codec.DecodeRuns(runs)
				if kind == "t" then
					s.text = Codec.SanitizeText(text)
				end
				for _, run in ipairs(decoded) do
					if kind == "f" or (kind == "t" and #run >= 2) or #run >= 4 then
						self:AddRun(s, run)
					end
				end
				if #s.runs == 0 or (kind == "t" and s.text == "") then
					self:Remove(id)
					self.tombstones[id] = nil
				else
					ArtPad.Canvas:RenderStroke(s)
					added = added + 1
				end
			end
		end
	end
	return added, #records - 1
end
