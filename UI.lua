--[[
	ArtPad - UI
	Toolbar shown above the canvas.
--]]
local _, ArtPad = ...

local UI = { toolButtons = {} }
ArtPad.UI = UI

local PALETTE = {
	{ 1, 1, 1 }, { 0, 0, 0 }, { 0.9, 0.15, 0.15 }, { 1, 0.6, 0.1 },
	{ 1, 0.9, 0.2 }, { 0.2, 0.8, 0.25 }, { 0.2, 0.55, 1 }, { 0.7, 0.3, 0.9 },
}

local TOOLS = {
	{ key = "pen", label = "Pen", tip = "Freehand drawing" },
	{ key = "l", label = "Line", tip = "Straight line" },
	{ key = "r", label = "Box", tip = "Rectangle" },
	{ key = "e", label = "Circle", tip = "Ellipse" },
	{ key = "a", label = "Arrow", tip = "Arrow" },
}

local BUTTON_BG = { 0, 0, 0, 0.75 }
local BUTTON_SELECTED = { 0.15, 0.48, 0, 0.9 }

local function setTooltip(button, text)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText(text, 1, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)
end

local function makeButton(parent, text, onClick, tip)
	local b = CreateFrame("Button", nil, parent)
	b:SetNormalFontObject("GameFontNormal")
	b:SetHighlightFontObject("GameFontHighlight")
	b:SetText(text)
	b:SetSize(b:GetTextWidth() + 18, 24)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	b.bg:SetColorTexture(unpack(BUTTON_BG))
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(0.15, 0.48, 0, 0.5)
	b:SetScript("OnClick", onClick)
	if tip then setTooltip(b, tip) end
	return b
end

local function layoutRow(parent, items, y)
	local x = 0
	for _, item in ipairs(items) do
		item:ClearAllPoints()
		item:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
		x = x + item:GetWidth() + (item.gap or 2)
	end
	return x
end

