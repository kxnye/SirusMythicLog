local _, ns = ...

local Session = ns.Session

local commands = {}

function commands.log(arg)
    if arg == "on" or arg == "off" then
        Session.SetSetting("autoLog", arg == "on")
    end
end

SLASH_SIRUSMYTHICLOG1 = "/sml"
SlashCmdList.SIRUSMYTHICLOG = function(msg)
    local cmd, arg = string.match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
    local handler = commands[string.lower(cmd or "")]
    if handler then
        handler(arg or "")
    else
        ns.Panel.Toggle()
    end
end
