-- Smoke: "Monter le metier" roadmap (effort, chances) and its hover tooltips.
local H = require("spec.helper_smoke")
local loadAddon = H.loadAddon
local printed, handlers, frames, timers
local function setup(opts)
  printed, handlers, frames, timers = {}, {}, {}, {}
  H.setup(opts, function() return printed, handlers, frames, timers end)
end

describe("Métier tab, 'Monter le métier': no AH resale note, the chance is exact when thresholds are known", function()
  it("says 'coûte' and never 'rentable seulement si tu revends à l'HV'; the estimate label only without thresholds", function()
    setup({ scanned = true, profs = { { 165, 75, "Travail du cuir", 150 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { goal = "level", learned = {}, profs = { ["Travail du cuir"] = { skill = 75, max = 150, recipes = {
      [2161] = { id = 2161, name = "Bottes", d = 0, out = 2309, oq = 1, mats = { { 2318, 6 }, { 2320, 2 } } } } } } }
    _G.GetLocale = function() return "frFR" end
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local due = timers; timers = {}
    for _, fn in ipairs(due) do pcall(fn) end
    local text = {}
    for _, l in ipairs(ns.Window.Lines()) do text[#text + 1] = ((l.left.text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    local all = table.concat(text, "\n")
    assert.matches("Ton parcours", all)
    assert.matches("Apprendre", all)                                                -- a recipe to learn is a step of the roadmap
    assert.matches("il te manque %d+ ×", all)
    for _, word in ipairs({ "coût", "rentable seulement", "prix HV", "estimation", "Presque", "Bientôt", "Prix manquant", "ingr." }) do
      assert.is_nil(all:find(word, 1, true), word)                                  -- the roadmap talks effort, not gold or estimates
    end
  end)
end)

describe("Monter le métier shows effort everywhere (owner's data, Horde)", function()
  local function plain(s) return ((s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
  local function render(goal, bag)
    setup({ scanned = true, faction = "Horde", counts = bag and { [2318] = 10, [2320] = 10, [2308] = 10, [2309] = 10 } or nil,
      profs = { { 165, 61, "Travail du cuir", 75 }, { 185, 124, "Cuisine", 150 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = {}, onlyBag = bag or false, goal = goal }
    for _, p in ipairs(dofile("spec/fixtures/owner_profiles.lua")) do
      local recipes = {}
      for _, id in ipairs(p.known) do recipes[id] = { id = id, name = "r" .. id, d = 2, out = 2302, oq = 1, mats = { { 2318, 1 } } } end
      ns.char.profs[p.name] = { skill = p.skill, max = p.skill > 100 and 150 or 75, recipes = recipes }
    end
    _G.GetLocale = function() return "frFR" end
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local due = timers; timers = {}
    for _, fn in ipairs(due) do pcall(fn) end
    return ns
  end

  it("no gold wording or coin icon in any line, except the learning price on a dim detail line", function()
    for _, bag in ipairs({ false, true }) do
      local ns = render("level", bag)
      for _, l in ipairs(allJobLines(ns)) do
        local left, right = plain(l.left.text), plain(l.right.text)
        for _, word in ipairs({ "rapporte", "coût", "coûte" }) do
          assert.is_nil(left:find(word, 1, true), word .. " in: " .. left)
          assert.is_nil(right:find(word, 1, true), word .. " in: " .. right)
        end
        assert.is_nil((l.right.text or ""):find("Interface\\", 1, true), "coin icon in the figure: " .. tostring(l.right.text))
      end
    end
  end)

  it("the roadmap has none of the removed wording, hides the bag checkbox, and the known recipes open on demand", function()
    local ns = render("level", true)
    local function text()
      local out = {}
      for _, l in ipairs(allJobLines(ns)) do out[#out + 1] = plain(l.lv and l.lv.text) .. " " .. plain(l.left.text) .. " " .. plain(l.right.text) end
      return table.concat(out, "\n")
    end
    assert.matches("Ton parcours", text())
    for _, word in ipairs({ "Presque", "Bientôt", "Réservé à l'Alliance", "Prix manquant", "estimation", "Meilleure à apprendre", "te ferait passer", "ingr." }) do
      assert.is_nil(text():find(word, 1, true), word)
    end
    assert.is_false(ns.Window.IsBagBoxShown())
    assert.matches("rochaine étape : rang", plain(select(2, allJobLines(ns))))
    assert.is_nil(text():find("Recettes connues", 1, true))                    -- collapsed by default
    ns.Window.recipesOpen = true
    ns.Window.SetTab("job")
    for _, fn in ipairs(timers) do pcall(fn) end
    assert.matches("Recettes connues", text())
  end)

  it("every profession has its own rank step or rank line", function()
    local ns = render("level", true)
    local all = {}
    for _, l in ipairs(allJobLines(ns)) do all[#all + 1] = plain(l.lv and l.lv.text) .. " " .. plain(l.left.text) end
    local text = table.concat(all, "\n")
    assert.matches("Cuisine  124/150\n[^\n]*\n[^\n]*", text)
    assert.matches("141 Apprendre le rang Expert", text)                      -- Cooking 124: the rank is a step of its own roadmap, with the recipe learned at the same trainer
    assert.matches("Apprendre le rang Compagnon", text)                       -- Leatherworking 61 >= 50: the rank is the first step
    local first = text:find("Apprendre le rang Compagnon", 1, true)
    assert.is_true(first < (text:find("Ton parcours", 1, true) or 0) + 60)
  end)

  it("shows one profession at a time, chosen with a tab per profession (like the mockup)", function()
    local ns = render("level", false)
    local labels = {}
    for _, b in ipairs(ns.Window.ProfTabs()) do if b:IsShown() then labels[#labels + 1] = b.label.text end end
    assert.are.same({ "Cuir 61", "Cuisine 124" }, labels)
    local function heads()
      local n, name = 0, nil
      for _, l in ipairs(ns.Window.Lines()) do
        local t = plain(l.left.text)
        if t:match("^%S.-  %d+/%d+$") then n, name = n + 1, t end
      end
      return n, name
    end
    local n, name = heads()
    assert.are.equal(1, n); assert.are.equal("Travail du cuir  61/75", name)
    ns.Window.ProfTabs()[2].scripts.OnClick(ns.Window.ProfTabs()[2])
    n, name = heads()
    assert.are.equal(1, n); assert.are.equal("Cuisine  124/150", name)
    assert.are.equal("Cuisine", ns.char.jobProf)
  end)

  it("gold mode keeps its gold wording", function()
    local ns = render("gold", false)
    local all = {}
    for _, l in ipairs(allJobLines(ns)) do all[#all + 1] = plain(l.left.text) .. " " .. plain(l.right.text) end
    assert.matches("par fabrication", table.concat(all, "\n"))
  end)

  it("the best recipe to learn follows the effort rule: nothing in the learn lists has fewer ingredients per point within the 15 % window with a better chance", function()
    local ns = render("level", false)
    local res
    ns.RunLeveling(function(r) res = r end)
    for _, p in ipairs(res.profs) do
      local lr = p.learn
      if lr and lr.best then
        local lean = math.huge
        for _, e in ipairs(lr.now) do
          if e.recommend and not e.unpriced and e.rankGated == lr.best.rankGated and e.priceKnown == lr.best.priceKnown then lean = math.min(lean, e.unitsPerPoint or math.huge) end
        end
        assert.is_true(lr.best.unitsPerPoint <= lean * 1.15 + 1e-9, p.name)
      end
    end
  end)
end)

describe("roadmap hover tooltips (comment l'obtenir)", function()
  local alchemy = { skill = 50, max = 75, recipes = {
    [1] = { id = 1, name = "Potion de soins", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } },
  } }
  local tooltip
  local function start(opts)
    setup(opts or { scanned = true, counts = {}, profs = { { 171, 50, "Alchimie", 75 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = alchemy }, goal = "level" }
    tooltip = { lines = {} }
    local T = _G.GameTooltip
    T.SetOwner = function(_, owner, anchor) tooltip = { owner = owner, anchor = anchor, lines = {} } end
    T.ClearAllPoints = function() end
    T.SetPoint = function(_, point, rel, relPoint) tooltip.point = { point, rel, relPoint } end
    T.SetText = function(_, t) tooltip.title = t end
    T.AddLine = function(_, t) tooltip.lines[#tooltip.lines + 1] = t end
    T.AddDoubleLine = function(_, l, r) tooltip.lines[#tooltip.lines + 1] = l .. " | " .. r end
    T.Show = function() tooltip.shown = true end
    T.Hide = function() tooltip.shown = false end
    ns.ReagentSources = { [2447] = { vendors = { { 77, "Marchand Test", 1411, 41.5, 22.5, "AH", 20, forever = true } } } }
    ns.Window.Toggle(); ns.Window.SetTab("job")
    return ns
  end
  local function rowWith(ns, pattern)
    for _, l in ipairs(ns.Window.Lines()) do
      if l.row and l.row.shown and (l.left.text or ""):find(pattern) then return l.row end
    end
  end

  it("a missing reagent has its own row with a tooltip button, anchored to the right of the row", function()
    local ns = start()
    local row = rowWith(ns, "il te manque %d+ ×")
    assert.is_not_nil(row)
    row.scripts.OnEnter(row)
    assert.are.equal(row, tooltip.owner)
    assert.are.equal("ANCHOR_NONE", tooltip.anchor)
    assert.are.same({ "TOPLEFT", row, "TOPRIGHT" }, tooltip.point)      -- right of the row, top aligned
    assert.are.equal("Item2447", tooltip.title)
    local text = table.concat(tooltip.lines, "\n")
    assert.matches("Il t'en manque", text)
    assert.matches("Chez un marchand", text)
    assert.matches("Marchand Test", text)
    assert.matches("Clic : repère sur le marchand le plus proche", text)
    assert.is_true(tooltip.shown)
    row.scripts.OnLeave(row)
    assert.is_false(tooltip.shown)
  end)

  it("a click on the row pins the best place with the existing pin code", function()
    local ns = start()
    local row = rowWith(ns, "il te manque %d+ ×")
    printed = {}
    row.scripts.OnEnter(row)
    row.scripts.OnClick(row)
    local chat = table.concat(printed, "\n")
    assert.matches("Marchand Test", chat)
    assert.matches("41%.5", chat)
  end)

  it("an item the game has not cached shows 'chargement...' and is redrawn when GET_ITEM_INFO_RECEIVED says it arrived", function()
    local ns = start()
    local row = rowWith(ns, "il te manque %d+ ×")
    _G.GetItemInfo = function() return nil end
    row.scripts.OnEnter(row)
    assert.are.equal("chargement...", tooltip.title)
    local receiver
    for _, fr in ipairs(frames) do if fr.events and fr.events.GET_ITEM_INFO_RECEIVED then receiver = fr end end
    assert.is_not_nil(receiver)
    _G.GetItemInfo = function(id) return "Pâlerette" .. id end
    receiver.scripts.OnEvent(receiver, "GET_ITEM_INFO_RECEIVED", 999)   -- another item: nothing changes
    assert.are.equal("chargement...", tooltip.title)
    receiver.scripts.OnEvent(receiver, "GET_ITEM_INFO_RECEIVED", 2447)
    assert.are.equal("Pâlerette2447", tooltip.title)
    row.scripts.OnLeave(row)
    receiver.scripts.OnEvent(receiver, "GET_ITEM_INFO_RECEIVED", 2447)   -- the mouse left: no tooltip comes back
    assert.is_false(tooltip.shown)
  end)

  it("a rank step has a tooltip on both of its rows, and rows without anything to say have no tooltip button", function()
    local ns = start()
    local rank = rowWith(ns, "Apprendre le rang")
    assert.is_not_nil(rank)
    rank.scripts.OnEnter(rank)
    assert.matches("Rang Compagnon", tooltip.title)
    for _, l in ipairs(ns.Window.Lines()) do
      if l.row and l.row.shown then assert.is_not_nil(l.row.tip) end
    end
    local title
    for _, l in ipairs(ns.Window.Lines()) do if (l.left.text or ""):find("Ton parcours", 1, true) then title = l end end
    assert.is_false(title.row.shown)
  end)
end)
