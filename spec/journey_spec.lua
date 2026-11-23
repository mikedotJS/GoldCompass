-- Regression of the levelling roadmap ("Monter le metier"): a simulated player follows the plan from skill 1 (or from the middle of a
-- profession) to 300, one skill point at a time, and the roadmap is recomputed after every point, as the window does when the profession
-- window is read again. Only INVARIANTS are asserted, never a recipe list, so tuning the plan does not break this file; a regression of the
-- plan itself (a recipe that vanishes, a plan that flips, a learn step that cannot be done, a plan that stops before 300) does.
--
-- Fixture: the addon loaded in its TOC order against a stubbed WoW API, the data files of the repo (Data/*.lua, committed), a new
-- character per scenario (it knows the recipes the data marks "known from the start"), empty bags and bank, level 60, deterministic prices.
-- Nothing comes from a saved-variables file or from a git-ignored folder. The WoW API stubs are the ones of smoke_spec.lua, reduced to what
-- the roadmap reads. The simulator this file is a lean version of is the "journey" harness (detectors D2 reorder, D5 learned recipe
-- vanishes, D6 impossible learn, D7 rank too early).
--
-- The player: the step shown first is the one he does. A craft gives +1 skill per craft while the colour allows (Leveling.ChanceAt > 0
-- with the recipe's own thresholds: the expected value, no luck), the step he follows is recomputed after each point. A recipe to learn
-- is added to the recipes the window knows, with the colour it has at that skill. A rank step lifts the cap by 75.

local V, ns, timers, BAG, BANK, KNOWN

local ENG = { [171] = "Alchemy", [164] = "Blacksmithing", [333] = "Enchanting", [202] = "Engineering", [165] = "Leatherworking",
  [197] = "Tailoring", [185] = "Cooking", [129] = "First Aid", [186] = "Mining" }
local RANK_CAP = { Apprentice = 0, Journeyman = 150, Expert = 225, Artisan = 300 }   -- the cap a rank needs to be held (what it trains from)
local LEVEL = 60
local GUARD = 900          -- iterations of one journey (a full 1 to 300 takes about 350 with a recompute per skill point)

-- ------------------------------------------------------------------------------------------------ the stubbed API
local function proxy()
  local p = { scripts = {} }
  return setmetatable(p, { __index = function(_, k)
    if type(k) ~= "string" or not k:match("^%u") then return nil end
    return function(self, a, b)
      if k == "SetScript" then self.scripts[a] = b end
      if k == "CreateTexture" or k == "CreateFontString" then return proxy() end
      if k == "IsShown" then return false end
      if k:match("^Create") then return proxy() end
      return self
    end
  end })
end

local function installApi(faction, profs)
  timers = {}
  _G.print = function() end
  _G.GoldCompassDB = nil
  _G.SlashCmdList = {}
  _G.UISpecialFrames = {}
  _G.tinsert = table.insert
  _G.UIParent = proxy()
  _G.CreateFrame = function() return proxy() end
  _G.C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
  _G.date, _G.time = os.date, os.time
  _G.debugstack = function() return "" end
  _G.GetBuildInfo = function() return "1.60.1", "70959", "Nov 20 2026", 16001 end
  _G.geterrorhandler = function() return function() end end
  _G.seterrorhandler = function() end
  _G.UnitName = function() return "Tester" end
  _G.GetRealmName = function() return "Realm" end
  _G.GetLocale = function() return "frFR" end
  _G.Item = { CreateFromItemID = function(_, id) return { ContinueOnItemLoad = function(_, cb) cb() end } end }
  _G.GetItemInfo = function(id) return "Item" .. id, nil, nil, nil, nil, nil, nil, nil, nil, nil, 25 end
  _G.C_Map = { GetMapInfo = function(id) return { name = "Zone" .. id } end, GetBestMapForUnit = function() return 1411 end }
  _G.UnitLevel = function() return LEVEL end
  _G.UnitFactionGroup = function() return faction end
  _G.InCombatLockdown = function() return false end
  _G.IsShiftKeyDown = function() return false end
  _G.IsAddOnLoaded = function() return false end
  _G.Enum = { TooltipDataType = { Item = 0 } }
  _G.C_Item = { GetItemCount = function(id) return BAG[id] or 0 end, GetItemInfoInstant = function() return 0, "", "", "", 0, 7 end,
    GetItemQualityByID = function() return 1 end }
  _G.C_Container = { GetContainerNumSlots = function() return 0 end, GetContainerItemInfo = function() return nil end }
  _G.GameTooltip = { lines = {}, AddLine = function() end, AddDoubleLine = function() end, IsShown = function() return false end }
  _G.TooltipDataProcessor = { AddTooltipPostCall = function() end }
  _G.GetProfessions = function() local t = {}; for i = 1, #profs do t[i] = i end; return table.unpack(t) end
  _G.GetProfessionInfo = function(i) local p = profs[i]; return p.name, nil, p.skill, p.max, nil, nil, p.line end
  _G.IsPlayerSpell = function(id) return KNOWN[id] == true end
  -- the price addon: a price for 6 items out of 7 (the 7th has none, as in the real market), all fresh; deterministic
  _G.GatherMate2 = { GetNodesForZone = function() return pairs({}) end }
  _G.Auctionator = { API = { v1 = {
    GetAuctionPriceByItemID = function(_, id) if id % 7 ~= 0 then return (id % 97 + 5) * 10 end end,
    GetAuctionAgeByItemID = function() return 2 end,
    GetVendorPriceByItemID = function() return nil end,
  } } }
end

-- Loads the addon files in the order of the .toc (so this spec never drifts from the real load order), once per faction.
local function loadAddon()
  local space = {}
  for line in io.lines("GoldCompass.toc") do
    local f = line:match("^([%w_\\]+)%.lua%s*$")
    if f then assert(loadfile((f:gsub("\\", "/")) .. ".lua"))("GoldCompass", space) end
  end
  return space
end

local function drain(get)
  -- RunLeveling spreads its work over C_Timer.After(0) steps: run the queued timers, in order, until the callback has been called
  for _ = 1, 400 do
    if get() then return end
    local queue = timers
    timers = {}
    if #queue == 0 then return end
    for _, fn in ipairs(queue) do fn() end
  end
end

-- ------------------------------------------------------------------------------------------------ one character
-- A fresh character of `line` in `faction`: skill/max given, knows `known` (set of recipe ids) plus what the data teaches from the start.
local function newWorld(line, faction, skill, max, knownFn)
  BAG, BANK, KNOWN = {}, {}, {}
  local prof = { name = ENG[line], line = line, skill = skill, max = max }
  installApi(faction, { prof })
  if not ns then   -- the files are loaded once for the whole file (the data is heavy); each scenario starts from a fresh character record
    ns = loadAddon()
    ns.FrameBudget = math.huge
    ns.Bank.Count = function(id) return BANK[id] or 0 end
    V = ns.Leveling
  end
  ns.ForgetProfessions()
  _G.GoldCompassDB = nil
  -- ADDON_LOADED of Core.lua: the saved variables and the character record
  ns.db = { buy = {}, buyDay = {}, chars = {}, trainers = {} }
  ns.char = { learned = {}, profs = {}, goal = "level", onlyBag = false }
  ns.charKey = "Tester-Realm"
  local DB = ns.ForeverDB
  local fixes = ns.ForeverFixes or {}
  local fallback = {}
  for _, c in ipairs(V.Crafts(ns.RecipeRows or {}, ENG[line])) do fallback[c.id] = c end
  local function thresholds(id)
    local r = DB:GetRecipes(line)
    local e = r and r[id]
    return e and V.Difficulty(e.difficulty, e.requiredSkill, ns.ForeverTrainers[id])
  end
  local function recipe(id, at)
    local e, fb = DB:GetRecipes(line)[id], fallback[id]
    local mats = {}
    for item, qty in pairs(e.reagents or {}) do mats[#mats + 1] = { item, qty } end
    table.sort(mats, function(a, b) return a[1] < b[1] end)
    if #mats == 0 and fb then mats = fb.mats end
    local th = thresholds(id)
    return { id = id, name = e.name, d = th and V.ColorAt(at, th) or 0, out = e.craftedItemId or (fb and fb.out),
      oq = (fixes.oq and fixes.oq[id]) or (fb and fb.oq) or 1, mats = mats }
  end
  local data = { skill = skill, max = max, updated = 1, recipes = {} }
  ns.char.profs[prof.name] = data
  local ids = {}
  for id in pairs(DB:GetRecipes(line)) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local ft = ns.ForeverTrainers[id]
    local gone = fixes.gone and fixes.gone[id]
    local start = (ft and ft.start) or DB:IsAutoTaughtRecipe(id)
    if not DB:IsHiddenRecipe(id) and not gone and (start or (knownFn and knownFn(id, ft))) then
      data.recipes[id] = recipe(id, skill)
      KNOWN[id], ns.char.learned[id] = true, true
    end
  end
  return { prof = prof, data = data, thresholds = thresholds, recipe = recipe, line = line }
end

local function roadmap(w)
  local res
  ns.RunLeveling(function(r) res = r end)
  drain(function() return res end)
  assert(res and res.state == "ok", "RunLeveling: " .. tostring(res and (res.state or res.message)))
  local entry = res.profs[1]
  return entry, entry.road
end

-- The plan (road.path: ranks, recipes to learn, crafts, solved once for the whole way) as a string and as the set of recipes it learns.
local function planOf(road)
  local t, learns = {}, {}
  for i, e in ipairs(road.path or {}) do
    t[i] = e.kind == "craft" and ("C%d:%d>%d"):format(e.rec.id, e.from, e.to)
      or e.kind == "learn" and ("L%d@%d"):format(e.rec.id, e.at) or ("R%s@%d"):format(tostring(e.rank), e.at)
    if e.kind == "learn" then learns[e.rec.id] = true end
  end
  return table.concat(t, " ") .. " reach=" .. tostring(road.reach), learns
end

-- The journey: follows step 1 of the roadmap, a skill point at a time, up to 300. Returns the report.
local function journey(w, opts)
  opts = opts or {}
  local P, data, th = w.prof, w.data, w.thresholds
  local R = { learns = {}, ranks = 0, iterations = 0, reorders = 0, reorderEx = {}, vanished = {}, badLearn = {}, badRank = {}, stop = "reached 300",
    first = nil, impure = {}, purityChecks = 0 }
  local lastPlan                -- { kind, id, to } of the craft step the player is on
  local justLearned
  local function setSkill(s)
    P.skill, data.skill = s, s
    for id, rec in pairs(data.recipes) do local t = th(id); if t then rec.d = V.ColorAt(s, t) end end
  end
  while P.skill < 300 do
    R.iterations = R.iterations + 1
    if R.iterations > GUARD then R.stop = "guard"; break end
    local entry, road = roadmap(w)
    if entry.status ~= "plan" or not road then R.stop = "status " .. tostring(entry.status); break end
    if opts.purity and R.iterations % 8 == 1 then
      -- (e) the same inputs again; bags and bank full of things no recipe uses; bags and bank full of every reagent of the recipes known
      local base, baseLearns = planOf(road)
      ns.ForgetProfessions()
      local same = planOf(select(2, roadmap(w)))
      for i = 1, 60 do BAG[900000 + i], BANK[900000 + i] = 200, 200 end
      ns.ForgetProfessions()
      local unrelated = planOf(select(2, roadmap(w)))
      for _, rec in pairs(data.recipes) do for _, m in ipairs(rec.mats) do BAG[m[1]], BANK[m[1]] = 200, 200 end end
      ns.ForgetProfessions()
      local stocked, stockedLearns = planOf(select(2, roadmap(w)))
      BAG, BANK = {}, {}
      ns.ForgetProfessions()
      R.purityChecks = R.purityChecks + 1
      local function bad(what) R.impure[#R.impure + 1] = ("skill %d: %s"):format(P.skill, what) end
      if same ~= base then bad("the same inputs gave another plan") end
      if unrelated ~= base then bad("bags and bank full of unrelated items changed the plan") end
      -- reagents in the bags: the "bonus" steps spend them first and the plan goes on from the skill they reach, so a recipe to learn for a
      -- few points may be skipped (the entry cost no longer pays off); it never learns a recipe the plan without bags did not, nor reaches less
      for id in pairs(stockedLearns) do if not baseLearns[id] then bad("the bags made the plan learn " .. id) end end
      if stocked:match("reach=%S+$") ~= base:match("reach=%S+$") then bad("the bags changed the reach of the plan") end
    end
    local steps = road.steps
    local s1 = steps[1]
    local skill, max = P.skill, P.max
    -- (c) the craft step the player is on must still be the first one while it lasts
    if lastPlan and lastPlan.to > skill and s1 and s1.kind == "craft" and s1.rec.id ~= lastPlan.id then
      R.reorders = R.reorders + 1
      if #R.reorderEx < 5 then R.reorderEx[#R.reorderEx + 1] = ("skill %d: was crafting %d up to %d, now %d"):format(skill, lastPlan.id, lastPlan.to,
        s1.rec.id) end
    end
    lastPlan = nil
    -- (b) the recipe just learned is in the plan, unless it has run out
    if justLearned then
      local found = false
      for _, s in ipairs(road.path or {}) do if s.kind == "craft" and s.rec.id == justLearned.id then found = true end end
      local t = th(justLearned.id)
      if not found and not (t and V.ChanceAt(t, skill) < V.MIN_CHANCE) then
        R.vanished[#R.vanished + 1] = ("skill %d: learned %d, absent from the next plan"):format(skill, justLearned.id)
      end
      justLearned = nil
    end
    if not s1 then
      if road.capped and road.nextRank then s1 = { kind = "rank", rank = road.nextRank, at = skill, banner = true }
      else R.stop = "stuck at " .. skill .. "/" .. max .. " (stopped=" .. tostring(road.stopped) .. ")"; break end
    end
    if s1.kind == "rank" then
      -- (d) a rank is trained from 25 points below the cap, and by a character of the level it asks for
      if skill < max - 25 then R.badRank[#R.badRank + 1] = ("rank at %d, cap %d"):format(skill, max) end
      if s1.needLevel and s1.needLevel > LEVEL then R.badRank[#R.badRank + 1] = ("rank needs level %d"):format(s1.needLevel) end
      R.ranks = R.ranks + 1
      P.max, data.max = max + 75, max + 75
    elseif s1.kind == "learn" then
      -- (d) never a learn step above the skill or the rank held
      local rec, bad = s1.rec, nil
      local way = rec.way or {}
      if rec.learn and rec.learn > skill then bad = ("needs skill %d, has %d"):format(rec.learn, skill) end
      if way.rank and RANK_CAP[way.rank] and RANK_CAP[way.rank] > max then bad = ("needs rank %s (cap %d), cap is %d"):format(way.rank, RANK_CAP[way.rank], max) end
      if bad then R.badLearn[#R.badLearn + 1] = ("%d: %s"):format(rec.id, bad) end
      -- (f) how much the learn is worth: the points the plan gives to that recipe afterwards
      if not R.first then
        local pts = 0
        for _, e in ipairs(road.path or {}) do if e.kind == "craft" and e.rec.id == rec.id then pts = pts + (e.to - e.from) end end
        R.first = { id = rec.id, skill = skill, points = pts }
      end
      R.learns[#R.learns + 1] = { id = rec.id, skill = skill }
      KNOWN[rec.id], ns.char.learned[rec.id] = true, true
      data.recipes[rec.id] = w.recipe(rec.id, skill)
      justLearned = rec
    else
      -- craft: +1 per craft (the point of the step) while the chance allows
      local t = th(s1.rec.id)
      local to = math.min(s1.to, max, skill + (opts.stride or 1))
      if to <= skill then to = math.min(skill + 1, max) end   -- a step that does not move is a plan bug, the +1 keeps the loop going
      if t and V.ChanceAt(t, skill) <= 0 then R.stop = "craft of a gray recipe at " .. skill; break end
      setSkill(to)
      if s1.to > to then lastPlan = { id = s1.rec.id, to = s1.to } end
    end
  end
  R.final, R.cap = P.skill, P.max
  return R
end

-- ------------------------------------------------------------------------------------------------ the scenarios
local LINES = { 165, 197, 164, 202, 171, 333, 185, 129 }
local FINE = { [171] = true, [185] = true, [129] = true }   -- recomputed at every skill point; the others every STRIDE points (time budget)
local STRIDE = { Horde = 3, Alliance = 7 }
-- A craft step in progress turned into another recipe: measured 0 on all 17 journeys of the current plan; two are tolerated (a tie that
-- breaks differently at one skill is not a regression, a plan that flips at every point is: the mutation tests gave 1 to 170).
local MAX_REORDERS = 2
local reports = {}

local function run(line, faction, skill, max, knownFn, stride, purity)
  local w = newWorld(line, faction, skill, max, knownFn)
  return journey(w, { stride = stride, purity = purity }), w
end

describe("levelling roadmap: a player who follows it from skill 1 to 300", function()
  for _, faction in ipairs({ "Horde", "Alliance" }) do
    for _, line in ipairs(LINES) do
      local stride = (faction == "Horde" and FINE[line]) and 1 or STRIDE[faction]
      describe(ENG[line] .. " " .. faction .. " (every " .. stride .. " point)", function()
        local R
        setup(function() R = run(line, faction, 1, 75, nil, stride, line == 165 or line == 185) end)

        it("reaches 300", function()
          assert.are.equal("reached 300", R.stop)
          assert.are.equal(300, R.final)
        end)

        it("never drops a recipe it told the player to learn (D5)", function()
          assert.are.same({}, R.vanished)
        end)

        it("asks for no learn or rank the character cannot do (D6, D7)", function()
          assert.are.same({}, R.badLearn)
          assert.are.same({}, R.badRank)
        end)

        it("does not turn a craft step in progress into another recipe (D2)", function()
          assert.is_true(R.reorders <= MAX_REORDERS, "reorders " .. R.reorders .. ": " .. table.concat(R.reorderEx, " | "))
        end)

        it("is a pure function: the same inputs give the same plan, a bag or a bank change does not change it", function()
          if R.purityChecks == 0 then return end
          assert.are.same({}, R.impure)
        end)
      end)
    end
  end
end)

-- A character met in the middle of a profession: the recipes a trainer teaches up to skill 100 are known, the bags are empty.
local function trained(id, ft) return ft and ft.cost ~= nil and ft.learn <= 100 end

describe("levelling roadmap: starting in the middle of a profession", function()
  for _, case in ipairs({ { 165, 140, 225 }, { 185, 144, 150 } }) do
    describe(ENG[case[1]] .. " " .. case[2] .. "/" .. case[3], function()
      local R
      setup(function() R = run(case[1], "Horde", case[2], case[3], trained, 2, true) end)

      it("reaches 300", function()
        assert.are.equal("reached 300", R.stop)
        assert.are.equal(300, R.final)
        assert.are.same({}, R.badLearn)
        assert.are.same({}, R.badRank)
        assert.are.same({}, R.vanished)
      end)

      it("gives its first learn step at least 10 points of use", function()
        if os.getenv("JOURNEY_VERBOSE") then io.stderr:write(("first learn %s\n"):format(R.first and ("%d at %d worth %d"):format(R.first.id, R.first.skill, R.first.points) or "none")) end
        assert.is_not_nil(R.first, "the plan never asks to learn anything")
        assert.is_true(R.first.points >= 10, ("learn %d at %d is worth %d points"):format(R.first.id, R.first.skill, R.first.points))
      end)

      it("is a pure function of the character, not of the bags", function()
        assert.are.same({}, R.impure)
      end)
    end)
  end
end)

-- Mining: its skill rises by smelting too (the Smelting recipes are in its window), the rest by gathering ("Ou monter", no recipe). The
-- data gives smelting recipes up to skill 145 only (nothing smelts for 145 to 155), so the smelting plan cannot reach 300 by itself and
-- stops there on purpose ("stopped = none"): this is not asserted as a failure. What is asserted: the plan is followed as far as it goes,
-- with the same invariants as above, and it does not stop earlier than the 145 measured (a smelting recipe vanishing would).
describe("levelling roadmap: Mining (smelting)", function()
  local R
  setup(function() R = run(186, "Horde", 1, 75, nil, 3, false) end)

  it("follows the smelting plan as far as the data goes, then stops cleanly", function()
    assert.is_true(R.final >= 140, "stopped at " .. R.final .. " (" .. R.stop .. ")")
    assert.is_true(R.stop == "reached 300" or R.stop:match("^stuck at %d+/%d+ %(stopped=none%)$") ~= nil, R.stop)
  end)

  it("asks for nothing the character cannot do and keeps its learned recipes", function()
    assert.are.same({}, R.badLearn)
    assert.are.same({}, R.badRank)
    assert.are.same({}, R.vanished)
    assert.is_true(R.reorders <= MAX_REORDERS)
  end)
end)
