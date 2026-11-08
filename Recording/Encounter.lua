local _, ns = ...

local Target, Instance, Boss = {}, {}, {}
ns.Target, ns.Instance, ns.Boss = Target, Instance, Boss

local D = ns.Data
local KV = ns.KV

local sub = string.sub
local concat, sort = table.concat, table.sort

local FLAG_LADDER, FLAG_MORTAL = 1, 2

function Target.Entry(guid)
    if #guid < 16 then return 0 end
    if C_GUID and C_GUID.GetObjectID then
        local id = C_GUID.GetObjectID(guid)
        if id then return id end
    end
    local high = sub(guid, 3, 6)
    if high == "F130" or high == "F150" or high == "F110" then
        return tonumber(sub(guid, -12, -7), 16) or 0
    end
    return 0
end

function Target.Info(unit)
    unit = unit or "target"
    local guid = UnitGUID(unit)
    if not guid then return nil end
    return {
        guid = guid,
        entry = Target.Entry(guid),
        name = UnitName(unit),
        level = UnitLevel(unit),
        class = UnitClassification(unit),
        kind = UnitCreatureType(unit),
        hpMax = UnitHealthMax(unit),
        hp = UnitHealth(unit),
        unit = unit,
    }
end

function Target.IsDummy(info)
    return info ~= nil and D.DUMMY_ENTRY[info.entry] == true
end

function Target.Alive()
    return not UnitIsDead("target") and UnitHealth("target") > 0
end

function Target.DummyAlive()
    return Target.IsDummy(Target.Info()) and Target.Alive()
end

function Target.Line(info, where)
    if not info then
        return KV("TARGET", "guid", "", "where", where)
    end
    return KV("TARGET", "guid", info.guid, "entry", info.entry, "name", info.name, "level", info.level,
        "class", info.class, "type", info.kind, "hpMax", info.hpMax, "hp", info.hp, "where", where)
end

local function DummyCVar(name)
    return tonumber(GetCVar(name)) or tonumber(GetCVarDefault(name))
end

local function DummyFlag(bit)
    local on = GetCVarBitfield and GetCVarBitfield("dummyFlags", bit)
    if on ~= nil then return on and 1 or 0 end
end

function Target.DummyLine(where)
    local stage = C_Service and tonumber(C_Service.GetRealmStage())
    local mode = DummyCVar("dummyMode")
    local health = DummyCVar("dummyHealth")
    local delay = DummyCVar("dummyDelay")
    local bloodlust = DummyCVar("dummyBloodlust")
    local potion = DummyCVar("dummyAlchemyPotion")
    local food = DummyCVar("dummyFoodBuff")
    local demon = DummyCVar("dummyDemonBuff")
    local ladder = DummyFlag(FLAG_LADDER) == 1
    local modeEff = ladder and 2 or D.DummyOption(D.DUMMY_MODE, mode, stage)
    local potionEff = D.DummyOption(D.DUMMY_POTION, potion, stage)
    local foodEff = D.DummyOption(D.DUMMY_FOOD, food, stage)
    local demonEff = D.DummyOption(D.DUMMY_DEMON, demon, stage)
    local latest, latestSpec, best, bestSpec
    if C_DummyControl then
        latest, latestSpec, best, bestSpec = C_DummyControl.GetRecords()
    end
    return KV("DUMMY", "mode", mode, "health", health, "delay", delay, "bloodlust", bloodlust, "potion", potion,
        "food", food, "demon", demon, "markBuff", DummyCVar("dummyHunterMarkBuff"), "flagsRaw", GetCVar("dummyFlags"),
        "f1", DummyFlag(1), "f2", DummyFlag(2), "f3", DummyFlag(3), "f4", DummyFlag(4), "f5", DummyFlag(5),
        "f6", DummyFlag(6), "f7", DummyFlag(7),
        "modeEff", modeEff, "modeRid", modeEff,
        "healthRid", D.DummyOption(D.DUMMY_HEALTH, health, stage),
        "delayRid", D.DummyOption(D.DUMMY_DELAY, delay, stage),
        "bloodlustRid", D.DummyOption(D.DUMMY_BLOODLUST, bloodlust, stage),
        "potionEff", potionEff, "potionSpell", D.DUMMY_POTION.list[potionEff].spell or 0,
        "potionDelay", potionEff > 4 and 1 or 0,
        "foodEff", foodEff, "foodSpell", D.DUMMY_FOOD.list[foodEff].spell or 0,
        "demonEff", demonEff, "demonSp", D.DUMMY_DEMON.list[demonEff].sp,
        "mortalEff", (ladder or DummyFlag(FLAG_MORTAL) == 1) and 1 or 0, "locked", ladder and 1 or 0,
        "stageKnown", stage and 1 or 0, "stage", stage, "realm", C_Service and C_Service.GetRealmID(),
        "recLatest", latest, "recLatestSpec", latestSpec, "recBest", best, "recBestSpec", bestSpec,
        "where", where)
