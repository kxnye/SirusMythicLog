local _, ns = ...

local Store = {}
ns.Store = Store

local D = ns.Data
local Jobs = ns.Jobs

local concat = table.concat
local floor, min = math.floor, math.min
local find, match = string.find, string.match

local DB_VERSION = 5
local CHUNK_LINES = 128
local CHUNK_BYTES = 8192
local MODS_CAP = 64
local ERRORS_CAP = 20
local CLEAN_CAP = 20
local SPARE = 1048576
local WARM_CHUNKS = 64

Store.DB_CAP = 31457280
Store.FIGHT_CAP = 8388608
Store.RESERVE = 262144

local db
local cur, chunks
local buf = {}
local bufN, bufBytes = 0, 0
local records, bytes, dropped = 0, 0, 0
local capped = false
local dbBytes = 0
local fights
local keepOf, onEvict
local shedJob, shedDone
local whoOf = setmetatable({}, { __mode = "k" })
local sizeOf = setmetatable({}, { __mode = "k" })
local refsOf = setmetatable({}, { __mode = "k" })

local function DropFights()
    fights = nil
end

local function Measure(session)
    local total = 0
    for _, chunk in ipairs(session.chunks) do
        total = total + #chunk + 1
    end
    return total
end

local function Size(session)
    local size = sizeOf[session]
    if not size then
        size = Measure(session)
        sizeOf[session] = size
    end
    return size
end

local function CleanRefs(line, used)
    for id in line:gmatch(";[gbs]=(%d+)") do
        used[tonumber(id)] = true
    end
end

local function ChunkRefs(chunk, used)
    local at = 1
    while true do
        local _, last = find(chunk, "STATIC;id=", at, true)
        if not last then return end
        local id = tonumber(match(chunk, "^%d+", last + 1))
        if id then
            used[id] = true
        end
        at = last + 1
    end
end

local function Refs(session)
    local refs = refsOf[session]
    if not refs then
        refs = {}
        for _, chunk in ipairs(session.chunks) do
            ChunkRefs(chunk, refs)
        end
        refsOf[session] = refs
    end
    return refs
end

local function Recount()
    dbBytes = 0
    for _, session in ipairs(db.sessions) do
        dbBytes = dbBytes + Measure(session)
    end
    for _, static in pairs(db.statics) do
        dbBytes = dbBytes + #(static.text or "") + 1
    end
    for _, line in ipairs(db.mods) do
        dbBytes = dbBytes + #line + 1
    end
    for _, line in ipairs(db.errors or {}) do
        dbBytes = dbBytes + #line + 1
    end
    for _, entry in ipairs(db.clean) do
        for _, line in ipairs(entry.lines) do
            dbBytes = dbBytes + #line + 1
        end
    end
end

local function RestartNumbering()
    if #db.sessions == 0 then
        db.nextId = 1
        if next(db.statics) == nil then
            db.staticNext = 1
        end
    end
end

