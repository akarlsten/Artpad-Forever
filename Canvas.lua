--[[
	ArtPad - Canvas
	The fullscreen drawing surface: input capture and rendering.
	Strokes are drawn with pooled Line objects (plus round dots for thick brushes).
--]]
local _, ArtPad = ...
local Codec, Strokes = ArtPad.Codec, ArtPad.Strokes

local Canvas = {
	linePool = {},
	dotPool = {},
	textPool = {},
	preview = {},
	playback = {},
	cursors = {},
	tool = "pen",
}
ArtPad.Canvas = Canvas

Canvas.WIDTH, Canvas.HEIGHT = 3840, 2160
local DOT_TEXTURE = "Interface\\AddOns\\ArtPad\\circle"
local MIN_MOVE = 2          -- px between captured freehand points
local MAX_PLAYBACK = 3      -- seconds; never replay a segment slower than this
local CURSOR_TIMEOUT = 1.5

local floor, min, max, sqrt = math.floor, math.min, math.max, math.sqrt
local tremove = table.remove

-- [[ Setup ]]
function Canvas:Init(settings)
	-- No parent: the canvas stays visible when the UI is hidden (Alt+Z), like the original.
	local f = CreateFrame("Frame", "ArtPadCanvas", nil)
	self.frame = f
	f:SetFrameStrata("BACKGROUND")
	f:SetSize(self.WIDTH, self.HEIGHT)
	f:SetScale(settings.Scale or 1)
	f:SetPoint("CENTER")
	f:SetMovable(true)
	f:SetClampedToScreen(false)
	f:Hide()

	self.background = f:CreateTexture(nil, "BACKGROUND")
	self.background:SetColorTexture(0, 0, 0, 0.5)
	self.background:SetAllPoints()

	local function border(p1, p2, w, h)
		local t = f:CreateTexture(nil, "BORDER")
		t:SetColorTexture(1, 1, 1, 0.7)
		t:SetPoint(p1)
		t:SetPoint(p2)
		if w then t:SetWidth(w) end
		if h then t:SetHeight(h) end
	end
	border("TOPLEFT", "TOPRIGHT", nil, 5)
	border("BOTTOMLEFT", "BOTTOMRIGHT", nil, 5)
	border("TOPLEFT", "BOTTOMLEFT", 5, nil)
	border("TOPRIGHT", "BOTTOMRIGHT", 5, nil)

	f:EnableMouse(true)
	f:EnableMouseWheel(true)
	f:EnableKeyboard(true)
	f:SetScript("OnMouseDown", function(_, button) self:OnMouseDown(button) end)
	f:SetScript("OnMouseUp", function(_, button) self:OnMouseUp(button) end)
	f:SetScript("OnMouseWheel", function(_, delta) self:OnMouseWheel(delta) end)
	f:SetScript("OnKeyDown", function(_, key) self:OnKeyDown(key) end)
	f:SetScript("OnUpdate", function(_, elapsed) self:OnUpdate(elapsed) end)
	f:SetScript("OnShow", function() self:OnShow() end)
	f:SetScript("OnHide", function() self:OnHide() end)
end

function Canvas:IsShown()
	return self.frame and self.frame:IsShown()
end

function Canvas:SetArtMode(on)
	self.artMode = on
	self.frame:SetFrameStrata(on and "FULLSCREEN" or "BACKGROUND")
	self.background:SetColorTexture(0, 0, 0, on and 1 or 0.5)
	ArtPad.UI:SetArtMode(on)
end

function Canvas:Recenter()
	self.frame:ClearAllPoints()
	self.frame:SetPoint("CENTER")
end

