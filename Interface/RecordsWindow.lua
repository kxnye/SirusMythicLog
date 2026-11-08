local _, ns = ...

local Panel = {}
ns.Panel = Panel

local Session, Store = ns.Session, ns.Store

local format = string.format
local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max

local WIDTH = 460
local PAD = 14
local ROWS = 8
local ROW_HEIGHT = 20
local HEADER_HEIGHT = 24
local STATUS_TOP = 40
local STATUS_GAP = 12
local LIST_TOP = 34
local COLUMNS_HEIGHT = 18
local GRID_TOP = LIST_TOP + COLUMNS_HEIGHT
local GRID_HEIGHT = ROWS * ROW_HEIGHT
local OWN_TOP = GRID_TOP + GRID_HEIGHT + 6
local OWN_HEIGHT = 20
local CONTROLS_HEIGHT = 22
local GAP = 6
local CONTENT = OWN_TOP + OWN_HEIGHT
local FOOTER = 78
local FOOT_ROW = 57
local BAR_WIDTH = 80
local ID_RIGHT, NAME_X, TIME_RIGHT, DPS_RIGHT, SPEC_X = 120, 128, 330, 396, 404
local SPEC_SIZE = 16
local SPEC_TIP = "|T%s:16:16:0:0:64:64:5:59:5:59|t"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local CLEAR_POPUP = "SIRUSMYTHICLOG_CLEAR"
local CLEAR_OWN_POPUP = "SIRUSMYTHICLOG_CLEAR_OWN"
local LOOK = {
    rec = { "Interface\\COMMON\\Indicator-Red", 1, 1, 1, 1, 0.45, 0.45 },
    wait = { "Interface\\COMMON\\Indicator-Yellow", 1, 1, 1, 0.9, 0.9, 0.9 },
    off = { "Interface\\COMMON\\Indicator-Gray", 1, 1, 1, 0.6, 0.6, 0.6 },
    full = { "Interface\\COMMON\\Indicator-Yellow", 1, 0.5, 0.15, 1, 0.6, 0.25 },
}

local function Fill(parent, layer, r, g, b, a)
    local texture = parent:CreateTexture(nil, layer)
    texture:SetTexture(r, g, b, a)
    return texture
end

local function Line(parent, layer)
    local line = Fill(parent, layer or "BORDER", 1, 1, 1, 0.08)
    line:SetHeight(1)
    return line
end

local function Text(parent, font, justify)
    local text = parent:CreateFontString(nil, "ARTWORK", font)
    text:SetJustifyH(justify or "LEFT")
    return text
end

local function ShowIf(region, shown)
    if shown then
        region:Show()
    else
        region:Hide()
    end
end

