local addonName, ns = ...

local Snapshot, Book, Cache, Modifier, CleanStats = {}, {}, {}, {}, {}
ns.Snapshot, ns.Book, ns.Cache, ns.Modifier, ns.CleanStats = Snapshot, Book, Cache, Modifier, CleanStats

local D = ns.Data
local Store = ns.Store
local KV = ns.KV

local floor, min = math.floor, math.min
local format, gsub, match, find = string.format, string.gsub, string.match, string.find
local concat, tinsert = table.concat, table.insert

local NATIVE = 1
local FACTIONS = { 932, 934 }

local auras, full

local function Clean(value)
    if value == nil then return "" end
    local text = tostring(value)
    text = gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = gsub(text, "|r", "")
    text = gsub(text, "|H.-|h(.-)|h", "%1")
    text = gsub(text, "|T.-|t", "")
    text = gsub(text, "|A.-|a", "")
    text = gsub(text, "|", "/")
    text = gsub(text, "[\r\n]+", " ")
    text = gsub(text, ";", ",")
    text = gsub(text, "^%s+", "")
    text = gsub(text, "%s+$", "")
    return text
end

local function Raw(value)
    if type(value) == "number" then
        return format("%.9g", value)
    end
    return value
end

local function Value(value)
    if type(value) == "number" then
        if value == floor(value) then
            return format("%.0f", value)
        end
        local text = format("%.2f", value)
        text = gsub(text, "0+$", "")
        text = gsub(text, "%.$", "")
        return text
    end
    return Clean(value)
end

local Writer = {}
Writer.__index = Writer

