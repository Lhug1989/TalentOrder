-- TalentOrder: reads the talent trees the game gives THIS character (any class) into plain tables.
-- Nothing here changes anything in the game: it only asks. Every call is guarded, a hidden ("secret") value
-- becomes the text "?", so the result can always be stored in the saved file.
--
-- TalentOrder_ReadTree() -> {
--   time, class, level, config, cfg = <GetConfigInfo>,
--   trees = { { id, info = <GetTreeInfo>, currencies = <GetTreeCurrencyInfo>, conditions = { <GetConditionInfo>... },
--               nodes = { { <GetNodeInfo fields>, entries = { { id, name, icon, def = <GetDefinitionInfo> } }, cost } } } },
--   classic = { has = { which old-style talent calls exist }, tabs = { { info = "a|b|c", talents = { { info, prereqs } } } } }
-- }
local MAX_DEPTH = 4

local function plain(v)
    if issecretvalue and issecretvalue(v) then return "?" end
    local kind = type(v)
    if kind == "number" or kind == "string" or kind == "boolean" then return v end
    return nil
end

-- a copy of a game answer with only numbers, texts, yes/no and tables of those in it
local function copy(v, depth)
    if issecretvalue and issecretvalue(v) then return "?" end
    if type(v) ~= "table" then return plain(v) end
    if (depth or 0) <= 0 then return nil end
    local out = {}
    for k, item in pairs(v) do
        if type(k) == "number" or type(k) == "string" then out[k] = copy(item, depth - 1) end
    end
    return out
end

-- one answer of a game call, nil when the call is missing or fails
local function one(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end

-- every answer of a game call as one text "a|b|c" ("-" = the call is missing, "!" = it failed)
local function row(fn, ...)
    if type(fn) ~= "function" then return "-" end
    local function pack(...) return select("#", ...), { ... } end
    local n, r = pack(pcall(fn, ...))
    if not r[1] then return "!" end
    local parts = {}
    for i = 2, n do
        local v = r[i]
        if issecretvalue and issecretvalue(v) then parts[#parts + 1] = "?" else parts[#parts + 1] = tostring(v) end
    end
    return table.concat(parts, "|")
end

local function spellName(id)
    if type(id) ~= "number" then return nil end
    local name
    if C_Spell and C_Spell.GetSpellName then name = one(C_Spell.GetSpellName, id) end
    if name == nil and GetSpellInfo then name = one(GetSpellInfo, id) end
    return plain(name)
end

local function spellIcon(id)
    if type(id) ~= "number" then return nil end
    local icon
    if C_Spell and C_Spell.GetSpellTexture then icon = one(C_Spell.GetSpellTexture, id) end
    if icon == nil and GetSpellTexture then icon = one(GetSpellTexture, id) end
    return plain(icon)
end

-- the old-style talent calls (tabs, rows and columns), when this game still has them
local function classic()
    local out = { has = {}, tabs = {} }
    for _, name in ipairs({ "GetNumTalentTabs", "GetNumTalents", "GetTalentInfo", "GetTalentPrereqs", "GetTalentTabInfo",
        "LearnTalent", "UnitCharacterPoints", "GetUnspentTalentPoints", "GetNumTalentGroups", "GetActiveTalentGroup" }) do
        out.has[name] = type(_G[name]) == "function"
    end
    out.points = row(_G.UnitCharacterPoints, "player")
    local tabs = one(_G.GetNumTalentTabs)
    if type(tabs) ~= "number" then return out end
    for t = 1, math.min(tabs, 6) do
        local tab = { info = row(_G.GetTalentTabInfo, t), talents = {} }
        local count = one(_G.GetNumTalents, t)
        if type(count) == "number" then
            for i = 1, math.min(count, 60) do
                tab.talents[i] = { info = row(_G.GetTalentInfo, t, i), prereqs = row(_G.GetTalentPrereqs, t, i) }
            end
        end
        out.tabs[t] = tab
    end
    return out
end

local function readNode(config, nodeID, conditions)
    local info = one(C_Traits.GetNodeInfo, config, nodeID)
    if type(info) ~= "table" or (issecretvalue and issecretvalue(info)) then return nil end
    local node = copy(info, MAX_DEPTH) or {}
    node.ID = node.ID or nodeID
    node.entries = {}
    if type(info.entryIDs) == "table" then
        for _, entryID in ipairs(info.entryIDs) do
            local entry = one(C_Traits.GetEntryInfo, config, entryID)
            local line = type(entry) == "table" and copy(entry, 2) or {}
            line.id = plain(entryID)
            local def = type(entry) == "table" and one(C_Traits.GetDefinitionInfo, entry.definitionID)
            if type(def) == "table" then
                line.def = copy(def, 2)
                local over = plain(def.overrideName)
                line.name = (type(over) == "string" and over ~= "") and over or spellName(def.spellID)
                line.icon = plain(def.overrideIcon) or spellIcon(def.spellID)
            end
            node.entries[#node.entries + 1] = line
        end
    end
    node.cost = copy(one(C_Traits.GetNodeCost, config, nodeID), 3)
    if type(info.conditionIDs) == "table" then
        for _, id in ipairs(info.conditionIDs) do
            if type(id) == "number" then conditions[id] = true end
        end
    end
    return node
end

function TalentOrder_ReadTree()
    local out = { time = date and date("%d %b %H:%M:%S") or "", trees = {} }
    out.class = plain(select(2, UnitClass("player")))
    out.level = plain(UnitLevel("player"))
    local okClassic, old = pcall(classic)
    out.classic = okClassic and old or { failed = tostring(old) }
    if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GetNodeInfo) then
        out.noTraits = true
        return out
    end
    local config = one(C_ClassTalents.GetActiveConfigID)
    out.config = plain(config)
    if type(config) ~= "number" then return out end
    local cfg = one(C_Traits.GetConfigInfo, config)
    out.cfg = copy(cfg, 3)
    local treeIDs = type(cfg) == "table" and type(cfg.treeIDs) == "table" and cfg.treeIDs or {}
    for _, treeID in ipairs(treeIDs) do
        local tree = { id = plain(treeID), nodes = {}, conditions = {} }
        local info = one(C_Traits.GetTreeInfo, config, treeID)
        tree.info = copy(info, MAX_DEPTH)
        tree.currencies = copy(one(C_Traits.GetTreeCurrencyInfo, config, treeID, false), 3)
        local wanted = {}
        if type(info) == "table" and type(info.gates) == "table" then
            for _, gate in ipairs(info.gates) do
                if type(gate) == "table" and type(gate.conditionID) == "number" then wanted[gate.conditionID] = true end
            end
        end
        local nodeIDs = one(C_Traits.GetTreeNodes, treeID)
        if type(nodeIDs) == "table" then
            for _, nodeID in ipairs(nodeIDs) do
                local node = readNode(config, nodeID, wanted)
                if node then tree.nodes[#tree.nodes + 1] = node end
            end
        end
        for id in pairs(wanted) do
            local cond = copy(one(C_Traits.GetConditionInfo, config, id), 2) or {}
            cond.id = id
            tree.conditions[#tree.conditions + 1] = cond
        end
        out.trees[#out.trees + 1] = tree
    end
    return out
end
