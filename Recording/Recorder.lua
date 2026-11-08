local _, ns = ...

local Recorder = {}
ns.Recorder = Recorder

local D = ns.Data
local Store, Target, Boss = ns.Store, ns.Target, ns.Boss
local Escape, NumberText, KV = ns.Escape, ns.NumberText, ns.KV

local Write = Store.Write
local format, floor, select, tostring, next = string.format, math.floor, select, tostring, next
local concat = table.concat
local pcall, debugprofilestop, GetTime, UnitAura = pcall, debugprofilestop, GetTime, UnitAura

local ERROR_CAP = 20
local UNKNOWN_CAP = 512
local ITEM_SLOTS = { 10, 13, 14 }

local active = false
local t0, t0ms = 0, 0
local probes = {}
local errors, errorCount, errorKinds = {}, 0, 0
local cpuMs, cpuMax, cpuBy = 0, 0, {}

local function Now()
    return floor((GetTime() - t0) * 1000 + 0.5)
end

local function Ms(at)
    return floor((at - t0) * 1000 + 0.5)
end

local function Probe(key, value)
    if probes[key] then return end
    probes[key] = true
    Write(ns.ProbeLine(key, value))
end

local function Fail(where, err)
    errorCount = errorCount + 1
    local text = tostring(err)
    if errors[text] or errorKinds >= ERROR_CAP then return end
    errors[text] = true
    errorKinds = errorKinds + 1
    Write(format("E;%d;%s;%s", Now(), where, Escape(text)))
    ns.SayError()
end

local function AddCpu(where, spent)
    cpuMs = cpuMs + spent
    cpuBy[where] = (cpuBy[where] or 0) + spent
    if spent > cpuMax then
        cpuMax = spent
    end
end

local function Run(handler, where, ...)
    local start = debugprofilestop()
    local ok, err = pcall(handler, ...)
    AddCpu(where, debugprofilestop() - start)
    if not ok then
        Fail(where, err)
    end
end

local function Try(where, handler, ...)
    local ok, err = pcall(handler, ...)
    if not ok then
        Fail(where, err)
    end
end

Recorder.Now = Now
Recorder.Ms = Ms
Recorder.Probe = Probe
Recorder.Run = Run

local statFields = {}

