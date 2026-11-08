local _, ns = ...

local CombatLog = {}
ns.CombatLog = CombatLog

local Store, Recorder = ns.Store, ns.Recorder
local Escape, NumberText = ns.Escape, ns.NumberText

local Write, Run, Probe, Now = Store.Write, Recorder.Run, Recorder.Probe, Recorder.Now
local format, find, floor = string.format, string.find, math.floor
local select, tonumber, tostring, type = select, tonumber, tostring, type
local concat = table.concat

local NIL_GUID = "0x0000000000000000"
local HOSTILE = 64
local TYPE_PLAYER = 1024
local CONTROL_PLAYER = 256
local UNIT_CAP = 512
local SPELL_CAP = 1024
local REASON_CAP = 64
local OTHER_CAP = 256
local AURA_NAME_CAP = 512
local REPEAT_CAP = 255

local CAST = { SPELL_CAST_START = 1, SPELL_CAST_SUCCESS = 2, SPELL_CAST_FAILED = 3 }

local AURA = {
    SPELL_AURA_APPLIED = true, SPELL_AURA_REMOVED = true, SPELL_AURA_APPLIED_DOSE = true,
    SPELL_AURA_REMOVED_DOSE = true, SPELL_AURA_BROKEN = true, SPELL_AURA_BROKEN_SPELL = true,
}

local TO_PLAYER = { SPELL_AURA_REFRESH = true, SPELL_ENERGIZE = true, SPELL_PERIODIC_ENERGIZE = true, UNIT_DIED = true,
    SPELL_RESURRECT = true }
local TO_TARGET = { UNIT_DIED = true, UNIT_DESTROYED = true }
local DEATH = { UNIT_DIED = true, UNIT_DESTROYED = true }
local HEAL = { SPELL_HEAL = true, SPELL_PERIODIC_HEAL = true }
for event in pairs(AURA) do
    TO_PLAYER[event] = true
    TO_TARGET[event] = true
end

local SPELL_EVENT = setmetatable({}, {
    __index = function(list, event)
        local spelled = find(event, "^SPELL_") ~= nil or find(event, "^RANGE_") ~= nil
            or find(event, "^DAMAGE_SHIELD") ~= nil or find(event, "^DAMAGE_SPLIT") ~= nil
        list[event] = spelled
        return spelled
    end,
})

local DAMAGE = setmetatable({}, {
    __index = function(list, event)
        local damage = event == "DAMAGE_SHIELD" or event == "DAMAGE_SPLIT"
            or (find(event, "_DAMAGE$") ~= nil and find(event, "DURABILITY", 1, true) == nil)
        list[event] = damage
        return damage
    end,
})

local HURT = setmetatable({}, {
    __index = function(list, event)
        local hurt = DAMAGE[event] or find(event, "_MISSED$") ~= nil
        list[event] = hurt
        return hurt
    end,
})

local ESCAPED = setmetatable({}, {
    __index = function(list, text)
        local escaped = Escape(text)
        list[text] = escaped
        return escaped
    end,
})

local frame = CreateFrame("Frame")
local playerGuid, targetGuid
local watched = {}
local healing = {}
local aggregate, others, otherIndex
local ownDamage, ladderDamage, gameDamage = 0, 0, 0
local blowGame, blowLadder = {}, {}
local hitDamage, firstHit, targetDied, guardians = 0, nil, nil, {}
local cleu0
local units, unitCount
local events, eventCount
local spells, spellCount
local reasons, reasonCount
local auraNames, auraNameCount
local repeats
local seen, succCast, lastStart
local lastRecord
local msSeen, msFraction
local members, checked
local paused = false
local fields = {}
local Account

local function Encode(value)
    local kind = type(value)
    if kind == "number" then
        return tostring(value)
    elseif kind == "string" then
        return ESCAPED[value]
    elseif value == true then
        return "1"
    end
    return ""
end

local function UnitId(guid, name, flags)
    if guid == nil or guid == NIL_GUID then return "" end
    local id = units[guid]
    if id then return id end
    if unitCount >= UNIT_CAP then return guid end
    unitCount = unitCount + 1
    id = tostring(unitCount)
    units[guid] = id
    Write(format("D;%d;u;%s", unitCount, Escape(guid .. ";" .. (name or "") .. ";" .. NumberText(flags or 0))))
    return id