local panel = CreateFrame("Frame", "SirusMythicLogPanel", UIParent)
panel:SetWidth(WIDTH)
panel:SetHeight(STATUS_TOP + 12 + STATUS_GAP + CONTENT + GAP + FOOTER)
panel:SetPoint("TOP", UIParent, "CENTER", 0, 160)
panel:SetFrameStrata("DIALOG")
panel:SetClampedToScreen(true)
panel:SetMovable(true)
panel:EnableMouse(true)
panel:EnableMouseWheel(true)
panel:SetBackdrop({
    bgFile = WHITE,
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = false, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
panel:SetBackdropColor(0.04, 0.04, 0.05, 0.94)
panel:SetBackdropBorderColor(0.45, 0.45, 0.5)
panel:Hide()
tinsert(UISpecialFrames, "SirusMythicLogPanel")

local header = CreateFrame("Frame", nil, panel)
header:SetPoint("TOPLEFT", 4, -4)
header:SetPoint("TOPRIGHT", -4, -4)
header:SetHeight(HEADER_HEIGHT)
header:EnableMouse(true)
header:RegisterForDrag("LeftButton")
header:SetScript("OnDragStart", function()
    panel:StartMoving()
end)
header:SetScript("OnDragStop", function()
    panel:StopMovingOrSizing()
    local left, top = panel:GetLeft(), panel:GetTop()
    if left and top then
        panel:ClearAllPoints()
        panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end
end)
Fill(header, "BACKGROUND", 1, 1, 1, 0.05):SetAllPoints()
local headerLine = Line(header)
headerLine:SetPoint("BOTTOMLEFT")
headerLine:SetPoint("BOTTOMRIGHT")

local logo = header:CreateTexture(nil, "ARTWORK")
logo:SetWidth(14)
logo:SetHeight(14)
logo:SetPoint("LEFT", PAD - 4, 0)
logo:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
logo:SetTexCoord(0.08, 0.92, 0.08, 0.92)

local title = Text(header, "GameFontNormal")
title:SetPoint("LEFT", logo, "RIGHT", 5, 0)
title:SetText("SirusMythicLog")

local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
close:SetWidth(24)
close:SetHeight(24)
close:SetPoint("TOPRIGHT", -4, -4)
close:SetFrameLevel(header:GetFrameLevel() + 2)

local dot = panel:CreateTexture(nil, "ARTWORK")
dot:SetWidth(10)
dot:SetHeight(10)
dot:SetPoint("TOPLEFT", PAD, -STATUS_TOP - 1)

local status = Text(panel, "GameFontHighlightSmall")
status:SetPoint("TOPLEFT", PAD + 16, -STATUS_TOP)
status:SetWidth(WIDTH - 2 * PAD - 16)

local body = CreateFrame("Frame", nil, panel)
body:SetWidth(WIDTH)
body:SetHeight(1)
body:SetPoint("TOPLEFT", 0, -(STATUS_TOP + 12 + STATUS_GAP))

local manualButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
manualButton:SetWidth(136)
manualButton:SetHeight(CONTROLS_HEIGHT)
manualButton:SetPoint("TOPLEFT", body, "TOPLEFT", PAD - 2, 0)
manualButton:SetText("Начать запись")
manualButton:SetScript("OnClick", function()
    if Session.Recording() then
        Session.Stop()
    else
        Session.Start()
    end
end)

local boxes = {}

local function Check(name, key, text, anchor)
    local label = Text(panel, "GameFontHighlightSmall")
    label:SetText(text)
    if anchor then
        label:SetPoint("RIGHT", anchor, "LEFT", -6, 1)
    else
        label:SetPoint("RIGHT", body, "TOPRIGHT", -PAD, -CONTROLS_HEIGHT / 2)
    end
    local box = CreateFrame("CheckButton", name, panel, "UICheckButtonTemplate")
    box:SetWidth(20)
    box:SetHeight(20)
    box:SetPoint("RIGHT", label, "LEFT", 0, -1)
    box:SetHitRectInsets(0, -label:GetStringWidth(), 0, 0)
    box.key = key
    box:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        if on and not Session.Setting("enabled") then
            for _, other in ipairs(boxes) do
                if other ~= self then
                    Session.SetSetting(other.key, false)
                end
            end
            Session.SetSetting(key, true)
            Session.SetSetting("enabled", true)
        else
            Session.SetSetting(key, on)
        end
    end)
    boxes[#boxes + 1] = box
    return box
end

local bossBox = Check("SirusMythicLogPanelBoss", "boss", "босс")
local dummyBox = Check("SirusMythicLogPanelDummy", "dummy", "манекен", bossBox)
local autoLabel = Text(panel, "GameFontDisableSmall")
autoLabel:SetPoint("RIGHT", dummyBox, "LEFT", -1, 1)
autoLabel:SetText("Автозапись:")

local columns = CreateFrame("Frame", nil, panel)
columns:SetWidth(WIDTH - 10)
columns:SetHeight(COLUMNS_HEIGHT)
columns:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -LIST_TOP)
Fill(columns, "BACKGROUND", 1, 1, 1, 0.04):SetAllPoints()
local columnsLine = Line(columns)
columnsLine:SetPoint("BOTTOMLEFT")
columnsLine:SetPoint("BOTTOMRIGHT")

local function Column(text, x, justify)
    local label = Text(columns, "GameFontDisableSmall", justify)
    label:SetPoint(justify, columns, "LEFT", x - 5, 0)
    label:SetText(text)
end

Column("Дата", PAD, "LEFT")
Column("Бой", ID_RIGHT - 11, "CENTER")
Column("Время", TIME_RIGHT, "RIGHT")
Column("УВС", DPS_RIGHT, "RIGHT")

for index = 2, ROWS, 2 do
    local stripe = Fill(panel, "BORDER", 1, 1, 1, 0.035)
    stripe:SetHeight(ROW_HEIGHT)
    stripe:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(GRID_TOP + (index - 1) * ROW_HEIGHT))
    stripe:SetPoint("TOPRIGHT", body, "TOPLEFT", WIDTH - 5, -(GRID_TOP + (index - 1) * ROW_HEIGHT))
end

local empty = Text(panel, "GameFontDisable", "CENTER")
empty:SetPoint("CENTER", body, "TOPLEFT", WIDTH / 2, -(GRID_TOP + GRID_HEIGHT / 2))
empty:SetText("Пусто")

