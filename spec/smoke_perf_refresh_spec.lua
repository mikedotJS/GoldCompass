-- Smoke: refreshes cost little (one calculation per event).
local H = require("spec.helper_smoke")
local loadAddon = H.loadAddon
local printed, handlers, frames, timers
local function setup(opts)
  printed, handlers, frames, timers = {}, {}, {}, {}
  H.setup(opts, function() return printed, handlers, frames, timers end)
end

describe("Refreshes cost little: one calculation per event, nothing recomputed that did not change", function()
  local alchemy = { skill = 50, max = 75, recipes = {
    [1] = { id = 1, name = "Potion de soins", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } } } }
  local counts
  local function start()
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } }, noSpell = true })
    counts = { [2447] = 4 }
    _G.C_Item.GetItemCount = function(id) return counts[id] or 0 end
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = alchemy }, goal = "level" }
    ns.Window.Toggle(); ns.Window.SetTab("job")
    for _, fn in ipairs(timers) do pcall(fn) end
    timers = {}
    return ns
  end
  local function fire(event, ...)
    for _, fr in ipairs(frames) do
      if fr.events and fr.events[event] and fr.scripts.OnEvent and fr.events.UNIT_SPELLCAST_START then fr.scripts.OnEvent(fr, event, ...) end
    end
  end
  local function fireAll(event, ...)
    for _, fr in ipairs(frames) do if fr.events and fr.events[event] and fr.scripts.OnEvent then fr.scripts.OnEvent(fr, event, ...) end end
  end
  local function runTimers() local t = timers; timers = {}; for _, fn in ipairs(t) do pcall(fn) end end

  it("a profession whose inputs did not change is not computed again; a changed reagent count recomputes it", function()
    local ns = start()
    local built = 0
    local real = ns.Leveling.Plan
    ns.Leveling.Plan = function(...) built = built + 1; return real(...) end
    local first
    ns.RunLeveling(function(r) first = r end)
    local again
    ns.RunLeveling(function(r) again = r end)
    assert.are.equal(0, built)                                                      -- the same answer, already computed by the tab
    assert.are.equal(first.profs[1], again.profs[1])
    counts[2447] = 9                                                                -- something was looted
    ns.RunLeveling(function(r) again = r end)
    assert.are.equal(1, built)
    counts[999999] = 5                                                              -- an item no recipe uses
    ns.RunLeveling(function(r) again = r end)
    assert.are.equal(1, built)
    ns.ForgetProfessions()                                                          -- the refresh button
    ns.RunLeveling(function(r) again = r end)
    assert.are.equal(2, built)
  end)

  it("a refresh that used its frame budget goes on in the next frames, one stage per frame, and answers once", function()
    local ns = start()
    ns.ForgetProfessions()
    ns.FrameBudget = 0
    local answers, res = 0, nil
    ns.RunLeveling(function(r) answers = answers + 1; res = r end)
    assert.is_nil(res)                                                              -- nothing computed in the calling frame
    local frames = 0
    while not res and frames < 20 do frames = frames + 1; runTimers() end
    assert.are.equal(1, answers)
    assert.are.equal("ok", res.state)
    assert.are.equal("plan", res.profs[1].status)
    assert.is_not_nil(res.profs[1].road)
    assert.is_true(frames >= 3)                                                     -- plan, places to learn, roadmap
    local sync
    ns.RunLeveling(function(r) sync = r end)                                        -- now cached: the answer is immediate
    assert.are.equal(res.profs[1], sync.profs[1])
  end)

  it("the split refresh gives the same answer as the one-frame refresh", function()
    local ns = start()
    local whole
    ns.ForgetProfessions()
    ns.RunLeveling(function(r) whole = r end)
    ns.ForgetProfessions()
    ns.FrameBudget = 0
    local split
    ns.RunLeveling(function(r) split = r end)
    local frames = 0
    while not split and frames < 20 do frames = frames + 1; runTimers() end
    local function steps(e) local out = {} for i, st in ipairs(e.road.steps) do out[i] = st.kind .. (st.rec and st.rec.id or "") end return table.concat(out, ",") end
    assert.are.equal(steps(whole.profs[1]), steps(split.profs[1]))
    assert.are.equal(whole.profs[1].plan.best.rec.id, split.profs[1].plan.best.rec.id)
  end)

  it("the place of a recipe is looked up once until the trainer records, the zone or the faction change", function()
    local ns = start()                                                              -- the tab's own refresh already looked the places up
    local looked, real = 0, ns.Where.Target
    ns.Where.Target = function(...) looked = looked + 1; return real(...) end
    local function refresh() ns.ForgetProfessions(); ns.RunLeveling(function() end) end
    refresh()
    assert.are.equal(0, looked)                                                     -- a refresh asked nobody again
    local stamp, recorded = ns.TrainerLog.Stamp, 0
    ns.TrainerLog.Stamp = function() return stamp() + recorded end
    recorded = 1                                                                    -- a trainer window was recorded
    refresh()
    local first = looked
    assert.is_true(first > 0)
    refresh()
    assert.are.equal(first, looked)
    local zone = C_Map.GetBestMapForUnit
    C_Map.GetBestMapForUnit = function() return 1412 end                            -- the character went to another zone
    refresh()
    assert.are.equal(2 * first, looked)
    C_Map.GetBestMapForUnit = zone
    ns.TrainerLog.Stamp = stamp
  end)

  it("a stage that fails ends the refresh with an error answer, never a silent hang", function()
    local ns = start()
    ns.ForgetProfessions()
    ns.FrameBudget = 0
    ns.BuildRoadmap = function() error("boom") end
    local res
    ns.RunLeveling(function(r) res = r end)
    local frames = 0
    while not res and frames < 20 do frames = frames + 1; runTimers() end
    assert.are.equal("error", res.state)
    assert.matches("boom", res.message)
  end)

  it("one bag event with the Métier tab and the shopping list on screen is one calculation, not two", function()
    local ns = start()
    ns.ShoppingList.Show()
    runTimers()
    local runs, real = 0, ns.RunLeveling
    ns.RunLeveling = function(...) runs = runs + 1; return real(...) end
    counts[2447] = 7
    fireAll("BAG_UPDATE_DELAYED")
    runTimers(); runTimers()
    assert.are.equal(1, runs)
    assert.is_not_nil(ns.ShoppingList.State())                                      -- the list was fed by the tab
  end)

  it("the tab keeps what it shows while an automatic refresh computes (no loading panel)", function()
    local ns = start()
    counts[2447] = 7
    local lines = #ns.Window.Lines()
    assert.is_true(lines > 0)
    fireAll("BAG_UPDATE_DELAYED")
    assert.is_false(ns.Window.IsPanelShown())
    runTimers()
    assert.is_true(#ns.Window.Lines() > 0)
  end)

  it("a redraw asked for in combat waits for the end of the fight", function()
    local ns = start()
    local runs, real = 0, ns.RunLeveling
    ns.RunLeveling = function(...) runs = runs + 1; return real(...) end
    _G.InCombatLockdown = function() return true end
    counts[2447] = 9
    fireAll("BAG_UPDATE_DELAYED")
    runTimers()
    assert.are.equal(0, runs)
    _G.InCombatLockdown = function() return false end
    fireAll("PLAYER_REGEN_ENABLED")
    runTimers(); runTimers()
    assert.are.equal(1, runs)
  end)
end)