-- [[ Render objects ]]
local function release(self, obj)
	obj:Hide()
	obj:ClearAllPoints()
	local kind = obj:GetObjectType()
	if kind == "Line" then
		self.linePool[#self.linePool + 1] = obj
	elseif kind == "FontString" then
		self.textPool[#self.textPool + 1] = obj
	else
		self.dotPool[#self.dotPool + 1] = obj
	end
end

function Canvas:DrawSegment(s, objs, x1, y1, x2, y2)
	local f = self.frame
	local l = tremove(self.linePool) or f:CreateLine(nil, "ARTWORK")
	l:SetColorTexture(s.r, s.g, s.b, s.a)
	l:SetThickness(s.w)
	l:SetStartPoint("BOTTOMLEFT", f, x1, y1)
	l:SetEndPoint("BOTTOMLEFT", f, x2, y2)
	l:Show()
	objs[#objs + 1] = l
end

function Canvas:DrawDot(s, objs, x, y, size)
	local f = self.frame
	local t = tremove(self.dotPool)
	if not t then
		t = f:CreateTexture(nil, "ARTWORK")
		t:SetTexture(DOT_TEXTURE)
	end
	t:SetVertexColor(s.r, s.g, s.b, s.a)
	t:SetSize(size, size)
	t:SetPoint("CENTER", f, "BOTTOMLEFT", x, y)
	t:Show()
	objs[#objs + 1] = t
end

-- Draws points [from, to] of a run (1-based point indices), with the
-- segment leading into each point. Thick brushes get round joints.
function Canvas:DrawRunRange(s, run, from, to, objs)
	objs = objs or s.objs
	if not objs then
		objs = {}
		s.objs = objs
	end
	local n = #run / 2
	if n == 1 then
		self:DrawDot(s, objs, run[1], run[2], max(s.w, 3))
		return
	end
	local round = s.w >= 4
	for i = max(from, 1), min(to, n) do
		local x, y = run[i * 2 - 1], run[i * 2]
		if i > 1 then
			self:DrawSegment(s, objs, run[i * 2 - 3], run[i * 2 - 2], x, y)
		end
		if round then
			self:DrawDot(s, objs, x, y, s.w)
		end
	end
end

function Canvas:RenderText(s)
	local fs = tremove(self.textPool) or self.frame:CreateFontString(nil, "OVERLAY")
	local x, y = s.runs[1][1], s.runs[1][2]
	fs:SetFont(STANDARD_TEXT_FONT, min(8 + s.w * 2, 64), "")
	fs:SetJustifyH("LEFT")
	fs:SetTextColor(s.r, s.g, s.b, s.a)
	fs:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", x, y)
	fs:SetText(s.text)
	fs:Show()
	s.objs = s.objs or {}
	s.objs[#s.objs + 1] = fs
	s.minx, s.miny = x, y
	s.maxx, s.maxy = x + fs:GetStringWidth(), y + fs:GetStringHeight()
end

function Canvas:RenderStroke(s)
	self:ReleaseStroke(s)
	if s.removed then return end
	if s.kind == "t" then
		self:RenderText(s)
		return
	end
	for _, run in ipairs(s.draw) do
		self:DrawRunRange(s, run, 1, #run / 2)
	end
end

function Canvas:ReleaseStroke(s)
	if s.objs then
		for _, obj in ipairs(s.objs) do
			release(self, obj)
		end
		s.objs = nil
	end
end

-- [[ Local preview (not yet committed to the model) ]]
function Canvas:PreviewSegment(style, x1, y1, x2, y2)
	self:DrawSegment(style, self.preview, x1, y1, x2, y2)
	if style.w >= 4 then
		self:DrawDot(style, self.preview, x2, y2, style.w)
	end
end

function Canvas:PreviewRuns(style, runs)
	self:ClearPreview()
	for _, run in ipairs(runs) do
		self:DrawRunRange(style, run, 1, #run / 2, self.preview)
	end
end

function Canvas:ClearPreview()
	for i = #self.preview, 1, -1 do
		release(self, self.preview[i])
		self.preview[i] = nil
	end
end

-- [[ Remote playback: draw received segments progressively so they look live ]]
function Canvas:PlayRun(s, run, durationMs)
	local n = #run / 2
	if not self:IsShown() or not durationMs or durationMs <= 0 or n < 3 then
		self:DrawRunRange(s, run, 1, n)
		if self:IsShown() then
			self:ShowCursor(s, run[#run - 1], run[#run])
		end
		return
	end
	local now = GetTime()
	local start = max(now, s.playEnd or 0)
	local duration = min(durationMs / 1000, MAX_PLAYBACK)
	s.playEnd = start + duration
	self.playback[#self.playback + 1] = { s = s, run = run, start = start, duration = duration, done = 0 }
end

function Canvas:UpdatePlayback(now)
	local queue = self.playback
	local i = 1
	while i <= #queue do
		local item = queue[i]
		local s, run = item.s, item.run
		local n = #run / 2
		if s.removed then
			tremove(queue, i)
		else
			if now >= item.start then
				local progress = (now - item.start) / item.duration
				local target = min(n, floor(progress * (n - 1)) + 1)
				if target > item.done then
					self:DrawRunRange(s, run, item.done + 1, target)
					item.done = target
					self:ShowCursor(s, run[target * 2 - 1], run[target * 2])
				end
			end
			if item.done >= n then
				tremove(queue, i)
			else
				i = i + 1
			end
		end
	end
end

function Canvas:FlushPlayback()
	for i = #self.playback, 1, -1 do
		local item = self.playback[i]
		if not item.s.removed then
			self:DrawRunRange(item.s, item.run, item.done + 1, #item.run / 2)
		end
		item.s.playEnd = nil
		self.playback[i] = nil
	end
end

-- [[ Remote cursors: name tags following whoever is drawing ]]
function Canvas:ShowCursor(s, x, y)
	local author = s.author
	if not author or author == ArtPad.me then return end
	local c = self.cursors[author]
	if not c then
		c = {}
		c.dot = self.frame:CreateTexture(nil, "OVERLAY")
		c.dot:SetTexture(DOT_TEXTURE)
		c.dot:SetSize(10, 10)
		c.label = self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		c.label:SetText(Ambiguate(author, "short"))
		self.cursors[author] = c
	end
	c.dot:SetVertexColor(s.r, s.g, s.b, 1)
	c.dot:ClearAllPoints()
	c.dot:SetPoint("CENTER", self.frame, "BOTTOMLEFT", x, y)
	c.label:ClearAllPoints()
	c.label:SetPoint("BOTTOMLEFT", c.dot, "TOPRIGHT", 2, 0)
	c.dot:Show()
	c.label:Show()
	c.last = GetTime()
end

function Canvas:UpdateCursors(now)
	for _, c in pairs(self.cursors) do
		if c.last and now - c.last > CURSOR_TIMEOUT then
			c.dot:Hide()
			c.label:Hide()
			c.last = nil
		end
	end
end

-- [[ Input ]]
function Canvas:CursorPosition()
	local f = self.frame
	local left, bottom = f:GetLeft(), f:GetBottom()
	if not left then return nil end
	local scale = f:GetEffectiveScale()
	local mx, my = GetCursorPosition()
	local x = Codec.ClampCoord(min(max(mx / scale - left, 0), self.WIDTH))
	local y = Codec.ClampCoord(min(max(my / scale - bottom, 0), self.HEIGHT))
	return x, y
end

function Canvas:SetTool(tool)
	self.tool = tool
	self.pendingText = nil
	ArtPad.UI:UpdateTool(tool)
end

function Canvas:SetPendingText(text)
	self.pendingText = text
end

function Canvas:OnMouseDown(button)
	if self.state then return end
	if IsShiftKeyDown() then
		self.frame:StartMoving()
		self.state = "MOVE"
		return
	end
	local x, y = self:CursorPosition()
	if not x then return end
	if button == "LeftButton" then
		if self.pendingText then
			ArtPad.Sync:PlaceText(x, y, self.pendingText)
			self.pendingText = nil
		elseif self.tool == "pen" then
			ArtPad.Sync:BeginFreehand(x, y)
			self.state = "PAINT"
			self.lastX, self.lastY = x, y
		elseif Strokes.VALID_KINDS[self.tool] then
			self.state = "SHAPE"
			self.shapeX, self.shapeY = x, y
			self.previewX, self.previewY = nil, nil
		end
	elseif button == "RightButton" then
		self.state = "ERASE"
		self.lastX, self.lastY = x, y
		ArtPad.Sync:EraseAt(x, y)
	end
end

function Canvas:EndInteraction()
	local state = self.state
	self.state = nil
	if state == "MOVE" then
		self.frame:StopMovingOrSizing()
	elseif state == "PAINT" then
		ArtPad.Sync:EndFreehand()
	elseif state == "SHAPE" then
		self:ClearPreview()
		local x, y = self:CursorPosition()
		if x then
			ArtPad.Sync:CommitShape(self.tool, self.shapeX, self.shapeY, x, y)
		end
	elseif state == "ERASE" then
		ArtPad.Sync:FlushErase()
	end
end

function Canvas:OnMouseUp()
	self:EndInteraction()
end

function Canvas:OnUpdate()
	local now = GetTime()
	self:UpdatePlayback(now)
	self:UpdateCursors(now)

	local state = self.state
	if state ~= "PAINT" and state ~= "SHAPE" and state ~= "ERASE" then return end
	local x, y = self:CursorPosition()
	if not x then return end

	if state == "PAINT" then
		local dx, dy = x - self.lastX, y - self.lastY
		if dx * dx + dy * dy >= MIN_MOVE * MIN_MOVE then
			ArtPad.Sync:FreehandPoint(x, y)
			self.lastX, self.lastY = x, y
		end
	elseif state == "SHAPE" then
		if x ~= self.previewX or y ~= self.previewY then
			self.previewX, self.previewY = x, y
			local style = ArtPad:CurrentStyleTable()
			self:PreviewRuns(style, Strokes.ShapeRuns(self.tool, self.shapeX, self.shapeY, x, y, style.w))
		end
	elseif state == "ERASE" then
		-- Interpolate so fast swipes don't skip strokes.
		local dx, dy = x - self.lastX, y - self.lastY
		local dist = sqrt(dx * dx + dy * dy)
		if dist > 0 then
			local step = max(ArtPad:EraserRadius() / 2, 1)
			local steps = math.ceil(dist / step)
			for i = 1, steps do
				ArtPad.Sync:EraseAt(self.lastX + dx * i / steps, self.lastY + dy * i / steps)
			end
			self.lastX, self.lastY = x, y
		end
	end
end

function Canvas:OnMouseWheel(delta)
	if IsControlKeyDown() then
		ArtPad:AdjustBrushSize(delta)
		return
	end
	-- Zoom around the cursor.
	local f = self.frame
	f:StopMovingOrSizing()
	local oldScale = f:GetScale()
	local newScale = oldScale + oldScale * 0.10 * delta
	if newScale >= 100 or newScale <= 0.05 then return end
	local mx, my = GetCursorPosition()
	local left, bottom = f:GetLeft() * oldScale, f:GetBottom() * oldScale
	local w, h = f:GetWidth() * oldScale, f:GetHeight() * oldScale
	local fx, fy = (mx - left) / w, (my - bottom) / h
	local newLeft = mx - fx * f:GetWidth() * newScale
	local newBottom = my - fy * f:GetHeight() * newScale
	f:SetScale(newScale)
	f:ClearAllPoints()
	f:SetPoint("BOTTOMLEFT", newLeft / newScale, newBottom / newScale)
end

function Canvas:OnKeyDown(key)
	if InCombatLockdown() then return end
	if key == "ESCAPE" then
		self.frame:SetPropagateKeyboardInput(false)
		if self.pendingText then
			self.pendingText = nil
		else
			ArtPad:Hide()
		end
	elseif key == "Z" and IsControlKeyDown() then
		self.frame:SetPropagateKeyboardInput(false)
		ArtPad.Sync:Undo()
	else
		self.frame:SetPropagateKeyboardInput(true)
	end
end

function Canvas:OnShow()
	ArtPad.UI:Show()
	ArtPad:SetLauncherActive(false)
end

function Canvas:OnHide()
	self:EndInteraction()
	self:ClearPreview()
	self:FlushPlayback()
	for _, c in pairs(self.cursors) do
		c.dot:Hide()
		c.label:Hide()
		c.last = nil
	end
	self.pendingText = nil
	ArtPad.UI:Hide()
end