local rows = {}
local visible = {}
local offset = 0
local total = 0
local syncing = false
local Refresh, UpdateControls

local function Wheel(_, delta)
    if total <= ROWS then return end
    offset = offset - delta
    Refresh()
end

panel:SetScript("OnMouseWheel", Wheel)

local scrollBar = CreateFrame("Slider", nil, panel)
scrollBar:SetOrientation("VERTICAL")
scrollBar:SetWidth(4)
scrollBar:SetPoint("TOPRIGHT", body, "TOPRIGHT", -6, -GRID_TOP)
scrollBar:SetHeight(GRID_HEIGHT)
scrollBar:SetValueStep(1)
scrollBar:SetThumbTexture(WHITE)
local thumb = scrollBar:GetThumbTexture()
thumb:SetVertexColor(1, 1, 1, 0.35)
thumb:SetWidth(4)
Fill(scrollBar, "BACKGROUND", 1, 1, 1, 0.06):SetAllPoints()
scrollBar:EnableMouseWheel(true)
scrollBar:SetScript("OnMouseWheel", Wheel)
scrollBar:SetScript("OnValueChanged", function(_, value)
    local wanted = floor(value + 0.5)
    if syncing or wanted == offset then return end
    offset = wanted
    Refresh()
end)
scrollBar:Hide()

local function RowTooltip(row)
    local fight = visible[row.index]
    if not fight then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddDoubleLine("Размер", ns.Size(fight.bytes), 0.6, 0.6, 0.6, 1, 1, 1)
    if fight.first.manual then
        GameTooltip:AddLine("вручную", 0.6, 0.6, 0.6)
    end
    if fight.capped then
        GameTooltip:AddLine("обрезан из-за нехватки памяти", 1, 0.6, 0.25)
    end
    GameTooltip:Show()
end

local function ClassColor(class)
    local color = CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[class] or RAID_CLASS_COLORS[class]
    if color then return color.r, color.g, color.b end
    if GetClassColor then return GetClassColor(class) end
    return 1, 1, 1
end

local function SpecTooltip(row)
    local who = row.who
    if not who then return end
    if not who.tip then
        local icon = format(SPEC_TIP, who.icon)
        who.tip = who.name and (icon .. " " .. who.name) or icon
    end
    GameTooltip:SetOwner(row.spec, "ANCHOR_RIGHT")
    GameTooltip:AddLine(who.tip, ClassColor(who.class))
    GameTooltip:Show()
end

local function Owned(row)
    return GameTooltip:IsOwned(row) or GameTooltip:IsOwned(row.spec)
end

local function Hover(row, on, spec)
    ShowIf(row.hover, on)
    row.remove:SetAlpha(on and 1 or 0)
    if on then
        if spec then
            SpecTooltip(row)
        else
            RowTooltip(row)
        end
    elseif Owned(row) then
        GameTooltip:Hide()
    end
end

local function Cell(row, x, width, justify)
    local cell = Text(row, "GameFontHighlightSmall", justify)
    cell:SetPoint("LEFT", x - 5, 0)
    cell:SetWidth(width)
    cell:SetHeight(ROW_HEIGHT)
    return cell
end

for index = 1, ROWS do
    local row = CreateFrame("Frame", nil, panel)
    row.index = index
    row:SetWidth(WIDTH - 10)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", body, "TOPLEFT", 5, -(GRID_TOP + (index - 1) * ROW_HEIGHT))
    row:EnableMouse(true)
    row:EnableMouseWheel(true)
    row.hover = Fill(row, "BORDER", 1, 1, 1, 0.08)
    row.hover:SetAllPoints()
    row.hover:Hide()
    row.date = Cell(row, PAD, ID_RIGHT - 22 - PAD - 4)
    row.date:SetTextColor(0.55, 0.55, 0.55)
    row.id = Cell(row, ID_RIGHT - 22, 22, "CENTER")
    row.id:SetTextColor(0.55, 0.55, 0.55)
    row.name = Cell(row, NAME_X, TIME_RIGHT - 40 - NAME_X)
    row.time = Cell(row, TIME_RIGHT - 40, 40, "RIGHT")
    row.dps = Cell(row, DPS_RIGHT - 52, 52, "RIGHT")
    row.spec = CreateFrame("Frame", nil, row)
    row.spec:SetWidth(SPEC_SIZE)
    row.spec:SetHeight(SPEC_SIZE)
    row.spec:SetPoint("LEFT", SPEC_X - 5, 0)
    row.spec:EnableMouse(true)
    row.spec:EnableMouseWheel(true)
    row.icon = row.spec:CreateTexture(nil, "ARTWORK")
    row.icon:SetAllPoints()
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.spec:SetScript("OnEnter", function()
        Hover(row, true, true)
    end)
    row.spec:SetScript("OnLeave", function()
        Hover(row, false)
    end)
    row.spec:SetScript("OnMouseWheel", Wheel)
    row.spec:Hide()
    row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
    row.remove:SetWidth(20)
    row.remove:SetHeight(20)
    row.remove:SetPoint("RIGHT", -6, 0)
    row.remove:SetAlpha(0)
    row.remove:SetScript("OnClick", function()
        local fight = visible[index]
        if not fight or fight.current then return end
        for _, entry in ipairs(fight.entries) do
            Session.Remove(entry)
        end
    end)
    row.remove:SetScript("OnEnter", function()
        Hover(row, true)
    end)
    row.remove:SetScript("OnLeave", function()
        Hover(row, false)
    end)
    row:SetScript("OnEnter", function(self)
        Hover(self, true)
    end)
    row:SetScript("OnLeave", function(self)
        Hover(self, false)
    end)
    row:SetScript("OnMouseWheel", Wheel)
    rows[index] = row
