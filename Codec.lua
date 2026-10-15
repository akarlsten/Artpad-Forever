--[[
	ArtPad - Codec
	Compact, chat-safe text encoding for strokes.

	Alphabet is 64 printable characters (no "|", ",", ";", ":", "^", "~").
	Points:  first point absolute (2+2 chars, 12 bit each), then one char per
	         axis for deltas in [-31,31]. A delta that doesn't fit is written as
	         the escape char (index 0) followed by an absolute point.
	Style:   RRGGBBAA hex + one char brush width.
--]]
local _, ArtPad = ...

local Codec = {}
ArtPad.Codec = Codec

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC, DEC = {}, {}
for i = 1, 64 do
	local c = ALPHABET:sub(i, i)
	ENC[i - 1] = c
	DEC[c:byte()] = i - 1
end

local floor, byte, sub, concat = math.floor, string.byte, string.sub, table.concat

Codec.MAX_COORD = 4095
Codec.MAX_DELTA = 31

local function clampCoord(v)
	v = floor(v + 0.5)
	if v < 0 then return 0 end
	if v > 4095 then return 4095 end
	return v
end
Codec.ClampCoord = clampCoord

local function enc12(v)
	return ENC[floor(v / 64)] .. ENC[v % 64]
end

local function encPoint(x, y)
	return enc12(x) .. enc12(y)
end
Codec.EncodePoint = encPoint

-- Token that moves from (px,py) to (x,y); assumes both are clamped integers.
function Codec.EncodeStep(px, py, x, y)
	local dx, dy = x - px, y - py
	if dx >= -31 and dx <= 31 and dy >= -31 and dy <= 31 then
		return ENC[dx + 32] .. ENC[dy + 32]
	end
	return ENC[0] .. encPoint(x, y)
end

