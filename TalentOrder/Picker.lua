-- Pure logic, no game calls (tested outside the game by addon/tests/test_picker.lua).
--
-- TalentOrder_NextPick(order, rankOf)
--   order  : list of steps { id = nodeId, name = ..., max = maxRank }, one step = one talent point.
--   rankOf : function(id) -> points already in that talent (number), or nil when the talent is unknown.
-- Returns: index, step  of the first step whose point is not spent yet
--          nil, "done"              when every step is satisfied
--          nil, "unknown", step     when the game does not know a talent of the list (never guess past it)
--
-- It walks the list from the top and counts how many points each talent should have by then. Levels are never
-- looked at, so talent points that arrive early (legacy points) or were spent by hand are handled the same way:
-- the next pick is always the first point of the list that is still missing.
function TalentOrder_NextPick(order, rankOf)
    local need = {}
    for index = 1, #order do
        local step = order[index]
        local id = step.id
        local want = (need[id] or 0) + 1
        need[id] = want
        local have = rankOf(id)
        if have == nil then
            return nil, "unknown", step
        end
        local cap = step.max
        if cap and want > cap then want = cap end
        if have < want then
            return index, step
        end
    end
    return nil, "done"
end
