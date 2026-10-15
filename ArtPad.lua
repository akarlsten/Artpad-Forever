--[[
	ArtPad
	by Dust-Turalyon-EU, Snaxxramas-DefiasBrotherhood-EU
	Updated for Midnight / WoW Forever by Aeverous-DefiasBrotherhood-EU.

	Core: settings, events, slash commands, launcher.
	See Codec.lua (encoding), Strokes.lua (model), Canvas.lua (drawing),
	Sync.lua (networking) and UI.lua (toolbar).
--]]
local addonName, ArtPad = ...
_G.ArtPad = ArtPad -- used by Bindings.xml

local Codec, Strokes, Canvas, Sync, UI = ArtPad.Codec, ArtPad.Strokes, ArtPad.Canvas, ArtPad.Sync, ArtPad.UI

local GetAddOnMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
ArtPad.version = GetAddOnMetadata(addonName, "Version")
ArtPad.saveVersion = tonumber(GetAddOnMetadata(addonName, "X-SaveVersion")) or 4

local ICON = "Interface\\AddOns\\ArtPad\\icon"
local ICON_ACTIVE = "Interface\\AddOns\\ArtPad\\iconact"
local NOTIFY_INTERVAL = 600

local DEFAULTS = {
	AdminOnly = false,   -- in group mode, only accept drawings from leader/assistants
	Mode = "GUILD",      -- "GUILD" or "RAID" (party/raid/instance group)
	Scale = 1,
	MinimapIcon = {},
	Debug = false,
	Notify = true,       -- chat hint when someone starts drawing while the canvas is hidden
	Persist = true,      -- keep the canvas across reloads/logins
	Seq = 0,
	Brush = { r = 1, g = 1, b = 1, a = 1, w = 3 },
}

-- [[ Helpers ]]
function ArtPad:Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffArtPad|r: " .. tostring(msg))
end

function ArtPad:Debug(...)
	if self.settings and self.settings.Debug then
		print("|cff66ccffArtPad|r debug:", ...)
	end
end

function ArtPad:RealmName()
	return GetNormalizedRealmName() or (GetRealmName() or ""):gsub("[%s%-]", "")
end

-- Always "Name-Realm" so stroke ids match on every client.
function ArtPad:NormalizeName(name)
	if not name:find("-", 1, true) then
		name = name .. "-" .. self:RealmName()
	end
	return name
end

function ArtPad:NextSeq()
	self.settings.Seq = (self.settings.Seq or 0) + 1
	return self.settings.Seq
end

function ArtPad:CurrentStyle()
	local b = self.settings.Brush
	return Codec.EncodeStyle(b.r, b.g, b.b, b.a, b.w)
end

-- Style as a table usable for previews (quantized like the network sees it).
function ArtPad:CurrentStyleTable()
	local r, g, b, a, w = Codec.DecodeStyle(self:CurrentStyle())
	return { r = r, g = g, b = b, a = a, w = w }
end

function ArtPad:EraserRadius()
	return math.max(8, self.settings.Brush.w * 2)
end

function ArtPad:SetColor(r, g, b, a)
	local brush = self.settings.Brush
	brush.r, brush.g, brush.b, brush.a = r, g, b, a or brush.a
	UI:UpdateBrush()
end

function ArtPad:AdjustBrushSize(delta)
	local brush = self.settings.Brush
	brush.w = math.max(1, math.min(20, brush.w + (delta > 0 and 1 or -1)))
	UI:UpdateBrush()
end

local function safeBool(func, ...)
	local ok, value = pcall(func, ...)
	if not ok or (issecretvalue and issecretvalue(value)) then return false end
	return value and true or false
end

function ArtPad:ValidateSender(sender)
	if not self.settings.AdminOnly or self.settings.Mode == "GUILD" then
		return true
	end
	local unit = Ambiguate(sender, "none")
	return safeBool(UnitIsGroupLeader, unit) or safeBool(UnitIsGroupAssistant, unit)
end

-- [[ Show / hide ]]
function ArtPad:Show()
	if InCombatLockdown() then
		self:Print("Can't open the canvas in combat.")
		return
	end
	Canvas.frame:Show()
end

function ArtPad:Hide()
	Canvas.frame:Hide()
end

function ArtPad:Toggle()
	if Canvas:IsShown() then self:Hide() else self:Show() end
end

function ArtPad:ToggleMode()
	self:SetMode(self.settings.Mode == "GUILD" and "RAID" or "GUILD")
end

function ArtPad:SetMode(mode)
	self.settings.Mode = mode
	UI:UpdateMode()
	self:Print(mode == "GUILD" and "Now sharing with your guild." or "Now sharing with your party/raid.")
	Sync:RequestSnapshot()
