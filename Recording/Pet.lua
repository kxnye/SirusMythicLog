local _, ns = ...

local Pet = {}
ns.Pet = Pet

local D = ns.Data
local Store, Recorder, ClassState, Target = ns.Store, ns.Recorder, ns.ClassState, ns.Target
local Escape = ns.Escape

local Write, Run, Now, ClientMs, SpellId = Store.Write, Recorder.Run, Recorder.Now, Recorder.ClientMs, Recorder.SpellId
local format, match = string.format, string.match
local tonumber = tonumber

local PET = ClassState.PET

local CAST_CODE = {
    UNIT_SPELLCAST_START = 1,
    UNIT_SPELLCAST_SUCCEEDED = 2,
    UNIT_SPELLCAST_INTERRUPTED = 3,
    UNIT_SPELLCAST_DELAYED = 4,
    UNIT_SPELLCAST_CHANNEL_START = 5,
    UNIT_SPELLCAST_CHANNEL_UPDATE = 6,
    UNIT_SPELLCAST_CHANNEL_STOP = 7,
    UNIT_SPELLCAST_FAILED = 8,
}
local CAST_WINDOW = { [1] = UnitCastingInfo, [4] = UnitCastingInfo, [5] = UnitChannelInfo, [6] = UnitChannelInfo }

local STAT_EVENTS = { "UNIT_STATS", "UNIT_ATTACK_POWER", "UNIT_ATTACK_SPEED", "UNIT_MAXHEALTH", "UNIT_RESISTANCES",
    "UNIT_LEVEL" }
local HAPPINESS = 4

local frame = CreateFrame("Frame")
local guid
local events = 0
local book = {}

local fields = {}

local function Field(name, read)
    fields[#fields + 1] = { name = name, read = read }
end

Field("hp", function()
    return UnitHealthMax("pet")
end)
Field("ap", function()
    local base, pos, neg = UnitAttackPower("pet")
    return base + pos + neg
end)
Field("ms", function()
    return (UnitAttackSpeed("pet"))
end)
Field("sp", function()
    return GetPetSpellBonusDamage and GetPetSpellBonusDamage()
end)
Field("arm", function()
    local _, effective = UnitArmor("pet")
    return effective
end)
for stat, name in ipairs(D.STAT_KEY) do
    Field(name, function()
        local _, effective = UnitStat("pet", stat)
        return effective
    end)
end
Field("hap", function()
    return (GetPetHappiness())
end)
Field("dmg", function()
    local _, damage = GetPetHappiness()
    return damage
end)

local stats = Recorder.Sparse("F", fields)

local FIELDS = Recorder.FIELDS
FIELDS[#FIELDS + 1] = { "J", "t,guid,entry,name,family,level" }
FIELDS[#FIELDS + 1] = { "F", "t," .. table.concat(stats.names, ",") }
FIELDS[#FIELDS + 1] = { "PC", "t,ev,sp,cid,csr,cer" }

local function BuildBook()
    book = {}
    for index = 1, HasPetSpells() or 0 do
        local name, rank = GetSpellName(index, "pet")
        local link = GetSpellLink(index, "pet")
        local id = link and tonumber(match(link, "spell:(%d+)"))
        if name and id then
            local ranks = book[name]
            if not ranks then
                ranks = {}
                book[name] = ranks
            end
            ranks[rank or ""] = id
        end
    end
end

local function PetSpell(name, rank)
    local ranks = name and book[name]
    return ranks and ranks[rank or ""] or SpellId(name, rank)
end

local function Refresh(t)
    Recorder.PetAuras(t)
    if not guid then return end
    stats.Sample(t)
    ClassState.UnitPowers(t, PET, "pet")
end

local function WritePet(t)
    local current = UnitGUID("pet")
    if current == guid then return end
    guid = current
    ClassState.Track(PET)
    stats.Reset()
    if current then
        BuildBook()
        Write(format("J;%d;%s;%d;%s;%s;%d", t, Escape(current), Target.Entry(current), Escape(UnitName("pet")),
            Escape(UnitCreatureFamily("pet")), UnitLevel("pet")))
    else
        book = {}
        Write(format("J;%d", t))
    end
    Refresh(t)
end

local function OnPet()
    WritePet(Now())
end

local function OnAura()
    Recorder.PetAuras(Now())
end

local function OnCast(event, unit, name, rank, castID)
    local t = Now()
    local code = CAST_CODE[event]
    local window = CAST_WINDOW[code]
    local startMs, endMs
    if window then
        startMs, endMs = select(5, window("pet"))
    end
    local sp = PetSpell(name, rank)
    if startMs and endMs then
        Write(format("PC;%d;%d;%d;%d;%d;%d", t, code, sp, tonumber(castID) or 0, ClientMs(startMs) - t,
            ClientMs(endMs) - t))
    else
        Write(format("PC;%d;%d;%d;%d", t, code, sp, tonumber(castID) or 0))
    end
end

local function OnStats()
    if guid then
        stats.Sample(Now())
    end
end

local function OnPower(event)
    local kind = D.POWER_EVENT[event]
    ClassState.Power(Now(), PET, D.POWER_CODE[kind], UnitPower("pet", kind), UnitPowerMax("pet", kind))
    if kind == HAPPINESS then
        OnStats()
    end
end

local HANDLERS = { UNIT_AURA = OnAura }
for event in pairs(CAST_CODE) do
    HANDLERS[event] = OnCast
end
for event in pairs(D.POWER_EVENT) do
    HANDLERS[event] = OnPower
end
for _, event in ipairs(STAT_EVENTS) do
    HANDLERS[event] = OnStats
end

local WHERE = { UNIT_PET = "pet.UNIT_PET" }
for event in pairs(HANDLERS) do
    WHERE[event] = "pet." .. event
end

frame:SetScript("OnEvent", function(self, event, unit, ...)
    if event == "UNIT_PET" then
        if unit ~= "player" then return end
        events = events + 1
        Run(OnPet, WHERE[event])
        return
    end
    if unit ~= "pet" then return end
    events = events + 1
    Run(HANDLERS[event], WHERE[event], event, unit, ...)
end)

function Pet.Begin(t)
    guid = nil
    events = 0
    WritePet(t)
    ns.RegisterUnit(frame, "UNIT_PET", "player")
    for event in pairs(HANDLERS) do
        ns.RegisterUnit(frame, event, "pet")
    end
end

function Pet.Stop()
    frame:UnregisterAllEvents()
    return { events = events }
end
