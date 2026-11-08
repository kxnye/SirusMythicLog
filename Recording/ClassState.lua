local _, ns = ...

local ClassState = {}
ns.ClassState = ClassState

local D = ns.Data
local Store, Recorder = ns.Store, ns.Recorder
local Escape = ns.Escape

local Write, Run, Now, Ms = Store.Write, Recorder.Run, Recorder.Now, Recorder.Ms
local format, floor, abs = string.format, math.floor, math.abs
local UnitPower, UnitPowerMax, GetComboPoints = UnitPower, UnitPowerMax, GetComboPoints

local PLAYER, PET = "", "e"
local ENCHANT_JITTER = 1000
local RUNES = 6

local FIELDS = Recorder.FIELDS
FIELDS[#FIELDS + 1] = { "Q", "t,u,k,v,mx" }
FIELDS[#FIELDS + 1] = { "U", "t,r,k,sr,d" }
FIELDS[#FIELDS + 1] = { "TM", "t,slot,name,sr,d" }
FIELDS[#FIELDS + 1] = { "WE", "t,slot,er,ch,name" }
FIELDS[#FIELDS + 1] = { "Z", "t,k,v" }

local frame = CreateFrame("Frame")
local class
local values, maxes = {}, {}
local lastUnit, lastCode, lastT, lastIndex, lastMax
local powerEvents, powerUnitEvents = 0, 0
local runeKind, runeStart, runeT, runeIndex = {}, {}, {}, {}
local totemName, totemStart = {}, {}
local enchantEnd, enchantCharges = {}, {}
local toggles = {}

local function PowerLine(t, u, code, v, mx)
    if mx then
        return format("Q;%d;%s;%s;%d;%d", t, u, code, v, mx)
    end
    return format("Q;%d;%s;%s;%d", t, u, code, v)
end

local function Track(u)
    values[u], maxes[u] = {}, {}
    if lastUnit == u then
        lastUnit = nil
    end
end

function ClassState.Power(t, u, code, v, mx)
    v, mx = tonumber(v) or 0, tonumber(mx)
    local known, limits = values[u], maxes[u]
    local oldMax = limits[code]
    if v == known[code] and (mx == nil or mx == oldMax) then return end
    known[code] = v
    if mx ~= nil then
        limits[code] = mx
    end
    mx = limits[code]
    if lastUnit == u and lastCode == code and lastT == t
        and Store.ReplaceLast(lastIndex, PowerLine(t, u, code, v, mx ~= lastMax and mx or nil)) then
        return
    end
    lastUnit, lastCode, lastT, lastMax = u, code, t, oldMax
    lastIndex = Write(PowerLine(t, u, code, v, mx ~= oldMax and mx or nil))
end

ClassState.Track = Track
ClassState.PLAYER, ClassState.PET = PLAYER, PET

local Power = ClassState.Power

function ClassState.UnitPowers(t, u, unit)
    local known = values[u]
    for _, kind in ipairs(D.POWER_KINDS) do
        local code = D.POWER_CODE[kind]
        local mx = tonumber(UnitPowerMax(unit, kind)) or 0
        if mx > 0 or known[code] then
            Power(t, u, code, UnitPower(unit, kind), mx)
        end
    end
end

local function PlayerPower(t, kind)
    Power(t, PLAYER, D.POWER_CODE[kind], UnitPower("player", kind), UnitPowerMax("player", kind))
end

local function OnPower(event, unit, token)
    powerEvents = powerEvents + 1
    local t = Now()
    local kind = D.POWER_EVENT[event]
    if event == "UNIT_POWER" then
        powerUnitEvents = powerUnitEvents + 1
        kind = token and D.POWER_TOKEN[token]
    end
    if kind then
        PlayerPower(t, kind)
    else
        ClassState.UnitPowers(t, PLAYER, "player")
    end
end

local function OnDisplayPower()
    local t = Now()
    local kind = UnitPowerType("player")
    Power(t, PLAYER, "y", kind)
    if D.POWER_CODE[kind] then
        PlayerPower(t, kind)
    end
end

local function WriteCombo(t)
    Power(t, PLAYER, "c", GetComboPoints("player", "target"))
end

local function OnCombo()
    WriteCombo(Now())
end

local function WriteShards(t)
    Power(t, PLAYER, "s", GetItemCount(D.SOUL_SHARD))
end

local function OnBags()
    WriteShards(Now())
end

local function WriteRune(t, rune)
    local start, duration, ready = GetRuneCooldown(rune)
    local kind = GetRuneType(rune) or 0
    if ready or not start then
        start = 0
    end
    if runeKind[rune] == kind and runeStart[rune] == start then return end
    runeKind[rune], runeStart[rune] = kind, start
    local line
    if start > 0 then
        line = format("U;%d;%d;%d;%d;%d", t, rune, kind, Ms(start) - t, floor(duration * 1000 + 0.5))
    else
        line = format("U;%d;%d;%d", t, rune, kind)
    end
    if runeT[rune] == t and Store.ReplaceLast(runeIndex[rune], line) then return end
    runeT[rune], runeIndex[rune] = t, Write(line)
end

local function WriteRunes(t)
    for rune = 1, RUNES do
        WriteRune(t, rune)
    end
end

local function OnRune(event, rune)
    local t = Now()
    if rune and rune >= 1 and rune <= RUNES then
        WriteRune(t, rune)
    else
        WriteRunes(t)
    end
end

local function WriteTotem(t, slot)
    local have, name, start, duration = GetTotemInfo(slot)
    if not have or not name or name == "" then
        if totemName[slot] then
            totemName[slot], totemStart[slot] = nil, nil
            Write(format("TM;%d;%d", t, slot))
        end
        return
    end
    if totemName[slot] == name and totemStart[slot] == start then return end
    totemName[slot], totemStart[slot] = name, start
    Write(format("TM;%d;%d;%s;%d;%d", t, slot, Escape(name), Ms(start) - t, floor(duration * 1000 + 0.5)))
end

local function WriteTotems(t)
    for slot = 1, D.MAX_TOTEMS do
        WriteTotem(t, slot)
    end
end

local function OnTotem(event, slot)
    local t = Now()
    if slot then
        WriteTotem(t, slot)
    else
        WriteTotems(t)
    end
end

local function EnchantName(slot)
    local count, texts = ns.ScanLines("SetInventoryItem", "player", slot)
    for i = 1, count do
        local text = texts[i]
        if text then
            for _, pattern in ipairs(ns.ENCHANT_TIME) do
                local name = text:match(pattern)
                if name then return name end
            end
        end
    end
    return ""
end

local function WriteEnchant(t, slot, has, expiration, charges)
    if not has then
        if enchantEnd[slot] then
            enchantEnd[slot], enchantCharges[slot] = nil, nil
            Write(format("WE;%d;%d", t, slot))
        end
        return
    end
    expiration, charges = expiration or 0, charges or 0
    local ends = t + expiration
    local known = enchantEnd[slot]
    if known and charges == enchantCharges[slot] and abs(ends - known) < ENCHANT_JITTER then return end
    enchantEnd[slot], enchantCharges[slot] = ends, charges
    Write(format("WE;%d;%d;%d;%d;%s", t, slot, expiration, charges, Escape(EnchantName(slot))))
end

local function WriteEnchants(t)
    local main, mainLeft, mainCharges, off, offLeft, offCharges = GetWeaponEnchantInfo()
    WriteEnchant(t, D.WEAPON_SLOTS[1], main, mainLeft, mainCharges)
    WriteEnchant(t, D.WEAPON_SLOTS[2], off, offLeft, offCharges)
end

local function OnInventory()
    WriteEnchants(Now())
end

local function Toggle(t, key, on)
    local value = on and 1 or 0
    if toggles[key] == value then return end
    toggles[key] = value
    Write(format("Z;%d;%s;%d", t, key, value))
end

local function AutoRepeat()
    if not IsAutoRepeatSpell then return false end
    for _, id in ipairs(D.AUTO_REPEAT) do
        local name = GetSpellInfo(id)
        if name and IsAutoRepeatSpell(name) then return true end
    end
    return false
end

local TOGGLE_EVENT = {
    PLAYER_ENTER_COMBAT = { "aa", true },
    PLAYER_LEAVE_COMBAT = { "aa", false },
    START_AUTOREPEAT_SPELL = { "ar", true },
    STOP_AUTOREPEAT_SPELL = { "ar", false },
    PET_ATTACK_START = { "pa", true },
    PET_ATTACK_STOP = { "pa", false },
}

local function OnToggle(event)
    local toggle = TOGGLE_EVENT[event]
    Toggle(Now(), toggle[1], toggle[2])
end

local PLAYER_UNIT_HANDLERS = {
    UNIT_POWER = OnPower,
    UNIT_DISPLAYPOWER = OnDisplayPower,
    UNIT_COMBO_POINTS = OnCombo,
    UNIT_INVENTORY_CHANGED = OnInventory,
}
for event in pairs(D.POWER_EVENT) do
    PLAYER_UNIT_HANDLERS[event] = OnPower
end

local EVENT_HANDLERS = {
    RUNE_POWER_UPDATE = OnRune,
    RUNE_TYPE_UPDATE = OnRune,
    PLAYER_TOTEM_UPDATE = OnTotem,
    BAG_UPDATE = OnBags,
}
for event in pairs(TOGGLE_EVENT) do
    EVENT_HANDLERS[event] = OnToggle
end

frame:SetScript("OnEvent", function(self, event, unit, ...)
    local handler = PLAYER_UNIT_HANDLERS[event]
    if handler then
        if unit ~= "player" then return end
    else
        handler = EVENT_HANDLERS[event]
    end
    Run(handler, event, event, unit, ...)
end)

function ClassState.Begin(t)
    local _
    _, class = UnitClass("player")
    lastUnit = nil
    Track(PLAYER)
    Track(PET)
    powerEvents, powerUnitEvents = 0, 0
    runeKind, runeStart, runeT, runeIndex = {}, {}, {}, {}
    totemName, totemStart = {}, {}
    enchantEnd, enchantCharges = {}, {}
    toggles = {}

    local kind = UnitPowerType("player")
    Power(t, PLAYER, "y", kind)
    ClassState.UnitPowers(t, PLAYER, "player")
    if D.COMBO_CLASS[class] then
        WriteCombo(t)
    end
    if class == "DEATHKNIGHT" then
        WriteRunes(t)
        frame:RegisterEvent("RUNE_POWER_UPDATE")
        frame:RegisterEvent("RUNE_TYPE_UPDATE")
    end
    if class == "WARLOCK" then
        WriteShards(t)
        frame:RegisterEvent("BAG_UPDATE")
    end
    WriteTotems(t)
    WriteEnchants(t)
    local attack = GetSpellInfo(D.ATTACK_SPELL)
    Toggle(t, "aa", attack and IsCurrentSpell(attack))
    Toggle(t, "ar", AutoRepeat())
    if UnitExists("pet") then
        Toggle(t, "pa", IsPetAttackActive and IsPetAttackActive())
    end

    for event in pairs(PLAYER_UNIT_HANDLERS) do
        if event == "UNIT_POWER" then
            pcall(ns.RegisterUnit, frame, event, "player")
        else
            ns.RegisterUnit(frame, event, "player")
        end
    end
    frame:RegisterEvent("PLAYER_TOTEM_UPDATE")
    for event in pairs(TOGGLE_EVENT) do
        frame:RegisterEvent(event)
    end
end

function ClassState.TargetChanged(t)
    if D.COMBO_CLASS[class] then
        WriteCombo(t)
    end
end

function ClassState.Poll(t)
    WriteEnchants(t)
end

function ClassState.Stop()
    frame:UnregisterAllEvents()
    return { power = powerEvents, powerUnit = powerUnitEvents }
end