function UI:Init()
	local bar = CreateFrame("Frame", "ArtPadToolbar", UIParent)
	self.bar = bar
	bar:SetPoint("TOP", UIParent, "TOP", 0, -40)
	bar:SetFrameStrata("HIGH")
	bar:SetClampedToScreen(true)
	bar:Hide()

	-- Row 1: tools, brush size, colors
	local row1 = {}
	for _, tool in ipairs(TOOLS) do
		local b = makeButton(bar, tool.label, function() ArtPad.Canvas:SetTool(tool.key) end, tool.tip)
		self.toolButtons[tool.key] = b
		row1[#row1 + 1] = b
	end
	local textButton = makeButton(bar, "Text", function() self:ShowTextInput() end,
		"Type some text, press Enter, then click where it should go")
	row1[#row1 + 1] = textButton
	row1[#row1].gap = 12

	local smaller = makeButton(bar, "-", function() ArtPad:AdjustBrushSize(-1) end, "Thinner brush (Ctrl+Mouse wheel)")
	local sizeFrame = CreateFrame("Frame", nil, bar)
	sizeFrame:SetSize(34, 24)
	local sizeBg = sizeFrame:CreateTexture(nil, "BACKGROUND")
	sizeBg:SetAllPoints()
	sizeBg:SetColorTexture(unpack(BUTTON_BG))
	self.sizeText = sizeFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	self.sizeText:SetPoint("CENTER")
	local bigger = makeButton(bar, "+", function() ArtPad:AdjustBrushSize(1) end, "Thicker brush (Ctrl+Mouse wheel)")
	bigger.gap = 12
	row1[#row1 + 1] = smaller
	row1[#row1 + 1] = sizeFrame
	row1[#row1 + 1] = bigger

	for _, c in ipairs(PALETTE) do
		local sw = CreateFrame("Button", nil, bar)
		sw:SetSize(22, 24)
		local t = sw:CreateTexture(nil, "ARTWORK")
		t:SetPoint("TOPLEFT", 2, -2)
		t:SetPoint("BOTTOMRIGHT", -2, 2)
		t:SetColorTexture(c[1], c[2], c[3], 1)
		local bg = sw:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.4, 0.4, 0.4, 1)
		local hl = sw:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.3)
		sw:SetScript("OnClick", function()
			local brush = ArtPad.settings.Brush
			ArtPad:SetColor(c[1], c[2], c[3], brush.a)
		end)
		row1[#row1 + 1] = sw
	end
	local picker = makeButton(bar, "Color...", function() self:OpenColorPicker() end, "Pick any color and opacity")
	self.colorSample = picker:CreateTexture(nil, "OVERLAY")
	self.colorSample:SetHeight(4)
	self.colorSample:SetPoint("BOTTOMLEFT")
	self.colorSample:SetPoint("BOTTOMRIGHT")
	row1[#row1 + 1] = picker

	-- Row 2: actions
	local row2 = {}
	row2[#row2 + 1] = makeButton(bar, "Undo", function() ArtPad.Sync:Undo() end, "Remove your last stroke (Ctrl+Z)")
	self.clearButton = makeButton(bar, "Clear Canvas", function() self:ConfirmClear() end, "Clear the canvas for everyone")
	row2[#row2 + 1] = self.clearButton
	row2[#row2 + 1] = makeButton(bar, "Art Mode", function() ArtPad.Canvas:SetArtMode(not ArtPad.Canvas.artMode) end,
		"Toggle an opaque canvas on top of everything")
	row2[#row2 + 1] = makeButton(bar, "Recenter", function() ArtPad.Canvas:Recenter() end, "Move the canvas back to the middle")
	self.modeButton = makeButton(bar, "Mode: Group", function() ArtPad:ToggleMode() end,
		"Share the canvas with your guild or with your party/raid")
	self.modeButton:SetWidth(self.modeButton:GetWidth() + 10)
	row2[#row2 + 1] = self.modeButton
	row2[#row2 + 1] = makeButton(bar, "Close", function() ArtPad:Hide() end, "Hide the canvas (Esc)")

	local w1 = layoutRow(bar, row1, 0)
	local w2 = layoutRow(bar, row2, -26)
	bar:SetSize(math.max(w1, w2), 50)

	local help = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	help:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -4)
	help:SetText("Left: draw   Right: erase   Shift-drag: move   Wheel: zoom   Ctrl-wheel: brush size   Ctrl+Z: undo")

	self.versionText = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	self.versionText:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, 4)
	self:SetVersionText()
	self.statusText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	self.statusText:SetPoint("LEFT", self.versionText, "RIGHT", 16, 0)

	-- Text entry
	local edit = CreateFrame("EditBox", nil, bar)
	self.textInput = edit
	edit:SetSize(320, 26)
	edit:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -6)
	edit:SetFontObject(ChatFontNormal)
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(120)
	edit:SetTextInsets(6, 6, 0, 0)
	local editBg = edit:CreateTexture(nil, "BACKGROUND")
	editBg:SetAllPoints()
	editBg:SetColorTexture(0, 0, 0, 0.85)
	edit:SetScript("OnEnterPressed", function(box)
		local text = box:GetText()
		box:ClearFocus()
		box:Hide()
		if text and text ~= "" then
			ArtPad.Canvas:SetPendingText(text)
			ArtPad:Print("Click on the canvas to place your text.")
		end
	end)
	edit:SetScript("OnEscapePressed", function(box)
		box:ClearFocus()
		box:Hide()
	end)
	edit:Hide()

	self:UpdateTool(ArtPad.Canvas.tool)
	self:UpdateBrush()
	self:UpdateMode()
end

function UI:Show()
	if self.bar then self.bar:Show() end
end

function UI:Hide()
	if not self.bar then return end
	self.bar:Hide()
	self.textInput:Hide()
end

function UI:SetArtMode(on)
	self.bar:SetFrameStrata(on and "FULLSCREEN_DIALOG" or "HIGH")
end

function UI:SetVersionText(newer)
	if not self.versionText then return end
	local text = "ArtPad v" .. tostring(ArtPad.version)
	if newer then
		text = text .. "  |cffff8040(v" .. newer .. " is available)|r"
	end
	self.versionText:SetText(text)
end

function UI:SetStatus(text)
	if self.statusText then
		self.statusText:SetText(text or "")
	end
end

function UI:UpdateTool(tool)
	for key, b in pairs(self.toolButtons) do
		b.bg:SetColorTexture(unpack(key == tool and BUTTON_SELECTED or BUTTON_BG))
	end
end

function UI:UpdateBrush()
	if not self.sizeText then return end
	local brush = ArtPad.settings.Brush
	self.sizeText:SetText(tostring(brush.w))
	self.colorSample:SetColorTexture(brush.r, brush.g, brush.b, 1)
end

function UI:UpdateMode()
	if not self.modeButton then return end
	self.modeButton:SetText(ArtPad.settings.Mode == "GUILD" and "Mode: Guild" or "Mode: Group")
end

function UI:ShowTextInput()
	self.textInput:SetText("")
	self.textInput:Show()
	self.textInput:SetFocus()
end

function UI:ConfirmClear()
	if self.clearArmed then
		self.clearArmed = nil
		self.clearButton:SetText("Clear Canvas")
		ArtPad.Sync:ClearAll()
		return
	end
	self.clearArmed = true
	self.clearButton:SetText("Really clear?")
	C_Timer.After(3, function()
		if self.clearArmed then
			self.clearArmed = nil
			self.clearButton:SetText("Clear Canvas")
		end
	end)
end

function UI:OpenColorPicker()
	local brush = ArtPad.settings.Brush
	local function apply()
		local r, g, b = ColorPickerFrame:GetColorRGB()
		ArtPad:SetColor(r, g, b, ColorPickerFrame:GetColorAlpha())
	end
	if ArtPad.Canvas.artMode then
		-- Keep the picker above the opaque canvas; put it back afterwards.
		ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
		if not self.pickerHooked then
			self.pickerHooked = true
			ColorPickerFrame:HookScript("OnHide", function(frame)
				if self.pickerRaised then
					self.pickerRaised = nil
					frame:SetFrameStrata("DIALOG")
				end
			end)
		end
		self.pickerRaised = true
	end
	ColorPickerFrame:SetupColorPickerAndShow({
		r = brush.r, g = brush.g, b = brush.b,
		opacity = brush.a,
		hasOpacity = true,
		swatchFunc = apply,
		opacityFunc = apply,
		cancelFunc = function(previous)
			ArtPad:SetColor(previous.r, previous.g, previous.b, previous.opacity or brush.a)
		end,
	})
end