end

local function EventId(event)
    local id = events[event]
    if id then return id end
    eventCount = eventCount + 1
    id = tostring(eventCount)
    events[event] = id
    Write(format("D;%d;e;%s", eventCount, Escape(event)))
    return id
end

local function SpellId(id, name, school)
    if type(id) ~= "number" then return Encode(id) end
    local text = spells[id]
    if text then return text end
    text = tostring(id)
    if spellCount < SPELL_CAP then
        spellCount = spellCount + 1
        spells[id] = text
        Write(format("D;%s;n;%s", text, Escape((name or "") .. ";" .. NumberText(school or 0))))
    end
    return text
end

local function ReasonId(text)
    if not text then return 0 end
    local id = reasons[text]
    if id then return id end
    if reasonCount >= REASON_CAP then return 0 end
    reasonCount = reasonCount + 1
    reasons[text] = reasonCount
    Write(format("D;%d;r;%s", reasonCount, Escape(text)))
    return reasonCount
end

local function FlushRepeat(sp)
    local run = repeats[sp]
    if not run then return end
    repeats[sp] = nil
    if run.n > 0 then
        Write(format("R;%s;%s", sp, concat(run.steps, ",", 1, run.n)))
    end
end

local function Stamp(timestamp)
    if not cleu0 then
        cleu0 = timestamp
        Store.Force(ns.SyncLine("cleu0", timestamp))
        Probe("cleu.minusTime", format("%.3f", timestamp - time()))
    end
    if msSeen < 10 then
        msSeen = msSeen + 1
        if timestamp ~= floor(timestamp) then
            msFraction = true
        end
        if msSeen == 10 or msFraction then
            Probe("cleu.ms", msFraction and 1 or 0)
        end
    end
    return floor((timestamp - cleu0) * 1000 + 0.5)
end

local function RecordCast(timestamp, code, dstGUID, dstName, dstFlags, spellId, spellName, school, reason)
    local t = Now()
    local c = Stamp(timestamp)
    local r = 0
    if code == 3 then
        r = ReasonId(reason)
    elseif code == 1 then
        lastStart = spellId
    elseif spellId == lastStart then
        succCast = succCast + 1
    end
    local target = UnitId(dstGUID, dstName, dstFlags)
    local sp = SpellId(spellId, spellName, school)
    local run = repeats[sp]
    if code == 3 and run and run.r == r and run.target == target and run.n < REPEAT_CAP then
        local dt, dc = t - run.t, c - run.c
        run.n = run.n + 1
        run.steps[run.n] = dc == dt and tostring(dt) or (dt .. ":" .. dc)
        run.t, run.c = t, c
        return
    end
    FlushRepeat(sp)
    if target == "" then
        Write(format("L;%d;%d;%d;%s;%d", t, c, code, sp, r))
    else
        Write(format("L;%d;%d;%d;%s;%d;%s", t, c, code, sp, r, target))
    end
    if code == 3 then
        repeats[sp] = { r = r, target = target, t = t, c = c, n = 0, steps = {} }
    end
end

local function RecordEvent(timestamp, event, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, ...)
    local c = Stamp(timestamp)
    fields[1] = "V"
    fields[2] = c - lastRecord
    lastRecord = c
    fields[3] = EventId(event)
    fields[4] = UnitId(srcGUID, srcName, srcFlags)
    fields[5] = UnitId(dstGUID, dstName, dstFlags)
    local n, from = 5, 1
    if SPELL_EVENT[event] then
        local spellId, spellName, school = ...
        n, from = 6, 4
        fields[6] = SpellId(spellId, spellName, school)
    end
    local last = n
    for i = from, select("#", ...) do
        local text = Encode((select(i, ...)))
        n = n + 1
        fields[n] = text
        if text ~= "" then
            last = n
        end
    end
    Write(concat(fields, ";", 1, last))
    Account(event, srcGUID, srcFlags, dstGUID, dstFlags, ...)
end