end

local ownBox = CreateFrame("CheckButton", "SirusMythicLogPanelOwn", panel, "UICheckButtonTemplate")
ownBox:SetWidth(20)
ownBox:SetHeight(20)
ownBox:SetPoint("TOPLEFT", body, "TOPLEFT", PAD - 4, -OWN_TOP)
local ownLabel = Text(panel, "GameFontHighlightSmall")
ownLabel:SetPoint("LEFT", ownBox, "RIGHT", 0, 1)
ownLabel:SetText("Только этот персонаж")
ownBox:SetHitRectInsets(0, -ownLabel:GetStringWidth(), 0, 0)
ownBox:SetScript("OnClick", function(self)
    Store.SetOwnOnly(self:GetChecked() and true or false)
    offset = 0
    Refresh()
end)

local footLine = Line(panel)
footLine:SetPoint("BOTTOMLEFT", 5, FOOTER - 1)
footLine:SetPoint("BOTTOMRIGHT", -5, FOOTER - 1)

local track = Fill(panel, "ARTWORK", 1, 1, 1, 0.1)
track:SetWidth(BAR_WIDTH)
track:SetHeight(4)
track:SetPoint("LEFT", panel, "BOTTOMLEFT", PAD, FOOT_ROW)

local fill = panel:CreateTexture(nil, "OVERLAY")
fill:SetTexture(WHITE)
fill:SetHeight(4)
fill:SetPoint("LEFT", track, "LEFT")

local used = Text(panel, "GameFontHighlightSmall")
used:SetPoint("LEFT", track, "RIGHT", 8, 0)

local clear = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
clear:SetWidth(108)
clear:SetHeight(CONTROLS_HEIGHT)
clear:SetPoint("RIGHT", panel, "BOTTOMRIGHT", -(PAD - 2), FOOT_ROW)
clear:SetText("Очистить всё")
clear:SetScript("OnClick", function()
    local own = Store.OwnOnly()
    if #Store.Fights(own) > 0 then
        StaticPopup_Show(own and CLEAR_OWN_POPUP or CLEAR_POPUP)
    end
end)

local fileTitle = Text(panel, "GameFontDisableSmall")
fileTitle:SetPoint("BOTTOMLEFT", PAD, 26)
fileTitle:SetHeight(12)
fileTitle:SetText("Файл лога - после /reload:")

local filePath = Text(panel, "GameFontDisableSmall")
filePath:SetPoint("BOTTOMLEFT", PAD, 12)
filePath:SetHeight(12)
filePath:SetText("WTF\\Account\\<аккаунт>\\SavedVariables\\SirusMythicLog.lua")

local function Head(rec)
    if rec then
        local entry = rec.entry
        return "rec", format("Запись боя %d%s%s: %s", entry.id, entry.boss and (" - " .. entry.boss) or "",
            entry.manual and " (вручную)" or "", ns.Duration(rec.ms))
    elseif Session.State() == "off" then
        return "off", "Автозапись выключена. Ручная запись - «Начать запись»"
    elseif Store.Full() then
        return "full", ns.FULL_TEXT
    elseif Session.Setting("boss") then
        return "wait", "Запись автоматически начнется в бою с боссом"
    end
    return "wait", "Запись автоматически начнется в бою с манекеном"
end