local function Field(name, read, group)
    statFields[#statFields + 1] = { name = name, read = read, group = group }
end

local function Rating(id)
    return function()
        return GetCombatRating(id)
    end
end

local function RatingBonus(id)
    return function()
        return GetCombatRatingBonus(id)
    end
end

for school = 2, 7 do
    Field("sp" .. school, function()
        return GetSpellBonusDamage(school)
    end, "sp")
end
for school = 2, 7 do
    Field("cr" .. school, function()
        return GetSpellCritChance(school)
    end, "cr")
end
Field("heal", GetSpellBonusHealing)
Field("ap", function()
    local base, pos, neg = UnitAttackPower("player")
    return base + pos + neg
end)
Field("rap", function()
    local base, pos, neg = UnitRangedAttackPower("player")
    return base + pos + neg
end)
Field("mcr", GetCritChance)
Field("rcr", GetRangedCritChance)
Field("hit", Rating(8))
Field("hitp", RatingBonus(8))
Field("mhitp", RatingBonus(6))
Field("rhitp", RatingBonus(7))
Field("crr", Rating(11))
Field("hr", Rating(20))
Field("hp", RatingBonus(20))
Field("mhp", RatingBonus(18))
Field("rhp", RatingBonus(19))
Field("exr", Rating(24))
Field("ex", GetExpertise)
Field("arr", Rating(25))
Field("arp", GetArmorPenetration)
for stat, name in ipairs(D.STAT_KEY) do
    Field(name, function()
        local _, effective = UnitStat("player", stat)
        return effective
    end)
end
Field("mmax", function()
    return UnitPowerMax("player", 0)
end)
Field("form", GetShapeshiftForm)
Field("ms", function()
    return (UnitAttackSpeed("player"))
end)
Field("os", function()
    local _, off = UnitAttackSpeed("player")
    return off
end)
Field("rs", function()
    return (UnitRangedDamage("player"))
end)

local function Sparse(tag, fields)
    local count = #fields
    local current, base, fresh, parts = {}, {}, {}, {}
    local lastT, lastIndex
    local sparse = { names = {} }
    for i, field in ipairs(fields) do
        sparse.names[i] = field.name
    end

    local function Read(out)
        for i = 1, count do
            out[i] = fields[i].read() or 0
        end
    end

    local function SharedValue(group, first, values, from)
        local value = values[first]
        local i = first
        while i <= count and fields[i].group == group do
            if values[i] ~= value or values[i] == from[i] then
                return nil, i
            end
            i = i + 1
        end
        return value, i
    end

    local function Line(t, values, from)
        local n = 2
        parts[1], parts[2] = tag, t
        local i = 1
        while i <= count do
            local field = fields[i]
            local value, after
            if field.group and (i == 1 or fields[i - 1].group ~= field.group) then
                value, after = SharedValue(field.group, i, values, from)
            end
            if value ~= nil then
                n = n + 1
                parts[n] = field.group .. "=" .. format("%.9g", value)
                i = after
            else
                if values[i] ~= from[i] then
                    n = n + 1
                    parts[n] = field.name .. "=" .. format("%.9g", values[i])
                end
                i = i + 1
            end
        end
        return concat(parts, ";", 1, n)
    end

    local function Keep(from, to)
        for i = 1, count do
            to[i] = from[i]
        end
    end

    function sparse.Sample(t)
        Read(fresh)
        local same = true
        for i = 1, count do
            if fresh[i] ~= current[i] then
                same = false
                break
            end
        end
        if same then return end
        if lastT == t and lastIndex and Store.ReplaceLast(lastIndex, Line(t, fresh, base)) then
            Keep(fresh, current)
            return
        end
        Keep(current, base)
        lastIndex = Store.Write(Line(t, fresh, current))
        lastT = t
        Keep(fresh, current)
    end

    function sparse.Reset()
        for i = 1, count do
            current[i], base[i] = nil, nil
        end
        lastT, lastIndex = nil, nil
    end

    return sparse
end

Recorder.Sparse = Sparse

local stats = Sparse("T", statFields)
local latency

local function SampleStats(t)
    local _, _, lag = GetNetStats()
    if lag ~= latency then
        latency = lag
        Write(format("W;%d;lat;%d", t, lag))
    end
    stats.Sample(t)
end

local function ResetStats()
    stats.Reset()
    latency = nil
end

local AURA_WARN_AT = 41
local AURA_CAP = 160
local KEY_STEP = 16777216
local OCC_STEP = 8 * KEY_STEP
local SOURCE = { [0] = "", "p", "t", "o" }
local OCCURRENCE = setmetatable({ [0] = "" }, {
    __index = function(list, k)
        local text = ";" .. k
        list[k] = text
        return text
    end,
})

local AURA_FULL = "A;%d;%s;%s;%d;%d;%d;%d;%s%s"
local AURA_DURATION = "A;%d;%s;%s;%d;%d;%d;;%s%s"
local AURA_EXPIRY = "A;%d;%s;%s;%d;%d;;%d;%s%s"
local AURA_BARE = "A;%d;%s;%s;%d;%d;;;%s%s"

local function AuraUnit(token, code, withCaster, harmful)
    return {
        token = token, code = code, withCaster = withCaster, harmful = harmful,
        stacks = {}, expiry = {}, duration = {}, caster = {}, seen = {}, count = 0,
    }
end

local targetHarmful = "HARMFUL"
local playerAuras = AuraUnit("player", "p", false, "HARMFUL")
local targetAuras = AuraUnit("target", "t", true, targetHarmful)
local petAuras = AuraUnit("pet", "e", true, "HARMFUL")
local scanGen = 0
local occGen, occN = {}, {}
local auraCapWarned, aura41Warned = false, false

local function CasterCode(caster)
    if caster == "player" then
        return 1
    elseif caster == "target" then
        return 2
    elseif caster == nil then
        return 0
    end
    return 3
end

local function WriteAura(t, u, op, sp, n, d, withDuration, expiry, code, k)
    if expiry > 0 then
        local left = Ms(expiry) - t
        if withDuration then
            Write(format(AURA_FULL, t, u, op, sp, n, d, left, SOURCE[code], OCCURRENCE[k]))
        else
            Write(format(AURA_EXPIRY, t, u, op, sp, n, left, SOURCE[code], OCCURRENCE[k]))
        end
    elseif withDuration then
        Write(format(AURA_DURATION, t, u, op, sp, n, d, SOURCE[code], OCCURRENCE[k]))
    else
        Write(format(AURA_BARE, t, u, op, sp, n, SOURCE[code], OCCURRENCE[k]))
    end
end

local function ScanFilter(unit, filter, debuff, t)
    local stacksOf, expiryOf, durationOf = unit.stacks, unit.expiry, unit.duration
    local casterOf, seen = unit.caster, unit.seen
    for i = 1, D.AURA_SCAN do
        local name, _, _, stacks, _, duration, expiration, caster, _, _, spellId = UnitAura(unit.token, i, filter)
        if not name then break end
        if i == AURA_WARN_AT and not aura41Warned then
            aura41Warned = true
            Write(format("W;%d;aura41;%s", t, unit.code))
        end
        spellId = spellId or 0
        local code = CasterCode(caster)
        local key0 = spellId + (unit.withCaster and (code * 2 + debuff) or debuff) * KEY_STEP
        local k = 0
        if occGen[key0] == scanGen then
            k = occN[key0] + 1
        end
        occGen[key0], occN[key0] = scanGen, k
        local key = key0 + k * OCC_STEP
        stacks = stacks or 0
        expiration = expiration or 0
        local d = floor((duration or 0) * 1000 + 0.5)
        local old = stacksOf[key]
        if not old then
            if unit.count >= AURA_CAP then
                if not auraCapWarned then
                    auraCapWarned = true
                    Write(format("W;%d;auracap;%s", t, unit.code))
                end
            else
                unit.count = unit.count + 1
                stacksOf[key], expiryOf[key], durationOf[key] = stacks, expiration, d
                casterOf[key], seen[key] = code, scanGen
                ns.CombatLog.NameAura(spellId, name)
                WriteAura(t, unit.code, "+", spellId, stacks, d, true, expiration, code, k)
            end
        else
            seen[key] = scanGen
            if expiration ~= expiryOf[key] then
                local withDuration = d ~= durationOf[key]
                stacksOf[key], expiryOf[key], durationOf[key], casterOf[key] = stacks, expiration, d, code
                WriteAura(t, unit.code, "~", spellId, stacks, d, withDuration, expiration, code, k)
            elseif stacks ~= old then
                local withDuration = d ~= durationOf[key]
                stacksOf[key], durationOf[key] = stacks, d
                WriteAura(t, unit.code, "#", spellId, stacks, d, withDuration, expiration, code, k)
            end
        end
    end
end

local function ScanAuras(unit, t)
    scanGen = scanGen + 1
    ScanFilter(unit, "HELPFUL", 0, t)
    ScanFilter(unit, unit.harmful, 1, t)
    local stacksOf, casterOf = unit.stacks, unit.caster
    for key, gen in next, unit.seen do
        if gen ~= scanGen and stacksOf[key] then
            stacksOf[key] = false
            unit.count = unit.count - 1
            Write(format("A;%d;%s;-;%d;;;;%s%s", t, unit.code, key % KEY_STEP, SOURCE[casterOf[key] or 0],
                OCCURRENCE[floor(key / OCC_STEP)]))
        end
    end
end

local function ResetAuras(mineOnTarget)
    targetHarmful = mineOnTarget and "HARMFUL|PLAYER" or "HARMFUL"
    playerAuras = AuraUnit("player", "p", false, "HARMFUL")
    targetAuras = AuraUnit("target", "t", true, targetHarmful)
    petAuras = AuraUnit("pet", "e", true, "HARMFUL")
    occGen, occN = {}, {}
    auraCapWarned, aura41Warned = false, false
end

function Recorder.PetAuras(t)
    ScanAuras(petAuras, t)
end

local SUBJECT_CAP = 8
local SAMPLE_STEP = 0.5
local SAMPLE_STEP_MS = 500
local HEALTH_EVERY = 2

local subjects, subjectByGuid = {}, {}
local sampling = false
local speed, lastTick
local ticks, encounterTicks = 0, 0

local function WriteSpeed(t)
    local current = floor(GetUnitSpeed("player") * 100 + 0.5) / 100
    if current ~= speed then
        speed = current
        Write(format("P;%d;%s", t, NumberText(current)))
    end
end

local function Won(subject, t, cue)
    if subject.won or subject.dead then return false end
    subject.won = true
    Write(format("W;%d;win;%s", t, cue))
    return true
end

local function SampleHealth(subject, t, final)
    if subject.dead then return false end
    local unit = Boss.Find(subject.guid, subject.unit)
    if not unit then return false end
    subject.unit = unit
    local hp, max = UnitHealth(unit), UnitHealthMax(unit)
    if hp ~= subject.hp or max ~= subject.max then
        if max ~= subject.max then
            Write(format("H;%d;%d;%d;%d", t, subject.n, hp, max))
        else
            Write(format("H;%d;%d;%d", t, subject.n, hp))
        end
        subject.hp, subject.max = hp, max
    end
    if final or hp <= 0 then return false end
    if not subject.friendly then
        if not subject.boss or not UnitIsFriend("player", unit) then return false end
        subject.friendly = true
        return Won(subject, t, "faction")
    end
    if not subject.heal then return false end
    if hp < max then
        subject.below = true
        return false
    end
    return subject.below == true and Won(subject, t, "health")
end

local function Tick()
    local t = Now()
    lastTick = t
    ticks = ticks + 1
    local won = false
    if ticks % HEALTH_EVERY == 0 then
        for _, subject in ipairs(subjects) do
            won = SampleHealth(subject, t) or won
        end
    end
    if Boss.EncounterUnits() > 0 then
        encounterTicks = encounterTicks + 1
    end
    WriteSpeed(t)
    ns.ClassState.Poll(t)
    if won then
        ns.Session.BossWon(t)
    end
end

local ticker
ticker = ns.NewTimer(function()
    if not sampling then return end
    Run(Tick, "sample")
    ticker.Start(SAMPLE_STEP)
end)

local function AddSubject(info, t)
    local known = info and info.guid and subjectByGuid[info.guid]
    if known or not info or not info.guid or #subjects >= SUBJECT_CAP then return known end
    local win = D.BOSS_WIN[info.entry or 0]
    local subject = { n = #subjects + 1, guid = info.guid, unit = info.unit, name = info.name, friendly = info.friendly,
        boss = info.by ~= nil and info.by ~= "target" and info.by ~= "dummy", heal = info.friendly and win == "heal",
        hidden = win == "hidden" }
    subjects[subject.n] = subject
    subjectByGuid[info.guid] = subject
    ns.CombatLog.Watch(info.guid, subject.n, subject.heal)
    Write(format("B;%d;%d;%s;%d;%s;%s;%d;%d;%s", t, subject.n, Escape(info.guid), info.entry or 0, Escape(info.name),
        Escape(info.class), info.level or 0, info.hpMax or 0, info.by or "target"))
    SampleHealth(subject, t)
    return subject
end

local function PokeSampler(t)
    if sampling and not ticker.running and (not lastTick or t - lastTick >= SAMPLE_STEP_MS) then
        Tick()
    end
end

local function StartSampling(list)
    subjects, subjectByGuid = {}, {}
    speed, lastTick = nil, nil
    ticks, encounterTicks = 0, 0
    sampling = true
    local t = Now()
    for _, info in ipairs(list) do
        AddSubject(info, t)
    end
    WriteSpeed(t)
    lastTick = t
    if ticker.native then
        ticker.Start(SAMPLE_STEP)
    end
end

local function StopSampling()
    sampling = false
    ticker.Stop()
end

function Recorder.SubjectDied(guid)
    local t = Now()
    local subject = subjectByGuid[guid]
    if not subject or subject.dead then return end
    if subject.hp ~= 0 then
        Write(format("H;%d;%d;0", t, subject.n))
        subject.hp = 0
    end
    subject.dead = true
    ns.Session.BossDied(t, guid)
end

function Recorder.Subjects()
    return subjects
end

function Recorder.AllSubjectsDead()
    if #subjects == 0 then return false end
    for _, subject in ipairs(subjects) do
        if not subject.dead then return false end
    end
    return true
end

function Recorder.BossesDead(onlyBosses)
    if not onlyBosses then return Recorder.AllSubjectsDead() end
    local any = false
    for _, subject in ipairs(subjects) do
        if subject.boss then
            if not subject.dead then return false end
            any = true
        end
    end
    return any
end

function Recorder.IsFriendly(guid)
    local subject = subjectByGuid[guid]
    return subject ~= nil and subject.friendly == true
end

function Recorder.HealWin(guid)
    local subject = subjectByGuid[guid]
    return subject ~= nil and subject.heal == true
end

function Recorder.Decided()
    for _, subject in ipairs(subjects) do
        if subject.boss and (subject.hidden or (subject.friendly and not subject.heal and not subject.won)) then
            return false
        end
    end
    return true
end

function Recorder.Below(guid)
    local subject = subjectByGuid[guid]
    return subject ~= nil and subject.below == true and not subject.won
end

function Recorder.SubjectHealed(guid)
    local subject = subjectByGuid[guid]
    local t = Now()
    if subject and Won(subject, t, "heal") then
        ns.Session.BossWon(t)
    end
end

local function OnFaction(unit)
    local subject = unit and subjectByGuid[UnitGUID(unit) or ""]
    if not subject or subject.friendly then return end
    local t = Now()
    if SampleHealth(subject, t) then
        ns.Session.BossWon(t)
    end
end

function Recorder.IsSubject(guid)
    return subjectByGuid[guid] ~= nil
end

local frame = CreateFrame("Frame")
local playerGUID
local book = { names = {} }
local unknown, unknownCount = {}, 0
local runes = false
local clearCalls, noCleu, cleuAtLastCast, lastCastT = 0, 0, 0, nil
local fpsSum, fpsCount, fpsMin = 0, 0, nil
local auraP, auraT, foreign = 0, 0, 0
local lastGcdStart, lastGcdDuration = 0, 0

Recorder.FIELDS = {
    { "N", "t,sp,tg" },
    { "S", "t,sp,cid,csr,ct,gsr,gd,rb" },
    { "C", "t,sp,cid,gsr,gd,mana,pw,cp,ru" },
    { "X", "t,sp,cid,k,cer" },
    { "Y", "t,sp,k,csr,cer" },
    { "L", "t,c,sub,sp,r,dst" },
    { "V", "dc,ev,src,dst,args" },
    { "T", "t," .. concat(stats.names, ",") },
    { "K", "t,gsr,gd" },
    { "A", "t,u,op,sp,n,d,er,src,k" },
    { "G", "t,guid,entry,level,class,hpMax" },
    { "I", "t,sp,s10,d10,s13,d13,s14,d14" },
    { "M", "t,text" },
    { "D", "id,kind,text" },
    { "W", "t,code,value" },
    { "E", "t,where,text" },
    { "B", "t,n,guid,entry,name,class,level,hpMax,by" },
    { "H", "t,n,hp,max" },
    { "P", "t,v" },
    { "O", "n,src,sp,hits,amount,over,first,last" },
    { "R", "sp,steps" },
    { "CH", "t,k,id" },
}

local CHAT_CAP = 256
local CHAT_KIND = { CHAT_MSG_MONSTER_YELL = "y", CHAT_MSG_MONSTER_EMOTE = "e", CHAT_MSG_RAID_BOSS_EMOTE = "r" }
local chatIds, chatCount = {}, 0

local function OnChat(event, text, sender)
    local kind = CHAT_KIND[event]
    if not kind or type(text) ~= "string" then return end
    sender = sender or ""
    if kind ~= "r" then
        local known = false
        for _, subject in ipairs(subjects) do
            if subject.name == sender then
                known = true
                break
            end
        end
        if not known then return end
    end
    local key = sender .. ";" .. text
    local id = chatIds[key]
    if not id then
        if chatCount >= CHAT_CAP then return end
        chatCount = chatCount + 1
        id = chatCount
        chatIds[key] = id
        Write(format("D;%d;c;%s", id, Escape(key)))
    end
    Write(format("CH;%d;%s;%d", Now(), kind, id))
end

local function SpellId(name, rank)
    if not name then return 0 end
    rank = rank or ""
    local ranks = book.names[name]
    local id = ranks and ranks[rank]
    if id then return id end
    ranks = unknown[name]
    id = ranks and ranks[rank]
    if id then return id end
    if unknownCount >= UNKNOWN_CAP then return 0 end
    unknownCount = unknownCount + 1
    id = -unknownCount
    if not ranks then
        ranks = {}
        unknown[name] = ranks
    end
    ranks[rank] = id
    Write(format("D;%d;s;%s", id, Escape(name .. ";" .. rank)))
    return id
end

local function Gcd(t)
    if not book.gcd then
        return 0, 0
    end
    local start, duration = GetSpellCooldown(book.gcd)
    if start > 0 and duration > 0 then
        return Ms(start) - t, floor(duration * 1000 + 0.5)
    end
    return 0, 0
end

local function RangeBits()
    local bits = 0
    if book.gcdIndex and IsSpellInRange(book.gcdIndex, "spell", "target") == 1 then
        bits = 1
    end
    if book.meleeIndex and IsSpellInRange(book.meleeIndex, "spell", "target") == 1 then
        bits = bits + 8
    end
    if CheckInteractDistance("target", 4) then
        bits = bits + 2
    end
    if CheckInteractDistance("target", 2) then
        bits = bits + 4
    end
    return bits
end

local function Resources()
    local powerType = UnitPowerType("player")
    local power = powerType and powerType ~= 0 and UnitPower("player", powerType) or nil
    local combo = GetComboPoints("player", "target")
    local rune
    if runes then
        local state = {}
        for i = 1, 6 do
            local _, _, ready = GetRuneCooldown(i)
            state[i] = ready and GetRuneType(i) or 0
        end
        rune = concat(state)
    end
    if rune then
        return format(";%s;%s;%s", power or "", combo > 0 and combo or "", rune)
    elseif combo > 0 then
        return format(";%s;%d", power or "", combo)
    elseif power then
        return ";" .. power
    end
    return ""
end

local function WriteItemCooldowns(t, sp)
    local parts = { format("I;%d;%d", t, sp) }
    for _, slot in ipairs(ITEM_SLOTS) do
        local start, duration = GetInventoryItemCooldown("player", slot)
        parts[#parts + 1] = format("%d;%d", start > 0 and Ms(start) or 0, floor(duration * 1000 + 0.5))
    end
    Write(concat(parts, ";"))
end

Recorder.SpellId = SpellId

function Recorder.ClientMs(ms)
    return ms - t0ms
end

local function OnSent(unit, name, rank, target, ...)
    local t = Now()
    Probe("args.sent", 4 + select("#", ...))
    ns.Session.CastActivity()
    local onTarget = target and target ~= "" and target == UnitName("target") and 1 or 0
    Write(format("N;%d;%d;%d", t, SpellId(name, rank), onTarget))
    if sampling then
        WriteSpeed(t)
    end
    PokeSampler(t)
end

local function OnStart(unit, name, rank, castID, ...)
    local t = Now()
    Probe("args.start", 4 + select("#", ...))
    local sp = SpellId(name, rank)
    local _, _, _, _, startMs, endMs = UnitCastingInfo("player")
    local csr, ct = 0, 0
    if startMs and endMs then
        csr, ct = startMs - t0ms - t, endMs - startMs
    end
    local gsr, gd = Gcd(t)
    Write(format("S;%d;%d;%d;%d;%d;%d;%d;%d", t, sp, castID or 0, csr, ct, gsr, gd, RangeBits()))
    Probe("gcd.first", gd)
    if sp > 0 and not probes["ct.ref"] then
        local _, _, _, _, _, _, castTime = GetSpellInfo(sp)
        Probe("ct.ref", format("%d/%d/%d", sp, castTime or -1, ct))
    end
    SampleStats(t)
end

local function OnSucceeded(unit, name, rank, castID, ...)
    local t = Now()
    Probe("args.succ", 4 + select("#", ...))
    local sp = SpellId(name, rank)
    local gsr, gd = Gcd(t)
    Write(format("C;%d;%d;%d;%d;%d;%d%s", t, sp, castID or 0, gsr, gd, UnitPower("player", 0), Resources()))
    if sp < 0 then
        WriteItemCooldowns(t, sp)
    end
    local seen = ns.CombatLog.Seen()
    if lastCastT and seen == cleuAtLastCast and t - lastCastT > 1000 then
        noCleu = noCleu + 1
        Write(format("W;%d;nocleu;%d", t, noCleu))
    end
    lastCastT, cleuAtLastCast = t, seen
    local fps = GetFramerate()
    fpsSum, fpsCount = fpsSum + fps, fpsCount + 1
    if not fpsMin or fps < fpsMin then
        fpsMin = fps
    end
    SampleStats(t)
    PokeSampler(t)
end

local function OnInterrupted(unit, name, rank, castID)
    Write(format("X;%d;%d;%d;1;0", Now(), SpellId(name, rank), castID or 0))
end

local function OnDelayed(unit, name, rank, castID)
    local t = Now()
    local _, _, _, _, _, endMs = UnitCastingInfo("player")
    Write(format("X;%d;%d;%d;2;%d", t, SpellId(name, rank), castID or 0, endMs and (endMs - t0ms - t) or 0))
end

local function WriteChannel(kind, name, rank)
    local t = Now()
    local sp = SpellId(name, rank)
    local _, _, _, _, startMs, endMs = UnitChannelInfo("player")
    if kind < 3 and startMs and endMs then
        Write(format("Y;%d;%d;%d;%d;%d", t, sp, kind, startMs - t0ms - t, endMs - t0ms - t))
    else
        Write(format("Y;%d;%d;%d", t, sp, kind))
    end
end

local function OnAura(unit)
    local t = Now()
    if unit == "player" then
        auraP = auraP + 1
        ScanAuras(playerAuras, t)
        SampleStats(t)
    else
        auraT = auraT + 1
        ScanAuras(targetAuras, t)
    end
end

local function OnStats()
    SampleStats(Now())
end

local function OnCooldown()
    if not book.gcd then return end
    local start, duration = GetSpellCooldown(book.gcd)
    if start == lastGcdStart and duration == lastGcdDuration then return end
    lastGcdStart, lastGcdDuration = start, duration
    if start > 0 and duration > 0 then
        local t = Now()
        Write(format("K;%d;%d;%d", t, Ms(start) - t, floor(duration * 1000 + 0.5)))
    end
end

local function OnTargetChanged()
    local t = Now()
    local guid = UnitGUID("target")
    targetAuras = AuraUnit("target", "t", true, targetHarmful)
    ns.CombatLog.SetTarget(guid)
    if guid then
        local info = Target.Info()
        Write(format("G;%d;%s;%d;%d;%s;%d", t, guid, info.entry or 0, info.level or 0, Escape(info.class),
            info.hpMax or 0))
        ScanAuras(targetAuras, t)
    else
        Write(format("G;%d;;0;0;;0", t))
    end
    ns.ClassState.TargetChanged(t)
    ns.Session.TargetChanged(guid)
end

local UNIT_HANDLERS = {
    UNIT_SPELLCAST_SENT = OnSent,
    UNIT_SPELLCAST_START = OnStart,
    UNIT_SPELLCAST_SUCCEEDED = OnSucceeded,
    UNIT_SPELLCAST_INTERRUPTED = OnInterrupted,
    UNIT_SPELLCAST_DELAYED = OnDelayed,
    UNIT_SPELLCAST_CHANNEL_START = function(unit, name, rank)
        WriteChannel(1, name, rank)
    end,
    UNIT_SPELLCAST_CHANNEL_UPDATE = function(unit, name, rank)
        WriteChannel(2, name, rank)
    end,
    UNIT_SPELLCAST_CHANNEL_STOP = function(unit, name, rank)
        WriteChannel(3, name, rank)
    end,
    UNIT_AURA = OnAura,
    UNIT_STATS = OnStats,
    UNIT_ATTACK_POWER = OnStats,
    UNIT_RANGED_ATTACK_POWER = OnStats,
    UNIT_ATTACK_SPEED = OnStats,
    UNIT_RANGEDDAMAGE = OnStats,
    UNIT_MAXMANA = OnStats,
}

local EVENT_HANDLERS = {
    PLAYER_TARGET_CHANGED = OnTargetChanged,
    COMBAT_RATING_UPDATE = OnStats,
    PLAYER_DAMAGE_DONE_MODS = OnStats,
    UPDATE_SHAPESHIFT_FORM = OnStats,
    SPELL_UPDATE_COOLDOWN = OnCooldown,
    UNIT_FACTION = OnFaction,
}
for event in pairs(CHAT_KIND) do
    EVENT_HANDLERS[event] = function(text, sender)
        OnChat(event, text, sender)
    end
end

local CAST_EVENTS = {
    "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_DELAYED", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_UPDATE",
    "UNIT_SPELLCAST_CHANNEL_STOP",
}
local STAT_EVENTS = {
    "UNIT_STATS", "UNIT_ATTACK_POWER", "UNIT_RANGED_ATTACK_POWER", "UNIT_ATTACK_SPEED", "UNIT_RANGEDDAMAGE",
    "UNIT_MAXMANA",
}
local PLAYER_EVENTS = {
    "PLAYER_TARGET_CHANGED", "COMBAT_RATING_UPDATE", "PLAYER_DAMAGE_DONE_MODS", "UPDATE_SHAPESHIFT_FORM",
    "SPELL_UPDATE_COOLDOWN",
}

frame:SetScript("OnEvent", function(self, event, unit, ...)
    local handler = UNIT_HANDLERS[event]
    if not handler then
        if active then
            Run(EVENT_HANDLERS[event], event, unit, ...)
        end
        return
    end
    if unit ~= "player" and (unit ~= "target" or event ~= "UNIT_AURA") then
        foreign = foreign + 1
        return
    end
    if not active then
        ns.Session.ArmedCast(event, unit, ...)
        if not active then return end
    end
    Run(handler, event, unit, ...)
end)

local function RegisterUnit(event, ...)
    ns.RegisterUnit(frame, event, ...)
end

function Recorder.Arm()
    RegisterUnit("UNIT_SPELLCAST_SENT", "player")
    RegisterUnit("UNIT_SPELLCAST_START", "player")
end

function Recorder.Disarm()
    if not active then
        frame:UnregisterAllEvents()
    end
end

function Recorder.SetBook(info)
    book = info or { names = {} }
end

function Recorder.Active()
    return active
end

function Recorder.AddCpu(where, spent)
    if active then
        AddCpu(where, spent)
    end
end

function Recorder.Begin(mode, list)
    playerGUID = UnitGUID("player")
    t0 = GetTime()
    t0ms = floor(t0 * 1000 + 0.5)
    probes = {}
    errors, errorCount, errorKinds = {}, 0, 0
    cpuMs, cpuMax, cpuBy = 0, 0, {}
    local _, class = UnitClass("player")
    runes = class == "DEATHKNIGHT"
    unknown, unknownCount = {}, 0
    clearCalls, noCleu, cleuAtLastCast, lastCastT = 0, 0, 0, nil
    fpsSum, fpsCount, fpsMin = 0, 0, nil
    auraP, auraT, foreign = 0, 0, 0
    lastGcdStart, lastGcdDuration = 0, 0
    ResetStats()
    ResetAuras(mode == "boss")
    active = true

    Write(ns.SyncLine("start", nil, t0))
    for _, row in ipairs(Recorder.FIELDS) do
        Write(KV("FIELDS", "type", row[1], "names", row[2]))
    end
    ns.CombatLog.Begin(playerGUID, UnitGUID("target"), mode ~= "boss")
    local t = Now()
    Try("begin", ScanAuras, playerAuras, t)
    Try("begin", ScanAuras, targetAuras, t)
    Try("begin", SampleStats, t)
    Try("begin", OnCooldown)
    Try("begin", ns.ClassState.Begin, t)
    Try("begin", ns.Pet.Begin, t)
    for _, event in ipairs(CAST_EVENTS) do
        RegisterUnit(event, "player")
    end
    for _, event in ipairs(STAT_EVENTS) do
        RegisterUnit(event, "player")
    end
    RegisterUnit("UNIT_AURA", "player", "target")
    for _, event in ipairs(PLAYER_EVENTS) do
        frame:RegisterEvent(event)
    end
    chatIds, chatCount = {}, 0
    if mode == "boss" then
        for event in pairs(CHAT_KIND) do
            frame:RegisterEvent(event)
        end
        frame:RegisterEvent("UNIT_FACTION")
    end
    StartSampling(list or {})
    return t0
end

function Recorder.AddSubject(info)
    if active then
        return AddSubject(info, Now())
    end
end

function Recorder.Throttle()
    frame:UnregisterEvent("UNIT_AURA")
    for _, event in ipairs(STAT_EVENTS) do
        frame:UnregisterEvent(event)
    end
    for _, event in ipairs(PLAYER_EVENTS) do
        if event ~= "PLAYER_TARGET_CHANGED" then
            frame:UnregisterEvent(event)
        end
    end
    ns.CombatLog.Pause()
    ns.ClassState.Stop()
    ns.Pet.Stop()
    StopSampling()
end

function Recorder.End()
    if not active then return nil end
    local t = Now()
    if sampling then
        for _, subject in ipairs(subjects) do
            SampleHealth(subject, t, true)
        end
        WriteSpeed(t)
    end
    StopSampling()
    active = false
    frame:UnregisterAllEvents()
    local class = ns.ClassState.Stop()
    local pet = ns.Pet.Stop()
    local cleu = ns.CombatLog.End()
    local parts = {}
    for where, ms in pairs(cpuBy) do
        parts[#parts + 1] = format("%s:%.3f", where, ms)
    end
    table.sort(parts)
    return {
        t = t,
        cpuMs = cpuMs,
        cpuMaxMs = cpuMax,
        cpuBy = concat(parts, ","),
        fpsAvg = fpsCount > 0 and fpsSum / fpsCount or nil,
        fpsMin = fpsMin,
        noCleu = noCleu,
        clear = clearCalls,
        succCast = cleu.succCast,
        cleuEvents = cleu.seen,
        errors = errorCount,
        cleu0 = cleu.cleu0,
        auraP = auraP,
        auraT = auraT,
        foreign = foreign,
        subjects = #subjects,
        ticks = ticks,
        encounterTicks = encounterTicks,
        others = cleu.others,
        ownDamage = cleu.ownDamage,
        ladderDamage = cleu.ladderDamage,
        gameDamage = cleu.gameDamage,
        hitDamage = cleu.hitDamage,
        firstHit = cleu.firstHit,
        targetDied = cleu.targetDied,
        power = class.power,
        powerUnit = class.powerUnit,
        petEvents = pet.events,
    }
end

function Recorder.OnClear()
    if not active then return end
    clearCalls = clearCalls + 1
    Write(format("W;%d;clear;%d", Now(), clearCalls))
end

function Recorder.Warn(code, value)
    Store.Force(format("W;%d;%s;%s", Now(), code, Escape(value)))
end
