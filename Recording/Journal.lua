local _, ns = ...

local Journal = {}
ns.Journal = Journal

local D = ns.Data

local floor = math.floor

local ID, INSTANCE, MASK, FIRST = 1, 2, 3, 4
local ENCOUNTER_LIMIT = 64
local CREATURE_LIMIT = 16
local DEFAULT_ICON = "interface\\encounterjournal\\ui-ej-boss-default"

local rows = D.JOURNAL
local skip = D.JOURNAL_SKIP
local byEntry = {}
local byId
local client = { instance = nil, encounters = 0, added = 0, via = "none" }

local function Index(row, entry)
    local known = byEntry[entry]
    if not known then
        byEntry[entry] = row
    elseif type(known[ID]) == "number" then
        byEntry[entry] = { known, row }
    else
        known[#known + 1] = row
    end
end

for _, row in ipairs(rows) do
    for k = FIRST, #row do
        Index(row, row[k])
    end
end

local function DifficultyBit()
    local _, _, difficulty = GetInstanceInfo()
    difficulty = tonumber(difficulty) or 1
    if difficulty < 1 then
        difficulty = 1
    end
    return 2 ^ (difficulty - 1)
end

local function Allows(mask, bit)
    return mask == -1 or floor(mask / bit) % 2 == 1
end

function Journal.Find(entry)
    local found = byEntry[entry]
    if not found or type(found[ID]) == "number" then return found end
    local here, bit = client.instance, DifficultyBit()
    local best, score = nil, -1
    for _, row in ipairs(found) do
        local value = (here and row[INSTANCE] == here and 2 or 0) + (Allows(row[MASK], bit) and 1 or 0)
        if value > score then
            best, score = row, value
        end
    end
    return best
end

function Journal.Id(row)
    return row[ID]
end

function Journal.Count(row)
    return #row - FIRST + 1
end

function Journal.Entries(row)
    local set = {}
    for k = FIRST, #row do
        set[row[k]] = true
    end
    return set
end

function Journal.Name(row)
    if not row or not EJ_GetEncounterInfo then return nil end
    local ok, name = pcall(EJ_GetEncounterInfo, row[ID])
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

local function CurrentInstance()
    if not EJ_GetCurrentInstance then return nil end
    if SetMapToCurrentZone and not (WorldMapFrame and WorldMapFrame:IsShown()) then
        SetMapToCurrentZone()
    end
    local ok, instance = pcall(EJ_GetCurrentInstance)
    if ok and type(instance) == "number" then return instance end
    return nil
end

local function Row(id, instance)
    if not byId then
        byId = {}
        for _, row in ipairs(rows) do
            byId[row[ID]] = row
        end
    end
    local row = byId[id]
    if not row then
        row = { id, instance, -1 }
        byId[id] = row
        rows[#rows + 1] = row
    end
    return row
end

local function Add(row, entry)
    if entry <= 0 or skip[entry] then return false end
    for k = FIRST, #row do
        if row[k] == entry then return false end
    end
    row[#row + 1] = entry
    Index(row, entry)
    return true
end

function Journal.ReadClient()
    client.instance, client.encounters, client.added = nil, 0, 0
    if not EJ_GetEncounterInfoByIndex or not EJ_GetCreatureInfo then
        client.via = "none"
        return client
    end
    local instance = CurrentInstance()
    if not instance then
        client.via = "unknown"
        return client
    end
    client.instance, client.via = instance, "client"
    for i = 1, ENCOUNTER_LIMIT do
        local ok, _, _, id = pcall(EJ_GetEncounterInfoByIndex, i, instance)
        if not ok or type(id) ~= "number" then break end
        client.encounters = client.encounters + 1
        local row = Row(id, instance)
        for k = 1, CREATURE_LIMIT do
            local found, _, _, _, _, icon, entry = pcall(EJ_GetCreatureInfo, k, id)
            if not found or type(entry) ~= "number" then break end
            local portrait = type(icon) == "string" and icon ~= "" and icon:lower() ~= DEFAULT_ICON
            if portrait and Add(row, entry) then
                client.added = client.added + 1
            end
        end
    end
    return client
end

function Journal.ClientLine()
    return (client.instance or client.via) .. ":" .. client.encounters .. ":" .. client.added
end