local function Usage()
    local bytes = Store.DbBytes()
    local share = min(bytes / Store.DB_CAP, 1)
    used:SetText(format("Занято %s из %s", ns.Size(bytes), ns.Size(Store.DB_CAP)))
    local width = floor(BAR_WIDTH * share + 0.5)
    fill:SetWidth(max(width, 1))
    ShowIf(fill, width >= 1)
    if share >= 1 then
        fill:SetVertexColor(1, 0.3, 0.3)
    elseif share >= 0.75 then
        fill:SetVertexColor(1, 0.65, 0.2)
    else
        fill:SetVertexColor(0.4, 0.75, 1)
    end
end

local bodyTop = STATUS_TOP + 12 + STATUS_GAP

local function UpdateStatus(rec)
    local state, text = Head(rec)
    local look = LOOK[state]
    dot:SetTexture(look[1])
    dot:SetVertexColor(look[2], look[3], look[4])
    status:SetText(text)
    status:SetTextColor(look[5], look[6], look[7])
    local top = STATUS_TOP + max(12, ceil(status:GetStringHeight())) + STATUS_GAP
    if top ~= bodyTop then
        bodyTop = top
        body:ClearAllPoints()
        body:SetPoint("TOPLEFT", 0, -top)
    end
    Usage()
end

local ticker = ns.NewTimer(function()
    if Session.Recording() then
        Refresh()
    end
end)

function Panel.Tick()
    if ticker.native and not ticker.running and panel:IsShown() and Session.Recording() then
        ticker.Start(1)
    end
end

local function Layout(count)
    ShowIf(empty, count == 0)
    ShowIf(scrollBar, count > ROWS)
    panel:SetHeight(bodyTop + CONTENT + GAP + FOOTER)
    if count > ROWS then
        thumb:SetHeight(max(12, floor(GRID_HEIGHT * ROWS / count + 0.5)))
        syncing = true
        scrollBar:SetMinMaxValues(0, count - ROWS)
        scrollBar:SetValue(offset)
        syncing = false
    end
end

function Refresh()
    if not panel:IsShown() then return end
    local rec = Session.Recording()
    local own = Store.OwnOnly()
    local list = Store.Fights(own)
    total = #list
    UpdateStatus(rec)
    UpdateControls(rec, own, total)
    offset = max(0, min(offset, total - ROWS))
    Layout(total)
    for index = 1, ROWS do
        local row = rows[index]
        local fight = list[offset + index]
        visible[index] = fight
        if fight then
            local first = fight.first
            row.date:SetText(ns.ShortDate(first.started))
            row.id:SetText(first.id or "")
            row.name:SetText(ns.FightName(first))
            if fight.current then
                row.time:SetText("идёт")
                row.time:SetTextColor(1, 0.35, 0.35)
            else
                row.time:SetText(fight.ms > 0 and ns.Duration(fight.ms) or "-")
                row.time:SetTextColor(1, 1, 1)
            end
            row.dps:SetText(fight.dps and ns.Thousands(fight.dps) or "-")
            ShowIf(row.remove, not fight.current)
            local who = Store.Who(first)
            if row.who ~= who then
                row.who = who
                if who then
                    row.icon:SetTexture(who.icon)
                end
                ShowIf(row.spec, who)
                if GameTooltip:IsOwned(row.spec) then
                    if who then
                        SpecTooltip(row)
                    else
                        GameTooltip:Hide()
                    end
                end
            end
            if GameTooltip:IsOwned(row) then
                RowTooltip(row)
            end
        elseif Owned(row) then
            GameTooltip:Hide()
        end
        ShowIf(row, fight ~= nil)
    end
    Panel.Tick()
end

function UpdateControls(rec, own, count)
    manualButton:SetText(rec and "Остановить запись" or "Начать запись")
    if rec or not Store.Full() then
        manualButton:Enable()
    else
        manualButton:Disable()
    end
    local enabled = Session.Setting("enabled")
    for _, box in ipairs(boxes) do
        box:SetChecked(enabled and Session.Setting(box.key))
    end
    ownBox:SetChecked(own)
    if rec or count == 0 then
        clear:Disable()
    else
        clear:Enable()
    end
end

StaticPopupDialogs[CLEAR_POPUP] = {
    text = "Удалить все записи?",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        Session.Clear()
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

StaticPopupDialogs[CLEAR_OWN_POPUP] = {
    text = "Удалить записи этого персонажа?",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        Session.Clear(true)
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

panel:SetScript("OnShow", Refresh)
panel:SetScript("OnHide", function()
    ticker.Stop()
end)

function Panel.Toggle()
    if panel:IsShown() then
        panel:Hide()
    else
        panel:Show()
    end
end

Panel.Refresh = Refresh
