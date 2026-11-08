local addonName, ns = ...

local Session = {}
ns.Session = Session

local Store, Recorder, Target, Instance, Boss, Journal = ns.Store, ns.Recorder, ns.Target, ns.Instance, ns.Boss, ns.Journal
local Cache, Modifier = ns.Cache, ns.Modifier
local KV, ProbeLine, Print, InCombat, MsSince = ns.KV, ns.ProbeLine, ns.Print, ns.InCombat, ns.MsSince

local format, floor, max = string.format, math.floor, math.max

local OFF, IDLE, ARMED, REC = "off", "idle", "armed", "rec"
local DUMMY, BOSS = "dummy", "boss"
local ENCOUNTER = "encounter"
local WIN, LOST, WIPE = "win", "lost", "wipe"
local CLOSING = { [BOSS] = true, [WIN] = true, [LOST] = true }
local RESULT = { [BOSS] = "kill", [WIN] = "win", [LOST] = "lost", [WIPE] = "wipe" }
local DR_WINDOW = 300
local REGEN_GRACE = 30
local BOSS_GRACE = 5
local KILL_GRACE = 3
local ENCOUNTER_STEP = 1
local ENCOUNTER_ACTIVE = 5
local ENCOUNTER_CAP = 900
local ENGAGE_STEP = 1
local MANUAL_IDLE = 600
local RESUME_WINDOW = 3600
local MOD_WAIT = 15

local state = IDLE
local db
local armed
local session, lastSession, lastEndAt
local resumable
local fullSaid
local lastForm
local postPending
local regenT, endT
local pullAt, pullSrv, killAt, killSrv, killGame, killLadder, finish
local frameAt, frameSrv
local watchFrom, quietAt
local encounter, encounterEntries, encounterSeen
local graceWhy
local encounterEvents = 0
local encounterRegistered = false
local hookedClear = false
local auraWatching = false
local modWatch
local timeStep
local logOurs, logSeenOn, logOptOut = false, nil, false
local Stop
local engageCheck

local frame = CreateFrame("Frame")

local function UpdateUI()
    ns.Button.Refresh()
    ns.Panel.Refresh()
    ns.CleanStats.StateChanged()
end

local laterFn
local later = ns.NewTimer(function()
    local fn = laterFn
    laterFn = nil
    if fn and state ~= REC then
        fn()
    end
    ns.CleanStats.Resume()
end)

local function Later(seconds, fn)
    laterFn = fn
    later.Start(seconds)
end

local function CancelLater()
    laterFn = nil
    later.Stop()
end

local CheckEncounter

local grace = ns.NewTimer(function()
    if state ~= REC then return end
    if graceWhy == ENCOUNTER then
        CheckEncounter()
    elseif CLOSING[graceWhy] or not InCombat() then
        Stop(graceWhy or "idle")
    end
end)

local function Wait(why, seconds)
    graceWhy = why
    grace.Start(seconds)
end

local function GroupInCombat()
    local raid = GetNumRaidMembers()
    if raid > 0 then
        for i = 1, raid do
            if UnitAffectingCombat("raid" .. i) then return true end
        end
        return false
    end
    for i = 1, GetNumPartyMembers() do
        if UnitAffectingCombat("party" .. i) then return true end
    end
    return false
end

local function EncounterAlive()
    local now = GetTime()
    local idle = false
    for _, subject in ipairs(Recorder.Subjects()) do
        if not subject.dead then
            local unit = Boss.Find(subject.guid, subject.unit)
            if unit then
                if UnitAffectingCombat(unit) and not UnitIsDead(unit) then return true end
                idle = true
            else
                local seen = Boss.Seen(subject.guid)
                if seen and not seen.kill and now - seen.last <= ENCOUNTER_ACTIVE then return true end
            end
        end
    end
    return not idle and GroupInCombat()
end

local function LastActivityT()
    local last
    for _, subject in ipairs(Recorder.Subjects()) do
        local seen = Boss.Seen(subject.guid)
        if seen and (not last or seen.last > last) then
            last = seen.last
        end
    end
    if last and session and session.t0 then
        return max(0, floor((last - session.t0) * 1000 + 0.5))
    end
    return Recorder.Now()
end

local function SetAuraWatch()
    local want = (state == ARMED and not InCombat()) or modWatch ~= nil
    if want == auraWatching then return end
    auraWatching = want
    if want then
        ns.RegisterUnit(frame, "UNIT_AURA", "player")
    else
        frame:UnregisterEvent("UNIT_AURA")
    end
end

local modTimer

local function EndModifierWatch()
    modWatch = nil
    modTimer.Stop()
    SetAuraWatch()
end

local function SaveModifier(where, found)
    local out = {}
    Modifier.Lines(where, found, out, MsSince(modWatch.at))
    for _, line in ipairs(out) do
        Store.AddMod(line)
    end
    Modifier.last = Modifier.Key(found)
end

modTimer = ns.NewTimer(function()
    if modWatch and not Recorder.Active() and not InCombat() then
        SaveModifier("equip", Modifier.Read())
    end
    EndModifierWatch()
end)