function Store.Init(saved)
    if type(saved) ~= "table" then
        saved = {}
    end
    if (tonumber(saved.v) or 0) < 3 then
        saved.autoLog = false
    end
    saved.v = DB_VERSION
    saved.cap = Store.DB_CAP
    if saved.enabled == nil then
        saved.enabled = true
    end
    if saved.dummy == nil then
        saved.dummy = true
    end
    if saved.boss == nil then
        saved.boss = true
    end
    for _, key in ipairs({ "sessions", "statics", "staticLast", "mods", "ui", "clean" }) do
        if type(saved[key]) ~= "table" then
            saved[key] = {}
        end
    end
    if type(saved.errors) ~= "table" then
        saved.errors = nil
    end
    saved.ui.mine = nil
    for _, session in ipairs(saved.sessions) do
        if type(session.chunks) ~= "table" then
            session.chunks = {}
        end
    end
    for _, entry in ipairs(saved.clean) do
        if type(entry.lines) ~= "table" then
            entry.lines = {}
        end
    end
    saved.nextId = tonumber(saved.nextId) or (#saved.sessions + 1)
    saved.staticNext = tonumber(saved.staticNext) or 1
    db = saved
    DropFights()
    RestartNumbering()
    Recount()
    if #db.sessions > 0 then
        Jobs.Add("warm", Store.Warm)
    end
    return db
end

function Store.DbBytes()
    return dbBytes + bufBytes
end

function Store.Current()
    return cur
end

function Store.Stats()
    return records, bytes, dropped, capped
end

function Store.Entries()
    return db and db.sessions or {}
end

function Store.UI()
    return db.ui
end

function Store.Owner()
    return GetRealmName(), UnitGUID("player")
end

function Store.Owns(entry, realm, guid)
    return guid ~= nil and entry.player == guid and (entry.realm == nil or entry.realm == realm)
end

local function Fits(total, spare)
    return total + Store.RESERVE + spare <= Store.DB_CAP
end

function Store.Room()
    return Fits(Store.DbBytes(), 0)
end

function Store.Hooks(keep, evicted)
    keepOf, onEvict = keep, evicted
end

function Store.NextId()
    local id = db.nextId
    db.nextId = id + 1
    return id
end

function Store.Flush()
    if not cur or bufN == 0 then return end
    chunks[#chunks + 1] = concat(buf, "\n", 1, bufN)
    dbBytes = dbBytes + bufBytes
    for i = 1, bufN do
        buf[i] = nil
    end
    bufN, bufBytes = 0, 0
    cur.bytes, cur.records, cur.dropped = bytes, records, dropped
end

local function Push(line)
    local size = #line + 1
    bufN = bufN + 1
    buf[bufN] = line
    bufBytes = bufBytes + size
    bytes = bytes + size
    records = records + 1
    if bufN >= CHUNK_LINES or bufBytes >= CHUNK_BYTES then
        Store.Flush()
    end
    return records
end

local Shed, Cap

function Store.Write(line)
    if not cur or not line then return nil end
    if capped then
        dropped = dropped + 1
        return nil
    end
    local index = Push(line)
    if bytes + Store.RESERVE > Store.FIGHT_CAP then
        Cap(true)
        return index
    end
    local used = dbBytes + bufBytes + Store.RESERVE
    if used + SPARE > Store.DB_CAP and not shedJob and not shedDone then
        shedJob = Jobs.Add("shed", Shed, true)
    end
    if used > Store.DB_CAP then
        Jobs.Finish(shedJob)
        if dbBytes + bufBytes + Store.RESERVE > Store.DB_CAP then
            Cap()
        end
    end
    return index
end

function Store.ReplaceLast(index, line)
    if not cur or capped or index ~= records or bufN == 0 then return false end
    local delta = #line - #buf[bufN]
    buf[bufN] = line
    bufBytes = bufBytes + delta
    bytes = bytes + delta
    return true
end

function Store.Force(line)
    if cur and line then
        Push(line)
    end
end

function Store.WriteChunk(text)
    Store.Flush()
    chunks[#chunks + 1] = text
    ChunkRefs(text, Refs(cur))
    local size = #text + 1
    dbBytes = dbBytes + size
    bytes = bytes + size
    cur.bytes = bytes
end

function Store.Open(session)
    cur = session
    chunks = session.chunks
    records, bytes, dropped = 0, 0, 0
    capped, shedDone = false, false
    Refs(session)
    db.sessions[#db.sessions + 1] = session
    DropFights()
end

function Store.Close(state)
    Store.Flush()
    cur.bytes, cur.records, cur.dropped = bytes, records, dropped
    cur.state = capped and "capped" or state
    local closed = cur
    cur, chunks = nil, nil
    return closed
end

function Store.Append(session, line)
    if session == cur then
        Store.Force(line)
        return
    end
    session.chunks[#session.chunks + 1] = line
    dbBytes = dbBytes + #line + 1
    session.bytes = (session.bytes or 0) + #line + 1
    if sizeOf[session] then
        sizeOf[session] = sizeOf[session] + #line + 1
    end
    if refsOf[session] then
        ChunkRefs(line, refsOf[session])
    end
end

function Store.Static(guid, text)
    local last = db.staticLast[guid]
    local known = last and db.statics[last]
    if known and known.text == text then return last end
    for id, static in pairs(db.statics) do
        if static.guid == guid and static.text == text then
            db.staticLast[guid] = id
            return id
        end
    end
    local id = db.staticNext
    db.staticNext = id + 1
    db.statics[id] = { guid = guid, text = text }
    db.staticLast[guid] = id
    dbBytes = dbBytes + #text + 1
    return id
end

function Store.LastStatic(key)
    local id = db.staticLast[key]
    local static = id and db.statics[id]
    if not static then return nil end
    return id, static.text
end

function Store.AddMod(line)
    local list = db.mods
    if #list >= MODS_CAP then
        dbBytes = dbBytes - #list[1] - 1
        table.remove(list, 1)
    end
    list[#list + 1] = line
    dbBytes = dbBytes + #line + 1
end

function Store.AddError(line)
    if type(db.errors) ~= "table" then
        db.errors = {}
    end
    local list = db.errors
    if #list >= ERRORS_CAP then
        dbBytes = dbBytes - #list[1] - 1
        table.remove(list, 1)
    end
    list[#list + 1] = line
    dbBytes = dbBytes + #line + 1
end

local function Summarize(fight)
    local parts = fight.entries
    local first, newest = parts[#parts], parts[1]
    local ms, bytes, weighted, weight = 0, 0, 0, 0
    fight.current, fight.dps = nil, nil
    for _, entry in ipairs(parts) do
        ms = ms + (entry.ms or 0)
        bytes = bytes + (entry.bytes or 0)
        if entry.dps and (entry.ms or 0) > 0 then
            weighted = weighted + entry.dps * entry.ms
            weight = weight + entry.ms
        end
        if entry == cur then
            fight.current = true
        end
    end
    fight.first, fight.ms, fight.bytes = first, ms, bytes
    if #parts == 1 then
        fight.dps = first.dps
    elseif weight > 0 then
        fight.dps = floor(weighted / weight + 0.5)
    end
    fight.open = newest.state == "open" and not fight.current
    fight.capped = newest.state == "capped"
    return fight
end

function Store.Fights()
    if fights then
        for _, fight in ipairs(fights) do
            Summarize(fight)
        end
        return fights
    end
    local list, byId = {}, {}
    for index = #db.sessions, 1, -1 do
        local entry = db.sessions[index]
        local fight = entry.kind ~= "snap" and byId[entry.id]
        if not fight then
            fight = { entries = {} }
            list[#list + 1] = fight
            if entry.kind ~= "snap" then
                byId[entry.id] = fight
            end
        end
        fight.entries[#fight.entries + 1] = entry
    end
    for _, fight in ipairs(list) do
        Summarize(fight)
    end
    fights = list
    return list
end

local function Recorded(entry)
    local chunks = entry.chunks
    local count = #chunks
    for i = 1, min(count, 2) do
        local chunk = chunks[i == 1 and 1 or count]
        local line = type(chunk) == "string" and match(chunk, "\nPLAYER;([^\n]*)")
        if line then
            local spec = ns.MainTab(match(chunk, "\nTALENTGROUP;[^\n]-;points=(%d+)/(%d+)/(%d+)"))
            return match(line, ";classToken=([^;]*)"), spec, match(line, "^name=([^;]*)")
        end
    end
end

function Store.Who(entry)
    local who = whoOf[entry]
    if who ~= nil then return who end
    local class, spec, name = entry.classToken, entry.spec, entry.name
    if class == nil then
        class, spec, name = Recorded(entry)
    end
    local icons = class and D.SPEC_ICON[class]
    local icon = icons and spec and icons[spec]
    who = icon and { icon = icon, class = class, name = name } or false
    whoOf[entry] = who
    return who
end

function Store.FightOf(entry)
    for _, fight in ipairs(Store.Fights()) do
        for _, part in ipairs(fight.entries) do
            if part == entry then return fight end
        end
    end
    return nil
end

function Store.LastOpen()
    for i = #db.sessions, 1, -1 do
        local session = db.sessions[i]
        if session.kind ~= "snap" then return session.state == "open" and session or nil end
    end
    return nil
end

local function DropUnusedStatics()
    local used = {}
    for _, session in ipairs(db.sessions) do
        for id in pairs(Refs(session)) do
            used[id] = true
        end
    end
    for _, entry in ipairs(db.clean) do
        for _, line in ipairs(entry.lines) do
            CleanRefs(line, used)
        end
    end
    local freed = 0
    for id, static in pairs(db.statics) do
        if not used[id] then
            freed = freed + #(static.text or "") + 1
            db.statics[id] = nil
        end
    end
    for guid, id in pairs(db.staticLast) do
        if not db.statics[id] then
            db.staticLast[guid] = nil
        end
    end
    return freed
end

function Store.Remove(entry)
    if entry == cur then return false end
    for i, session in ipairs(db.sessions) do
        if session == entry then
            table.remove(db.sessions, i)
            DropFights()
            dbBytes = dbBytes - Size(entry) - DropUnusedStatics()
            RestartNumbering()
            shedDone = false
            return true
        end
    end
    return false
end

local function Removable(fight, keep)
    for _, entry in ipairs(fight.entries) do
        if entry == cur or keep[entry] then return false end
    end
    return true
end

local function Plan(keep, spare)
    local total = Store.DbBytes()
    if Fits(total, spare) then return nil end
    local count, pinned = {}, {}
    for _, session in ipairs(db.sessions) do
        for id in pairs(Refs(session)) do
            count[id] = (count[id] or 0) + 1
        end
    end
    for _, entry in ipairs(db.clean) do
        for _, line in ipairs(entry.lines) do
            CleanRefs(line, pinned)
        end
    end
    local function Free(id)
        local static = db.statics[id]
        if static and not pinned[id] then
            total = total - #(static.text or "") - 1
        end
    end
    for id in pairs(db.statics) do
        if not count[id] then
            Free(id)
        end
    end
    local list, drop, gone = Store.Fights(), {}, {}
    for index = #list, 1, -1 do
        local fight = list[index]
        if Removable(fight, keep) then
            gone[#gone + 1] = fight
            for _, entry in ipairs(fight.entries) do
                drop[entry] = true
                total = total - Size(entry)
                for id in pairs(Refs(entry)) do
                    count[id] = count[id] - 1
                    if count[id] == 0 then
                        Free(id)
                    end
                end
            end
            if Fits(total, spare) then
                return drop, gone, total
            end
        end
    end
    return nil
end

local function Drop(drop, total)
    local kept = {}
    for _, session in ipairs(db.sessions) do
        if not drop[session] then
            kept[#kept + 1] = session
        end
    end
    db.sessions = kept
    DropFights()
    DropUnusedStatics()
    RestartNumbering()
    dbBytes = total - bufBytes
end

local function Keep()
    return keepOf and keepOf() or {}
end

function Store.Full()
    return not Store.Room() and not Plan(Keep(), 0)
end

local function WarmRefs(session)
    if refsOf[session] then return end
    local refs = {}
    for i, chunk in ipairs(session.chunks) do
        ChunkRefs(chunk, refs)
        if i % WARM_CHUNKS == 0 then
            Jobs.Yield()
        end
    end
    refsOf[session] = refsOf[session] or refs
end

function Store.Warm()
    for _, session in ipairs(db.sessions) do
        WarmRefs(session)
        if session ~= cur then
            Size(session)
        end
        Jobs.Yield()
    end
end

function Store.Evict(spare)
    local drop, gone, total = Plan(Keep(), spare or 0)
    if not drop then return nil end
    Drop(drop, total)
    if onEvict then
        onEvict(gone)
    end
    return gone
end

Shed = function()
    Store.Warm()
    shedJob = nil
    if not cur or capped then return end
    if not (Store.Evict(SPARE) or Store.Evict(0)) then
        shedDone = true
    end
end

Cap = function(fight)
    capped = true
    ns.Recorder.Warn("cap", bytes)
    ns.Recorder.Throttle()
    if fight then
        ns.Print(("запись боя дошла до предела %d МБ, дальше в этом бою записывается только итог"):format(floor(Store.FIGHT_CAP / 1048576)))
    else
        ns.Print("место для логов закончилось, дальше в этом бою записывается только итог. Отправьте файл на upload.sirusmythic.ru и нажмите «Очистить всё» в /sml")
    end
end

function Store.Reset()
    if cur then return false end
    db.sessions = {}
    DropFights()
    db.statics = {}
    db.staticLast = {}
    db.mods = {}
    db.errors = nil
    db.clean = {}
    dbBytes = 0
    shedDone = false
    RestartNumbering()
    return true
end

local function CleanEntry(create)
    local realm, guid = Store.Owner()
    if not guid then return nil end
    for _, entry in ipairs(db.clean) do
        if Store.Owns(entry, realm, guid) then return entry end
    end
    if not create then return nil end
    local entry = { player = guid, realm = realm, lines = {} }
    db.clean[#db.clean + 1] = entry
    return entry
end

function Store.LastClean()
    local entry = CleanEntry(false)
    return entry and entry.lines[#entry.lines]
end

function Store.AddClean(line, info)
    local entry = CleanEntry(true)
    for key, value in pairs(info) do
        entry[key] = value
    end
    local lines = entry.lines
    lines[#lines + 1] = line
    dbBytes = dbBytes + #line + 1
    if #lines <= CLEAN_CAP then return end
    local gone = {}
    while #lines > CLEAN_CAP do
        local old = table.remove(lines, 1)
        dbBytes = dbBytes - #old - 1
        CleanRefs(old, gone)
    end
    local kept = {}
    for _, other in ipairs(db.clean) do
        for _, rest in ipairs(other.lines) do
            CleanRefs(rest, kept)
        end
    end
    for id in pairs(kept) do
        gone[id] = nil
    end
    if next(gone) then
        dbBytes = dbBytes - DropUnusedStatics()
    end
end
