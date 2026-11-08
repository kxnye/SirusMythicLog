local addonName, ns = ...

ns.VERSION = "1.0.0"
ns.FORMAT = 6
ns.SCHEMA = 8

local floor, format, gsub, match = math.floor, string.format, string.gsub, string.match
local concat = table.concat

local errorSaid = false

ns.FULL_TEXT = "Место переполнено, новые логи не будут записаны, отправьте файл и/или очистите список"

function ns.Print(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSIRUS MYTHIC LOG|r " .. text)
end

function ns.SayError()
    if errorSaid then return end
    errorSaid = true
    ns.Print("ошибка, подробности в файле записи")
end

function ns.InCombat()
    return InCombatLockdown() or UnitAffectingCombat("player")
end

function ns.MsSince(at)
    return floor((GetTime() - at) * 1000 + 0.5)
end

function ns.RegisterUnit(frame, event, ...)
    if frame.RegisterUnitEvent then
        frame:RegisterUnitEvent(event, ...)
    else
        frame:RegisterEvent(event)
    end
end

function ns.ItemId(slot)
    local link = GetInventoryItemLink("player", slot)
    return link and tonumber(match(link, "item:(%d+)"))
end

function ns.AddonKB()
    if ns.InCombat() then return nil end
    UpdateAddOnMemoryUsage()
    return tonumber(GetAddOnMemoryUsage(addonName))
end

local ESCAPE = { ["%"] = "%25", [";"] = "%3B", ["="] = "%3D", ["|"] = "%7C", ["\n"] = "%0A", ["\r"] = "%0D" }

local function Escape(value)
    if value == nil then return "" end
    return (gsub(tostring(value), "[%%;=|\r\n]", ESCAPE))
end

local function NumberText(value)
    if value ~= value or value == math.huge or value == -math.huge then return "" end
    if value == floor(value) then
        return format("%.0f", value)
    end
    return format("%.9g", value)
end

local function KV(tag, ...)
    local parts = { tag }
    for i = 1, select("#", ...), 2 do
        local key, value = select(i, ...)
        if value ~= nil then
            local kind = type(value)
            if kind == "number" then
                value = NumberText(value)
            elseif kind == "boolean" then
                value = value and "1" or "0"
            else
                value = Escape(value)
            end
            parts[#parts + 1] = key .. "=" .. value
        end
    end
    return concat(parts, ";")
end

local function ProbeLine(key, value)
    return KV("PROBE", "key", key, "value", value)
end

local function TimeZone(epoch)
    local loc, utc = date("*t", epoch), date("!*t", epoch)
    local days = loc.yday - utc.yday
    if loc.year ~= utc.year then
        days = loc.year > utc.year and 1 or -1
    end
    return days * 86400 + (loc.hour - utc.hour) * 3600 + (loc.min - utc.min) * 60, loc.isdst and 1 or 0
end

local function SyncLine(kind, cleu, gt)
    local epoch = time()
    local tz, dst = TimeZone(epoch)
    return KV("SYNC", "kind", kind, "epoch", epoch, "local", date("%Y-%m-%d %H:%M:%S", epoch), "tz", tz, "dst", dst,
        "gt", format("%.3f", gt or GetTime()), "cleu", cleu and format("%.3f", cleu) or nil,
        "srv", GetServerTime and GetServerTime(), "fps", floor(GetFramerate() + 0.5))
end

function ns.FormatPattern(text)
    if type(text) ~= "string" or text == "" then return nil end
    text = gsub(text, "|4[^;]*;", "\001")
    text = gsub(text, "[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")
    text = gsub(text, "%%%%s", "(.-)")
    text = gsub(text, "%%%%d", "%%d+")
    text = gsub(text, "%%%%g", "([%%d%%.,]+)")
    text = gsub(text, "\001", ".-")
    return "^" .. text .. "$"
end

function ns.FormatPatterns(...)
    local list = {}
    for i = 1, select("#", ...) do
        list[#list + 1] = ns.FormatPattern(_G[select(i, ...)])
    end
    return list
end

local function Stamp()
    return date("%Y-%m-%d %H:%M:%S")
end

ns.Escape = Escape
ns.NumberText = NumberText
ns.KV = KV
ns.ProbeLine = ProbeLine
ns.SyncLine = SyncLine
ns.Stamp = Stamp

function ns.Duration(ms)
    local seconds = floor((ms or 0) / 1000 + 0.5)
    return format("%d:%02d", floor(seconds / 60), seconds % 60)
end

function ns.Size(bytes)
    local kb = (bytes or 0) / 1024
    if kb >= 1024 then
        return (gsub(format("%.1f МБ", kb / 1024), "%.", ","))
    end
    return format("%.0f КБ", kb)
end

function ns.FightName(entry)
    if entry.mode == "boss" then
        return entry.boss or "Босс"
    end
    local guid = entry.target
    if type(guid) == "string" and ns.Data.DUMMY_ENTRY[ns.Target.Entry(guid)] then
        return "Манекен"
    end
    return "Вручную"
end

function ns.MainTab(...)
    local best, most = nil, 0
    for tab = 1, select("#", ...) do
        local points = tonumber((select(tab, ...))) or 0
        if points > most then
            best, most = tab, points
        end
    end
    return best
end

function ns.Thousands(value)
    local text = format("%.0f", value or 0)
    local sign, digits = match(text, "^(%-?)(%d+)$")
    if not digits then return text end
    local head = #digits % 3
    if head == 0 then
        head = 3
    end
    local groups = { digits:sub(1, head) }
    for at = head + 1, #digits, 3 do
        groups[#groups + 1] = digits:sub(at, at + 2)
    end
    return sign .. concat(groups, " ")
end

function ns.ShortDate(stamp)
    local year, month, day, hour, minute = match(stamp or "", "^(%d+)-(%d+)-(%d+) (%d+):(%d+)")
    if not year then return "-" end
    return format("%s.%s %s:%s", day, month, hour, minute)
end

function ns.NewTimer(callback)
    local frame = CreateFrame("Frame")
    local slots, current, firing = {}, nil, nil
    for i = 1, 2 do
        local group = frame:CreateAnimationGroup()
        if group then
            slots[i] = { group = group, anim = group:CreateAnimation("Animation") }
        end
    end
    local native = slots[1] ~= nil and slots[2] ~= nil
    local timer = { native = native, running = false }
    local startedAt, wanted, left = 0, 0, 0

    local function Fire(slot)
        if slot ~= current then return end
        current = nil
        timer.running = false
        timer.lagMs = ns.MsSince(startedAt + wanted)
        firing = slot
        callback()
        firing = nil
    end

    local function OnUpdate(self, elapsed)
        left = left - elapsed
        if left <= 0 then
            frame:SetScript("OnUpdate", nil)
            Fire(frame)
        end
    end

    if native then
        for _, slot in ipairs(slots) do
            slot.group:SetScript("OnFinished", function()
                Fire(slot)
            end)
        end
    end

    function timer.Stop()
        timer.running = false
        local slot = current
        current = nil
        if not slot then return end
        if not native then
            frame:SetScript("OnUpdate", nil)
        elseif slot ~= firing and slot.group:IsPlaying() then
            slot.group:Stop()
        end
    end

    function timer.Start(seconds)
        timer.Stop()
        timer.running = true
        startedAt, wanted = GetTime(), seconds
        if native then
            local slot = slots[1] ~= firing and slots[1] or slots[2]
            slot.anim:SetDuration(seconds)
            current = slot
            slot.group:Play()
        else
            left = seconds
            current = frame
            frame:SetScript("OnUpdate", OnUpdate)
        end
    end

    return timer
end

local scanner = CreateFrame("GameTooltip", "SirusMythicLogScanner", UIParent, "GameTooltipTemplate")
scanner:SetOwner(UIParent, "ANCHOR_NONE")
scanner:Hide()

function ns.ScanTooltip(method, ...)
    scanner:Hide()
    scanner:ClearLines()
    scanner:SetOwner(UIParent, "ANCHOR_NONE")
    scanner[method](scanner, ...)
    local count = scanner:NumLines()
    local left, right = {}, {}
    for i = 1, count do
        left[i] = _G["SirusMythicLogScannerTextLeft" .. i]:GetText()
        right[i] = _G["SirusMythicLogScannerTextRight" .. i]:GetText()
    end
    scanner:Hide()
    return count, left, right
end

local lines, texts = {}, {}

function ns.ScanLines(method, ...)
    scanner:Hide()
    scanner:ClearLines()
    scanner:SetOwner(UIParent, "ANCHOR_NONE")
    scanner[method](scanner, ...)
    local count = scanner:NumLines()
    for i = 1, count do
        local line = lines[i]
        if not line then
            line = _G["SirusMythicLogScannerTextLeft" .. i]
            lines[i] = line
        end
        texts[i] = line:GetText()
    end
    scanner:Hide()
    return count, texts
end

ns.ENCHANT_TIME = ns.FormatPatterns("ITEM_ENCHANT_TIME_LEFT_SEC", "ITEM_ENCHANT_TIME_LEFT_MIN", "ITEM_ENCHANT_TIME_LEFT_HOURS",
    "ITEM_ENCHANT_TIME_LEFT_DAYS")
