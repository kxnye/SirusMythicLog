local addonName, ns = ...

local Button = {}
ns.Button = Button

local Session, Store = ns.Session, ns.Store

local format = string.format

local cos, sin, rad, deg, atan2 = math.cos, math.sin, math.rad, math.deg, math.atan2
local min, max, sqrt = math.min, math.max, math.sqrt

local DEFAULT_ANGLE = 210
local ICON = "Interface\\Icons\\INV_Misc_PocketWatch_01"
local DOT = {
    off = "Interface\\COMMON\\Indicator-Gray",
    wait = "Interface\\COMMON\\Indicator-Yellow",
    rec = "Interface\\COMMON\\Indicator-Red",
}

local ROUND_CORNERS = {
    ROUND = { TL = true, TR = true, BL = true, BR = true },
    SQUARE = {},
    ["CORNER-TOPLEFT"] = { TL = true },
    ["CORNER-TOPRIGHT"] = { TR = true },
    ["CORNER-BOTTOMLEFT"] = { BL = true },
    ["CORNER-BOTTOMRIGHT"] = { BR = true },
    ["SIDE-LEFT"] = { TL = true, BL = true },
    ["SIDE-RIGHT"] = { TR = true, BR = true },
    ["SIDE-TOP"] = { TL = true, TR = true },
    ["SIDE-BOTTOM"] = { BL = true, BR = true },
    ["TRICORNER-TOPLEFT"] = { TL = true, TR = true, BL = true },
    ["TRICORNER-TOPRIGHT"] = { TL = true, TR = true, BR = true },
    ["TRICORNER-BOTTOMLEFT"] = { TL = true, BL = true, BR = true },
    ["TRICORNER-BOTTOMRIGHT"] = { TR = true, BL = true, BR = true },
}

local button = CreateFrame("Button", "SirusMythicLogMinimapButton", Minimap)
button:SetWidth(31)
button:SetHeight(31)
button:SetFrameStrata("MEDIUM")
button:SetFrameLevel(8)
button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
button:RegisterForDrag("LeftButton")
button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")

local background = button:CreateTexture(nil, "BACKGROUND")
background:SetWidth(20)
background:SetHeight(20)
background:SetPoint("TOPLEFT", 7, -5)
background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

local icon = button:CreateTexture(nil, "ARTWORK")
icon:SetWidth(17)
icon:SetHeight(17)
icon:SetPoint("TOPLEFT", 7, -6)
icon:SetTexture(ICON)

local function ResetIcon()
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
end

ResetIcon()

local border = button:CreateTexture(nil, "OVERLAY")
border:SetWidth(53)
border:SetHeight(53)
border:SetPoint("TOPLEFT")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local dot = button:CreateTexture(nil, "OVERLAY")
dot:SetWidth(10)
dot:SetHeight(10)
dot:SetPoint("BOTTOMRIGHT", -5, 5)

local function Status()
    local state = Session.State()
    if state == "rec" then
        local rec = Session.Recording()
        local entry = rec.entry
        return "rec", format("Идёт запись%s: %s, %s%s", entry.boss and (" - " .. entry.boss) or "", ns.Duration(rec.ms),
            ns.Size(rec.bytes), entry.manual and " (вручную)" or ""), 1, 0.3, 0.3
    elseif state == "off" then
        return "off", "Автозапись выключена", 0.6, 0.6, 0.6
    elseif Store.Full() then
        return "off", ns.FULL_TEXT, 1, 0.5, 0.2
    end
    return "wait", "Ждем бой", 0.3, 1, 0.3
end

local function FillTooltip(tooltip)
    local _, text, r, g, b = Status()
    tooltip:AddLine("SirusMythicLog", 1, 1, 1)
    tooltip:AddLine(text, r, g, b, true)
    tooltip:AddLine("ЛКМ - список боёв || ПКМ - включить/выключить автозапись", 0.6, 0.6, 0.6)
end

local function ShowTooltip(self)
    if self.dragging then return end
    local x = self:GetCenter()
    GameTooltip:SetOwner(self, x and x > UIParent:GetWidth() / 2 and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
    FillTooltip(GameTooltip)
    GameTooltip:Show()
end

function Button.Place(angle)
    local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
    local radius = Minimap:GetWidth() / 2 + 10
    local x, y = cos(rad(angle)), sin(rad(angle))
    local corner = (y > 0 and "T" or "B") .. (x < 0 and "L" or "R")
    if (ROUND_CORNERS[shape] or ROUND_CORNERS.ROUND)[corner] then
        x, y = x * radius, y * radius
    else
        local diagonal = sqrt(2 * radius * radius) - 10
        x = max(-radius, min(x * diagonal, radius))
        y = max(-radius, min(y * diagonal, radius))
    end
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function FollowCursor(self)
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    self.angle = deg(atan2(py / scale - my, px / scale - mx)) % 360
    Button.Place(self.angle)
end

function Button.Refresh()
    local state = Status()
    dot:SetTexture(DOT[state])
    icon:SetDesaturated(state == "off")
    if GameTooltip:IsOwned(button) then
        ShowTooltip(button)
    end
end

local function OnClick(self, mouse)
    if mouse == "RightButton" then
        Session.SetSetting("enabled", not Session.Setting("enabled"))
    else
        ns.Panel.Toggle()
    end
end

button:SetScript("OnEnter", ShowTooltip)
button:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)
button:SetScript("OnClick", OnClick)
button:SetScript("OnMouseDown", function()
    icon:SetTexCoord(0, 1, 0, 1)
end)
button:SetScript("OnMouseUp", ResetIcon)
button:SetScript("OnDragStart", function(self)
    self.dragging = true
    self:LockHighlight()
    GameTooltip:Hide()
    self:SetScript("OnUpdate", FollowCursor)
end)
button:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    self:UnlockHighlight()
    ResetIcon()
    self.dragging = nil
    FollowCursor(self)
    Store.UI().angle = self.angle
end)

function Button.Setup()
    Button.Place(tonumber(Store.UI().angle) or DEFAULT_ANGLE)
    local broker = LibStub and LibStub("LibDataBroker-1.1", true)
    if broker and not broker:GetDataObjectByName(addonName) then
        broker:NewDataObject(addonName, {
            type = "launcher",
            icon = ICON,
            OnClick = OnClick,
            OnTooltipShow = FillTooltip,
        })
    end
    Button.Refresh()
end