end

-- [[ Launcher (LibDataBroker, LibDBIcon if some other addon loaded it, addon compartment) ]]
function ArtPad:OnLauncherClick(button)
	if button == "RightButton" then
		self:ToggleMode()
	else
		self:Toggle()
	end
end

function ArtPad:SetupLauncher()
	local LDB = LibStub("LibDataBroker-1.1", true)
	if not LDB then return end
	self.launcher = LDB:NewDataObject("ArtPad", {
		type = "launcher",
		icon = ICON,
		OnClick = function(_, button) self:OnLauncherClick(button) end,
		OnTooltipShow = function(tt)
			tt:AddLine("ArtPad")
			tt:AddLine("|cffffff00Left Click|r to toggle the canvas")
			tt:AddLine("|cffffff00Right Click|r to switch between guild and group mode")
		end,
	})
	local LDBIcon = LibStub("LibDBIcon-1.0", true)
	if LDBIcon then
		LDBIcon:Register("ArtPad", self.launcher, self.settings.MinimapIcon)
	end
end

function ArtPad:SetLauncherActive(active)
	if self.launcher then
		self.launcher.icon = active and ICON_ACTIVE or ICON
	end
end

function ArtPad_OnAddonCompartmentClick(_, button)
	ArtPad:OnLauncherClick(button)
end

function ArtPad:NotifyActivity(sender)
	if Canvas:IsShown() then return end
	self:SetLauncherActive(true)
	if not self.settings.Notify then return end
	self.lastNotify = self.lastNotify or {}
	local now = GetTime()
	if now - (self.lastNotify[sender] or -NOTIFY_INTERVAL) >= NOTIFY_INTERVAL then
		self.lastNotify[sender] = now
		self:Print(Ambiguate(sender, "short") .. " is drawing on the ArtPad. Type /ap to look.")
	end
end

function ArtPad:OnPeerVersion(theirs, sender)
	local mine, other = tonumber(self.version), tonumber(theirs)
	if mine and other and other > mine and not self.newerVersion then
		self.newerVersion = theirs
		UI:SetVersionText(theirs)
		self:Debug(sender, "has newer version", theirs)
	end
end

-- [[ Settings & persistence ]]
local function applyDefaults(target, defaults)
	for k, v in pairs(defaults) do
		if target[k] == nil then
			target[k] = type(v) == "table" and CopyTable(v) or v
		elseif type(v) == "table" and type(target[k]) == "table" then
			applyDefaults(target[k], v)
		end
	end
end

function ArtPad:LoadSettings()
	local saved = ArtPad_Settings
	if type(saved) ~= "table" then
		saved = {}
	elseif (tonumber(saved.SaveVersion) or 0) < self.saveVersion then
		-- Keep the useful bits from older versions.
		saved = {
			AdminOnly = saved.AdminOnly,
			Mode = saved.Mode,
			MinimapIcon = saved.MinimapIcon,
			Debug = saved.Debug,
		}
	end
	applyDefaults(saved, DEFAULTS)
	if saved.Mode ~= "GUILD" and saved.Mode ~= "RAID" then saved.Mode = "GUILD" end
	saved.SaveVersion = self.saveVersion
	ArtPad_Settings = saved
	self.settings = saved
end

function ArtPad:LoadCanvas()
	if not self.settings.Persist or type(ArtPad_Canvas) ~= "table" then return end
	if ArtPad_Canvas.v == 1 and type(ArtPad_Canvas.data) == "string" then
		local added = Strokes:Merge(ArtPad_Canvas.data)
		self:Debug("restored", added, "strokes")
	end
end

function ArtPad:SaveCanvas()
	if self.settings.Persist then
		ArtPad_Canvas = { v = 1, data = Strokes:Serialize() }
	else
		ArtPad_Canvas = nil
	end
end