Account = function(event, srcGUID, srcFlags, dstGUID, dstFlags, ...)
    if DAMAGE[event] then
        local from = SPELL_EVENT[event] and 4 or 1
        local amount = tonumber((select(from, ...))) or 0
        local overkill = tonumber((select(from + 1, ...))) or 0
        if overkill < 0 then
            overkill = 0
        end
        local npc = dstGUID ~= playerGuid and floor((dstFlags or 0) / TYPE_PLAYER) % 2 == 0
        if dstGUID ~= playerGuid and (srcGUID == playerGuid or (srcFlags or 0) % 2 == 1) then
            ownDamage = ownDamage + amount
            if npc and floor((dstFlags or 0) / CONTROL_PLAYER) % 2 == 0 then
                gameDamage = gameDamage + amount - overkill
            end
        end
        if srcGUID == playerGuid or (guardians[srcGUID] and (srcFlags or 0) % 2 == 1) then
            hitDamage = hitDamage + amount
            if npc then
                ladderDamage = ladderDamage + amount - overkill
            end
        end
        if overkill > 0 and watched[dstGUID] then
            blowGame[dstGUID], blowLadder[dstGUID] = gameDamage, ladderDamage
        end
    elseif event == "SPELL_SUMMON" and srcGUID == playerGuid and dstGUID and dstGUID ~= NIL_GUID then
        guardians[dstGUID] = true
    end
end