-- pts is a flat array {x1, y1, x2, y2, ...}
function Codec.EncodePoints(pts)
	local n = #pts
	if n < 2 then return "" end
	local out = {}
	local px, py = clampCoord(pts[1]), clampCoord(pts[2])
	out[1] = encPoint(px, py)
	for i = 3, n - 1, 2 do
		local x, y = clampCoord(pts[i]), clampCoord(pts[i + 1])
		out[#out + 1] = Codec.EncodeStep(px, py, x, y)
		px, py = x, y
	end
	return concat(out)
end

local function dec12(s, i)
	local a, b = DEC[byte(s, i)], DEC[byte(s, i + 1)]
	if not a or not b then return nil end
	return a * 64 + b
end

function Codec.DecodePoints(s)
	if type(s) ~= "string" or #s < 4 then return nil end
	local pts = {}
	local x, y = dec12(s, 1), dec12(s, 3)
	if not x or not y then return nil end
	pts[1], pts[2] = x, y
	local i, n = 5, #s
	while i <= n do
		local c = DEC[byte(s, i)]
		if c == nil then return nil end
		if c == 0 then
			if i + 4 > n then return nil end
			x, y = dec12(s, i + 1), dec12(s, i + 3)
			if not x or not y then return nil end
			i = i + 5
		else
			local d = DEC[byte(s, i + 1)]
			if not d then return nil end
			x, y = x + c - 32, y + d - 32
			i = i + 2
		end
		pts[#pts + 1] = x
		pts[#pts + 1] = y
	end
	return pts
end

-- Runs are lists of flat point arrays, encoded joined with ";"
function Codec.EncodeRuns(runs)
	local out = {}
	for i, run in ipairs(runs) do
		out[i] = Codec.EncodePoints(run)
	end
	return concat(out, ";")
end

function Codec.DecodeRuns(s)
	local runs = {}
	for part in string.gmatch(s or "", "[^;]+") do
		local pts = Codec.DecodePoints(part)
		if pts then runs[#runs + 1] = pts end
	end
	return runs
end

-- Variable length non-negative integers (used for sequence numbers, durations)
function Codec.EncodeInt(n)
	n = floor(n)
	if n <= 0 then return ENC[0] end
	local out = {}
	while n > 0 do
		table.insert(out, 1, ENC[n % 64])
		n = floor(n / 64)
	end
	return concat(out)
end

function Codec.DecodeInt(s)
	if type(s) ~= "string" or s == "" then return nil end
	local n = 0
	for i = 1, #s do
		local d = DEC[byte(s, i)]
		if not d then return nil end
		n = n * 64 + d
	end
	return n
end

-- Fixed width non-negative integers (6 bits per char)
function Codec.EncodeFixed(n, width)
	n = floor(n)
	local out = {}
	for i = width, 1, -1 do
		out[i] = ENC[n % 64]
		n = floor(n / 64)
	end
	return concat(out)
end
Codec.DecodeFixed = Codec.DecodeInt

-- Small, stable string hash (24 bit)
function Codec.Hash(s)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + byte(s, i)) % 16777216
	end
	return h
end

-- Style: color (0..1 floats) + width (1..63)
local function hexByte(v)
	v = floor((tonumber(v) or 0) * 255 + 0.5)
	if v < 0 then v = 0 elseif v > 255 then v = 255 end
	return string.format("%02x", v)
end

function Codec.EncodeStyle(r, g, b, a, w)
	w = floor(tonumber(w) or 2)
	if w < 1 then w = 1 elseif w > 63 then w = 63 end
	return hexByte(r) .. hexByte(g) .. hexByte(b) .. hexByte(a) .. ENC[w]
end

function Codec.DecodeStyle(s)
	if type(s) ~= "string" or #s ~= 9 then return nil end
	local r, g, b, a = tonumber(sub(s, 1, 2), 16), tonumber(sub(s, 3, 4), 16), tonumber(sub(s, 5, 6), 16), tonumber(sub(s, 7, 8), 16)
	local w = DEC[byte(s, 9)]
	if not (r and g and b and a and w) or w < 1 then return nil end
	return r / 255, g / 255, b / 255, a / 255, w
end

-- Free text can't contain our separators or chat escape characters.
function Codec.SanitizeText(text)
	text = tostring(text or "")
	text = text:gsub("[|,;:%^~\r\n\t]", " ")
	return sub(text, 1, 120)
end

-- Ramer-Douglas-Peucker on a flat point array, keeps first and last point.
function Codec.Simplify(pts, epsilon)
	local n = #pts / 2
	if n <= 2 then return pts end
	local keep = { [1] = true, [n] = true }
	local stack = { 1, n }
	local eps2 = epsilon * epsilon
	while #stack > 0 do
		local last = table.remove(stack)
		local first = table.remove(stack)
		local ax, ay = pts[first * 2 - 1], pts[first * 2]
		local bx, by = pts[last * 2 - 1], pts[last * 2]
		local dx, dy = bx - ax, by - ay
		local len2 = dx * dx + dy * dy
		local maxD, maxI = -1, nil
		for i = first + 1, last - 1 do
			local px, py = pts[i * 2 - 1], pts[i * 2]
			local d
			if len2 == 0 then
				d = (px - ax) ^ 2 + (py - ay) ^ 2
			else
				local cross = dx * (py - ay) - dy * (px - ax)
				d = cross * cross / len2
			end
			if d > maxD then maxD, maxI = d, i end
		end
		if maxI and maxD > eps2 then
			keep[maxI] = true
			stack[#stack + 1] = first
			stack[#stack + 1] = maxI
			stack[#stack + 1] = maxI
			stack[#stack + 1] = last
		end
	end
	local out = {}
	for i = 1, n do
		if keep[i] then
			out[#out + 1] = pts[i * 2 - 1]
			out[#out + 1] = pts[i * 2]
		end
	end
	return out
end

-- Optional compression for big payloads (snapshots). Falls back to plain text.
function Codec.Pack(text)
	local EU = C_EncodingUtil
	if EU and EU.CompressString and EU.EncodeBase64 and Enum and Enum.CompressionMethod then
		local ok, packed = pcall(function()
			return EU.EncodeBase64(EU.CompressString(text, Enum.CompressionMethod.Deflate))
		end)
		if ok and type(packed) == "string" and #packed < #text then
			return "1" .. packed
		end
	end
	return "0" .. text
end

function Codec.Unpack(data)
	if type(data) ~= "string" then return nil end
	local flag, body = sub(data, 1, 1), sub(data, 2)
	if flag == "0" then return body end
	if flag == "1" then
		local EU = C_EncodingUtil
		if not (EU and EU.DecompressString and EU.DecodeBase64) then return nil end
		local ok, text = pcall(function()
			return EU.DecompressString(EU.DecodeBase64(body), Enum.CompressionMethod.Deflate)
		end)
		if ok and type(text) == "string" then return text end
	end
	return nil
end
