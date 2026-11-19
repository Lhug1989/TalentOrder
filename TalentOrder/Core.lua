-- TalentOrder: spends talent points in the order of Order.lua (rogue only).
--   /to          status: next pick, mode
--   /to plan     the planner window: click the talents in the order you want them (any class)
--   /to on       really spend points (default is PREVIEW: nothing is spent, it only says what it would pick)
--   /to off      back to preview
--   /to probe    write what the game reports into the saved file (read from outside after /reload)
-- Goes by ORDER, never by level. Never acts in combat. Stops (does not skip) when the game refuses a pick.
-- Running out of points is not a refusal: the picks staged so far are saved and it waits for the next point.
local ADDON = "TalentOrder"
local DEFAULT = TalentOrder_ORDER      -- the built-in rogue order: used by a rogue who has made no plan of their own
local NextPick = TalentOrder_NextPick

local MAX_BUYS = 60          -- hard limit of points staged in one run
local MAX_FAILS = 3          -- failed runs in a row before it stops trying until /to on or a reload
local COMMIT_TIMEOUT = 15    -- seconds to wait for the game to confirm a commit
local LOG_KEEP = 60

local db
local fails, waiting, queued, stopped = 0, false, false, false

local function say(text)
    print("|cffffd100TalentOrder|r: " .. text)
end

