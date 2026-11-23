-- Smoke: the hints of Synergy.lua on the Métier tab and the shopping list: Leatherworking asks for Light Leather, the character skins.
local H = require("spec.helper_smoke")
local loadAddon = H.loadAddon
local printed, handlers, frames, timers
local function setup(opts)
  printed, handlers, frames, timers = {}, {}, {}, {}
  H.setup(opts, function() return printed, handlers, frames, timers end)
end

local function plain(s) return ((s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

-- Leatherworking 61/75 knows one recipe that eats Light Leather (2318); `skins` gives or removes the Skinning profession.
local function start(skins, extra)
  local profs = { { 165, 61, "Travail du cuir", 75 } }
  if skins then profs[2] = { 393, 110, "Dépeçage", 150 } end
  local opts = { scanned = true, faction = "Horde", level = 20, counts = {}, profs = profs }
  for k, v in pairs(extra or {}) do opts[k] = v end
  setup(opts)
  local ns = loadAddon()
  for _, f in ipairs({ "Data/ForeverSkinZones.lua", "Data/ForeverSkinPoints.lua" }) do assert(loadfile(f))("GoldCompass", ns) end
  ns.db = { buy = {} }
  ns.char = { goal = "level", learned = {}, profs = { ["Travail du cuir"] = { skill = 61, max = 75, recipes = {
    [2161] = { id = 2161, name = "Bottes", d = 0, out = 2309, oq = 1, mats = { { 2318, 6 }, { 2320, 2 } } } } } } }
  _G.GetLocale = function() return "frFR" end
  return ns
end

local function open(ns)
  ns.Window.Toggle(); ns.Window.SetTab("job")
  for _ = 1, 20 do
    local due = timers; timers = {}
    if #due == 0 then break end
    for _, fn in ipairs(due) do pcall(fn) end
  end
end

-- the lines of the tab, with the route button each carries
local function lines(ns)
  local out = {}
  for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = { text = plain(l.left.text), route = l.route and l.route.step or nil } end
  return out
end
local function find(list, pattern)
  for i, l in ipairs(list) do if l.text:find(pattern) then return i, l end end
end

describe("Métier tab hints (Synergy.lua)", function()
  it("a skinning character gets 'ton Dépeçage : ~N bêtes, zone' under the Light Leather line, with an Itinéraire button", function()
    local ns = start(true)
    open(ns)
    local list = lines(ns)
    local at, line = find(list, "ton Dépeçage : ~%d+ bêtes")
    assert.is_not_nil(at, table.concat((function() local t = {} for i, l in ipairs(list) do t[i] = l.text end return t end)(), "\n"))
    assert.matches("Item2318", list[at - 1].text)                    -- right under the line it is about
    assert.matches("il te manque", list[at - 1].text)
    assert.matches(", Zone%d+", line.text)
    assert.is_not_nil(line.route)                                     -- the Itinéraire button
    assert.are.equal(tonumber(line.text:match("Zone(%d+)")), line.route.zone)
    assert.is_true(#line.route.points > 0)                            -- built when read: the click
  end)

  it("leaves the screen exactly as without the hints when the character does not skin", function()
    local ns = start(false)
    open(ns)
    for _, l in ipairs(lines(ns)) do assert.is_nil(l.text:find("ton Dépeçage", 1, true)) end
    local without = {}
    for i, l in ipairs(lines(ns)) do without[i] = l.text end
    -- the same character with the hints switched off (Build fails): identical lines
    local again = start(false)
    again.Synergy.Build = function() error("boom") end
    open(again)
    local off = {}
    for i, l in ipairs(lines(again)) do off[i] = l.text end
    assert.are.same(without, off)
  end)

  it("a failing Synergy.Build is logged and the Skinning character sees today's screen", function()
    local base = start(true)
    base.Synergy.Build = function() error("boom") end
    open(base)
    local logged = {}
    for _, e in ipairs(base.LogRecent(50)) do logged[#logged + 1] = e.text end
    assert.matches("synergy build failed", table.concat(logged, "\n"))
    for _, l in ipairs(lines(base)) do assert.is_nil(l.text:find("ton Dépeçage", 1, true)) end
    local shown, today = {}, {}
    for i, l in ipairs(lines(base)) do shown[i] = l.text end
    local lone = start(false)                                         -- the Cuir tab of a character that does not skin
    open(lone)
    for i, l in ipairs(lines(lone)) do today[i] = l.text end
    assert.is_true(#shown > 0)                                        -- the tab still draws
    assert.are.same(today, shown)
  end)

  it("the Skinning tab says what its skins are for, above the zones", function()
    local ns = start(true)
    ns.char.jobProf = "Dépeçage"
    open(ns)
    local list = lines(ns)
    local head = find(list, "^Où monter")
    local feeds = find(list, "^Sert pour Travail du cuir : %d+ × Item%d+, %d+ × Item%d+")
    assert.is_not_nil(feeds)
    assert.are.equal(head + 1, feeds)                                 -- under the route head
  end)

  it("never changes the plan: the roadmap steps are the same with and without the hints", function()
    local function steps(skins, off)
      local ns = start(skins)
      if off then ns.Synergy.Build = function() error("off") end end
      ns.Window.Toggle(); ns.Window.SetTab("job")
      local res
      ns.RunLeveling(function(r) res = r end, true)
      for _ = 1, 20 do
        if res then break end
        local due = timers; timers = {}
        for _, fn in ipairs(due) do pcall(fn) end
      end
      local out = {}
      for _, p in ipairs(res.profs) do
        for _, s in ipairs(p.road and p.road.steps or {}) do
          local miss = {}
          for _, m in ipairs(s.missing or {}) do miss[#miss + 1] = m.item .. "x" .. m.n end
          out[#out + 1] = p.name .. ":" .. s.kind .. ":" .. tostring(s.rec and s.rec.id) .. ":" .. tostring(s.from) .. "-" .. tostring(s.to) .. ":" .. table.concat(miss, ",")
        end
      end
      return out, res
    end
    local on, res = steps(true, false)
    local off = steps(true, true)
    assert.are.same(off, on)
    assert.is_not_nil(res.synergy)
  end)
end)

describe("shopping list hints (Synergy.lua)", function()
  it("a row of the list gets the hint, and the note says where to farm first", function()
    local ns = start(true)
    ns.char.profs["Travail du cuir"].recipes[2161].mats = { { 2318, 6 }, { 2320, 2 } }
    local res
    ns.RunLeveling(function(r) res = r end, true)
    for _ = 1, 20 do
      if res then break end
      local due = timers; timers = {}
      for _, fn in ipairs(due) do pcall(fn) end
    end
    assert.are.equal("ok", res.state)
    local rows
    local list = ns.Shopping.Build(res.profs, { bag = function() return 0 end, bank = function() return 0 end,
      name = function(id) return "Item" .. id end, hint = res.synergy.hint })
    rows = list.rows
    local hinted
    for _, r in ipairs(rows) do if r.hint and not r.hint.rare and not hinted then hinted = r end end
    assert.is_not_nil(hinted)                                          -- 2318 is short: Light Leather comes from the beasts
    assert.are.equal(hinted.hint.zone, list.farm.zone)
    -- the frame: the sub line carries the short hint, the farm line sits above the rows
    ns.ShoppingList.Show()
    ns.ShoppingList.Feed(res)
    local texts = {}
    for _, row in ipairs(ns.ShoppingList.Rows()) do texts[#texts + 1] = plain(row.sub.text) end
    local joined = table.concat(texts, "\n")
    if hinted then assert.matches("ton Dépeçage · Zone%d+ · ~%d+ bêtes", joined) end
    assert.are.equal(list.farm ~= nil, plain(ns.ShoppingList.Frame().farm.text or ""):find("À farmer d'abord", 1, true) ~= nil)
  end)
end)