end

local GROUP_INSTANCE = { party = true, raid = true }

function Instance.Info()
    local name, kind, difficulty, difficultyName, maxPlayers, dynamicDifficulty, isDynamic = GetInstanceInfo()
    return {
        name = name,
        kind = kind or "none",
        difficulty = difficulty,
        difficultyName = difficultyName,
        maxPlayers = maxPlayers,
        dynamicDifficulty = dynamicDifficulty,
        isDynamic = isDynamic,
    }
end

function Instance.Group()
    local inside, kind = IsInInstance()
    if inside and GROUP_INSTANCE[kind] then return true end
    local mode = C_ChallengeMode
    return mode ~= nil and mode.IsChallengeModeActive ~= nil and mode.IsChallengeModeActive() == true
end

function Instance.Line(where)
    local info = Instance.Info()
    return KV("INSTANCE", "name", info.name, "type", info.kind, "difficulty", info.difficulty,
        "difficultyName", info.difficultyName, "maxPlayers", info.maxPlayers, "dynamic", info.dynamicDifficulty,
        "isDynamic", info.isDynamic and 1 or nil, "instanceDifficulty", GetInstanceDifficulty(),
        "zone", GetRealZoneText(), "subzone", GetSubZoneText(), "raid", GetNumRaidMembers(),
        "party", GetNumPartyMembers(), "where", where)
end

function Instance.MythicLine(where)
    local mode = C_ChallengeMode
    if not mode or not mode.IsChallengeModeActive or not mode.IsChallengeModeActive() then return nil end
    local map = mode.GetActiveChallengeMapID()
    local level, affixes = mode.GetActiveKeystoneInfo()
    local damage, health
    if map and level then
        damage, health = mode.GetPowerLevelDamageHealthMod(map, level)
    end
    local deaths, lost = mode.GetDeathCount()
    return KV("MPLUS", "map", map, "level", level, "affixes", affixes and concat(affixes, ","), "damagePct", damage,
        "healthPct", health, "deaths", deaths, "lostS", lost, "where", where)
end

