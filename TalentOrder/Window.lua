-- TalentOrder: the planner window (/to plan), for every class.
-- The window shows the character's own talent trees as the game gives them (Model.lua). A left click on a talent
-- plans the next point there, a right click takes the last point of that talent back. The ORDER of the clicks is
-- the plan; it is saved per character and it is what the spender (Core.lua) follows. The rules are the game's
-- (Plan.lua): points needed in the tree, talents that need another one full, the size of each talent.
--
-- Points the character has already learned always come first and cannot be taken back here. While the window is
-- open nothing is spent (the plan is still being made); closing it lets the spender carry on.
local P = {}                        -- state and actions; the tests drive these
TalentOrder_Planner = P
P.order = {}                        -- talent ids, one per point: the learned points first, then the planned ones
P.learned = 0                       -- how many picks at the start of the order are learned in the game already
P.message = ""                      -- why the last click did nothing (shown in red), or ""

local ICON, STEP, PAD, GAP = 30, 42, 14, 20
local LIST_W, LINES, LINE_H = 230, 24, 14
local TOP, BOTTOM = 60, 86
local TAG = "|cffffd100TalentOrder|r: "

local function saved()
    TalentOrderDB = TalentOrderDB or {}
    return TalentOrderDB
end

-- the talents in reading order: tree by tree, row by row, left to right
local function reading(model)
    local list = {}
    for _, tab in ipairs(model.tabs) do
        local ids = {}
        for _, id in ipairs(tab.talents) do ids[#ids + 1] = id end
        table.sort(ids, function(a, b)
            local x, y = model.talents[a], model.talents[b]
            if x.row ~= y.row then return x.row < y.row end
            if x.col ~= y.col then return x.col < y.col end
            return tostring(a) < tostring(b)
        end)
        for _, id in ipairs(ids) do list[#list + 1] = id end
    end
    return list
end

-- The learned points the plan does not hold (`held[id]` = how many of a talent's learned points it does hold), in
-- an order the rules allow where that is possible. A learned point the rules cannot place goes to the end: it is
-- learned all the same.
local function learnedOrder(model, held)
    local ids, left, order = reading(model), {}, {}
    for _, id in ipairs(ids) do
        local t = model.talents[id]
        local missing = math.min(t.rank, t.max) - (held and held[id] or 0)
        if missing > 0 then left[id] = missing end
    end
    local free = { talents = model.talents, groups = model.groups }       -- (no limit while placing what is learned)
    local moved = true
    while moved do
        moved = false
        for _, id in ipairs(ids) do
            while (left[id] or 0) > 0 and TalentOrder_PlanCanAdd(free, order, id) do
                order[#order + 1] = id
                left[id] = left[id] - 1
                moved = true
            end
        end
    end
    for _, id in ipairs(ids) do
        for _ = 1, left[id] or 0 do order[#order + 1] = id end
    end
    return order
end

-- The order to show. The k-th point of a talent is learned once the talent holds k points. First come the learned
-- points the plan does not hold (learned by hand), then the plan's own picks that are learned, IN THE PLAN'S ORDER
-- (so a talent reset is spent again the way the player planned it), then the plan's picks still to come. Picks of
-- talents the game no longer has are dropped; picks the rules no longer allow are cut from the first such pick on.
-- Returns order, learned, dropped, cut.
local function reconcile(model, plan)
    local dropped, cut = 0, 0
    local seen, held, mine, coming = {}, {}, {}, {}
    for _, id in ipairs(plan or {}) do
        local t = model.talents[id]
        if not t then
            dropped = dropped + 1
        else
            seen[id] = (seen[id] or 0) + 1
            if seen[id] <= math.min(t.rank, t.max) then
                mine[#mine + 1] = id
                held[id] = seen[id]
            else
                coming[#coming + 1] = id
            end
        end
    end
    local order = learnedOrder(model, held)
    for _, id in ipairs(mine) do order[#order + 1] = id end
    local learned = #order
    for _, id in ipairs(coming) do order[#order + 1] = id end
    local bad = TalentOrder_PlanCheck(model, order, learned + 1)
    if bad then
        cut = #order - bad + 1
        for i = #order, bad, -1 do order[i] = nil end
    end
    return order, learned, dropped, cut
end

local function planIds()
    local d = saved()
    local plan = d.plan
    if type(plan) ~= "table" or not P.model or plan.class ~= P.model.class or type(plan.steps) ~= "table" then return nil end
    local ids = {}
    for _, step in ipairs(plan.steps) do
        if type(step) == "table" and step.id ~= nil then ids[#ids + 1] = step.id end
    end
    return ids
end

-- After every change the plan is saved and the window drawn again. A plan the player has touched is THE order from
-- then on, even an empty one: an emptied plan spends nothing (a rogue does not fall back to the built-in order
-- behind the player's back; the "Built-in order" button brings that back as a plan).
local function commit()
    saved().plan = { class = P.model.class, steps = TalentOrder_PlanSteps(P.model, P.order) }
    P.dirty = true
    if P.Paint then P.Paint() end
end

-- does the spender have a plan of the player's for this class?
function P.HasPlan()
    local plan = saved().plan
    return type(plan) == "table" and P.model ~= nil and plan.class == P.model.class and type(plan.steps) == "table"
end

-- Reads the game's trees and the saved plan. true, or false and why.
function P.Load()
    local model, why = TalentOrder_Model()
    if not model then
        P.model = nil
        return false, why
    end
    P.model = model
    local ids = planIds()
    local dropped, cut
    P.order, P.learned, dropped, cut = reconcile(model, ids)
    P.message = ""
    if dropped + cut > 0 then
        P.message = (dropped + cut) .. " saved pick(s) no longer fit the game's talents and were left out"
    end
    return true
end

-- the game's talents changed while the window is open (a point learned by hand): keep the order, re-read the rest
function P.Refresh()
    local model = TalentOrder_Model()
    if not model then return false end
    P.model = model
    P.order, P.learned = reconcile(model, P.order)
    if P.Paint then P.Paint() end
    return true
end

function P.State()
    return TalentOrder_PlanState(P.model, P.order)
end

function P.Add(id)
    if not P.model then return false end
    local talent = P.model.talents[id]
    local ok, why = TalentOrder_PlanCanAdd(P.model, P.order, id)
    if ok and talent and talent.choice then
        -- a spot where one of two talents is chosen: the spender cannot make that choice and would stop there
        ok, why = false, talent.name .. " is a choice between two talents: pick it by hand in the game"
    end
    if not ok then
        P.message = why
        if P.Paint then P.Paint() end
        return false
    end
    P.order[#P.order + 1] = id
    P.message = ""
    commit()
    return true
end

function P.Take(id)
    if not P.model then return false end
    local out, why = TalentOrder_PlanRemove(P.model, P.order, id, P.learned + 1)
    if not out then
        P.message = why
        if P.Paint then P.Paint() end
        return false
    end
    P.order = out
    P.message = ""
    commit()
    return true
end

function P.Undo()
    if not P.model then return false end
    if #P.order <= P.learned then
        P.message = "nothing planned to take back"
        if P.Paint then P.Paint() end
        return false
    end
    P.order[#P.order] = nil
    P.message = ""
    commit()
    return true
end

function P.Clear()
    if not P.model then return false end
    for i = #P.order, P.learned + 1, -1 do P.order[i] = nil end
    P.message = ""
    commit()
    return true
end

-- a rogue can start from the built-in order (Order.lua) and change it from there
function P.UseBuiltIn()
    if not P.model or P.model.class ~= "ROGUE" or type(TalentOrder_ORDER) ~= "table" then return false end
    local ids = {}
    for _, step in ipairs(TalentOrder_ORDER) do ids[#ids + 1] = step.id end
    local dropped, cut
    P.order, P.learned, dropped, cut = reconcile(P.model, ids)
    P.message = (dropped + cut > 0) and ((dropped + cut) .. " pick(s) of the built-in order do not fit and were left out") or ""
    commit()
    return true
end

-- the order as lines for the list: { text, learned }
function P.Lines()
    local lines, count = {}, {}
    for i, id in ipairs(P.order) do
        local t = P.model.talents[id]
        count[id] = (count[id] or 0) + 1
        lines[i] = { text = i .. ". " .. (t and t.name or "?") .. " " .. count[id] .. "/" .. (t and t.max or "?"), learned = i <= P.learned }
    end
    return lines
end

-------------------------------------------------------------------------------------------------------------------
-- the window
-------------------------------------------------------------------------------------------------------------------
local win
local scroll = 0

local function tooltip(b)
    if not (GameTooltip and P.model and b.id) then return end
    local t = P.model.talents[b.id]
    if not t then return end
    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
    if t.spell and GameTooltip.SetSpellByID then GameTooltip:SetSpellByID(t.spell) else GameTooltip:SetText(t.name) end
    local have = P.State().ranks[b.id] or 0
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Planned: " .. have .. "/" .. t.max .. (t.rank > 0 and ("  (learned: " .. t.rank .. ")") or ""), 1, 0.82, 0)
    local ok, why = TalentOrder_PlanCanAdd(P.model, P.order, b.id)
    if ok then
        GameTooltip:AddLine("Click: plan the next point here", 0.1, 1, 0.1)
    else
        GameTooltip:AddLine(why, 1, 0.3, 0.3, true)
    end
    GameTooltip:AddLine("Right-click: take the last point back", 0.7, 0.7, 0.7)
    if t.choice then GameTooltip:AddLine("A choice between two talents: pick this one by hand in the game.", 1, 0.3, 0.3, true) end
    GameTooltip:Show()
end

local function newTalent(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(ICON, ICON)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.edge = b:CreateTexture(nil, "BACKGROUND")
    b.edge:SetPoint("TOPLEFT", -2, 2)
    b.edge:SetPoint("BOTTOMRIGHT", 2, -2)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.count = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.count:SetPoint("BOTTOMRIGHT", 4, -6)
    b:SetScript("OnClick", function(self, button)
        if button == "RightButton" then P.Take(self.id) else P.Add(self.id) end
        if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(self) then tooltip(self) end
    end)
    b:SetScript("OnEnter", tooltip)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    return b
end

local function button(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local function build()
    win = CreateFrame("Frame", "TalentOrderPlannerFrame", UIParent)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    win:EnableMouse(true)
    win:SetMovable(true)
    win:SetClampedToScreen(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self) self:StartMoving() end)
    win:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    win.back = win:CreateTexture(nil, "BACKGROUND")
    win.back:SetAllPoints()
    win.back:SetColorTexture(0.05, 0.05, 0.07, 0.95)
    win.title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    win.title:SetPoint("TOPLEFT", PAD, -10)
    win.hint = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    win.hint:SetPoint("TOPLEFT", PAD, -30)
    win.hint:SetText("Click talents in the order you want them. Right-click takes a point back. Nothing is spent while this window is open.")
    win.trees, win.talents, win.links, win.lines = {}, {}, {}, {}
    win.canvas = CreateFrame("Frame", nil, win)
    win.canvas:SetPoint("TOPLEFT", PAD, -TOP)
    win.list = CreateFrame("Frame", nil, win)
    win.list:SetSize(LIST_W, LINES * LINE_H)
    win.list:EnableMouseWheel(true)
    win.list:SetScript("OnMouseWheel", function(_, delta)
        scroll = math.max(0, math.min(math.max(0, #P.order - LINES), scroll - delta * 3))
        P.Paint()
    end)
    win.listTitle = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    win.listTitle:SetText("The order")
    for i = 1, LINES do
        local line = win.list:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetPoint("TOPLEFT", 0, -(i - 1) * LINE_H)
        line:SetWidth(LIST_W)
        line:SetJustifyH("LEFT")
        win.lines[i] = line
    end
    win.status = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    win.status:SetPoint("BOTTOMLEFT", PAD, 40)
    win.warn = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    win.warn:SetPoint("BOTTOMLEFT", PAD, 68)
    win.warn:SetTextColor(1, 0.3, 0.3)
    win.follow = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    win.follow:SetPoint("BOTTOMLEFT", PAD, 54)
    win.follow:SetTextColor(0.6, 0.8, 1)
    win.undo = button(win, "Undo last", 90, function() P.Undo() end)
    win.undo:SetPoint("BOTTOMLEFT", PAD, 10)
    win.clear = button(win, "Clear plan", 90, function() P.Clear() end)
    win.clear:SetPoint("LEFT", win.undo, "RIGHT", 6, 0)
    win.builtIn = button(win, "Built-in order", 110, function() P.UseBuiltIn() end)
    win.builtIn:SetPoint("LEFT", win.clear, "RIGHT", 6, 0)
    win.spend = button(win, "", 150, function()
        if TalentOrder_SetOn and TalentOrder_IsOn then TalentOrder_SetOn(not TalentOrder_IsOn()) end
        P.Paint()
    end)
    win.spend:SetPoint("LEFT", win.builtIn, "RIGHT", 6, 0)
    win.close = button(win, "Close", 80, function() win:Hide() end)
    win.close:SetPoint("BOTTOMRIGHT", -PAD, 10)
    win:SetScript("OnEvent", function() if win:IsShown() then P.Refresh() end end)
    pcall(win.RegisterEvent, win, "TRAIT_CONFIG_UPDATED")
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "TalentOrderPlannerFrame") end      -- Esc closes it
    win:Hide()
    -- (set after the first Hide: only a window the player closes tells the spender to carry on)
    win:SetScript("OnHide", function()
        if TalentOrder_PlanChanged then TalentOrder_PlanChanged(P.dirty == true) end
        P.dirty = false
    end)
end

-- where everything sits for this character's trees
local function layout()
    local model = P.model
    local x, rows = 0, 7
    for _, tab in ipairs(model.tabs) do rows = math.max(rows, tab.rows) end
    local used = 0
    for i, tab in ipairs(model.tabs) do
        local width = math.max(4, tab.cols) * STEP
        local head = win.trees[i]
        if not head then
            head = win.canvas:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            win.trees[i] = head
        end
        head:ClearAllPoints()
        head:SetPoint("TOPLEFT", x, 16)
        head:Show()
        head.tab = tab
        for _, id in ipairs(tab.talents) do
            local t = model.talents[id]
            used = used + 1
            local b = win.talents[used]
            if not b then
                b = newTalent(win.canvas)
                win.talents[used] = b
            end
            b.id = id
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", x + t.col * STEP + (STEP - ICON) / 2, -(t.row * STEP + (STEP - ICON) / 2))
            b.icon:SetTexture(t.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            b:Show()
        end
        x = x + width + GAP
    end
    for i = used + 1, #win.talents do win.talents[i]:Hide() end
    for i = #model.tabs + 1, #win.trees do win.trees[i]:Hide() end
    local treesW = math.max(0, x - GAP)
    win.canvas:SetSize(treesW, rows * STEP)
    win.list:ClearAllPoints()
    win.list:SetPoint("TOPLEFT", PAD + treesW + GAP, -TOP)
    win.listTitle:ClearAllPoints()
    win.listTitle:SetPoint("BOTTOMLEFT", win.list, "TOPLEFT", 0, 4)
    win:SetSize(math.max(560, PAD + treesW + GAP + LIST_W + PAD), TOP + math.max(rows * STEP, LINES * LINE_H) + BOTTOM)
    win.title:SetText("Talent plan" .. (model.class and (": " .. model.class:sub(1, 1) .. model.class:sub(2):lower()) or ""))
    win.builtIn:SetShown(model.class == "ROGUE" and type(TalentOrder_ORDER) == "table")
end

function P.Paint()
    if not (win and P.model) then return end
    local model, state = P.model, P.State()
    for _, b in ipairs(win.talents) do
        local t = b:IsShown() and model.talents[b.id]
        if t then
            local have = state.ranks[b.id] or 0
            local open = TalentOrder_PlanCanAdd(model, P.order, b.id)
            b.count:SetText(have .. "/" .. t.max)
            if have >= t.max then
                b.edge:SetColorTexture(1, 0.82, 0, 1)
                b.count:SetTextColor(1, 0.82, 0)
            elseif have > 0 then
                b.edge:SetColorTexture(0.1, 0.9, 0.1, 1)
                b.count:SetTextColor(0.1, 1, 0.1)
            elseif open then
                b.edge:SetColorTexture(0.75, 0.75, 0.75, 1)
                b.count:SetTextColor(1, 1, 1)
            else
                b.edge:SetColorTexture(0.25, 0.25, 0.25, 1)
                b.count:SetTextColor(0.5, 0.5, 0.5)
            end
            b.icon:SetDesaturated(have == 0 and not open)
        end
    end
    for _, head in ipairs(win.trees) do
        if head.tab and head:IsShown() then head:SetText(head.tab.name .. "  (" .. (state.spent[head.tab.group] or 0) .. ")") end
    end
    local lines = P.Lines()
    scroll = math.max(0, math.min(scroll, math.max(0, #lines - LINES)))
    for i = 1, LINES do
        local line = lines[i + scroll]
        win.lines[i]:SetText(line and line.text or "")
        if line and line.learned then win.lines[i]:SetTextColor(0.55, 0.55, 0.55) else win.lines[i]:SetTextColor(1, 1, 1) end
    end
    local planned = #P.order - P.learned
    win.status:SetText(#P.order .. " of " .. (model.cap or "?") .. " points in the order: " .. P.learned .. " learned, " .. planned
        .. " planned." .. (#lines > LINES and "  (scroll the list with the mouse wheel)" or ""))
    win.warn:SetText(P.message or "")
    if P.HasPlan() then
        win.follow:SetText("Points are spent in this order" .. ((TalentOrder_IsOn and TalentOrder_IsOn()) and "" or " once auto-spend is ON") .. ".")
    elseif model.class == "ROGUE" and type(TalentOrder_ORDER) == "table" then
        win.follow:SetText("No plan of your own yet: the built-in rogue order is used until you click a talent.")
    else
        win.follow:SetText("No plan yet: nothing is spent until you plan a point.")
    end
    local on = TalentOrder_IsOn and TalentOrder_IsOn()
    win.spend:SetText(on and "Auto-spend: ON" or "Auto-spend: OFF")
end

function TalentOrder_ShowPlanner()
    local ok, why = P.Load()
    if not ok then
        print(TAG .. "cannot open the planner: " .. tostring(why))
        return false
    end
    if not win then build() end
    P.dirty = false
    scroll = math.max(0, P.learned - 3)             -- the list opens where the planned picks begin
    layout()
    P.Paint()
    win:Show()
    return true
end

function TalentOrder_PlannerShown()
    return win ~= nil and win:IsShown() == true
end
