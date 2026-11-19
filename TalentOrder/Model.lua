-- TalentOrder: this character's talent trees in the shape the planner needs (any class). Nothing here changes
-- anything in the game: it only asks.
--
-- How WoW Forever holds talents (seen in the game's own data through other addons that draw the vanilla window):
-- the active talent set has ONE trait tree; the class's three vanilla trees are that tree's "groups"; a talent is a
-- visible node with an entry; where it sits comes from its position; an arrow runs from a talent to the one it
-- unlocks. The vanilla rule "row N needs 5 x (N - 1) points in that tree" is applied by the game itself; the
-- planner applies the same rule from the row.
--
-- TalentOrder_Grid(points)  pure: points = { [id] = { x = n, y = n } }
--                           -> cells = { [id] = { col = n, row = n } } (from 0), columns, rows
-- TalentOrder_Model()       game calls -> model (the table Plan.lua works on, plus what the window draws) or nil, "why"
--   model = { class, config, treeID, unspent, spent, cap,
--             tabs = { { group, name, cols, rows, talents = { id, ... } }, ... },      in the game's order
--             groups = { [group] = name },
--             talents = { [id] = { id, name, icon, spell, group, max, rank (learned now), col, row,
--                                  points (needed in its tree), needs = { { id, rank } } } } }
local POINTS_PER_ROW = 5
local MOST_LINES = 12          -- a tree with more rows or columns than this was read wrong: lines are then just counted

local function plain(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end
local function number(v)
    v = plain(v)
    if type(v) == "number" then return v end
    return nil
end
local function text(v)
    v = plain(v)
    if type(v) == "string" and v ~= "" then return v end
    return nil
end
local function ask(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return plain(a) end
    return nil
end

-- One axis of a tree: a function that gives the line (0, 1, 2, ...) a position sits on.
-- The game's positions are not perfectly regular: some talents sit a few units off their line, and a few carry an
-- extra zero (ten times too far out). So the step between two lines is the smallest gap that is not tiny next to
-- the usual gap, and a position far beyond the rest whose tenth lands on the grid is read as that tenth.
-- sturdy = the second way to find the step, for a tree where MOST gaps are the tiny "few units off" kind (the usual
-- gap is then tiny too): the yardstick is the widest gap that is not a lone far-out position, and anything under
-- an eighth of it is the same line.
local function axis(list, sturdy)
    local sorted = {}
    for i, v in ipairs(list) do sorted[i] = v end
    table.sort(sorted)
    local gaps = {}
    for i = 2, #sorted do
        local d = sorted[i] - sorted[i - 1]
        if d > 0 then gaps[#gaps + 1] = d end
    end
    if #gaps == 0 then return function() return 0 end end
    table.sort(gaps)
    local floor
    if sturdy then
        local widest = #gaps
        while widest > 1 and gaps[widest] > 5 * gaps[widest - 1] do widest = widest - 1 end
        floor = gaps[widest] / 8
    else
        floor = gaps[math.floor(#gaps / 2) + 1] / 4
    end
    local step = gaps[#gaps]
    for _, d in ipairs(gaps) do
        if d > floor then step = d break end
    end
    local first, last = sorted[1], sorted[1]
    for i = 2, #sorted do
        if sorted[i] - sorted[i - 1] > 4 * step then break end
        last = sorted[i]
    end
    return function(v)
        if v > last + 4 * step then
            local tenth = v / 10
            local k = (tenth - first) / step
            if k > -0.25 and tenth <= last + step / 4 and math.abs(k - math.floor(k + 0.5)) < 0.25 then v = tenth end
        end
        return math.floor((v - first) / step + 0.5)
    end
end

-- lines that came out absurdly far apart are simply counted in their order: 0, 1, 2, ...
local function squeeze(cells, key)
    local seen, order = {}, {}
    for _, cell in pairs(cells) do
        if not seen[cell[key]] then
            seen[cell[key]] = true
            order[#order + 1] = cell[key]
        end
    end
    table.sort(order)
    local index = {}
    for i, v in ipairs(order) do index[v] = i - 1 end
    for _, cell in pairs(cells) do cell[key] = index[cell[key]] end
    return #order
end

-- the lines of one axis for every talent: the usual way first; when that gives more lines than a talent tree can
-- have, the sturdy way; when that fails too, the lines are simply counted
local function lines(points, key, cells, into)
    local values = {}
    for _, p in pairs(points) do values[#values + 1] = p[key] end
    local count
    for attempt = 1, 2 do
        local lineOf = axis(values, attempt == 2)
        count = 0
        for id, p in pairs(points) do
            local line = math.max(0, lineOf(p[key]))
            cells[id][into] = line
            count = math.max(count, line + 1)
        end
        if count <= MOST_LINES then return count end
    end
    return squeeze(cells, into)
end

function TalentOrder_Grid(points)
    local cells = {}
    for id in pairs(points) do cells[id] = {} end
    local cols = lines(points, "x", cells, "col")
    local rows = lines(points, "y", cells, "row")
    return cells, cols, rows
end

-- name, picture and spell of a talent (its active entry, else its first)
local function face(config, info)
    local entryID
    local active = plain(info.activeEntry)
    if type(active) == "table" then entryID = number(active.entryID) end
    if not entryID and type(info.entryIDs) == "table" then entryID = number(info.entryIDs[1]) end
    if not entryID then return nil end
    local entry = ask(C_Traits.GetEntryInfo, config, entryID)
    local def = type(entry) == "table" and ask(C_Traits.GetDefinitionInfo, entry.definitionID)
    if type(def) ~= "table" then return nil end
    local spell = number(def.spellID)
    local name = text(def.overrideName)
    if not name and spell then
        if C_Spell and C_Spell.GetSpellName then name = text(ask(C_Spell.GetSpellName, spell)) end
        if not name and GetSpellInfo then name = text(ask(GetSpellInfo, spell)) end
    end
    local icon = number(def.overrideIcon)
    if (not icon or icon == 0) and spell then
        if C_Spell and C_Spell.GetSpellTexture then icon = plain(ask(C_Spell.GetSpellTexture, spell)) end
        if not icon and GetSpellTexture then icon = plain(ask(GetSpellTexture, spell)) end
    end
    return name, icon, spell
end

function TalentOrder_Model()
    if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GetNodeInfo
        and C_Traits.GetTreeNodes and C_Traits.GetConfigInfo and C_Traits.GetGroupDisplayInfoByTreeID) then
        return nil, "this game does not offer the talent data the planner needs"
    end
    local config = number(ask(C_ClassTalents.GetActiveConfigID))
    if not config then return nil, "the game gave no talent data yet (too early after login?)" end
    local cfg = ask(C_Traits.GetConfigInfo, config)
    local treeID = type(cfg) == "table" and type(cfg.treeIDs) == "table" and number(cfg.treeIDs[1])
    if not treeID then return nil, "the game named no talent tree for this character" end
    local shown = ask(C_Traits.GetGroupDisplayInfoByTreeID, treeID)
    if type(shown) ~= "table" then return nil, "the game listed no talent trees" end

    local model = { config = config, treeID = treeID, tabs = {}, groups = {}, talents = {} }
    local _, class = UnitClass("player")
    model.class = text(class)
    if not model.class then return nil, "the game did not say which class this character is" end

    local list = {}
    for _, g in ipairs(shown) do
        if type(g) == "table" and plain(g.groupID) ~= nil then
            list[#list + 1] = { group = g.groupID, name = text(g.displayName), order = number(g.orderIndex) or (#list + 1) }
        end
    end
    table.sort(list, function(a, b) return a.order < b.order end)
    if #list == 0 then return nil, "the game listed no talent trees" end
    local byGroup = {}
    for i, g in ipairs(list) do
        local tab = { group = g.group, name = g.name or ("Tree " .. i), talents = {}, cols = 0, rows = 0 }
        model.tabs[i] = tab
        model.groups[g.group] = tab.name
        byGroup[g.group] = tab
    end

    local nodes = ask(C_Traits.GetTreeNodes, treeID)
    if type(nodes) ~= "table" then return nil, "the game listed no talents" end
    local targets = {}
    for _, nodeID in ipairs(nodes) do
        local info = ask(C_Traits.GetNodeInfo, config, nodeID)
        if type(info) == "table" and plain(info.isVisible) == true and type(info.entryIDs) == "table" and info.entryIDs[1] then
            local tab
            if type(info.groupIDs) == "table" then
                for _, groupID in ipairs(info.groupIDs) do
                    tab = byGroup[plain(groupID)]
                    if tab then break end
                end
            end
            if tab then
                local name, icon, spell = face(config, info)
                model.talents[nodeID] = {
                    id = nodeID, name = name or ("Talent " .. tostring(nodeID)), icon = icon, spell = spell,
                    group = tab.group, max = number(info.maxRanks) or 1, rank = number(info.activeRank) or 0,
                    x = number(info.posX) or 0, y = number(info.posY) or 0,
                    choice = #info.entryIDs > 1 or nil,
                }
                tab.talents[#tab.talents + 1] = nodeID
                local edges = {}
                if type(info.visibleEdges) == "table" then
                    for _, edge in ipairs(info.visibleEdges) do
                        local target = type(edge) == "table" and plain(edge.targetNode)
                        if target ~= nil then edges[#edges + 1] = target end
                    end
                end
                targets[nodeID] = edges
            end
        end
    end

    local count = 0
    for _, tab in ipairs(model.tabs) do
        local points = {}
        for _, id in ipairs(tab.talents) do
            local t = model.talents[id]
            points[id] = { x = t.x, y = t.y }
            count = count + 1
        end
        local cells, cols, rows = TalentOrder_Grid(points)
        tab.cols, tab.rows = cols, rows
        for id, cell in pairs(cells) do
            local t = model.talents[id]
            t.col, t.row = cell.col, cell.row
            t.points = POINTS_PER_ROW * cell.row
        end
    end
    if count == 0 then return nil, "the game showed no talents for this character" end

    -- an arrow from A to B: B needs A full
    for id, edges in pairs(targets) do
        local from = model.talents[id]
        for _, target in ipairs(edges) do
            local to = model.talents[target]
            if to and to ~= from then
                to.needs = to.needs or {}
                to.needs[#to.needs + 1] = { id = id, rank = from.max }
            end
        end
    end

    -- how many points a plan may hold: those the character has, plus one for every level still to come
    local money = C_Traits.GetTreeCurrencyInfo and ask(C_Traits.GetTreeCurrencyInfo, config, treeID, false)
    local first = type(money) == "table" and money[1]
    local unspent = type(first) == "table" and number(first.quantity)
    local spent = type(first) == "table" and number(first.spent)
    local level = number(UnitLevel("player"))
    model.unspent, model.spent = unspent, spent
    if unspent and spent and level then
        model.cap = math.max(51, unspent + spent + math.max(0, 60 - level))
    else
        model.cap = 61
    end
    return model
end
