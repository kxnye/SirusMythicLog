local _, ns = ...

local Jobs = {}
ns.Jobs = Jobs

local create, resume, yield, status, running = coroutine.create, coroutine.resume, coroutine.yield, coroutine.status,
    coroutine.running
local debugprofilestop = debugprofilestop
local tinsert, tremove = table.insert, table.remove
local max = math.max

Jobs.BUDGET = 1
Jobs.spent = 0

local COMBAT = { "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }

local queue = {}
local deadline
local timer
local frame = CreateFrame("Frame")

local function Fail(where, err)
    local text = where .. ": " .. tostring(err)
    if ns.Recorder and ns.Recorder.Active() then
        ns.Recorder.Warn("error", text)
    elseif ns.Store then
        pcall(ns.Store.AddError, ns.KV("ERROR", "time", ns.Stamp(), "where", where, "text", tostring(err)))
    end
    ns.SayError()
end

local function Ready(job)
    return job.urgent or not ns.InCombat()
end

local function Resume(job, budget)
    local outer, before = deadline, Jobs.spent
    local start = debugprofilestop()
    deadline = budget and start + budget or nil
    local ok, err = resume(job.co)
    local spent = debugprofilestop() - start
    deadline = outer
    local inner = Jobs.spent - before
    Jobs.spent = before + spent
    ns.Recorder.AddCpu(job.where, spent - inner)
    if not ok then
        Fail(job.where, err)
    end
    if status(job.co) == "dead" then
        job.done = true
    end
end

local function Drop(job)
    for i, other in ipairs(queue) do
        if other == job then
            tremove(queue, i)
            return
        end
    end
end

local function Schedule()
    local due, wait = false, false
    for _, job in ipairs(queue) do
        if Ready(job) then
            due = true
        else
            wait = true
        end
    end
    if due then
        if not timer.running then
            timer.Start(0)
        end
    elseif timer.running then
        timer.Stop()
    end
    for _, event in ipairs(COMBAT) do
        if wait or due then
            frame:RegisterEvent(event)
        else
            frame:UnregisterEvent(event)
        end
    end
end

local function Step()
    local start = debugprofilestop()
    local ran = false
    while true do
        local left = Jobs.BUDGET - (debugprofilestop() - start)
        if ran and left <= 0 then break end
        local job
        for _, other in ipairs(queue) do
            if Ready(other) then
                job = other
                break
            end
        end
        if not job then break end
        Resume(job, max(left, 0))
        ran = true
        if job.done then
            Drop(job)
        end
    end
    Schedule()
end

timer = ns.NewTimer(Step)
frame:SetScript("OnEvent", Schedule)

function Jobs.Add(where, fn, urgent)
    local job = { where = where, co = create(fn), urgent = urgent and true or false }
    local at = #queue + 1
    if job.urgent then
        for i, other in ipairs(queue) do
            if not other.urgent then
                at = i
                break
            end
        end
    end
    tinsert(queue, at, job)
    Schedule()
    return job
end

function Jobs.Yield()
    if deadline and running() and debugprofilestop() >= deadline then
        yield()
    end
end

function Jobs.Finish(job)
    if not job or job.done then return end
    while not job.done and status(job.co) == "suspended" do
        Resume(job, nil)
    end
    if job.done then
        Drop(job)
        Schedule()
    end
end

function Jobs.Pending()
    return #queue
end