local function WatchModifier()
    if Recorder.Active() or InCombat() then return end
    if not modWatch then
        modWatch = { key = Modifier.Key(Modifier.Read()) }
    end
    modWatch.at = GetTime()
    modTimer.Start(MOD_WAIT)
end

local function CancelModifierWatch()
    if modWatch then
        EndModifierWatch()
    end
end

local function CheckModifier()
    if not modWatch then return end
    if InCombat() then
        EndModifierWatch()
        return
    end
    local found = Modifier.Read()
    if Modifier.Key(found) ~= modWatch.key then
        SaveModifier("change", found)
        EndModifierWatch()
    end
end

local function ClientLogOn()
    local on = LoggingCombat() and true or false
    if logSeenOn and not on then
        logOptOut = true
        logOurs = false
    end
    logSeenOn = on
    return on
end

local function ArmClientLog(fresh, out)
    if fresh then
        logOptOut = false
    end
    local before = ClientLogOn()
    local call = "skip"
    if not before and db.autoLog and not logOptOut then
        local ok, err = pcall(LoggingCombat, true)
        call = ok and "ok" or tostring(err)
    end
    local after = LoggingCombat() and true or false
    out[#out + 1] = ProbeLine("log.before", before and 1 or 0)
    out[#out + 1] = ProbeLine("log.call", call)
    out[#out + 1] = ProbeLine("log.after", after and 1 or 0)
    local enabled = after and not before
    if enabled then
        logOurs = true
    end
    logSeenOn = after
    return after, enabled
end

local function ReleaseClientLog()
    if state == REC or not logOurs then return end
    logOurs = false
    if not pcall(LoggingCombat, false) or LoggingCombat() then return end
    logSeenOn = false
    if lastSession then
        Store.Append(lastSession, ProbeLine("log.off", 1))
    end
end

local function MeasureTimeStep()
    local start = debugprofilestop()
    local last = GetTime()
    local changes, step = 0, 0
    while debugprofilestop() - start < 20 do
        local now = GetTime()
        if now ~= last then
            changes = changes + 1
            step = floor((now - last) * 1000 + 0.5)
            last = now
            if changes >= 2 then break end
        end
    end
    return step
end

local function StaticProbes(out)
    out[#out + 1] = ProbeLine("api.RegisterUnitEvent", type(frame.RegisterUnitEvent))
    out[#out + 1] = ProbeLine("hook.clear", hookedClear and 1 or 0)
    out[#out + 1] = ProbeLine("cvar.predictedPower", GetCVar("predictedPower"))
    if ns.Snapshot.talentsMatch ~= nil then
        out[#out + 1] = ProbeLine("talents.match", ns.Snapshot.talentsMatch)
    end
    ns.CleanStats.Probes(out)
end

local function ClientProbes(out, measure)
    if timeStep == nil and measure then
        timeStep = MeasureTimeStep()
    end
    if timeStep ~= nil then
        out[#out + 1] = ProbeLine("gt.step", timeStep)
    end
    local book = Cache.LastBook()
    out[#out + 1] = ProbeLine("range.melee", book and book.melee or 0)
    out[#out + 1] = ProbeLine("gcd.ref", book and book.gcd or 0)
    out[#out + 1] = ProbeLine("timer.native", grace.native and 1 or 0)
end

local function RoomForRecording()
    if not Store.Full() then return true end
    if not fullSaid then
        fullSaid = true
        Print("место для логов закончилось, новые бои не записываются. Отправьте файл на upload.sirusmythic.ru и нажмите «Очистить всё» в /sml")
    end
    return false
end

local function AutoDummy()
    return db.enabled and db.dummy
end

local function AutoBoss()
    return db.enabled and db.boss
end

local function UpdateListen()
    local bossRec = state == REC and session ~= nil and session.mode == BOSS
    Boss.Listen(db ~= nil and Instance.Group() and (AutoBoss() or bossRec))
end

local function ModeOf(info)
    if Target.IsDummy(info) then return AutoDummy() and DUMMY or nil end
    if info and AutoBoss() and Instance.Group() and Boss.Check("target") then return BOSS end
    return nil
end

local function BuildArm(info, mode, fresh, rearm)
    Cache.Book()
    local snap
    if rearm or Cache.Take() then
        snap = Cache.Copy()
    end
    local where = rearm and "rearm" or "arm"
    local out = {}
    local modKey = Modifier.Snapshot("arm", out)
    if mode ~= BOSS then
        out[#out + 1] = Target.DummyLine(where)
    end
    out[#out + 1] = Target.Line(info, where)
    StaticProbes(out)
    ClientProbes(out, not rearm)
    local logOn, logAuto
    if rearm then
        logOn = ClientLogOn()
        out[#out + 1] = ProbeLine("log.after", logOn and 1 or 0)
    else
        logOn, logAuto = ArmClientLog(fresh, out)
    end
    return {
        guid = info and info.guid,
        name = info and info.name,
        mode = mode,
        snap = snap,
        lines = out,
        modKey = modKey,
        logOn = logOn,
        logAuto = logAuto,
        at = GetTime(),
    }
end

local function SetArmed(value)
    armed = value
    state = ARMED
    Recorder.Arm()
    SetAuraWatch()
    UpdateUI()
end

local function Disarm()
    state = IDLE
    armed = nil
    Recorder.Disarm()
    SetAuraWatch()
    UpdateUI()
end

local function Arm(warm)
    if state == REC or InCombat() then return end
    local info = Target.Info()
    local mode = ModeOf(info)
    if not mode or not Target.Alive() then
        if state == ARMED then
            Disarm()
        end
        if mode ~= DUMMY then
            ReleaseClientLog()
        end
        if warm and AutoBoss() and Instance.Group() then
            Cache.Book()
            Cache.Take()
        end
        return
    end
    if not RoomForRecording() then return end
    local again = armed and armed.guid == info.guid
    SetArmed(BuildArm(info, mode, not again))
end

local function ArmLater()
    if state ~= REC then
        Arm(true)
    end
end

local function Resumable(guid, player, trigger)
    if armed and armed.resume and (trigger == "manual" or armed.resume.target == guid) then
        return armed.resume
    end
    if resumable and guid and resumable.target == guid and resumable.player == player
        and time() - (resumable.epoch or 0) < RESUME_WINDOW then
        return resumable
    end
    return nil
end

local function SubjectsOf(mode, info, bosses)
    if mode ~= BOSS then
        if not info then return {} end
        info.by = Target.IsDummy(info) and DUMMY or "target"
        return { info }
    end
    local found = bosses or Boss.Scan()
    local chosen, friendly
    for _, boss in ipairs(found) do
        if boss.encounter and (not chosen or (friendly and not boss.friendly)) then
            chosen, friendly = boss.encounter, boss.friendly
        end
    end
    local list = {}
    for _, boss in ipairs(found) do
        if not boss.encounter or boss.encounter == chosen then
            list[#list + 1] = boss
        end
    end
    if #list == 0 and info then
        info.by = "target"
        list[1] = info
    end
    return list, chosen
end

local function MarkSeen(info)
    if encounterEntries and info.entry and encounterEntries[info.entry] then
        encounterSeen[info.entry] = true
    end
end

local function Unseen()
    if not encounterEntries then return nil end
    local count = 0
    for entry in pairs(encounterEntries) do
        if not encounterSeen[entry] then
            count = count + 1
        end
    end
    return count
end

local function ManualMode(info)
    if Target.IsDummy(info) then return DUMMY end
    if Instance.Group() or Boss.Check("target") then return BOSS end
    return DUMMY
end

local function Begin(trigger, mode, bosses)
    if state == REC or not RoomForRecording() then return false end
    local cpu0 = debugprofilestop()
    local inCombat = InCombat()
    local info = Target.Info()
    local player = UnitGUID("player") or ""
    local pre = armed
    mode = mode or (pre and pre.mode) or ManualMode(info)
    local subjects, chosen = SubjectsOf(mode, info, bosses)
    local first = subjects[1]
    local manual = trigger == "manual"
    local resume = Resumable(first and first.guid, player, trigger)
    if resume then
        trigger = "resume"
        manual = manual or resume.manual == true
    end
    local armedHere = pre and not pre.resume and (not info or pre.guid == info.guid)
    if not Cache.LastBook() or (not inCombat and not (armedHere and trigger == "auto")) then
        Cache.Book()
    end
    if not inCombat and (not armedHere or Cache.StaticDirty() or (trigger ~= "auto" and Cache.Stale())) then
        pre = BuildArm(info, mode, false)
    elseif not armedHere then
        local out = {}
        if mode == BOSS then
            StaticProbes(out)
        else
            out[1] = Target.DummyLine("start")
        end
        out[#out + 1] = Target.Line(info, "start")
        ClientProbes(out, not inCombat)
        local logOn, logAuto = ArmClientLog(false, out)
        local stale, dyn = Cache.State()
        pre = { lines = out, logOn = logOn, logAuto = logAuto, stale = stale, dyn = dyn, snap = Cache.Copy() }
    else
        pre.stale, pre.dyn = Cache.State()
    end
    local id, part
    if resume then
        id, part = resume.id, (resume.part or 1) + 1
    else
        id, part = Store.NextId(), 1
    end
    local place = Instance.Info()
    local _, classToken = UnitClass("player")
    session = {
        id = id,
        part = part > 1 and part or nil,
        label = resume and resume.label or "",
        state = "open",
        started = ns.Stamp(),
        epoch = time(),
        target = first and first.guid,
        player = player,
        realm = GetRealmName(),
        name = UnitName("player"),
        classToken = classToken,
        spec = ns.Snapshot.MainTab(),
        bytes = 0,
        records = 0,
        dropped = 0,
        errors = 0,
        chunks = {},
        mode = mode == BOSS and BOSS or nil,
        manual = manual or nil,
        boss = mode == BOSS and (Journal.Name(chosen) or (first and first.name)) or nil,
        encounter = chosen and Journal.Id(chosen) or nil,
        instance = mode == BOSS and place.name or nil,
    }
    resumable = nil
    Store.Open(session)
    Cache.Write(pre.snap, player)
    for _, line in ipairs(pre.lines) do
        Store.Write(line)
    end
    Modifier.last = pre.modKey or Modifier.last
    Store.Write(KV("SESSION", "id", id, "schema", ns.SCHEMA, "label", session.label, "trigger", trigger,
        "mode", session.mode, "manual", manual and 1 or nil, "cl", pre.logOn and 1 or 0,
        "clAuto", pre.logAuto and 1 or 0, "stale", pre.stale and 1 or 0, "snapDyn", pre.dyn and 1 or nil,
        "snapAgeMs", pre.snap and pre.snap.at and MsSince(pre.snap.at) or nil,
        "armAgoMs", pre.at and MsSince(pre.at) or nil,
        "part", session.part, "by", mode == BOSS and first and first.by or nil, "encounter", session.encounter,
        "bosses", chosen and Journal.Count(chosen) or nil))
    Store.Write(Target.Line(info, "start"))
    Store.Write(Instance.Line("start"))
    Store.Write(Instance.MythicLine("start"))
    if mode == BOSS then
        Store.Write(Instance.RosterLine())
        Store.Write(ProbeLine("event.encounter", encounterRegistered and 1 or 0))
        Store.Write(ProbeLine("boss.units", Boss.EncounterUnits()))
        Store.Write(ProbeLine("journal.client", Journal.ClientLine()))
    end
    state = REC
    armed = nil
    regenT, endT, graceWhy = nil, nil, nil
    killAt, killSrv, killGame, killLadder, watchFrom, quietAt, finish = nil, nil, nil, nil, nil, nil, nil
    pullAt, pullSrv = GetTime(), time()
    if mode == BOSS then
        local framed = frameAt and Boss.EncounterUnits() > 0
        for _, subject in ipairs(subjects) do
            local seen = Boss.Engagement(subject.guid)
            if seen and seen.first < pullAt then
                pullAt, pullSrv = seen.first, seen.srv
            end
            if subject.friendly and framed and frameAt < pullAt then
                pullAt, pullSrv = frameAt, frameSrv
            end
        end
    end
    engageCheck.Stop()
    UpdateListen()
    encounterEvents = 0
    CancelLater()
    grace.Stop()
    CancelModifierWatch()
    SetAuraWatch()
    encounter, encounterSeen = chosen, {}
    encounterEntries = chosen and Journal.Entries(chosen) or nil
    for _, subject in ipairs(subjects) do
        MarkSeen(subject)
    end
    session.t0 = Recorder.Begin(mode, subjects)
    ns.CombatLog.Members(encounterEntries)
    Recorder.AddCpu("begin", debugprofilestop() - cpu0)
    if trigger ~= "resume" then
        local how = manual and ", запись запущена вручную" or ""
        if session.boss then
            Print(format("запись боя %d: %s%s.", id, session.boss, how))
        else
            Print(format("запись боя %d%s.", id, how))
        end
    end
    UpdateUI()
    return true
end

local function TryBoss()
    if state == REC or not AutoBoss() or not InCombat() or not Instance.Group() then return false end
    local live = {}
    local idle = false
    for _, boss in ipairs(Boss.Scan()) do
        if boss.engaged then
            live[#live + 1] = boss
        else
            idle = true
        end
    end
    if #live == 0 then
        if idle and engageCheck.native and not engageCheck.running then
            engageCheck.Start(ENGAGE_STEP)
        end
        return false
    end
    engageCheck.Stop()
    return Begin("auto", BOSS, live)
end

engageCheck = ns.NewTimer(function()
    if state ~= REC and InCombat() then
        TryBoss()
    end
end)

local function Post(closed)
    Cache.After(closed)
    local out = {}
    Modifier.last = Modifier.Snapshot("stop", out)
    if closed.mode ~= BOSS then
        out[#out + 1] = Target.DummyLine("stop")
    end
    out[#out + 1] = Target.Line(Target.Info(), "post")
    local addonKB = ns.AddonKB()
    out[#out + 1] = KV("MEMORY", "addonKB", addonKB and floor(addonKB + 0.5), "luaKB",
        floor(collectgarbage("count") + 0.5), "dbKB", floor(Store.DbBytes() / 1024 + 0.5), "where", "post")
    for _, line in ipairs(out) do
        Store.Append(closed, line)
    end
end

local function Rearm()
    local info = Target.Info()
    if not Target.IsDummy(info) then
        ReleaseClientLog()
        return
    end
    if not AutoDummy() or not Target.Alive() or not RoomForRecording() then return end
    SetArmed(BuildArm(info, DUMMY, false, true))
    Later(2, ArmLater)
end

local function SaySaved(fight)
    if not fight then return end
    local first = fight.first
    Print(format("бой %d%s записан: %s, %s%s.", first.id, first.boss and (" (" .. first.boss .. ")") or "",
        ns.Duration(fight.ms), ns.Size(fight.bytes), fight.capped and ", обрезан из-за нехватки памяти" or ""))
end

local function EncounterSpan(reason, info)
    local t0 = session.t0
    if session.mode ~= BOSS or not pullAt or not t0 then return nil end
    local ended = killAt ~= nil and (finish == BOSS or finish == WIN) and (reason == finish or session.manual)
    local pullT = floor((pullAt - t0) * 1000 + 0.5)
    local endAtT = ended and floor((killAt - t0) * 1000 + 0.5) or nil
    local toT = endAtT or endT or regenT or info.t
    local encSec
    if ended and killSrv and pullSrv then
        encSec = killSrv - pullSrv + 1
    else
        encSec = floor((toT - pullT) / 1000) + 1
    end
    local killT = ended and finish == BOSS and endAtT or nil
    local winT = ended and finish == WIN and endAtT or nil
    return pullT, killT, winT, max(1, toT - pullT), max(1, encSec)
end

local function ResultOf(killT, winT)
    if killT then return RESULT[BOSS] end
    if winT then return RESULT[WIN] end
    if finish == LOST or finish == WIPE then return RESULT[finish] end
    return nil
end

Stop = function(reason)
    if state ~= REC then return false end
    local waited = grace.running or reason == "idle"
    grace.Stop()
    graceWhy = nil
    engageCheck.Stop()
    local info = Recorder.End()
    local pullT, killT, winT, gameMs, encSec = EncounterSpan(reason, info)
    local gameDamage, bossDamage
    if pullT then
        if killT or winT or (finish == LOST and killGame) then
            gameDamage, bossDamage = killGame, killLadder
        else
            gameDamage, bossDamage = info.gameDamage, info.ladderDamage
        end
    end
    local logOn = ClientLogOn()
    Store.Force(ns.SyncLine("end"))
    Store.Force(Target.Line(Target.Info(), "end"))
    Store.Force(Instance.MythicLine("end"))
    local records, bytes, dropped, capped = Store.Stats()
    Store.Force(KV("END",
        "t", info.t,
        "records", records + 1,
        "bytes", bytes,
        "dropped", dropped,
        "capped", capped and 1 or 0,
        "errors", info.errors,
        "cl", logOn and 1 or 0,
        "luaKB", floor(collectgarbage("count") + 0.5),
        "cpuMs", format("%.3f", info.cpuMs),
        "cpuMaxMs", format("%.3f", info.cpuMaxMs),
        "cpuBy", info.cpuBy,
        "fpsAvg", info.fpsAvg and floor(info.fpsAvg + 0.5) or nil,
        "fpsMin", info.fpsMin and floor(info.fpsMin + 0.5) or nil,
        "noCleu", info.noCleu,
        "clear", info.clear,
        "succCast", info.succCast,
        "cleuEvents", info.cleuEvents,
        "auraP", info.auraP,
        "auraT", info.auraT,
        "foreign", info.foreign,
        "regenT", regenT,
        "endT", session.mode == BOSS and endT or nil,
        "encounter", encounter and Journal.Id(encounter) or nil,
        "unseen", Unseen(),
        "subjects", info.subjects,
        "ticks", info.ticks,
        "encounterTicks", session.mode == BOSS and info.encounterTicks or nil,
        "encounterEvents", session.mode == BOSS and encounterEvents or nil,
        "others", info.others > 0 and info.others or nil,
        "ownDamage", info.ownDamage,
        "power", info.power,
        "powerUnit", info.powerUnit,
        "petEvents", info.petEvents,
        "manual", session.manual and 1 or nil,
        "timerLagMs", grace.lagMs,
        "pullT", pullT,
        "killT", killT,
        "winT", winT,
        "encSec", encSec,
        "bossDamage", bossDamage,
        "gameDamage", gameDamage,
        "result", pullT and ResultOf(killT, winT) or nil,
        "reason", reason
    ))
    session.errors = info.errors
    if session.mode == BOSS and not session.manual then
        session.ms = endT or info.t
    else
        session.ms = waited and regenT or info.t
    end
    if pullT then
        if gameDamage > 0 then
            session.dps = floor(gameDamage * 1000 / gameMs + 0.5)
        end
    else
        local fightEnd = info.targetDied or session.ms
        if info.firstHit and info.hitDamage > 0 and fightEnd > info.firstHit then
            session.dps = floor(info.hitDamage / max(1, floor((fightEnd - info.firstHit) / 1000)))
        end
    end
    local closed = Store.Close("done")
    lastSession, lastEndAt = closed, GetTime()
    session = nil
    state = IDLE
    regenT, endT = nil, nil
    pullAt, pullSrv, killAt, killSrv, killGame, killLadder, watchFrom, quietAt = nil, nil, nil, nil, nil, nil, nil, nil
    finish = nil
    encounter, encounterEntries, encounterSeen = nil, nil, nil
    UpdateListen()
    local inCombat = InCombat()
    if inCombat then
        postPending = closed
    else
        Post(closed)
    end
    SaySaved(Store.FightOf(closed))
    if not inCombat and reason ~= "logout" then
        Rearm()
    end
    UpdateUI()
    return true
end

local function OnDummyResult(message)
    local npc, latest, latestSpec, best, bestSpec = strsplit(":", message or "")
    if state == REC and session.mode ~= BOSS and not session.manual and not InCombat() then
        Stop("dummy")
    end
    local entry = session or lastSession
    if not entry or entry.mode == BOSS or (not session and (not lastEndAt or GetTime() - lastEndAt > DR_WINDOW)) then
        return
    end
    local t = entry.t0 and MsSince(entry.t0) or 0
    Store.Append(entry, KV("DR", "t", t, "npc", tonumber(npc) or npc, "latest", tonumber(latest),
        "latestSpec", tonumber(latestSpec), "best", tonumber(best), "bestSpec", tonumber(bestSpec)))
    UpdateUI()
end

local function Joined(info)
    if not Recorder.AddSubject(info) then return end
    MarkSeen(info)
    endT = nil
    killAt, killSrv, killGame, killLadder, finish = nil, nil, nil, nil, nil
    if CLOSING[graceWhy] then
        grace.Stop()
        graceWhy = nil
    end
end

local function AddBoss(unit)
    local guid, by, found = Boss.Check(unit)
    if not guid or Recorder.IsSubject(guid) then return end
    if found then
        if encounter and found ~= encounter then return end
        if not encounter then
            encounter, session.encounter = found, Journal.Id(found)
            encounterEntries = Journal.Entries(found)
            ns.CombatLog.Members(encounterEntries)
        end
    end
    local info = Target.Info(unit)
    info.by, info.encounter, info.friendly = by, found, by == "friendly" or nil
    Joined(info)
end

function Session.Discovered(guid, name, entry)
    if state ~= REC or not encounter or Recorder.IsSubject(guid) then return end
    local unit = Boss.Find(guid)
    local info = unit and Target.Info(unit) or { guid = guid, entry = entry, name = name }
    info.by, info.encounter = "journal", encounter
    Joined(info)
end

function Session.ArmedCast(event, unit, name, rank, target)
    if state ~= ARMED or not armed or UnitGUID("target") ~= armed.guid then return end
    if event == "UNIT_SPELLCAST_SENT" then
        if not target or target == "" or target == UnitName("player") then return end
        if armed.name and target ~= armed.name then return end
    elseif event ~= "UNIT_SPELLCAST_START" then
        return
    end
    Begin("auto")
end

function Session.CastActivity()
    if grace.running and graceWhy == "idle" then
        grace.Start(session.manual and MANUAL_IDLE or REGEN_GRACE)
    end
end

function Session.TargetChanged(guid)
    if state ~= REC then return end
    if session.mode == BOSS then
        if guid then
            AddBoss("target")
        end
    elseif not session.manual and not InCombat() and not Target.IsDummy(Target.Info()) then
        Stop("target")
    end
end

local function Council()
    return encounter ~= nil and Journal.Count(encounter) > 1
end

local function Close(why)
    if session.manual then return end
    if InCombat() then
        Wait(why, KILL_GRACE)
    else
        Stop(why)
    end
end

local function Finish(why, t)
    endT = t
    killAt, killSrv, finish = GetTime(), time(), why
    killGame, killLadder = ns.CombatLog.Damage()
    Close(why)
end

function Session.BossDied(t, guid)
    if state ~= REC or session.mode ~= BOSS then return end
    if Recorder.IsFriendly(guid) then
        if Recorder.HealWin(guid) and finish ~= WIN then
            Finish(LOST, t)
        end
        return
    end
    if not Recorder.BossesDead(session.manual) then return end
    endT = t
    killAt, killSrv, finish = GetTime(), time(), BOSS
    killGame, killLadder = ns.CombatLog.Damage()
    local at, srv = Boss.KillOf(guid)
    if at and at < killAt then
        killAt, killSrv = at, srv
        local game, ladder = ns.CombatLog.AtBlow(guid)
        if game then
            killGame, killLadder = game, ladder
        end
    end
    if session.manual or (Council() and (InCombat() or graceWhy == ENCOUNTER)) then return end
    Close(BOSS)
end

function Session.BossWon(t)
    if state ~= REC or session.mode ~= BOSS or finish == WIN or finish == LOST then return end
    Finish(WIN, t)
end

CheckEncounter = function()
    if InCombat() then
        graceWhy = nil
        return
    end
    if finish == WIN or finish == LOST then
        Stop(finish)
        return
    end
    local now = GetTime()
    if Recorder.AllSubjectsDead() and not (Council() and GroupInCombat()) then
        Stop(BOSS)
        return
    end
    if EncounterAlive() then
        quietAt = nil
        endT = nil
    elseif not quietAt then
        quietAt = now
        endT = endT or LastActivityT()
    end
    if quietAt and now - quietAt >= BOSS_GRACE then
        finish = Recorder.Decided() and IsInInstance() and WIPE or nil
        Stop(UnitIsDeadOrGhost("player") and "dead" or "combat")
    elseif now - watchFrom >= ENCOUNTER_CAP then
        Stop("timeout")
    else
        Wait(ENCOUNTER, ENCOUNTER_STEP)
    end
end

local function Guard(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if ok then return end
    if Recorder.Active() then
        Recorder.Warn("error", where .. ": " .. tostring(err))
    elseif db then
        Store.AddError(KV("ERROR", "time", ns.Stamp(), "where", where, "text", tostring(err)))
    end
    ns.SayError()
end

function Session.BossEngaged()
    if state ~= REC and db and InCombat() then
        Guard("engage", TryBoss)
    end
end

local function SayResume(id)
    Print(format("запись боя %d прервана, продолжение по той же цели после удара.", id))
end

function frame:ADDON_LOADED(name)
    if name == addonName then
        SirusMythicLogDB = Store.Init(SirusMythicLogDB)
        db = SirusMythicLogDB
    end
end

function frame:PLAYER_LOGIN()
    RoomForRecording()
    hookedClear = pcall(hooksecurefunc, "CombatLogClearEntries", Recorder.OnClear)
    lastForm = GetShapeshiftForm()
    local open = Store.LastOpen()
    local player = UnitGUID("player") or ""
    if open and open.target and open.player == player and time() - (open.epoch or 0) < RESUME_WINDOW then
        resumable = open
        if InCombat() then
            Cache.Book()
            SetArmed({ guid = open.target, resume = open, mode = open.mode == BOSS and BOSS or DUMMY })
            SayResume(open.id)
        end
    end
    if not InCombat() then
        Later(1, function()
            if state ~= IDLE then return end
            Arm(true)
            if armed and resumable and armed.guid == resumable.target then
                SayResume(resumable.id)
            end
        end)
    end
    UpdateUI()
    ns.Button.Setup()
end

function frame:PLAYER_LOGOUT()
    if state == REC and not InCombat() then
        Stop("logout")
    elseif state == REC then
        ns.CombatLog.FlushRepeats()
    end
    Store.Flush()
end

function frame:PLAYER_TARGET_CHANGED()
    if state == REC then return end
    if InCombat() then
        if AutoBoss() and Boss.Check("target") then
            TryBoss()
        end
    else
        Arm(false)
    end
end

function frame:PLAYER_REGEN_ENABLED()
    if state == REC and session.manual then
        regenT = Recorder.Now()
        Recorder.Warn("regen", 1)
        if grace.native then
            Wait("idle", MANUAL_IDLE)
        end
    elseif state == REC and session.mode == BOSS then
        regenT = Recorder.Now()
        endT = endT or regenT
        Recorder.Warn("regen", 1)
        if finish == WIN or finish == LOST then
            Stop(finish)
        elseif Recorder.AllSubjectsDead() and not (Council() and GroupInCombat()) then
            Stop(BOSS)
        elseif not grace.native then
            Stop("combat")
        else
            watchFrom = GetTime()
            quietAt = watchFrom
            Wait(ENCOUNTER, ENCOUNTER_STEP)
        end
    elseif state == REC then
        if grace.native and Target.DummyAlive() then
            regenT = Recorder.Now()
            Recorder.Warn("regen", 1)
            Wait("idle", REGEN_GRACE)
        else
            Stop("combat")
        end
    elseif postPending then
        local closed = postPending
        postPending = nil
        Post(closed)
        Rearm()
    end
    if state == IDLE and not laterFn then
        Later(2, ArmLater)
    end
    SetAuraWatch()
end

function frame:PLAYER_REGEN_DISABLED()
    if state == REC then
        if grace.running and not CLOSING[graceWhy] then
            grace.Stop()
            graceWhy = nil
            if session.mode == BOSS and not session.manual then
                endT, quietAt = nil, nil
            end
            Recorder.Warn("regen", 0)
        end
    elseif state == ARMED and armed and UnitGUID("target") == armed.guid
        and (armed.mode ~= BOSS or Boss.Engaged(armed.guid, "target")) then
        CancelLater()
        Begin("auto")
    elseif state == ARMED and armed and armed.mode == BOSS and UnitGUID("target") == armed.guid then
        CancelLater()
        TryBoss()
    else
        CancelLater()
        TryBoss()
    end
    CancelModifierWatch()
    SetAuraWatch()
end

function frame:INSTANCE_ENCOUNTER_ENGAGE_UNIT()
    local units = Boss.EncounterUnits()
    if units == 0 then
        frameAt, frameSrv = nil, nil
    elseif not frameAt then
        frameAt, frameSrv = GetTime(), time()
    end
    if state == REC then
        encounterEvents = encounterEvents + 1
        Recorder.Warn("frames", units)
    end
    if state == REC and session.mode == BOSS then
        for _, unit in ipairs(Boss.UNITS) do
            AddBoss(unit)
        end
    else
        TryBoss()
    end
end

function frame:CHAT_MSG_ADDON(prefix, message, channel, sender)
    if prefix ~= "ASMSG_DUMMY_CONTROL_SHOW" or channel ~= "UNKNOWN" or sender ~= UnitName("player") then
        return
    end
    OnDummyResult(message)
    if state == IDLE and not laterFn then
        Arm(false)
    end
end

function frame:UNIT_AURA(unit)
    if unit ~= "player" then return end
    Cache.MarkDynamic()
    CheckModifier()
end

function frame:PLAYER_EQUIPMENT_CHANGED()
    Cache.MarkAll()
    WatchModifier()
    SetAuraWatch()
end

function frame:CHARACTER_POINTS_CHANGED()
    Cache.MarkAll()
end

frame.PLAYER_TALENT_UPDATE = frame.CHARACTER_POINTS_CHANGED
frame.PLAYER_TALENT_UPDATE_EX = frame.CHARACTER_POINTS_CHANGED
frame.PLAYER_TALENT_ACTIVE_GROUP_CHANGED = frame.CHARACTER_POINTS_CHANGED
frame.GLYPH_ADDED = frame.CHARACTER_POINTS_CHANGED
frame.GLYPH_REMOVED = frame.CHARACTER_POINTS_CHANGED
frame.GLYPH_UPDATED = frame.CHARACTER_POINTS_CHANGED
frame.LEARNED_SPELL_IN_TAB = frame.CHARACTER_POINTS_CHANGED

function frame:SPELLS_CHANGED()
    Cache.MarkBook()
end

function frame:UPDATE_SHAPESHIFT_FORM()
    local form = GetShapeshiftForm()
    if form ~= lastForm then
        lastForm = form
        Cache.MarkDynamic()
    end
end

function frame:ZONE_CHANGED_NEW_AREA()
    if Instance.Group() then
        Journal.ReadClient()
    end
    if state ~= REC then
        Boss.Forget()
    end
    UpdateListen()
    if state == IDLE and not laterFn then
        Later(2, ArmLater)
    end
end

frame.PLAYER_ENTERING_WORLD = frame.ZONE_CHANGED_NEW_AREA

function frame:PLAYER_ALIVE()
    if state == REC and not UnitIsDeadOrGhost("player") then
        Recorder.Warn("alive", "alive")
    end
end

function frame:PLAYER_UNGHOST()
    if state == REC and not UnitIsDeadOrGhost("player") then
        Recorder.Warn("alive", "unghost")
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    local ok, err = pcall(self[event], self, ...)
    if not ok then
        if Recorder.Active() then
            Recorder.Warn("error", event .. ": " .. tostring(err))
        elseif db then
            Store.AddError(KV("ERROR", "time", ns.Stamp(), "where", event, "text", tostring(err)))
        end
        ns.SayError()
    end
end)

for _, event in ipairs({
    "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LOGOUT", "PLAYER_TARGET_CHANGED", "PLAYER_REGEN_ENABLED",
    "PLAYER_REGEN_DISABLED", "CHAT_MSG_ADDON", "PLAYER_EQUIPMENT_CHANGED", "CHARACTER_POINTS_CHANGED",
    "PLAYER_TALENT_UPDATE", "GLYPH_ADDED", "GLYPH_REMOVED", "GLYPH_UPDATED", "UPDATE_SHAPESHIFT_FORM",
    "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "PLAYER_ALIVE",
    "PLAYER_UNGHOST",
}) do
    frame:RegisterEvent(event)
end
encounterRegistered = pcall(frame.RegisterEvent, frame, "INSTANCE_ENCOUNTER_ENGAGE_UNIT")
if frame.RegisterCustomEvent then
    pcall(frame.RegisterCustomEvent, frame, "PLAYER_TALENT_UPDATE_EX")
    pcall(frame.RegisterCustomEvent, frame, "PLAYER_TALENT_ACTIVE_GROUP_CHANGED")
end

local function DropResume()
    Disarm()
    Arm(false)
end

local function Refresh()
    if state == REC and not session.manual and not (db.enabled and db[session.mode or DUMMY]) then
        Stop("off")
    end
    if state == ARMED and not ModeOf(Target.Info()) then
        Disarm()
    elseif state ~= REC then
        Arm(false)
    end
    UpdateListen()
    UpdateUI()
end

function Session.State()
    if state ~= REC and db and not (db.enabled and (db.dummy or db.boss)) then return OFF end
    return state
end

function Session.Pending()
    return laterFn ~= nil
end

function Session.Setting(key)
    return db ~= nil and db[key] == true
end

function Session.SetSetting(key, on)
    db[key] = on and true or false
    if key ~= "autoLog" then
        Refresh()
    end
end

function Session.Start()
    return Begin("manual")
end

function Session.Stop()
    return Stop("manual")
end

function Session.Recording()
    if state ~= REC or not session then return nil end
    local _, bytes = Store.Stats()
    return { entry = session, ms = Recorder.Now(), bytes = bytes, grace = grace.running }
end

local function Forget(gone)
    if gone[lastSession] then
        lastSession = nil
    end
    if gone[resumable] then
        resumable = nil
    end
    if gone[postPending] then
        postPending = nil
    end
    if armed and gone[armed.resume] then
        DropResume()
    end
    fullSaid = false
    UpdateUI()
end

function Session.Remove(entry)
    if not Store.Remove(entry) then return false end
    Forget({ [entry] = true })
    return true
end

function Session.Clear(own)
    if own then
        local gone = Store.RemoveOwn()
        if not gone then return false end
        Forget(gone)
        return true
    end
    if not Store.Reset() then return false end
    lastSession, resumable, postPending = nil, nil, nil
    if armed and armed.resume then
        DropResume()
    end
    fullSaid = false
    UpdateUI()
    return true
end
