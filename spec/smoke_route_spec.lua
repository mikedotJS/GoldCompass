-- Smoke: "Ou monter" zones and spawn points, mining smelting roadmap.
local H = require("spec.helper_smoke")
local loadAddon = H.loadAddon
local printed, handlers, frames, timers
local function setup(opts)
  printed, handlers, frames, timers = {}, {}, {}, {}
  H.setup(opts, function() return printed, handlers, frames, timers end)
end

describe("Où monter keeps the zone the character was sent to", function()
  it("a zone that still gives points stays first, so the plan does not change zone before the zone is spent", function()
    setup({ scanned = true, profs = { { 393, 110, "Dépeçage", 150 } } })
    local ns = loadAddon()
    assert(loadfile("Data/ForeverSkinZones.lua"))("GoldCompass", ns)
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = {} }
    local road = { nextRank = "Expert", rankAt = 125, capped = false }
    local p = { skill = 110, max = 150, line = 393 }
    local first = ns.RouteMap.Plan(p, road, "Skinning").steps[1]
    assert.are.equal("zone", first.kind)
    assert.are.equal(first.zone, ns.char.routeZone.Skinning)                         -- remembered
    -- another zone that gives points becomes the remembered one: the plan puts it first
    local others = {}
    for _, z in ipairs(ns.Route.SkinZones(110, ns.SkinZones)) do
      local lo = ns.Zones[z.zone] and ns.Zones[z.zone][2]
      if z.zone ~= first.zone and (not lo or lo - 16 <= 4) then others[#others + 1] = z.zone end
    end
    table.sort(others)
    assert.is_true(#others > 0)
    ns.char.routeZone.Skinning = others[1]
    local again = ns.RouteMap.Plan(p, road, "Skinning").steps
    local zone
    for _, s in ipairs(again) do if s.kind == "zone" then zone = s.zone; break end end
    -- the remembered zone leads unless it has no known point to walk through (then it goes after the zones that have some)
    assert.is_true(zone == others[1] or zone == first.zone)
  end)
end)

describe("Où monter walks through every known spawn point of the beasts (Data/ForeverSkinPoints.lua)", function()
  local road = { nextRank = "Artisan", rankAt = 200, capped = false }

  it("gives every zone step of skinning 150 to 299 known points, and a loop of at most MAX_POINTS merged points", function()
    setup({ scanned = true, profs = { { 393, 200, "Dépeçage", 225 } } })
    local ns = loadAddon()
    for _, f in ipairs({ "Data/ForeverSkinZones.lua", "Data/ForeverSkinPoints.lua" }) do assert(loadfile(f))("GoldCompass", ns) end
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = {} }
    local zoneSteps = 0
    for skill = 150, 299, 7 do
      local max = skill < 225 and 225 or 300
      local steps = ns.RouteMap.Plan({ skill = skill, max = max, line = 393 }, { nextRank = "Artisan", rankAt = max - 25, capped = false }, "Skinning").steps
      for _, s in ipairs(steps) do
        if s.kind == "zone" then
          zoneSteps = zoneSteps + 1
          assert.is_true(#s.points > 0, ("skill %d zone %d has no point"):format(skill, s.zone))
          local loop = ns.Route.Loop(s.points, { x = 50, y = 50 })
          assert.is_true(#loop.points >= 1 and #loop.points <= ns.Route.MAX_POINTS)
        end
      end
    end
    assert.is_true(zoneSteps >= 20)
  end)

  it("prefers the points players saw in Forever, and adds the Classic ones only below MIN_FOREVER", function()
    setup({ scanned = true, profs = { { 393, 200, "Dépeçage", 225 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = {} }
    local function steps(packed)
      -- one beast, requirement 200, in zone 1413
      ns.SkinZones = { [1413] = { { 9001, "Test Beast", 40, 42, 200, spots = 10, foreverSpots = 0 } } }
      ns.SkinPoints = { [90011413] = packed }
      for _, s in ipairs(ns.RouteMap.Plan({ skill = 210, max = 225, line = 393 }, road, "Skinning").steps) do
        if s.kind == "zone" then return s end
      end
    end
    local four = steps("0a0a0b0b0c0c0d0d.5a5a5b5b")                 -- 4 Forever points: the 2 Classic ones stay out
    assert.equals(4, #four.points)
    local three = steps("0a0a0b0b0c0c.5a5a5b5b")                    -- 3 Forever points: the Classic ones fill in
    assert.equals(5, #three.points)
    assert.equals(1, #steps(".5a5a").points)                        -- Classic only
  end)

  it("a zone whose beasts have no known point goes after the ones that have, and says so with no points (no hang)", function()
    setup({ scanned = true, profs = { { 393, 200, "Dépeçage", 225 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = {} }
    ns.SkinZones = {
      [1413] = { { 9001, "Bare Beast", 40, 42, 200, spots = 99, foreverSpots = 0 } },
      [1411] = { { 9002, "Known Beast", 40, 42, 200, spots = 1, foreverSpots = 0 } },
    }
    ns.SkinPoints = { [90021411] = "0a0a0b0b" }
    local first
    for _, s in ipairs(ns.RouteMap.Plan({ skill = 210, max = 225, line = 393 }, road, "Skinning").steps) do
      if s.kind == "zone" then first = s; break end
    end
    assert.equals(1411, first.zone)
    assert.equals(2, #first.points)
    ns.SkinPoints = nil                                              -- no data file at all: still a plan, steps without points
    for _, s in ipairs(ns.RouteMap.Plan({ skill = 210, max = 225, line = 393 }, road, "Skinning").steps) do
      if s.kind == "zone" then assert.equals(0, #s.points) end
    end
  end)
end)

describe("Mining: the smelting roadmap (Fondre) next to the zones (Où monter)", function()
  local function lineTexts(ns)
    local out = {}
    for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = (l.left.text or "") .. " " .. (l.right.text or "") end
    return table.concat(out, "\n")
  end
  -- a recipe of the Mining window as Learned.Capture remembers it, from the Forever data
  local function known(ns, ids)
    local recipes, all = {}, ns.ForeverDB:GetRecipes(186)
    for _, id in ipairs(ids) do
      local e = all[id]
      local mats = {}
      for item, n in pairs(e.reagents) do mats[#mats + 1] = { item, n } end
      recipes[id] = { id = id, name = "Fonte " .. id, d = 0, out = e.craftedItemId, oq = 1, mats = mats }
    end
    return recipes
  end
  local function start(skill, max, name, line, recipes)
    setup({ scanned = true, level = 60, counts = {}, profs = { { line or 186, skill, name or "Minage", max } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = {}, goal = "level" }
    -- the ore of the stub is Metal & Stone (class 7, subclass 7), as in the game
    _G.C_Item.GetItemInfoInstant = function() return 0, "", "", "", 0, 7, 7 end
    ns.ForgetProfessions()
    if recipes then ns.char.profs[name or "Minage"] = { skill = skill, max = max, recipes = recipes(ns) } end
    return ns
  end
  local function run(ns)
    local res
    ns.RunLeveling(function(r) res = r end)
    return res
  end

  it("plans the smelting steps with the ore to mine, after the zones, and says where the ore comes from", function()
    local ns = start(1, 75, nil, nil, function(n) return known(n, { 2657 }) end)
    local p = run(ns).profs[1]
    assert.are.equal("plan", p.status)
    assert.is_true(p.road.gathering)
    assert.are.equal("seen", p.road.smelt)
    assert.is_not_nil(p.road.where)                               -- the zones are still there
    local craft = p.road.steps[1]
    assert.are.equal("craft", craft.kind)
    assert.are.equal(2657, craft.rec.id)                          -- Smelt Copper
    assert.are.equal(2770, craft.missing[1].item)                 -- Copper Ore, none in the bags
    assert.are.equal("ore", craft.missing[1].how)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local text = lineTexts(ns)
    local zones, smelt = text:find("Où monter", 1, true), text:find("Fondre", 1, true)
    assert.is_truthy(zones and smelt and zones < smelt)
    assert.matches("il te manque %d+ × Item2770", text)
    assert.matches("se mine dans les zones", text)
    assert.is_nil(text:find("Ton parcours", 1, true))             -- one title per block: Où monter, Fondre
  end)

  it("puts the ore of the smelting steps on the shopping list", function()
    local ns = start(1, 75, nil, nil, function(n) return known(n, { 2657 }) end)
    local res = run(ns)
    local need = 0
    for _, s in ipairs(res.profs[1].road.steps) do
      for _, m in ipairs(s.kind == "craft" and s.missing or {}) do if m.item == 2770 then need = need + m.n end end
    end
    assert.is_true(need > 0)
    local list = ns.Shopping.Build(res.profs, { bag = function() return 0 end, bank = function() return 0 end, name = function(id) return "Item" .. id end })
    local row
    for _, r in ipairs(list.rows) do if r.item == 2770 then row = r end end
    assert.is_not_nil(row)
    assert.are.equal(need, row.need)
    assert.is_false(row.ok)
    assert.are.equal("Minage", list.upTo[1].name)
  end)

  it("a character that never opened the Mining window gets the zones and the usual 'open your window once' line, no error", function()
    local ns = start(1, 75)
    local res = run(ns)
    assert.are.equal("ok", res.state)
    local p = res.profs[1]
    assert.are.equal("plan", p.status)
    assert.are.equal("unseen", p.road.smelt)
    assert.are.same({}, p.road.steps)
    assert.is_not_nil(p.road.where)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local text = lineTexts(ns)
    assert.matches("Où monter", text)
    assert.matches("Ouvre ta fenêtre de Minage une fois", text)
    assert.is_nil(text:find("Fondre", 1, true))
  end)

  it("says there is nothing to smelt at this skill (the zones carry the gap) instead of leaving an empty block", function()
    -- skill 150 with copper, bronze, silver and iron known: nothing to smelt until Smelt Gold (155)
    local ns = start(150, 225, nil, nil, function(n) return known(n, { 2657, 2659, 2658, 3307 }) end)
    local p = run(ns).profs[1]
    assert.are.equal(0, #p.road.steps)
    assert.is_not_nil(p.road.where)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local text = lineTexts(ns)
    assert.matches("Où monter", text)
    assert.matches("Fondre", text)
    assert.matches("Rien à fondre à ce niveau", text)
    assert.is_nil(text:find("Plus de recette utile", 1, true))
  end)

  it("leaves Herb Gathering and Skinning as they were: zones only, no smelting block, whatever the window listed", function()
    for _, case in ipairs({ { 182, "Herboristerie" }, { 393, "Dépeçage" } }) do
      local ns = start(50, 75, case[2], case[1], function(n) return known(n, { 2657 }) end)   -- recipes of the window, ignored
      local p = run(ns).profs[1]
      assert.are.equal("plan", p.status)
      assert.is_true(p.road.gathering)
      assert.is_nil(p.road.smelt)
      for _, s in ipairs(p.road.steps) do assert.are.equal("rank", s.kind) end   -- no craft, no recipe to learn
      ns.Window.Toggle(); ns.Window.SetTab("job")
      local text = lineTexts(ns)
      assert.matches("Où monter", text)
      assert.is_nil(text:find("Fondre", 1, true))
      assert.is_nil(text:find("Ouvre ta fenêtre", 1, true))
    end
  end)
end)