local function AddOther(timestamp, event, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, ...)
    local spellId, spellName, school, amount, overkill
    if SPELL_EVENT[event] then
        spellId, spellName, school, amount, overkill = ...
    elseif find(event, "^ENVIRONMENTAL") then
        amount, overkill = select(2, ...)
    else
        amount, overkill = ...
    end
    local c = Stamp(timestamp)
    local n = watched[dstGUID]
    local id = type(spellId) == "number" and spellId or 0
    local bySource = otherIndex[n]
    if not bySource then
        bySource = {}
        otherIndex[n] = bySource
    end
    local src = srcGUID or ""
    local bySpell = bySource[src]
    local row = bySpell and bySpell[id]
    if not row and #others >= OTHER_CAP then
        src, id = "", 0
        bySpell = bySource[src]
        row = bySpell and bySpell[id]
        srcGUID = src
    end
    if not row then
        if not bySpell then
            bySpell = {}
            bySource[src] = bySpell
        end
        row = { n = n, src = src, srcName = srcName, srcFlags = srcFlags, spell = id, spellName = spellName,
            school = school, hits = 0, amount = 0, over = 0, first = c }
        bySpell[id] = row
        others[#others + 1] = row
    end
    row.hits = row.hits + 1
    row.amount = row.amount + (tonumber(amount) or 0)
    overkill = tonumber(overkill) or 0
    if overkill > 0 then
        row.over = row.over + overkill
        blowGame[dstGUID], blowLadder[dstGUID] = gameDamage, ladderDamage
    end
    row.last = c
end

local function Hostile(flags)
    return floor((flags or 0) / HOSTILE) % 2 == 1
end

local function Discover(guid, name, flags, subevent)
    checked[guid] = true
    if DEATH[subevent] or not Hostile(flags) then return end
    local entry = ns.Target.Entry(guid)
    if members[entry] then
        Run(ns.Session.Discovered, "cleu", guid, name, entry)
    end
end

frame:SetScript("OnEvent", function(self, event, timestamp, subevent, srcGUID, srcName, srcFlags, dstGUID, dstName,
    dstFlags, ...)
    seen = seen + 1
    if not firstHit and DAMAGE[subevent] and dstGUID ~= playerGuid
        and (srcGUID == playerGuid or (srcFlags or 0) % 2 == 1) then
        firstHit = Now()
    elseif DEATH[subevent] and (dstGUID == targetGuid or watched[dstGUID]) then
        targetDied = Now()
    end
    if members and not paused then
        if srcGUID and not checked[srcGUID] then
            Discover(srcGUID, srcName, srcFlags, subevent)
        end
        if dstGUID and not checked[dstGUID] then
            Discover(dstGUID, dstName, dstFlags, subevent)
        end
    end
    local keep, died
    local healed = healing[dstGUID] and HEAL[subevent] and (tonumber((select(5, ...))) or 0) > 0
        and Recorder.Below(dstGUID)
    if srcGUID == playerGuid then
        local code = CAST[subevent]
        if code then
            if not paused then
                Run(RecordCast, "cleu", timestamp, code, dstGUID, dstName, dstFlags, ...)
            end
            return
        end
        keep = true
    elseif (srcFlags or 0) % 2 == 1 then
        keep = true
    elseif not aggregate and watched[srcGUID] and (CAST[subevent] or 3) < 3 then
        keep = true
    elseif dstGUID == playerGuid then
        keep = TO_PLAYER[subevent] or HURT[subevent]
    elseif dstGUID == targetGuid or watched[dstGUID] then
        if TO_TARGET[subevent] or (srcGUID == dstGUID and HURT[subevent]) then
            keep = true
            died = DEATH[subevent] and watched[dstGUID]
        elseif aggregate and not paused and watched[dstGUID] and DAMAGE[subevent] then
            Run(AddOther, "cleu", timestamp, subevent, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, ...)
        end
    end
    if keep or healed then
        if paused then
            Run(Account, "cleu", subevent, srcGUID, srcFlags, dstGUID, dstFlags, ...)
        else
            Run(RecordEvent, "cleu", timestamp, subevent, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, ...)
        end
        if died then
            Run(Recorder.SubjectDied, "cleu", dstGUID)
        elseif healed then
            healing[dstGUID] = nil
            Run(Recorder.SubjectHealed, "cleu", dstGUID)
        end
    end
end)

function CombatLog.Begin(player, target, aggregateOthers)
    playerGuid, targetGuid = player, target
    watched, healing = {}, {}
    aggregate, others, otherIndex = aggregateOthers and true or false, {}, {}
    ownDamage, ladderDamage, gameDamage = 0, 0, 0
    blowGame, blowLadder = {}, {}
    hitDamage, firstHit, targetDied, guardians = 0, nil, nil, {}
    cleu0 = nil
    units, unitCount = {}, 0
    events, eventCount = {}, 0
    spells, spellCount = {}, 0
    reasons, reasonCount = {}, 0
    auraNames, auraNameCount = {}, 0
    repeats = {}
    seen, succCast, lastStart = 0, 0, nil
    lastRecord = 0
    msSeen, msFraction = 0, false
    members, checked = nil, nil
    paused = false
    frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
end

function CombatLog.Members(entries)
    members, checked = entries, entries and {} or nil
end

function CombatLog.SetTarget(guid)
    targetGuid = guid
end

function CombatLog.Seen()
    return seen
end

function CombatLog.Damage()
    return gameDamage, ladderDamage
end

function CombatLog.AtBlow(guid)
    if blowGame[guid] == nil then return nil end
    return blowGame[guid], blowLadder[guid]
end

function CombatLog.Watch(guid, n, friendly)
    watched[guid] = n
    healing[guid] = friendly or nil
end

function CombatLog.NameAura(id, name)
    if not auraNames or spells[id] or auraNames[id] or auraNameCount >= AURA_NAME_CAP or not name then return end
    auraNameCount = auraNameCount + 1
    auraNames[id] = true
    Write(format("D;%d;a;%s", id, Escape(name)))
end

function CombatLog.FlushRepeats()
    if not repeats then return end
    local list = {}
    for sp in pairs(repeats) do
        list[#list + 1] = sp
    end
    table.sort(list)
    for _, sp in ipairs(list) do
        FlushRepeat(sp)
    end
end

function CombatLog.Pause()
    paused = true
end

function CombatLog.End()
    frame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    CombatLog.FlushRepeats()
    for _, row in ipairs(others) do
        local src = row.src ~= "" and UnitId(row.src, row.srcName, row.srcFlags) or ""
        local sp = row.spell ~= 0 and SpellId(row.spell, row.spellName, row.school) or "0"
        Store.Force(format("O;%d;%s;%s;%d;%.0f;%.0f;%d;%d", row.n, src, sp, row.hits, row.amount, row.over, row.first,
            row.last))
    end
    return { seen = seen, succCast = succCast, cleu0 = cleu0, ownDamage = ownDamage, ladderDamage = ladderDamage,
        gameDamage = gameDamage, others = #others,
        hitDamage = hitDamage, firstHit = firstHit, targetDied = targetDied }
end