local function note(text)
    if not db then return end
    local log = db.log
    log[#log + 1] = date("%d %b %H:%M:%S ") .. text
    while #log > LOG_KEEP do table.remove(log, 1) end
end

local function hasApi()
    return C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits and C_Traits.GetNodeInfo
        and C_Traits.PurchaseRank and true or false
end

local function configId()
    return hasApi() and C_ClassTalents.GetActiveConfigID() or nil
end

local function nodeInfo(config, id)
    local ok, info = pcall(C_Traits.GetNodeInfo, config, id)
    if ok and type(info) == "table" and info.ID and info.ID ~= 0 then return info end
    return nil
end

-- Points in a talent, counting points staged in this run (currentRank) so a run can buy several in a row.
local function rankReader(config)
    return function(id)
        local info = nodeInfo(config, id)
        if not info then return nil end
        return info.currentRank or info.ranksPurchased or info.activeRank or 0
    end
end

-- Name of one entry of a node (a spot with a choice between two talents has two entries), nil when it cannot be told.
local function entryName(config, entry)
    if not entry or not C_Traits.GetEntryInfo then return nil end
    local ok, e = pcall(C_Traits.GetEntryInfo, config, entry)
    if not ok or type(e) ~= "table" or not e.definitionID or not C_Traits.GetDefinitionInfo then return nil end
    local ok2, def = pcall(C_Traits.GetDefinitionInfo, e.definitionID)
    if not ok2 or type(def) ~= "table" then return nil end
    if def.overrideName and def.overrideName ~= "" then return def.overrideName end
    local spell = def.spellID
    if not spell then return nil end
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(spell) end
    if GetSpellInfo then return (GetSpellInfo(spell)) end
    return nil
end

-- Name the game gives a node (nil when it cannot be told). Used to refuse a pick whose id points elsewhere.
local function nodeName(config, id)
    local info = nodeInfo(config, id)
    local entry = info and (info.activeEntry and info.activeEntry.entryID or (info.entryIDs and info.entryIDs[1]))
    return entryName(config, entry)
end

local function playerClass()
    local _, class = UnitClass("player")
    return class
end

-- The player's own plan (made in the planner window, /to plan; saved per character) as steps { id, name, max },
-- or nil when there is none for this class or the saved one is damaged. A plan the player emptied is still their
-- plan (no steps): nothing is spent then.
local function planSteps()
    local plan = db and db.plan
    if type(plan) ~= "table" or plan.class ~= playerClass() or type(plan.steps) ~= "table" then return nil end
    for _, step in ipairs(plan.steps) do
        if type(step) ~= "table" or type(step.id) ~= "number" or type(step.name) ~= "string" then return nil end
    end
    return plan.steps
end

-- The steps to spend, in order, and what they are: the player's own plan; else the built-in order for a rogue;
-- else nil (any other class without a plan: nothing is spent).
local function currentOrder()
    local own = planSteps()
    if own then return own, "your plan" end
    if playerClass() == "ROGUE" and type(DEFAULT) == "table" then return DEFAULT, "the built-in rogue order" end
    return nil
end

local function staged(config)
    if not C_Traits.ConfigHasStagedChanges then return false end
    local ok, result = pcall(C_Traits.ConfigHasStagedChanges, config)
    return ok and result == true
end

-- Unspent talent points, counting what this run has staged; nil when the game does not tell. Needed because the
-- game says "can" for the talent whose turn it is even when no point is left (seen in game 19 Nov).
local function pointsLeft(config)
    if not (C_Traits.GetConfigInfo and C_Traits.GetTreeCurrencyInfo) then return nil end
    local ok, cfg = pcall(C_Traits.GetConfigInfo, config)
    local tree = ok and type(cfg) == "table" and type(cfg.treeIDs) == "table" and cfg.treeIDs[1]
    if not tree then return nil end
    local ok2, list = pcall(C_Traits.GetTreeCurrencyInfo, config, tree, false)
    if not ok2 or type(list) ~= "table" then return nil end
    local total, any = 0, false
    for _, c in ipairs(list) do
        if type(c) == "table" and type(c.quantity) == "number" then
            total, any = total + c.quantity, true
        end
    end
    return any and total or nil
end

-- Only an explicit `true` from the game counts as "save started"; which call worked goes into the log.
local function commit(config)
    if C_ClassTalents.CommitConfig then
        local ok, result = pcall(C_ClassTalents.CommitConfig, nil)
        if ok and result == true then return "C_ClassTalents.CommitConfig" end
    end
    if C_Traits.CommitConfig and staged(config) then
        local ok, result = pcall(C_Traits.CommitConfig, config)
        if ok and result == true then return "C_Traits.CommitConfig" end
    end
    return nil
end

local function rollback(config)
    if C_Traits.RollbackConfig then pcall(C_Traits.RollbackConfig, config) end
end

local function failed(why)
    fails = fails + 1
    note("FAILED: " .. why .. " (" .. fails .. "/" .. MAX_FAILS .. ")")
    if fails >= MAX_FAILS then
        stopped = true
        say(why .. ". Stopped trying; /to on tries again.")
    end
end

-- One run: stage every pick the game allows, in order, then commit once.
local function run(reason)
    queued = false
    if not db or stopped or waiting then return end
    -- while the planner window is open the plan is still being made: nothing is spent until it is closed
    if TalentOrder_PlannerShown and TalentOrder_PlannerShown() then return end
    if InCombatLockdown() or UnitIsDeadOrGhost("player") then return end   -- PLAYER_REGEN_ENABLED / next event retries
    local ORDER = currentOrder()
    if not ORDER then return end
    local config = configId()
    if not config then return end
    local rankOf = rankReader(config)

    -- Points somebody else staged (the talent window, the bot, another addon) are never ours to save or undo.
    if db.enabled and staged(config) then
        if db.lastIdle ~= "foreign" then
            db.lastIdle = "foreign"
            note("talent changes staged by something else: waiting, nothing touched")
        end
        return
    end

    if not db.enabled then
        local index, step, bad = NextPick(ORDER, rankOf)
        local line
        if index then
            local info = nodeInfo(config, step.id)
            local can = info and info.canPurchaseRank and pointsLeft(config) ~= 0
            line = "preview, next pick #" .. index .. " " .. step.name
                .. (can and " (a point is available)" or " (no point available now)")
        elseif step == "unknown" then
            line = "preview, the game does not know talent " .. bad.name .. " (id " .. bad.id .. ")"
        else
            line = "preview, the whole order is spent"
        end
        if line ~= db.lastPreview then
            db.lastPreview = line
            note(line .. " [" .. reason .. "]")
        end
        return
    end

    local bought = {}
    for _ = 1, MAX_BUYS do
        local index, step, bad = NextPick(ORDER, rankOf)
        if not index then
            if step == "unknown" then
                if #bought > 0 then rollback(config) end
                failed("the game does not know talent " .. bad.name .. " (id " .. bad.id .. ")")
                return
            end
            break
        end
        local info = nodeInfo(config, step.id)
        local left = pointsLeft(config)
        if left == 0 or not info or not info.canPurchaseRank then          -- no point left, or not allowed yet
            if #bought == 0 then
                local idle = "next is #" .. index .. " " .. step.name .. ": "
                    .. (left == 0 and "no talent point to spend" or "the game allows no pick now")
                if db.lastIdle ~= idle then
                    db.lastIdle = idle
                    note(idle)
                end
            end
            break
        end
        local name = nodeName(config, step.id)
        if name and name ~= step.name then
            if #bought > 0 then rollback(config) end
            failed("talent id " .. step.id .. " is \"" .. name .. "\" in the game, the list says \"" .. step.name .. "\"")
            return
        end
        local before = rankOf(step.id) or 0
        local ok, result = pcall(C_Traits.PurchaseRank, config, step.id)
        local after = rankOf(step.id) or 0
        if not ok or result == false or after <= before then
            -- In game 19 Nov: 12 picks staged, the 13th refused (no point left, yet the game said "can"), all 12 thrown
            -- away, three times, then stopped. So a plain refusal (the rank did not move) after at least one pick of
            -- this run means the points ran out: what is staged is kept and saved. A refusal of the very first
            -- pick, one where the rank moved anyway, or a Lua error from the call stays a failure.
            if ok and after <= before and #bought > 0 then
                note("points ran out at #" .. index .. " " .. step.name .. " after " .. #bought .. " picks")
                break
            end
            -- The first pick refused while the game does not tell how many points are left: taken as "none left"
            -- (a wait, not a failure), or it would stop itself between two levels and miss the next point.
            if ok and after <= before and left == nil and not staged(config) then
                local idle = "next is #" .. index .. " " .. step.name .. ": refused, cannot tell if a point is left"
                if db.lastIdle ~= idle then
                    db.lastIdle = idle
                    note(idle)
                end
                break
            end
            if #bought > 0 or staged(config) then rollback(config) end
            failed("the game refused " .. step.name .. " (pick #" .. index .. ")" .. (ok and "" or (": " .. tostring(result))))
            return
        end
        bought[#bought + 1] = step.name
    end
    if #bought == 0 then return end
    db.lastIdle = nil

    local list = table.concat(bought, ", ")
    local token = {}
    waiting = token                                 -- set BEFORE the save: the game may answer during the call
    db.pendingList = list
    local how = commit(config)
    if not how then
        if waiting == token then waiting = false end
        db.pendingList = nil
        rollback(config)
        failed("the game refused to save: " .. list)
        return
    end
    note("staged + save sent (" .. how .. "): " .. list .. " [" .. reason .. "]")
    C_Timer.After(COMMIT_TIMEOUT, function()
        if waiting ~= token then return end
        waiting = false
        db.pendingList = nil
        local c = configId()
        if c and staged(c) then rollback(c) end
        failed("no answer from the game after saving: " .. list)
    end)
end

local function queue(reason, delay)
    if queued then return end
    queued = true
    C_Timer.After(delay or 2, function() run(reason) end)
end

local function probe()
    local ORDER = currentOrder() or {}
    local p = { time = date("%d %b %H:%M:%S"), level = UnitLevel("player"), class = select(2, UnitClass("player")),
        api = { C_ClassTalents = C_ClassTalents ~= nil, C_Traits = C_Traits ~= nil,
            PurchaseRank = C_Traits ~= nil and C_Traits.PurchaseRank ~= nil,
            ClassCommit = C_ClassTalents ~= nil and C_ClassTalents.CommitConfig ~= nil,
            TraitsCommit = C_Traits ~= nil and C_Traits.CommitConfig ~= nil,
            LearnTalent = LearnTalent ~= nil },
        nodes = {}, currencies = {} }
    local config = configId()
    p.config = config
    if config then
        local seen = {}
        for _, step in ipairs(ORDER) do
            if not seen[step.id] then
                seen[step.id] = true
                local info = nodeInfo(config, step.id)
                -- every entry of the node with its name: two or more = a spot where one of several talents is chosen
                local entries = {}
                for _, e in ipairs(info and type(info.entryIDs) == "table" and info.entryIDs or {}) do
                    local ok, name = pcall(entryName, config, e)
                    entries[#entries + 1] = tostring(e) .. " " .. tostring(ok and name or "?")
                end
                p.nodes[#p.nodes + 1] = { id = step.id, list = step.name, game = nodeName(config, step.id) or "?",
                    found = info ~= nil, rank = info and info.currentRank or -1, max = info and info.maxRanks or -1,
                    can = info and info.canPurchaseRank or false, type = info and info.type or -1,
                    entries = table.concat(entries, " | "),
                    active = info and type(info.activeEntry) == "table" and info.activeEntry.entryID or -1 }
            end
        end
        local ok, cfg = pcall(C_Traits.GetConfigInfo, config)
        local tree = ok and type(cfg) == "table" and cfg.treeIDs and cfg.treeIDs[1]
        p.tree = tree
        if tree and C_Traits.GetTreeCurrencyInfo then
            local ok2, cur = pcall(C_Traits.GetTreeCurrencyInfo, config, tree, false)
            if ok2 and type(cur) == "table" then
                for _, c in ipairs(cur) do
                    p.currencies[#p.currencies + 1] = { id = c.traitCurrencyID, quantity = c.quantity, spent = c.spent }
                end
            end
        end
        local index, step = NextPick(ORDER, rankReader(config))
        p.next = index and (index .. " " .. step.name) or tostring(step)
    end
    db.probe = p
    -- the whole talent tree as the game gives it (any class): read from outside after a /reload
    if TalentOrder_ReadTree then
        local ok, tree = pcall(TalentOrder_ReadTree)
        db.tree = ok and tree or { failed = tostring(tree) }
    end
    return p
end

local function status()
    local config = configId()
    local ORDER, which = currentOrder()
    if not ORDER then say("no talent plan for this character yet. Type /to plan to make one.") return end
    if not config then say("the game gave no talent data yet.") return end
    if #ORDER == 0 then say("your talent plan has no points in it: nothing to spend. Type /to plan.") return end
    local index, step, bad = NextPick(ORDER, rankReader(config))
    local mode = db.enabled and (stopped and "ON but stopped after errors" or "ON (spends points)") or "PREVIEW (spends nothing)"
    local left = pointsLeft(config)
    if index then
        say(mode .. ", following " .. which .. ". Next pick: #" .. index .. " of " .. #ORDER .. ", " .. step.name .. "."
            .. (left and (" Points to spend: " .. left .. ".") or ""))
    elseif step == "unknown" then
        say(mode .. ". The game does not know " .. bad.name .. " (id " .. bad.id .. ").")
    else
        say(mode .. ", following " .. which .. ". Every point of it is spent.")
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        TalentOrderDB = TalentOrderDB or {}
        db = TalentOrderDB
        db.log = db.log or {}
        if db.enabled == nil then db.enabled = false end
        for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_UP", "PLAYER_REGEN_ENABLED", "PLAYER_ALIVE",
            "PLAYER_UNGHOST", "TRAIT_CONFIG_UPDATED", "TRAIT_TREE_CURRENCY_INFO_UPDATED", "CONFIG_COMMIT_FAILED" }) do
            pcall(frame.RegisterEvent, frame, e)
        end
        return
    end
    if not db then return end
    if event == "TRAIT_CONFIG_UPDATED" then
        local c = configId()
        if waiting and c and not staged(c) then     -- our save landed (nothing staged any more)
            waiting = false
            fails = 0
            note("saved: " .. tostring(db.pendingList))
            say("spent: " .. tostring(db.pendingList))
            db.pendingList = nil
        end
    elseif event == "CONFIG_COMMIT_FAILED" then
        if waiting then
            waiting = false
            local c = configId()
            if c then rollback(c) end
            failed("the game could not save: " .. tostring(db.pendingList))
            db.pendingList = nil
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(6, function() if db and hasApi() then pcall(probe) end end)     -- (any class: the tree is read too)
    end
    queue(event, event == "PLAYER_ENTERING_WORLD" and 8 or 2)
end)

-- The planner window calls this when it closes (nothing is spent while it is open). changed = the plan was
-- edited: start afresh with the new order; else just carry on as before.
function TalentOrder_PlanChanged(changed)
    if not db then return end
    if changed then
        fails, stopped = 0, false
        db.lastIdle, db.lastPreview = nil, nil
    end
    queue("plan", 2)
end
function TalentOrder_IsOn() return db ~= nil and db.enabled == true end
function TalentOrder_SetOn(on)
    if not db then return end
    db.enabled = on and true or false
    fails, stopped = 0, false
    db.lastPreview = nil
    note(on and "switched ON" or "switched to preview")
    if on then queue("/to on", 1) end
end

SLASH_TALENTORDER1 = "/to"
SLASH_TALENTORDER2 = "/talentorder"
SlashCmdList["TALENTORDER"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if not db then return end
    if msg == "on" then
        db.enabled = true
        fails, stopped = 0, false
        note("switched ON")
        say("ON: talent points are now spent in the listed order.")
        queue("/to on", 1)
    elseif msg == "off" then
        db.enabled = false
        db.lastPreview = nil
        note("switched to preview")
        say("PREVIEW: nothing is spent.")
    elseif msg == "plan" then
        if TalentOrder_ShowPlanner then TalentOrder_ShowPlanner() else say("the planner window did not load.") end
    elseif msg == "probe" then
        local p = probe()
        say("probe written (next: " .. tostring(p.next) .. "). /reload saves it to disk.")
    else
        status()
    end
end