function Writer:Line(tag, ...)
    local parts = { tag }
    for i = 1, select("#", ...), 2 do
        local key, value = select(i, ...)
        if value ~= nil then
            local text = Value(value)
            if text ~= "" then
                parts[#parts + 1] = key .. "=" .. text
            end
        end
    end
    self.lines[#self.lines + 1] = concat(parts, ";")
end

function Writer:Add(line)
    self.lines[#self.lines + 1] = line
end

local function ParseGuid(hex)
    if type(hex) ~= "string" or #hex < 18 then
        return 0, hex or ""
    end
    local high = tonumber(hex:sub(3, 10), 16) or 0
    local low = tonumber(hex:sub(11, 18), 16) or 0
    return high * 4294967296 + low, hex
end

local function WriteIdentity(w)
    local client, build = GetBuildInfo()
    w:Line("SNAPSHOT", "addon", addonName, "version", ns.VERSION, "format", ns.FORMAT,
        "time", date("%Y-%m-%d %H:%M:%S"), "client", client, "clientBuild", build, "realm", GetRealmName())

    local guid, guidHex = ParseGuid(UnitGUID("player"))
    local race, raceToken, raceId = UnitRace("player")
    local class, classToken, classId = UnitClass("player")
    local faction, factionName = UnitFactionGroup("player")
    local guild = GetGuildInfo("player")
    w:Line("PLAYER", "name", UnitName("player"), "guid", guid, "guidHex", guidHex, "level", UnitLevel("player"),
        "race", race, "raceToken", raceToken, "raceId", raceId, "class", class, "classToken", classToken,
        "classId", classId, "gender", UnitSex("player"), "faction", faction, "factionName", factionName,
        "guild", guild)

    local form = GetShapeshiftForm()
    if form > 0 then
        local _, formName = GetShapeshiftFormInfo(form)
        w:Line("FORM", "index", form, "name", formName)
    end

    local resource = { "RESOURCE", "healthMax", UnitHealthMax("player") }
    local powers = {}
    for kind = 0, 6 do
        local maxPower = UnitPowerMax("player", kind)
        if maxPower > 0 then
            resource[#resource + 1] = D.POWER_KEY[kind]
            resource[#resource + 1] = maxPower
            powers[#powers + 1] = { kind = kind, max = maxPower }
        end
    end
    w:Line(unpack(resource))

    local primary = UnitPowerType("player")
    for _, power in ipairs(powers) do
        w:Line("POWER", "type", power.kind, "key", D.POWER_KEY[power.kind], "cur", UnitPower("player", power.kind),
            "max", power.max, "primary", power.kind == primary and 1 or nil)
    end
end

local function FirstAura(known)
    for _, list in ipairs({ auras.buffs, auras.debuffs }) do
        for _, aura in ipairs(list) do
            if known[aura.spellId] then return aura end
        end
    end
end

local function WriteBoosts(w)
    local category = FirstAura(D.CATEGORY)
    if category then
        local info = D.CATEGORY[category.spellId]
        w:Line("CATEGORY", "rank", info.rank, "plus", info.plus, "points", D.CategoryPoints(info.rank, info.plus),
            "spellId", category.spellId, "name", category.name)
    end
    local vip = FirstAura(D.VIP_LEVEL)
    if vip then
        w:Line("VIP", "level", D.VIP_LEVEL[vip.spellId], "spellId", vip.spellId, "name", vip.name)
    end
    local zodiac = FirstAura(D.ZODIAC)
    if zodiac then
        w:Line("ZODIAC", "spellId", zodiac.spellId, "name", D.ZODIAC[zodiac.spellId], "aura", zodiac.name)
    end

    local info = C_PlayerInfo
    if not info then
        w:Line("UPS", "api", 0)
        return
    end
    local total, maxPoints, available = info.GetBonusStatPointInfo()
    local spent = info.GetNumBonusStatsSpent()
    local count = info.GetNumBonusStats() or 0
    if total == nil and spent == nil and count <= 0 then
        w:Line("UPS", "api", 0)
        return
    end
    w:Line("UPS", "api", 1, "total", Raw(total), "max", Raw(maxPoints), "available", Raw(available),
        "spent", Raw(spent), "count", count)
    for i = 1, count do
        local name, points, bonus, perPoint = info.GetBonusStatInfo(i)
        w:Line("BOOST", "id", i, "stat", D.BOOST_KEY[i] or ("boost" .. i), "name", name, "points", Raw(points),
            "bonus", Raw(bonus), "perPoint", Raw(perPoint))
    end
end

local function WriteSirus(w)
    local unit = C_Unit
    if not unit then return end
    local category, categorySpell = unit.GetCategoryInfo("player")
    local zodiacRace, zodiac = unit.GetZodiacByDebuff("player")
    w:Line("SIRUS", "category", category, "categorySpell", categorySpell, "vipCategory", unit.GetVipCategory("player"),
        "zodiacRace", zodiacRace, "zodiac", zodiac)
end

local function SchoolName(school)
    return _G["DAMAGE_SCHOOL" .. school] or ("school" .. school)
end

local function WriteStats(w)
    for i = 1, 5 do
        local stat, effective, pos, neg = UnitStat("player", i)
        w:Line("STAT", "id", D.STAT_KEY[i], "value", effective, "base", stat - pos - neg, "pos", pos, "neg", neg)
    end

    local armorBase, armor, _, armorPos, armorNeg = UnitArmor("player")
    w:Line("STAT", "id", "armor", "value", armor, "base", armorBase, "pos", armorPos, "neg", armorNeg)

    local defense, defenseMod = UnitDefense("player")
    w:Line("STAT", "id", "defense", "value", defense + defenseMod, "base", defense, "mod", defenseMod)

    w:Line("STAT", "id", "dodge", "pct", GetDodgeChance())
    w:Line("STAT", "id", "parry", "pct", GetParryChance())
    w:Line("STAT", "id", "block", "pct", GetBlockChance())
    w:Line("STAT", "id", "block_value", "value", GetShieldBlock())
    w:Line("STAT", "id", "resilience", "value", min(GetCombatRating(15), GetCombatRating(16), GetCombatRating(17)))

    local onslaught = GetOnslaughtRating and GetOnslaughtRating()
    if onslaught then
        w:Line("STAT", "id", "onslaught", "value", onslaught)
    end

    local ap, apPos, apNeg = UnitAttackPower("player")
    w:Line("STAT", "id", "attack_power", "value", ap + apPos + apNeg, "base", ap, "pos", apPos, "neg", apNeg)
    w:Line("STAT", "id", "crit_melee", "pct", GetCritChance())

    local expertise, expertiseOff = GetExpertise()
    local expertisePct, expertiseOffPct = GetExpertisePercent()
    w:Line("STAT", "id", "expertise", "value", expertise, "offhand", expertiseOff, "pct", expertisePct,
        "offhandPct", expertiseOffPct)

    local mainSpeed, offSpeed = UnitAttackSpeed("player")
    w:Line("STAT", "id", "melee_speed", "main", mainSpeed, "off", offSpeed)

    local minDamage, maxDamage, minOff, maxOff = UnitDamage("player")
    w:Line("STAT", "id", "melee_damage", "min", floor(minDamage + 0.5), "max", floor(maxDamage + 0.5),
        "minOff", minOff and floor(minOff + 0.5), "maxOff", maxOff and floor(maxOff + 0.5))

    local rap, rapPos, rapNeg = UnitRangedAttackPower("player")
    w:Line("STAT", "id", "ranged_attack_power", "value", rap + rapPos + rapNeg, "base", rap, "pos", rapPos,
        "neg", rapNeg)
    w:Line("STAT", "id", "crit_ranged", "pct", GetRangedCritChance())

    local rangedSpeed, rangedMin, rangedMax = UnitRangedDamage("player")
    w:Line("STAT", "id", "ranged_damage", "speed", rangedSpeed, "min", floor(rangedMin + 0.5),
        "max", floor(rangedMax + 0.5))

    for school = 2, 7 do
        w:Line("STAT", "id", "spell_power", "school", school, "name", SchoolName(school),
            "value", GetSpellBonusDamage(school))
    end
    w:Line("STAT", "id", "spell_healing", "value", GetSpellBonusHealing())
    for school = 2, 7 do
        w:Line("STAT", "id", "crit_spell", "school", school, "name", SchoolName(school),
            "pct", GetSpellCritChance(school))
    end
    w:Line("STAT", "id", "spell_penetration", "value", GetSpellPenetration())

    local regen, regenCasting = GetManaRegen()
    w:Line("STAT", "id", "mana_regen", "value", regen * 5, "casting", regenCasting * 5)
    w:Line("STAT", "id", "armor_penetration", "pct", GetArmorPenetration())

    for school = 1, 6 do
        local base, total, pos, neg = UnitResistance("player", school)
        w:Line("RES", "school", school, "name", SchoolName(school + 1), "value", total, "base", base, "pos", pos,
            "neg", neg)
    end
    for id = 1, 25 do
        w:Line("RATING", "id", id, "key", D.RATING_KEY[id], "value", GetCombatRating(id),
            "pct", GetCombatRatingBonus(id))
    end
end

local function WriteRawStats(w)
    for i = 1, 5 do
        local stat, effective, pos, neg = UnitStat("player", i)
        w:Line("RAW_STAT", "id", D.STAT_KEY[i], "stat", Raw(stat), "effective", Raw(effective), "pos", Raw(pos),
            "neg", Raw(neg))
    end

    local armorBase, armorEffective, armor, armorPos, armorNeg = UnitArmor("player")
    w:Line("RAW_ARMOR", "base", Raw(armorBase), "effective", Raw(armorEffective), "armor", Raw(armor),
        "pos", Raw(armorPos), "neg", Raw(armorNeg))

    local defense, defenseMod = UnitDefense("player")
    w:Line("RAW_DEFENSE", "base", Raw(defense), "mod", Raw(defenseMod), "total", Raw(defense + defenseMod))

    w:Line("RAW_AVOID", "dodge", Raw(GetDodgeChance()), "parry", Raw(GetParryChance()), "block", Raw(GetBlockChance()),
        "blockValue", Raw(GetShieldBlock()))
    w:Line("RAW_CRIT_HELPERS", "melee", Raw(GetCritChance()), "ranged", Raw(GetRangedCritChance()),
        "fromAgi", Raw(GetCritChanceFromAgility("player")),
        "spellFromInt", Raw(GetSpellCritChanceFromIntellect("player")))
    for school = 2, 7 do
        w:Line("RAW_SPELL_CRIT", "school", school, "value", Raw(GetSpellCritChance(school)))
    end
    for id = 1, 25 do
        w:Line("RAW_RATING", "id", id, "key", D.RATING_KEY[id], "rating", Raw(GetCombatRating(id)),
            "bonus", Raw(GetCombatRatingBonus(id)))
    end

    local ap, apPos, apNeg = UnitAttackPower("player")
    w:Line("RAW_AP", "base", Raw(ap), "pos", Raw(apPos), "neg", Raw(apNeg), "total", Raw(ap + apPos + apNeg))
    local rap, rapPos, rapNeg = UnitRangedAttackPower("player")
    w:Line("RAW_RAP", "base", Raw(rap), "pos", Raw(rapPos), "neg", Raw(rapNeg), "total", Raw(rap + rapPos + rapNeg))

    local _, str = UnitStat("player", 1)
    local _, agi = UnitStat("player", 2)
    w:Line("RAW_AP_HELPERS", "str", Raw(str), "fromStr", Raw(GetAttackPowerForStat(1, str)), "agi", Raw(agi),
        "fromAgi", Raw(GetAttackPowerForStat(2, agi)))

    local expertise, expertiseOff = GetExpertise()
    local expertisePct, expertiseOffPct = GetExpertisePercent()
    w:Line("RAW_EXPERTISE", "main", Raw(expertise), "off", Raw(expertiseOff), "mainPct", Raw(expertisePct),
        "offPct", Raw(expertiseOffPct))

    local mainSpeed, offSpeed = UnitAttackSpeed("player")
    w:Line("RAW_MELEE_SPEED", "main", Raw(mainSpeed), "off", Raw(offSpeed))

    local minDamage, maxDamage, minOff, maxOff, physicalPos, physicalNeg, percent = UnitDamage("player")
    w:Line("RAW_MELEE_DAMAGE", "min", Raw(minDamage), "max", Raw(maxDamage), "minOff", Raw(minOff),
        "maxOff", Raw(maxOff), "physicalPos", Raw(physicalPos), "physicalNeg", Raw(physicalNeg),
        "percent", Raw(percent))

    local rangedSpeed, rangedMin, rangedMax, rangedPos, rangedNeg, rangedPercent = UnitRangedDamage("player")
    w:Line("RAW_RANGED_DAMAGE", "speed", Raw(rangedSpeed), "min", Raw(rangedMin), "max", Raw(rangedMax),
        "physicalPos", Raw(rangedPos), "physicalNeg", Raw(rangedNeg), "percent", Raw(rangedPercent))

    for school = 2, 7 do
        w:Line("RAW_SPELL_POWER", "school", school, "value", Raw(GetSpellBonusDamage(school)))
    end
    w:Line("RAW_HEALING", "value", Raw(GetSpellBonusHealing()))
    w:Line("RAW_PENETRATION", "spell", Raw(GetSpellPenetration()), "armorPct", Raw(GetArmorPenetration()))

    local regen, regenCasting = GetManaRegen()
    w:Line("RAW_MANA_REGEN", "normalPerSec", Raw(regen), "castingPerSec", Raw(regenCasting),
        "normalMP5", Raw(regen * 5), "castingMP5", Raw(regenCasting * 5))

    if GetUnitMaxHealthModifier then
        w:Line("RAW_HEALTH_MOD", "value", Raw(GetUnitMaxHealthModifier("player")))
    end
end

local function WriteAuras(w)
    for _, aura in ipairs(auras.buffs) do
        w:Line("BUFF", "i", aura.index, "spellId", aura.spellId, "name", aura.name, "rank", aura.rank,
            "stacks", aura.count, "duration", aura.duration, "caster", aura.caster)
    end
    for _, aura in ipairs(auras.debuffs) do
        w:Line("DEBUFF", "i", aura.index, "spellId", aura.spellId, "name", aura.name, "rank", aura.rank,
            "stacks", aura.count, "duration", aura.duration, "type", aura.debuffType, "caster", aura.caster)
    end
end

local function TalentId(tab, index)
    local link = GetTalentLink(tab, index, false, false, NATIVE, false)
    return link and tonumber(match(link, "|Htalent:(%-?%d+)"))
end

local function TalentGroups()
    local groups = C_Talent and C_Talent.GetNumTalentGroups() or 0
    local active = C_Talent and C_Talent.GetActiveTalentGroup() or 0
    if groups < 1 then
        groups = GetNumTalentGroups()
    end
    if active < 1 then
        active = GetActiveTalentGroup()
    end
    if groups < 1 then
        groups = 1
    end
    if active < 1 then
        active = 1
    end
    return groups, active
end

local function TabPoints()
    local spent = {}
    for tab = 1, GetNumTalentTabs() do
        local _, _, points = GetTalentTabInfo(tab, false, false, NATIVE)
        spent[tab] = points
    end
    return spent
end

function Snapshot.MainTab()
    return ns.MainTab(unpack(TabPoints()))
end

local function TabTalents(tab, visit)
    for index = 1, GetNumTalents(tab) do
        local name, _, tier, column, rank, maxRank = GetTalentInfo(tab, index, false, false, NATIVE)
        if rank > 0 then
            visit(index, TalentId(tab, index), rank, maxRank, tier, column, name)
        end
    end
end

local function EachGlyph(visit)
    for socket = 1, 6 do
        local enabled, glyphType, glyphSpell = GetGlyphSocketInfo(socket, NATIVE)
        if enabled and glyphSpell and glyphSpell ~= 0 then
            visit(socket, glyphType == 1 and "major" or "minor", glyphSpell)
        end
    end
end

local function WriteTalents(w)
    local groups, active = TalentGroups()
    w:Line("TALENTS", "groups", groups, "active", active, "native", NATIVE)

    local spentByTab = TabPoints()
    local tabs = #spentByTab
    w:Line("TALENTGROUP", "id", active, "points", concat(spentByTab, "/"),
        "unspent", GetUnspentTalentPoints(false, false, NATIVE))

    if C_Talent and C_Talent.GetTalentGroupPointSpent then
        local sirus = { C_Talent.GetTalentGroupPointSpent(active) }
        if #sirus > 0 then
            Snapshot.talentsMatch = 1
            for tab = 1, tabs do
                if (sirus[tab] or 0) ~= spentByTab[tab] then
                    Snapshot.talentsMatch = 0
                end
            end
        end
    end

    for tab = 1, tabs do
        w:Line("TREE", "group", active, "tab", tab, "name", GetTalentTabInfo(tab, false, false, NATIVE),
            "points", spentByTab[tab])
        TabTalents(tab, function(index, talentId, rank, maxRank, tier, column, name)
            w:Line("TALENT", "group", active, "tab", tab, "index", index, "talentId", talentId,
                "rank", rank, "max", maxRank, "tier", tier, "col", column, "name", name)
        end)
    end

    EachGlyph(function(socket, kind, spellId)
        w:Line("GLYPH", "group", active, "socket", socket, "type", kind, "spellId", spellId,
            "name", (GetSpellInfo(spellId)))
    end)
end

local function FirstHeader(wanted)
    for i = 1, GetNumSkillLines() do
        local name, isHeader, isExpanded = GetSkillLineInfo(i)
        if name and isHeader and wanted(name, isExpanded) then
            return i, name
        end
    end
end

local function WriteSkills(w)
    local expanded = {}
    for _ = 1, 41 do
        local index, name = FirstHeader(function(_, isExpanded)
            return not isExpanded
        end)
        if not index then break end
        expanded[name] = true
        ExpandSkillHeader(index)
    end

    local header = ""
    for i = 1, GetNumSkillLines() do
        local name, isHeader, _, rank, temp, modifier, maxRank = GetSkillLineInfo(i)
        if name then
            if isHeader then
                header = Clean(name)
            else
                local bonus = temp + modifier
                w:Line("SKILL", "name", name, "rank", rank, "max", maxRank, "bonus", bonus ~= 0 and bonus or nil,
                    "header", header)
            end
        end
    end

    for _ = 1, 41 do
        local index, name = FirstHeader(function(skill, isExpanded)
            return isExpanded and expanded[skill]
        end)
        if not index then break end
        expanded[name] = nil
        CollapseSkillHeader(index)
    end
end

local function TooltipLines(slot)
    local lines = {}
    local count, left, right = ns.ScanTooltip("SetInventoryItem", "player", slot)
    for i = 1, count do
        local l, r = Clean(left[i]), Clean(right[i])
        if l ~= "" and r ~= "" then
            lines[#lines + 1] = l .. " / " .. r
        elseif l ~= "" or r ~= "" then
            lines[#lines + 1] = l ~= "" and l or r
        end
    end
    return lines
end

local function LinkFields(link)
    local body = match(link, "item:([^|]+)")
    if not body then return {} end
    local fields = {}
    for value in (body .. ":"):gmatch("(.-):") do
        fields[#fields + 1] = tonumber(value) or 0
    end
    return fields
end

local ammoPatterns = ns.FormatPatterns("AMMO_DAMAGE_TEMPLATE", "AMMO_SCHOOL_DAMAGE_TEMPLATE")

local function AmmoDps()
    local count, left = ns.ScanTooltip("SetInventoryItem", "player", 0)
    for i = 1, count do
        for _, pattern in ipairs(ammoPatterns) do
            local value = left[i] and match(left[i], pattern)
            if value then
                return tonumber((gsub(value, ",", ".")))
            end
        end
    end
end

local function WriteAmmo(w, link)
    local name = GetItemInfo(link) or match(link, "%[(.-)%]")
    w:Line("AMMO", "id", ns.ItemId(0), "name", name, "count", GetInventoryItemCount("player", 0), "dps", AmmoDps())
end

local function WriteGear(w)
    local links, equipped = {}, 0
    for _, slot in ipairs(D.SLOTS) do
        local link = GetInventoryItemLink("player", slot[1])
        links[slot[1]] = link
        if link then
            equipped = equipped + 1
        end
    end
    w:Line("GEAR", "items", equipped)
    if links[0] then
        WriteAmmo(w, links[0])
    end

    for _, slot in ipairs(D.SLOTS) do
        local id, key = slot[1], slot[2]
        local link = links[id]
        if not link then
            w:Line("ITEM", "slot", id, "key", key, "id", 0)
        else
            local fields = LinkFields(link)
            local name, _, quality, itemLevel, _, itemType, itemSubType = GetItemInfo(link)
            if not name then
                name = match(link, "%[(.-)%]")
            end
            local durability, durabilityMax = GetInventoryItemDurability(id)
            local broken = GetInventoryItemBroken("player", id)
            w:Line("ITEM", "slot", id, "key", key, "id", fields[1] or 0, "name", name, "quality", quality,
                "ilvl", itemLevel, "type", itemType, "subType", itemSubType, "enchant", fields[2],
                "gem1", fields[3], "gem2", fields[4], "gem3", fields[5], "gem4", fields[6], "suffix", fields[7],
                "unique", fields[8], "linkLevel", fields[9], "durability", durability, "durabilityMax", durabilityMax,
                "broken", broken and 1 or nil)
            if full then
                for n, text in ipairs(TooltipLines(id)) do
                    w:Line("TIP", "slot", id, "n", n, "text", text)
                end
            end
        end
    end
end

local function WriteItemLinks(w)
    for _, slot in ipairs(D.SLOTS) do
        local id = slot[1]
        local link = GetInventoryItemLink("player", id)
        if link then
            w:Add(KV("ITEMLINK", "slot", id, "link", match(link, "(item:[^|]+)") or ""))
            for socket = 1, 4 do
                local _, gemLink = GetItemGem(link, socket)
                local gem = gemLink and tonumber(match(gemLink, "item:(%d+)"))
                if gem then
                    w:Add(KV("GEMITEM", "slot", id, "socket", socket, "itemId", gem))
                end
            end
        end
    end
end

local function WriteReputation(w)
    for _, faction in ipairs(FACTIONS) do
        local name, _, standing, barMin, barMax, barValue = GetFactionInfoByID(faction)
        if name then
            w:Add(KV("REP", "faction", faction, "standing", standing, "value", barValue, "min", barMin, "max", barMax,
                "name", name))
        end
    end
end

local function WriteTalentLink(w)
    local link = C_Talent and C_Talent.GenerateTalentWebLink and C_Talent.GenerateTalentWebLink(false)
    if link then
        w:Add(KV("WEB", "talents", link))
    end
end

local function WriteSpellbook(w)
    Book.Each(function(id, name, rank, tab, index)
        local _, _, _, cost, _, _, castTime = GetSpellInfo(id)
        w:Add(KV("SB", "id", id, "name", name, "rank", rank or "", "ct", castTime, "cost", cost, "book", tab,
            "index", index))
    end)
end

local SECTIONS = {
    { "identity", WriteIdentity },
    { "boosts", WriteBoosts },
    { "sirus", WriteSirus },
    { "stats", WriteStats },
    { "precision_stats", WriteRawStats },
    { "auras", WriteAuras },
    { "talents", WriteTalents },
    { "skills", WriteSkills, fullOnly = true },
    { "gear", WriteGear },
    { "itemlinks", WriteItemLinks, fullOnly = true },
    { "reputation", WriteReputation },
    { "web", WriteTalentLink, fullOnly = true },
    { "spellbook", WriteSpellbook, fullOnly = true },
}

local STATIC_PART = { TIP = "gear", ITEMLINK = "gear", GEMITEM = "gear", SB = "book", SKILL = "book", WEB = "book" }

local function PlayerAuras(query)
    local list = {}
    for i = 1, D.AURA_SCAN do
        local name, rank, _, count, debuffType, duration, _, caster, _, _, spellId = query("player", i)
        if not name then break end
        list[#list + 1] = {
            index = i,
            name = name,
            rank = rank ~= "" and rank or nil,
            count = count or 0,
            debuffType = debuffType,
            duration = floor((duration or 0) + 0.5),
            caster = caster,
            spellId = spellId or 0,
        }
    end
    return list
end

function Snapshot.Build(withStatic)
    auras = { buffs = PlayerAuras(UnitBuff), debuffs = PlayerAuras(UnitDebuff) }
    full = withStatic and true or false
    Snapshot.talentsMatch = nil

    local w = setmetatable({ lines = {} }, Writer)
    for _, section in ipairs(SECTIONS) do
        if full or not section.fullOnly then
            local before = #w.lines
            local ok, err = pcall(section[2], w)
            if not ok then
                w:Line("ERROR", "section", section[1], "text", err)
            end
            if before > 0 and #w.lines > before then
                tinsert(w.lines, before + 1, "")
            end
        end
    end

    local parts = { dyn = {}, gear = {}, book = {} }
    for _, line in ipairs(w.lines) do
        local tag = line ~= "" and STATIC_PART[match(line, "^[^;]*")] or "dyn"
        local part = parts[tag]
        part[#part + 1] = line
    end
    local dyn = concat(parts.dyn, "\n")
    if not full then return dyn end
    return dyn, concat(parts.gear, "\n"), concat(parts.book, "\n")
end

local function Collect(part, ...)
    local w = setmetatable({ lines = {} }, Writer)
    local wasFull = full
    full = true
    for i = 1, select("#", ...) do
        select(i, ...)(w)
    end
    full = wasFull
    local out = {}
    for _, line in ipairs(w.lines) do
        if STATIC_PART[match(line, "^[^;]*")] == part then
            out[#out + 1] = line
        end
    end
    return concat(out, "\n")
end

local function GearStatic()
    return Collect("gear", WriteGear, WriteItemLinks)
end

local function ItemLinks()
    return Collect("gear", WriteItemLinks)
end

local function BookStatic()
    return Collect("book", WriteSkills, WriteTalentLink, WriteSpellbook)
end

local function Spec()
    local points = TabPoints()
    local talents, major, minor = {}, {}, {}
    for tab = 1, #points do
        TabTalents(tab, function(_, talentId, rank)
            if talentId then
                talents[#talents + 1] = talentId .. ":" .. rank
            end
        end)
    end
    EachGlyph(function(_, kind, spellId)
        local list = kind == "major" and major or minor
        list[#list + 1] = spellId
    end)
    return concat(points, "/"), concat(talents, ","), concat(major, ","), concat(minor, ",")
end

function Book.Each(visit)
    for tab = 1, GetNumSpellTabs() do
        local _, _, offset, count = GetSpellTabInfo(tab)
        for index = offset + 1, offset + count do
            local name, rank = GetSpellName(index, "spell")
            local link = GetSpellLink(index, "spell")
            local id = link and tonumber(match(link, "spell:(%d+)"))
            if name and id then
                visit(id, name, rank, tab, index)
            end
        end
    end
end

local function Resolve(bases, indexOf, highest)
    for _, base in ipairs(bases or {}) do
        local name = GetSpellInfo(base)
        local id = name and highest[name]
        if id then
            return id, indexOf[id]
        end
    end
end

function Book.Build()
    local names, indexOf, highest = {}, {}, {}
    Book.Each(function(id, name, rank, _, index)
        local ranks = names[name]
        if not ranks then
            ranks = {}
            names[name] = ranks
        end
        ranks[rank or ""] = id
        indexOf[id] = index
        highest[name] = id
    end)
    local _, class = UnitClass("player")
    local refs = D.CLASS[class] or {}
    local gcd, gcdIndex = Resolve(refs.gcd, indexOf, highest)
    local melee, meleeIndex = Resolve(refs.melee, indexOf, highest)
    return {
        names = names,
        index = indexOf,
        highest = highest,
        gcd = gcd,
        gcdIndex = gcdIndex,
        melee = melee,
        meleeIndex = meleeIndex,
    }
end

local CACHE_FRESH = 60

local snap = {}
local staticDirty, dynDirty, bookDirty = true, true, true
local book

local function AuraSignature()
    local ids = {}
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        for i = 1, D.AURA_SCAN do
            local name, _, _, count, _, _, _, _, _, _, spellId = UnitAura("player", i, filter)
            if not name then break end
            ids[#ids + 1] = tostring(spellId or 0) .. "x" .. tostring(count or 0)
        end
        ids[#ids + 1] = "|"
    end
    return concat(ids, ",")
end

function Cache.MarkAll()
    staticDirty, dynDirty, bookDirty = true, true, true
end

function Cache.MarkDynamic()
    dynDirty = true
end

function Cache.MarkBook()
    bookDirty = true
end

function Cache.StaticDirty()
    return staticDirty
end

function Cache.Book()
    if bookDirty or not book then
        book = Book.Build()
        ns.Recorder.SetBook(book)
        bookDirty = false
    end
    return book
end

function Cache.LastBook()
    return book
end

function Cache.Stale()
    return staticDirty or dynDirty or not snap.at or GetTime() - snap.at >= CACHE_FRESH
end

function Cache.State()
    local stale = staticDirty or not snap.dyn or not snap.at or GetTime() - snap.at >= CACHE_FRESH
    return stale, not stale and dynDirty
end

function Cache.Take()
    if ns.InCombat() then return snap.dyn and snap or nil end
    local sig = AuraSignature()
    if sig ~= snap.sig then
        dynDirty = true
    end
    if staticDirty or not snap.book then
        snap.dyn, snap.gear, snap.book = Snapshot.Build(true)
        staticDirty = false
    elseif Cache.Stale() then
        snap.dyn = Snapshot.Build(false)
    else
        return snap
    end
    snap.at = GetTime()
    snap.sig = sig
    dynDirty = false
    return snap
end

function Cache.Copy()
    if not snap.dyn then return nil end
    return { dyn = snap.dyn, gear = snap.gear, book = snap.book, at = snap.at }
end

function Cache.Write(parts, guid)
    if not parts then return end
    local out = { parts.dyn }
    if parts.gear and parts.gear ~= "" then
        out[#out + 1] = "STATIC;id=" .. Store.Static(guid .. ":gear", parts.gear)
    end
    if parts.book and parts.book ~= "" then
        out[#out + 1] = "STATIC;id=" .. Store.Static(guid .. ":book", parts.book)
    end
    Store.WriteChunk(concat(out, "\n"))
end

function Cache.After(closed)
    local dyn = Snapshot.Build(false)
    Store.Append(closed, dyn)
    snap.dyn, snap.at, snap.sig = dyn, GetTime(), AuraSignature()
    dynDirty = false
end

local MOD_SPELL = 382349

local function ModifierText(index, filter)
    local lines = {}
    local count, left = ns.ScanTooltip("SetUnitAura", "player", index, filter)
    for i = 1, count do
        local text = left[i]
        if text and text ~= "" then
            lines[#lines + 1] = text
        end
    end
    return lines
end

local function ModifierValue(lines)
    for i = 2, #lines do
        local number = match(lines[i], "(%-?%d+[%.,]?%d*)%s*%%")
        if number then
            return tonumber((gsub(number, ",", ".")))
        end
    end
end

function Modifier.Read()
    local found = {}
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        for i = 1, D.AURA_SCAN do
            local name, _, _, _, _, _, _, _, _, _, spellId = UnitAura("player", i, filter)
            if not name then break end
            if spellId == MOD_SPELL or find(name, "Модификатор", 1, true) == 1 then
                local lines = ModifierText(i, filter)
                local mod = { spellId = spellId, value = ModifierValue(lines), text = concat(lines, " / ") }
                if spellId == MOD_SPELL then
                    tinsert(found, 1, mod)
                else
                    found[#found + 1] = mod
                end
            end
        end
    end
    return found
end

function Modifier.Key(found)
    local parts = {}
    for _, mod in ipairs(found) do
        parts[#parts + 1] = tostring(mod.spellId) .. ":" .. tostring(mod.value) .. ":" .. mod.text
    end
    return concat(parts, "|")
end

local function CountT4()
    local count = 0
    for slot = 1, 19 do
        if D.T4[ns.ItemId(slot)] then
            count = count + 1
        end
    end
    return count
end

local function ModifierLine(where, mod, dtMs)
    return KV("MOD", "spellId", mod and mod.spellId or MOD_SPELL, "present", mod and 1 or 0,
        "value", mod and mod.value, "text", mod and mod.text, "where", where, "t4", CountT4(),
        "time", ns.Stamp(), "gt", format("%.3f", GetTime()), "dtMs", dtMs)
end

function Modifier.Lines(where, found, out, dtMs)
    if #found == 0 then
        out[#out + 1] = ModifierLine(where, nil, dtMs)
    end
    for _, mod in ipairs(found) do
        out[#out + 1] = ModifierLine(where, mod, dtMs)
    end
end

function Modifier.Snapshot(where, out)
    local found = Modifier.Read()
    local key = Modifier.Key(found)
    if where == "arm" and Modifier.last and Modifier.last ~= key then
        where = "change"
    end
    Modifier.Lines(where, found, out)
    local parsed = 0
    for _, mod in ipairs(found) do
        if mod.value then
            parsed = 1
        end
    end
    out[#out + 1] = ns.ProbeLine("mod.parsed", parsed)
    return key
end

local NumberText, InCombat = ns.NumberText, ns.InCombat
local select, tostring, tonumber, max, gmatch, byte = select, tostring, tonumber, math.max, string.gmatch, string.byte
local GetTime, UnitAura = GetTime, UnitAura
local ENCHANT_TIME = ns.ENCHANT_TIME

local QUIET = 2
local SETTLE = 15
local MAIN, OFF = D.WEAPON_SLOTS[1], D.WEAPON_SLOTS[2]
local CLOSE = byte(")")
local BUSY = { rec = true, armed = true }
local TALENT_EVENT = {
    PLAYER_TALENT_UPDATE_EX = "ex", PLAYER_TALENT_ACTIVE_GROUP_CHANGED = "group", PLAYER_TALENT_UPDATE = "talent",
    CHARACTER_POINTS_CHANGED = "points",
}
local TALENT_KEYS = { "ex", "group", "talent", "points" }

local frame = CreateFrame("Frame")
local timer
local holdUntil, dueAt, firstAt = 0, 0, 0
local deferred = false
local bookStale = true
local listening = false
local lastWait, enchantHeld, enchantGone
local talentSeen = { ex = 0, group = 0, talent = 0, points = 0 }

local function Join(...)
    local parts, last = {}, 0
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        parts[i] = value and NumberText(value) or ""
        if parts[i] ~= "" then
            last = i
        end
    end
    if last == 0 then return nil end
    return concat(parts, ",", 1, last)
end

local function List(items)
    if #items == 0 then return nil end
    return concat(items, ",")
end

local function Text(value)
    if value == "" then return nil end
    return value
end

local function Schools(read)
    local first = read(2)
    local values, same = { first }, true
    for school = 3, 7 do
        local value = read(school)
        values[#values + 1] = value
        if value ~= first then
            same = false
        end
    end
    if same then return NumberText(first) end
    return Join(unpack(values))
end

local function ScanAuras(filter, out)
    for i = 1, D.AURA_SCAN do
        local name, rank, _, count, _, duration, _, caster, _, _, spellId = UnitAura("player", i, filter)
        if not name then return true end
        if (caster and caster ~= "player") or (duration and duration > 0 and not D.Neutral(spellId)) then
            return false, "aura:" .. tostring(spellId or 0) .. ":" .. (caster or "-") .. ":" .. NumberText(duration or 0)
        end
        out[#out + 1] = { spellId = spellId or 0, rank = rank, count = count or 0, caster = caster }
    end
    return true
end

local function EnchantBlocks(slot)
    local count, texts = ns.ScanLines("SetInventoryItem", "player", slot)
    local seen = false
    for i = 1, count do
        local text = texts[i]
        if text and byte(text, -1) == CLOSE then
            for p = 1, #ENCHANT_TIME do
                local name = match(text, ENCHANT_TIME[p])
                if name then
                    if not D.NeutralEnchant(name) then return name end
                    seen = true
                    break
                end
            end
        end
    end
    if not seen then return "-" end
end

local function EnchantWait()
    local main, mainMs, _, off, offMs = GetWeaponEnchantInfo()
    local name = main and EnchantBlocks(MAIN)
    if name then
        enchantHeld = MAIN
        return "enchant:" .. MAIN .. ":" .. name, (mainMs or 0) / 1000
    end
    name = off and EnchantBlocks(OFF)
    if name then
        enchantHeld = OFF
        return "enchant:" .. OFF .. ":" .. name, (offMs or 0) / 1000
    end
    if enchantHeld then
        enchantHeld, enchantGone = false, "later"
    end
end

local function Refusal(scan)
    if Store.Full() then return "full" end
    if UnitIsDeadOrGhost("player") then return "dead" end
    local clean, aura = ScanAuras("HELPFUL", scan)
    if clean then
        clean, aura = ScanAuras("HARMFUL", scan)
    end
    if aura then return aura end
    return EnchantWait()
end

local function Known(scan, list)
    for _, aura in ipairs(scan) do
        local info = list[aura.spellId]
        if info then return info, aura.spellId end
    end
end

local function AuraTokens(scan, zodiac)
    local mine, none = {}, {}
    for _, aura in ipairs(scan) do
        local token = tostring(aura.spellId)
        if aura.count ~= 0 then
            token = token .. "x" .. aura.count
        end
        if zodiac and aura.rank == zodiac then
            token = token .. "z"
        end
        local list = aura.caster and mine or none
        list[#list + 1] = token
    end
    return List(mine), List(none)
end

local function Boosts()
    local info = C_PlayerInfo
    if not info then return nil end
    local parts = {}
    for i = 1, info.GetNumBonusStats() or 0 do
        local _, points = info.GetBonusStatInfo(i)
        if points and points ~= 0 then
            parts[#parts + 1] = i .. ":" .. NumberText(points)
        end
    end
    return List(parts)
end

local function ModifierValues()
    local values = {}
    for _, mod in ipairs(Modifier.Read()) do
        values[#values + 1] = mod.value and NumberText(mod.value) or ""
    end
    return List(values)
end

local function Form()
    local form = GetShapeshiftForm()
    if form == 0 then return nil end
    return (select(2, GetShapeshiftFormInfo(form)))
end

local function Ammo()
    local id = ns.ItemId(0)
    if not id then return nil end
    return Join(id, AmmoDps())
end

local function Ratings()
    local ratings, bonuses = {}, {}
    for id = 1, #D.RATING_KEY do
        local value = GetCombatRating(id)
        if value ~= 0 then
            ratings[#ratings + 1] = id .. ":" .. NumberText(value)
        end
    end
    for _, id in ipairs(D.RATING_PCT) do
        local value = GetCombatRatingBonus(id)
        if value ~= 0 then
            bonuses[#bonuses + 1] = id .. ":" .. NumberText(value)
        end
    end
    return List(ratings), List(bonuses)
end

local function Put(out, key, value)
    if value ~= nil then
        out[#out + 1] = key
        out[#out + 1] = value
    end
end

local function SpecRef(guid)
    local points, talents, major, minor = Spec()
    return Store.Static(guid .. ":spec", KV("SPEC", "points", points, "talents", Text(talents), "major", Text(major),
        "minor", Text(minor)))
end

local function Body(scan, guid)
    local category, categorySpell = Known(scan, D.CATEGORY)
    local vip, vipSpell = Known(scan, D.VIP_LEVEL)
    local zodiac, zodiacSpell = Known(scan, D.ZODIAC)
    local mine, none = AuraTokens(scan, zodiac)
    local ratings, bonuses = Ratings()
    local mana = UnitPowerMax("player", 0)
    local out = {}
    Put(out, "lv", UnitLevel("player"))
    Put(out, "s", SpecRef(guid))
    Put(out, "cat", category and Join(category.rank, category.plus, categorySpell))
    Put(out, "vip", vip and Join(vip, vipSpell))
    Put(out, "zod", zodiac and (zodiacSpell .. "," .. zodiac))
    Put(out, "ups", Boosts())
    Put(out, "mod", ModifierValues())
    Put(out, "form", Form())
    Put(out, "pa", mine)
    Put(out, "na", none)
    Put(out, "ammo", Ammo())
    for stat, key in ipairs(D.STAT_KEY) do
        Put(out, key, Join(UnitStat("player", stat)))
    end
    Put(out, "hp", UnitHealthMax("player"))
    Put(out, "mp", mana > 0 and mana or nil)
    Put(out, "arm", Join(UnitArmor("player")))
    Put(out, "def", Join(UnitDefense("player")))
    Put(out, "dodge", GetDodgeChance())
    Put(out, "parry", GetParryChance())
    Put(out, "block", GetBlockChance())
    Put(out, "bv", GetShieldBlock())
    Put(out, "ap", Join(UnitAttackPower("player")))
    Put(out, "rap", Join(UnitRangedAttackPower("player")))
    Put(out, "mcr", GetCritChance())
    Put(out, "rcr", GetRangedCritChance())
    Put(out, "ex", Join(GetExpertise()))
    Put(out, "ms", Join(UnitAttackSpeed("player")))
    Put(out, "md", Join(UnitDamage("player")))
    Put(out, "rd", Join(UnitRangedDamage("player")))
    Put(out, "sp", Schools(GetSpellBonusDamage))
    Put(out, "cr", Schools(GetSpellCritChance))
    Put(out, "heal", GetSpellBonusHealing())
    Put(out, "pen", GetSpellPenetration())
    Put(out, "arp", GetArmorPenetration())
    Put(out, "mreg", Join(GetManaRegen()))
    Put(out, "r", ratings)
    Put(out, "rb", bonuses)
    for school = 1, 6 do
        local base, total, pos, neg = UnitResistance("player", school)
        if base ~= 0 or total ~= 0 or pos ~= 0 or neg ~= 0 then
            Put(out, "res" .. school, Join(base, total, pos, neg))
        end
    end
    return KV("", unpack(out))
end

local function Settled(text)
    return (gsub(text, ";([pn]a=)([^;]*)", function(field, list)
        local kept = {}
        for token in gmatch(list, "[^,]+") do
            if not D.Neutral(tonumber(match(token, "^%d+"))) then
                kept[#kept + 1] = token
            end
        end
        if #kept == 0 then return "" end
        return ";" .. field .. concat(kept, ",")
    end))
end

local function Ends(text, tail)
    if #text < #tail or text:sub(-#tail) ~= tail then return false end
    return #text == #tail or text:sub(-#tail - 1, -#tail - 1) == "\n"
end

local function GearRef(guid)
    local links = ItemLinks()
    if links == "" then return nil end
    local key = guid .. ":gear"
    local id, text = Store.LastStatic(key)
    if id and Ends(text, links) then return id end
    return Store.Static(key, GearStatic())
end

local function BookRef(guid)
    local key = guid .. ":book"
    local id = Store.LastStatic(key)
    if id and not bookStale then return id end
    local text = BookStatic()
    bookStale = false
    if text == "" then return nil end
    return Store.Static(key, text)
end

local function Player()
    local _, raceToken, raceId = UnitRace("player")
    local _, _, classId = UnitClass("player")
    return { name = UnitName("player"), class = classId, race = raceToken, raceId = raceId }
end

local function Busy()
    return ns.Recorder.Active() or BUSY[ns.Session.State()] or ns.Session.Pending()
end

local function Take()
    if InCombat() then return end
    firstAt = 0
    if Busy() then
        deferred = true
        return
    end
    local scan = {}
    local wait, left = Refusal(scan)
    if wait then
        lastWait = wait
        if left and left > 0 then
            timer.Start(left + QUIET)
        end
        return
    end
    local guid = UnitGUID("player")
    local body = Body(scan, guid)
    local last = Store.LastClean()
    local at = last and find(last, ";lv=", 1, true)
    if at and Settled(last:sub(at)) == Settled(body) then return end
    local head = KV("CLEAN", "at", time(), "g", GearRef(guid), "b", BookRef(guid))
    Store.AddClean(head .. body, Player())
    ns.Button.Refresh()
    ns.Panel.Refresh()
end

local function Run(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if ok then return end
    Store.AddError(KV("ERROR", "time", ns.Stamp(), "where", where, "text", tostring(err)))
    ns.SayError()
end

timer = ns.NewTimer(function()
    Run("clean", Take)
end)

local function Touch(wait)
    if InCombat() then return end
    local now = GetTime()
    if wait > QUIET then
        holdUntil = max(holdUntil, now + wait)
    end
    if firstAt == 0 or firstAt + SETTLE < now then
        firstAt = now
    end
    dueAt = max(min(now + QUIET, firstAt + SETTLE), holdUntil)
    if Busy() then
        deferred = true
        return
    end
    deferred = false
    timer.Start(dueAt - now)
end

local UNIT_TRIGGERS = { "UNIT_AURA", "UNIT_STATS", "UNIT_INVENTORY_CHANGED" }
local TRIGGERS = {
    "PLAYER_EQUIPMENT_CHANGED", "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE", "GLYPH_ADDED", "GLYPH_REMOVED",
    "GLYPH_UPDATED", "PLAYER_LEVEL_UP", "UPDATE_SHAPESHIFT_FORM", "SPELLS_CHANGED", "SKILL_LINES_CHANGED",
}

local function Listen(on)
    if on == listening then return end
    listening = on
    for _, event in ipairs(UNIT_TRIGGERS) do
        if on then
            ns.RegisterUnit(frame, event, "player")
        else
            frame:UnregisterEvent(event)
        end
    end
    for _, event in ipairs(TRIGGERS) do
        if on then
            frame:RegisterEvent(event)
        else
            frame:UnregisterEvent(event)
        end
    end
end

function frame:PLAYER_ENTERING_WORLD()
    Listen(not InCombat())
    Touch(SETTLE)
end

function frame:PLAYER_REGEN_DISABLED()
    timer.Stop()
    firstAt = 0
    Listen(false)
end

function frame:PLAYER_REGEN_ENABLED()
    Listen(true)
    Touch(QUIET)
end

function frame:PLAYER_EQUIPMENT_CHANGED()
    Touch(SETTLE)
end

frame.CHARACTER_POINTS_CHANGED = frame.PLAYER_EQUIPMENT_CHANGED
frame.PLAYER_TALENT_UPDATE = frame.PLAYER_EQUIPMENT_CHANGED
frame.PLAYER_TALENT_UPDATE_EX = frame.PLAYER_EQUIPMENT_CHANGED
frame.PLAYER_TALENT_ACTIVE_GROUP_CHANGED = frame.PLAYER_EQUIPMENT_CHANGED
frame.GLYPH_ADDED = frame.PLAYER_EQUIPMENT_CHANGED
frame.GLYPH_REMOVED = frame.PLAYER_EQUIPMENT_CHANGED
frame.GLYPH_UPDATED = frame.PLAYER_EQUIPMENT_CHANGED
frame.PLAYER_LEVEL_UP = frame.PLAYER_EQUIPMENT_CHANGED

function frame:UNIT_AURA(unit)
    if unit == "player" then
        Touch(QUIET)
    end
end

frame.UNIT_STATS = frame.UNIT_AURA

function frame:UNIT_INVENTORY_CHANGED(unit)
    if unit ~= "player" then return end
    if enchantHeld then
        local main, _, _, off = GetWeaponEnchantInfo()
        if not (enchantHeld == MAIN and main or enchantHeld == OFF and off) then
            enchantHeld, enchantGone = false, "inv"
        end
    end
    Touch(QUIET)
end

function frame:UPDATE_SHAPESHIFT_FORM()
    Touch(QUIET)
end

function frame:SPELLS_CHANGED()
    bookStale = true
end

frame.SKILL_LINES_CHANGED = frame.SPELLS_CHANGED

frame:SetScript("OnEvent", function(self, event, ...)
    local talent = TALENT_EVENT[event]
    if talent then
        talentSeen[talent] = talentSeen[talent] + 1
    end
    Run(event, self[event], self, ...)
end)

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
if frame.RegisterCustomEvent then
    pcall(frame.RegisterCustomEvent, frame, "PLAYER_TALENT_UPDATE_EX")
    pcall(frame.RegisterCustomEvent, frame, "PLAYER_TALENT_ACTIVE_GROUP_CHANGED")
end

function CleanStats.StateChanged()
    if not Busy() then
        if deferred then
            Touch(QUIET)
        end
    elseif deferred or timer.running then
        timer.Stop()
        deferred = true
        dueAt = max(GetTime() + QUIET, holdUntil)
    end
end

function CleanStats.Resume()
    if not deferred or InCombat() or Busy() then return end
    deferred = false
    local left = dueAt - GetTime()
    if left > 0 then
        timer.Start(left)
    else
        Run("clean", Take)
    end
end

function CleanStats.Probes(out)
    if lastWait then
        out[#out + 1] = ns.ProbeLine("clean.wait", lastWait)
    end
    if enchantGone then
        out[#out + 1] = ns.ProbeLine("clean.enchant", enchantGone)
    end
    local seen, any = {}, false
    for i, key in ipairs(TALENT_KEYS) do
        seen[i] = key .. ":" .. talentSeen[key]
        any = any or talentSeen[key] > 0
    end
    if any then
        out[#out + 1] = ns.ProbeLine("talent.events", concat(seen, ","))
    end
end