local function ClassList(counts)
    local parts = {}
    for token, n in pairs(counts) do
        parts[#parts + 1] = token .. ":" .. n
    end
    sort(parts)
    return concat(parts, ",")
end

local function Count(counts, token)
    if token then
        counts[token] = (counts[token] or 0) + 1
    end
end

function Instance.RosterLine()
    local all, party = {}, {}
    local size = GetNumRaidMembers()
    if size > 0 then
        local me = UnitName("player")
        local mine
        for i = 1, size do
            local name, _, subgroup = GetRaidRosterInfo(i)
            if name == me then
                mine = subgroup
            end
        end
        for i = 1, size do
            local name, _, subgroup, _, _, token = GetRaidRosterInfo(i)
            Count(all, token)
            if subgroup == mine and name ~= me then
                Count(party, token)
            end
        end
    else
        local _, own = UnitClass("player")
        Count(all, own)
        size = GetNumPartyMembers() + 1
        for i = 1, size - 1 do
            local _, token = UnitClass("party" .. i)
            Count(all, token)
            Count(party, token)
        end
    end
    return KV("ROSTER", "size", size, "classes", ClassList(all), "party", ClassList(party))
end

Boss.UNITS = { "boss1", "boss2", "boss3", "boss4" }

local SCAN_LIMIT = 4
local ENCOUNTER_UNIT = { boss1 = true, boss2 = true, boss3 = true, boss4 = true }
local SCAN_UNITS = { "boss1", "boss2", "boss3", "boss4", "target", "focus", "mouseover", "targettarget", "focustarget",
    "pettarget" }
for i = 1, 4 do
    SCAN_UNITS[#SCAN_UNITS + 1] = "party" .. i .. "target"
end
for i = 1, 40 do
    SCAN_UNITS[#SCAN_UNITS + 1] = "raid" .. i .. "target"
end

function Boss.Check(unit)
    local guid = UnitGUID(unit)
    if not guid then return nil end
    local entry = Target.Entry(guid)
    if D.DUMMY_ENTRY[entry] or UnitIsPlayer(unit) or UnitIsDead(unit) then return nil end
    local encounter = ns.Journal.Find(entry)
    if not UnitCanAttack("player", unit) then
        if encounter and ENCOUNTER_UNIT[unit] then
            return guid, "friendly", encounter
        end
        return nil
    end
    if encounter then
        return guid, "journal", encounter
    end
    if ENCOUNTER_UNIT[unit] then
        return guid, "encounter"
    end
    if UnitClassification(unit) == "worldboss" then
        return guid, "worldboss"
    end
    return nil
end

function Boss.Scan()
    local found, seen = {}, {}
    for _, unit in ipairs(SCAN_UNITS) do
        if #found >= SCAN_LIMIT then break end
        local guid, by, encounter = Boss.Check(unit)
        if guid and not seen[guid] then
            seen[guid] = true
            local info = Target.Info(unit)
            info.by, info.encounter, info.friendly = by, encounter, by == "friendly" or nil
            info.engaged = Boss.Engaged(guid, unit)
            found[#found + 1] = info
        end
    end
    return found
end

function Boss.EncounterUnits()
    local count = 0
    for _, unit in ipairs(Boss.UNITS) do
        if UnitGUID(unit) then
            count = count + 1
        end
    end
    return count
end

function Boss.Find(guid, hint)
    if hint and UnitGUID(hint) == guid then return hint end
    for _, unit in ipairs(SCAN_UNITS) do
        if UnitGUID(unit) == guid then return unit end
    end
    return nil
end

local ENGAGE_GAP = 10
local KILL_LAG = 2
local MEMO_CAP = 4096
local NIL_GUID = "0x0000000000000000"
local find, select, tonumber = string.find, select, tonumber
local listener = CreateFrame("Frame")
local bossOf, memoCount = {}, 0
local engaged = {}
local listening = false

local HOSTILE = setmetatable({}, {
    __index = function(list, event)
        local hostile = (find(event, "_DAMAGE$") ~= nil or find(event, "_MISSED$") ~= nil or event == "DAMAGE_SHIELD"
            or event == "DAMAGE_SPLIT" or event == "SPELL_INTERRUPT") and find(event, "DURABILITY", 1, true) == nil
        list[event] = hostile
        return hostile
    end,
})

local OVERKILL_AT = setmetatable({}, {
    __index = function(list, event)
        local at = 0
        if event == "SWING_DAMAGE" then
            at = 2
        elseif find(event, "^ENVIRONMENTAL") then
            at = 3
        elseif HOSTILE[event] and find(event, "_MISSED$") == nil and event ~= "SPELL_INTERRUPT" then
            at = 5
        end
        list[event] = at
        return at
    end,
})

local function IsBossGuid(guid)
    local known = bossOf[guid]
    if known ~= nil then return known end
    if memoCount >= MEMO_CAP then
        bossOf, memoCount = {}, 0
    end
    known = guid ~= NIL_GUID and ns.Journal.Find(Target.Entry(guid)) ~= nil
    bossOf[guid] = known
    memoCount = memoCount + 1
    return known
end

local function Mark(guid, now, blow)
    local seen = engaged[guid]
    if not seen or (not seen.kill and now - seen.last > ENGAGE_GAP) then
        seen = { first = now, srv = time(), last = now }
        engaged[guid] = seen
        ns.Session.BossEngaged(guid)
    else
        seen.last = now
    end
    if blow then
        seen.blow, seen.blowSrv = now, time()
    end
end

listener:SetScript("OnEvent", function(_, _, _, subevent, srcGUID, _, _, dstGUID, _, _, ...)
    if subevent == "UNIT_DIED" then
        local seen = dstGUID and engaged[dstGUID]
        if seen and not seen.kill then
            local now = GetTime()
            if seen.blow and now - seen.blow <= KILL_LAG then
                seen.kill, seen.killSrv = seen.blow, seen.blowSrv
            else
                seen.kill, seen.killSrv = now, time()
            end
        end
        return
    end
    if not HOSTILE[subevent] or srcGUID == dstGUID then return end
    if dstGUID and IsBossGuid(dstGUID) then
        local at = OVERKILL_AT[subevent]
        Mark(dstGUID, GetTime(), at > 0 and (tonumber((select(at, ...))) or 0) > 0)
    elseif srcGUID and IsBossGuid(srcGUID) then
        Mark(srcGUID, GetTime(), false)
    end
end)

function Boss.Listen(on)
    on = on and true or false
    if on == listening then return end
    listening = on
    if on then
        listener:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    else
        listener:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        engaged = {}
    end
end

function Boss.Forget()
    bossOf, memoCount, engaged = {}, 0, {}
end

function Boss.Engagement(guid)
    local seen = guid and engaged[guid]
    if seen and not seen.kill and GetTime() - seen.last <= ENGAGE_GAP then return seen end
    return nil
end

function Boss.Seen(guid)
    return guid and engaged[guid] or nil
end

function Boss.KillOf(guid)
    local seen = guid and engaged[guid]
    if not seen then return nil end
    if seen.kill then return seen.kill, seen.killSrv end
    if seen.blow and GetTime() - seen.blow <= KILL_LAG then return seen.blow, seen.blowSrv end
    return nil
end

function Boss.Engaged(guid, unit)
    if unit and ENCOUNTER_UNIT[unit] then return true end
    if unit and UnitAffectingCombat(unit) then return true end
    return Boss.Engagement(guid) ~= nil
end