-- [[ Slash commands ]]
local commands
commands = {
	show = function() ArtPad:Show() end,
	hide = function() ArtPad:Hide() end,
	toggle = function() ArtPad:Toggle() end,
	clear = function() Sync:ClearAll() end,
	undo = function() Sync:Undo() end,
	guild = function() ArtPad:SetMode("GUILD") end,
	raid = function() ArtPad:SetMode("RAID") end,
	group = function() ArtPad:SetMode("RAID") end,
	sync = function()
		ArtPad:Print("Asking for the latest canvas...")
		Sync:RequestSnapshot()
	end,
	adminonly = function(arg)
		local s = ArtPad.settings
		if arg == "on" or arg == "true" then
			s.AdminOnly = true
		elseif arg == "off" or arg == "false" then
			s.AdminOnly = false
		else
			s.AdminOnly = not s.AdminOnly
		end
		ArtPad:Print("Only accept drawings from group leader/assistants: " .. (s.AdminOnly and "on" or "off"))
	end,
	notify = function()
		ArtPad.settings.Notify = not ArtPad.settings.Notify
		ArtPad:Print("Drawing notifications: " .. (ArtPad.settings.Notify and "on" or "off"))
	end,
	persist = function()
		ArtPad.settings.Persist = not ArtPad.settings.Persist
		ArtPad:Print("Save canvas between sessions: " .. (ArtPad.settings.Persist and "on" or "off"))
	end,
	minimap = function()
		local LDBIcon = LibStub("LibDBIcon-1.0", true)
		if not LDBIcon then
			ArtPad:Print("No minimap button library loaded; use the addon compartment (minimap addons menu) instead.")
			return
		end
		local db = ArtPad.settings.MinimapIcon
		db.hide = not db.hide
		if db.hide then LDBIcon:Hide("ArtPad") else LDBIcon:Show("ArtPad") end
	end,
	debug = function()
		ArtPad.settings.Debug = not ArtPad.settings.Debug
		ArtPad:Print("Debug mode: " .. tostring(ArtPad.settings.Debug))
		if ArtPad.settings.Debug then
			ArtPad:Print(("strokes=%d outbox=%d tokens=%.1f channel=%s lockdown=%s"):format(
				Strokes:Count(), #Sync.outbox, Sync.tokens, tostring(Sync:Distribution()), tostring(Sync:InLockdown())))
		end
	end,
	selftest = function()
		local pts = { 0, 0, 10, 12, 50, 5, 4000, 2000, 3999, 2001 }
		local ok1 = table.concat(Codec.DecodePoints(Codec.EncodePoints(pts)), ",") == table.concat(pts, ",")
		local sample = string.rep("ArtPad snapshot test ~ ", 200)
		local packed = Codec.Pack(sample)
		local ok2 = Codec.Unpack(packed) == sample
		ArtPad:Print(("codec: %s, compression: %s (%s, %d -> %d bytes)"):format(
			ok1 and "ok" or "FAILED", ok2 and "ok" or "FAILED",
			packed:sub(1, 1) == "1" and "deflate" or "uncompressed", #sample, #packed))
	end,
}

local function onSlashCommand(msg)
	local cmd, arg = (msg or ""):match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()
	if cmd == "" then
		ArtPad:Toggle()
	elseif commands[cmd] then
		commands[cmd](arg)
	else
		ArtPad:Print("Commands:")
		ArtPad:Print("/ap [show | hide | toggle | clear | undo]")
		ArtPad:Print("/ap [guild | group] - who you share the canvas with")
		ArtPad:Print("/ap sync - ask others for the current canvas")
		ArtPad:Print("/ap [adminonly | notify | persist | minimap | debug | selftest]")
	end
end

SLASH_ARTPAD1 = "/artpad"
SLASH_ARTPAD2 = "/ap"
SlashCmdList["ARTPAD"] = onSlashCommand

-- [[ Key bindings ]]
BINDING_HEADER_ARTPAD = "ArtPad"
BINDING_NAME_ARTPAD_SHOW = "Show Canvas"
BINDING_NAME_ARTPAD_HIDE = "Hide Canvas"
BINDING_NAME_ARTPAD_TOGGLE = "Toggle Canvas"

-- [[ Events ]]
local events = {}

function events:ADDON_LOADED(name)
	if name ~= addonName then return end
	ArtPad:LoadSettings()
end

function events:PLAYER_LOGIN()
	ArtPad.me = ArtPad:NormalizeName(UnitName("player"))
	Canvas:Init(ArtPad.settings)
	UI:Init()
	Sync:Init()
	ArtPad:SetupLauncher()
	ArtPad:LoadCanvas()
end

function events:PLAYER_ENTERING_WORLD()
	if ArtPad.enteredWorld then return end
	ArtPad.enteredWorld = true
	C_Timer.After(5, function()
		Sync:AnnounceVersion()
		Sync:RequestSnapshot()
	end)
end

function events:GROUP_JOINED()
	if ArtPad.settings.Mode == "RAID" then
		C_Timer.After(3, function() Sync:RequestSnapshot() end)
	end
end

function events:PLAYER_REGEN_DISABLED()
	-- Close the canvas when entering combat.
	if Canvas:IsShown() then ArtPad:Hide() end
end

function events:PLAYER_LOGOUT()
	ArtPad:SaveCanvas()
end

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, ...) events[event](events, ...) end)
for event in pairs(events) do
	eventFrame:RegisterEvent(event)
end
