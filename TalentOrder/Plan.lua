-- TalentOrder: the rules of a talent plan. Pure logic, no game calls (tested by addon/tests/test_plan.lua).
--
-- A plan is the ORDER in which talent points get spent: a list of talent ids, one entry per point.
-- The rules are the game's own:
--   * a talent takes at most `max` points,
--   * a talent opens once `points` points are spent in its own tree (`group`),
--   * a talent can ask for another talent at a certain rank first (`needs`),
--   * no more points than can ever be earned (`cap`).
--
-- model = {
--   talents = { [id] = { id, name, group, max, points = <points needed in its tree, 0 = none>,
--                        needs = { { id = <other talent>, rank = <points it must hold> }, ... } } },
--   groups  = { [group] = <name shown to the player> },      (optional, for the wording)
--   cap     = <how many points a plan may hold>              (optional)
-- }
--
-- TalentOrder_PlanState(model, order, upTo) -> { ranks = { [id] = n }, spent = { [group] = n }, total = n }
-- TalentOrder_PlanCanAdd(model, order, id)  -> true   |   false, "why not" (plain words)
-- TalentOrder_PlanCheck(model, order, from) -> nil when every pick was allowed at its turn   |   index, "why not"
-- TalentOrder_PlanRemove(model, order, id, from) -> the new order (the LAST point of that talent taken away)
--                                              |   nil, "why not" (a later pick needs it)
--   from (optional): the first pick that is checked / may be taken away. The picks before it are points the
--   character has already learned in the game: they are counted as they are and cannot be taken back here.
-- TalentOrder_PlanSteps(model, order)       -> { { id, name, max }, ... } for the spender (Picker.lua)

local function groupName(model, group)
    local names = model.groups
    local name = names and names[group]
    if type(name) == "string" and name ~= "" then return name end
    return "that tree"
end

-- ranks and points per tree after the first `upTo` picks (all of them when left out). Picks of talents the model
-- does not know are counted in `total` only.
function TalentOrder_PlanState(model, order, upTo)
    local state = { ranks = {}, spent = {}, total = 0 }
    local last = math.min(upTo or #order, #order)
    for i = 1, last do
        local id = order[i]
        local talent = model.talents[id]
        state.total = state.total + 1
        if talent then
            state.ranks[id] = (state.ranks[id] or 0) + 1
            if talent.group ~= nil then
                state.spent[talent.group] = (state.spent[talent.group] or 0) + 1
            end
        end
    end
    return state
end

-- may one more point go into this talent, with the picks counted in `state` already made?
local function allowed(model, state, id)
    local talent = model.talents[id]
    if not talent then return false, "the game does not know this talent" end
    local name = talent.name or "this talent"
    local have = state.ranks[id] or 0
    local max = talent.max or 1
    if have >= max then return false, name .. " is full (" .. have .. "/" .. max .. ")" end
    if model.cap and state.total >= model.cap then
        return false, "all " .. model.cap .. " points are planned"
    end
    local need = talent.points or 0
    if need > 0 then
        local spent = talent.group ~= nil and state.spent[talent.group] or 0
        if spent < need then
            return false, name .. " needs " .. need .. " points in " .. groupName(model, talent.group)
                .. " first (" .. spent .. " so far)"
        end
    end
    for _, want in ipairs(talent.needs or {}) do
        local other = model.talents[want.id]
        local rank = want.rank or (other and other.max) or 1
        local got = state.ranks[want.id] or 0
        if got < rank then
            return false, name .. " needs " .. (other and other.name or "another talent") .. " at " .. rank .. "/"
                .. (other and other.max or rank) .. " first (" .. got .. " so far)"
        end
    end
    return true
end

function TalentOrder_PlanCanAdd(model, order, id)
    return allowed(model, TalentOrder_PlanState(model, order), id)
end

function TalentOrder_PlanCheck(model, order, from)
    local state = { ranks = {}, spent = {}, total = 0 }
    from = from or 1
    for i = 1, #order do
        local id = order[i]
        if i >= from then
            local ok, why = allowed(model, state, id)
            if not ok then return i, why end
        end
        local talent = model.talents[id]
        state.total = state.total + 1
        if talent then
            state.ranks[id] = (state.ranks[id] or 0) + 1
            if talent.group ~= nil then state.spent[talent.group] = (state.spent[talent.group] or 0) + 1 end
        end
    end
    return nil
end

function TalentOrder_PlanRemove(model, order, id, from)
    local at
    for i = #order, 1, -1 do
        if order[i] == id then at = i break end
    end
    local talent = model.talents[id]
    local name = talent and talent.name or "this talent"
    if not at then return nil, "no point planned in " .. name end
    if from and at < from then return nil, name .. ": that point is already learned in the game" end
    local out = {}
    for i = 1, #order do
        if i ~= at then out[#out + 1] = order[i] end
    end
    local bad, why = TalentOrder_PlanCheck(model, out, from)
    if bad then
        local later = model.talents[out[bad]]
        return nil, "a later pick still needs that point: " .. (later and later.name or "a talent") .. " (" .. tostring(why) .. ")"
    end
    return out
end

function TalentOrder_PlanSteps(model, order)
    local steps = {}
    for i = 1, #order do
        local talent = model.talents[order[i]]
        steps[i] = { id = order[i], name = talent and talent.name or ("talent " .. tostring(order[i])), max = talent and talent.max or nil }
    end
    return steps
end
