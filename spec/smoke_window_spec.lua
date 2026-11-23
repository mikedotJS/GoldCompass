-- Smoke: window layout, coins and tooltip rows, scrollable lists.
local H = require("spec.helper_smoke")
local loadAddon = H.loadAddon
local printed, handlers, frames, timers
local function setup(opts)
  printed, handlers, frames, timers = {}, {}, {}, {}
  H.setup(opts, function() return printed, handlers, frames, timers end)
end

describe("window layout and drawing", function()
  local ORDER = { BACKGROUND = 1, BORDER = 2, ARTWORK = 3, OVERLAY = 4, HIGHLIGHT = 5 }
  local function overlap(a, b) return a.l < b.r and b.l < a.r and a.t < b.b and b.t < a.b end

  local function assertNoOverlap(groups, L)
    local all = {}
    for _, g in ipairs(groups) do
      for name, r in pairs(g) do
        assert.is_true(r.l >= L.frame.l and r.t >= L.frame.t and r.r <= L.frame.r and r.b <= L.frame.b, name .. " leaves the frame")
        all[#all + 1] = { name = name, r = r }
      end
    end
    for i = 1, #all do
      for j = i + 1, #all do
        assert.is_false(overlap(all[i].r, all[j].r), all[i].name .. " overlaps " .. all[j].name)
      end
    end
  end

  it("keeps every slot inside the frame and never over another, for each group that can be visible together", function()
    setup({})
    local L = loadAddon().Window.Layout
    assert.is_true(L.frame.r <= 460 and L.frame.b <= 520) -- about 460 wide, at most about 520 tall
    local controls = { levelBox = L.map.levelBox, profBtn = L.map.profBtn, toMap = L.map.toMap, note = L.map.note }
    assertNoOverlap({ L.common, L.map }, L)
    assertNoOverlap({ L.common, L.list }, L)
    assertNoOverlap({ L.common, L.job }, L)             -- Métier tab: checkbox, "Voir sans filtre" and the scroll area
    assertNoOverlap({ L.common, { tabs = L.job.tabs, goalLevel = L.job.goalLevel, goalGold = L.job.goalGold, goalLabel = L.job.goalLabel }, L.jobGold }, L)
    assertNoOverlap({ L.common, L.panel, controls }, L)
  end)

  it("keeps the lines and the scroll bar inside the scroll slot", function()
    setup({})
    local W = loadAddon().Window
    for _, slot in ipairs({ W.Layout.list.lines, W.Layout.job.lines, W.Layout.jobGold.lines }) do
      assert.is_true(W.LineWide.r + 20 <= slot.r - slot.l)       -- 20 px left for the scroll bar
      assert.is_true(W.LineParts.right.r <= W.LineWide.r)
    end
  end)

  it("keeps the parts of a row and of a list line apart and inside their slot", function()
    setup({})
    local W = loadAddon().Window
    local row = { l = 0, t = 0, r = 432, b = 30 }
    assertNoOverlap({ W.RowParts }, { frame = row })
    assertNoOverlap({ W.LineParts }, { frame = { l = 0, t = 0, r = 432, b = 17 } })
  end)

  it("fits the frame on screen whatever the UI scale makes of UIParent's size", function()
    setup({})
    local W = loadAddon().Window
    for _, size in ipairs({ { 1366, 768 }, { 1138, 640 }, { 1707, 960 }, { 800, 480 }, { 640, 400 } }) do
      -- UI scale 1.0, 1.2 and 0.8 on a 768 high screen give 768, 640 and 960; the smaller ones are small screens
      local s = W.FitScale(size[1], size[2])
      assert.is_true(s <= 1)
      assert.is_true(500 * s <= size[2] * 0.9 + 1e-9, "taller than the screen at " .. size[2])
      assert.is_true(460 * s <= size[1] * 0.9 + 1e-9)
    end
    assert.are.equal(1, W.FitScale(1366, 768))
  end)

  it("draws row decorations (selection, hover, bar) below every font string of the row", function()
    setup({ scanned = true })
    local ns = loadAddon()
    ns.db = {}
    ns.Window.Toggle()
    local rows = ns.Window.Rows()
    assert.are.equal(10, #rows)
    for _, row in ipairs(rows) do
      local textRank
      for _, child in ipairs(row.children) do
        if child.kind == "CreateFontString" then
          assert.are.equal("OVERLAY", child.layer)
          textRank = ORDER[child.layer]
        end
      end
      assert.is_not_nil(textRank)
      for _, tex in ipairs({ row.sel, row.hover, row.bar }) do
        assert.is_true(ORDER[tex.layer] < textRank, "decoration layer " .. tostring(tex.layer) .. " is not below the text")
      end
      assert.is_true(ORDER[row.hover.layer] < ORDER["HIGHLIGHT"]) -- not the HIGHLIGHT layer, which draws over the text
    end
  end)

  it("shows a clean figure and a separate price freshness, and builds the details tooltip", function()
    setup({ scanned = true })
    local ns = loadAddon()
    ns.db = {}
    ns.Window.Toggle()
    local row = ns.Window.Rows()[1]
    assert.matches("^~%d+s/h", row.gph.text)
    assert.matches("%(estimation%)", row.gph.text)
    assert.is_nil(row.gph.text:find("prix", 1, true))
    assert.matches("prix", row.age.text)
    assert.are.equal("prix d'aujourd'hui", ns.PriceAgeText(0))
    assert.are.equal("prix de 3 j", ns.PriceAgeText(3))
    assert.are.equal("âge du prix inconnu", ns.PriceAgeText(nil))
    local tip = table.concat(ns.Window.RowTooltipLines({ zone = 1411, name = "Durotar", spots = 100, maxAge = 1,
      detail = { { item = 2770, unit = 38 } } }), "\n")
    assert.matches("Durotar", tip)
    assert.matches("Item2770 : ~", tip)
    assert.matches("prix de 1 j", tip)
    assert.matches("60 points de récolte par heure, 2 objets chacun, taxe HV de 5 %%.", tip)
    -- skinning: a beast measured in game (20 skins or more) says so, a beast with fewer skins does not
    assert(loadfile("SkinLoot.lua"))("GoldCompass", ns)
    ns.db = { skinLoot = { [1] = { n = 25, d = 1, i = {} }, [2] = { n = 19, d = 1, i = {} } } }
    local beasts = { { 1, "Boar", 5, 6, 1, items = {} }, { 2, "Bear", 5, 5, 1, items = {} } }
    local lines = ns.Window.RowTooltipLines({ zone = 1411, name = "Durotar", spots = 100, beasts = beasts, detail = {} })
    assert.matches("Boar · niv%. 5%-6.*mesuré en jeu sur 25 dépeçages", lines[4])
    assert.is_nil(lines[5]:find("mesuré", 1, true))
  end)
end)

describe("coins, tooltip rows and spell data loading", function()
  it("formats every amount through one function: coin icons when the game has them, plain text otherwise", function()
    setup({ scanned = true })
    local ns = loadAddon()
    assert.are.equal("1g 24s", ns.Money(12449))                    -- no coin API: the plain formatter
    _G.GetCoinTextureString = function(c) return "[global " .. c .. "]" end
    assert.are.equal("[global 12400]", ns.Money(12449))            -- rounded to the silver, then icons
    _G.C_CurrencyInfo = { GetCoinTextureString = function(c) return "[currency " .. c .. "]" end }
    assert.are.equal("[currency 1230000]", ns.Money(1234567))      -- 123.4567g -> 123g
    assert.are.equal("[currency 40]", ns.Money(40))                -- under 1s: exact copper
    assert.are.equal("prix inconnu", ns.Money(0))
    _G.C_CurrencyInfo, _G.GetCoinTextureString = nil, nil
  end)

  it("uses coin icons in the per-hour figure and keeps it inside its slot", function()
    setup({ scanned = true })
    _G.GetCoinTextureString = function(c) return "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t" .. c end
    local ns = loadAddon()
    ns.db = {}
    ns.Window.Toggle()
    assert.matches("^~.*UI%-SilverIcon.*/h", ns.Window.Rows()[1].gph.text)
    -- the figure slot is wide enough for icons: at least 180 px, and still clear of the zone and bar slots
    local P = ns.Window.RowParts
    assert.is_true(P.gph.r - P.gph.l >= 180)
    assert.is_true(P.zone.r <= P.gph.l and P.sub.r <= P.gph.l)
    _G.GetCoinTextureString = nil
  end)

  it("puts each recipe and its result price on one row, the status on the line below", function()
    setup({ scanned = true, alchemy = true, noSpell = true })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {} }
    local doubles, singles = {}, {}
    GameTooltip.AddDoubleLine = function(_, l, r) doubles[#doubles + 1] = { l, r }; GameTooltip.lines[#GameTooltip.lines + 1] = l .. " | " .. r end
    GameTooltip.AddLine = function(_, t) singles[#singles + 1] = t; GameTooltip.lines[#GameTooltip.lines + 1] = t end
    handlers.item(GameTooltip, { id = 2449 })
    local recipeRows = 0
    for _, d in ipairs(doubles) do
      if d[1]:find("Elixir", 1, true) then
        recipeRows = recipeRows + 1
        assert.is_nil(d[1]:find("apprendre", 1, true)) -- no status in the left text
        assert.is_nil(d[1]:find("  ", 1, true))
      end
    end
    assert.is_true(recipeRows >= 1)
    local status = false
    for _, t in ipairs(singles) do status = status or t:find("^  .*apprendre") ~= nil end
    assert.is_true(status)
  end)

  it("asks for spell data once, keeps the English name meanwhile, and redraws on arrival for the same item only", function()
    setup({ scanned = true, alchemy = true, noSpell = true })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {} }
    local loaded, requests = {}, {}
    _G.C_Spell = {
      GetSpellName = function(id) return loaded[id] and ("Nom FR " .. id) or nil end,
      RequestLoadSpellData = function(id) requests[#requests + 1] = id end,
    }
    handlers.item(GameTooltip, { id = 2449 })
    local first = table.concat(GameTooltip.lines, "\n")
    assert.matches("Elixir of Minor Fortitude", first)         -- English fallback while the name is not cached
    local n = #requests
    assert.is_true(n >= 1)
    GameTooltip.lines = {}
    handlers.item(GameTooltip, { id = 2449 })
    assert.are.equal(n, #requests)                             -- once per spell, not per hover
    local function fire(event, id)
      for _, fr in ipairs(frames) do
        if fr.events and fr.events[event] then fr.scripts.OnEvent(fr, event, id) end
      end
    end
    local id = requests[1]
    loaded[id] = true
    fire("SPELL_DATA_LOAD_RESULT", id)
    assert.are.equal(1, GameTooltip.refreshed)                 -- the data arrived: redraw once
    fire("SPELL_DATA_LOAD_RESULT", id)
    assert.are.equal(1, GameTooltip.refreshed)                 -- not twice for the same spell
    GameTooltip.lines = {}
    handlers.item(GameTooltip, { id = 2449 })
    assert.matches("Nom FR " .. id, table.concat(GameTooltip.lines, "\n"))
    -- another item under the mouse: no redraw
    GameTooltip.lines = {}
    handlers.item(GameTooltip, { id = 2449 })
    local other = requests[#requests]
    _G.GetItemInfo = _G.GetItemInfo
    local shown = GameTooltip.refreshed
    GameTooltip.GetItem = function() return "Name", "|Hitem:9999::::|h[y]|h" end
    loaded[other] = true
    fire("SPELL_DATA_LOAD_RESULT", other)
    assert.are.equal(shown, GameTooltip.refreshed)
    _G.C_Spell = nil
  end)

  it("does not redraw for spell data in combat", function()
    setup({ scanned = true, alchemy = true, noSpell = true, combat = true })
    loadAddon()
    for _, fr in ipairs(frames) do
      if fr.events and fr.events.SPELL_DATA_LOAD_RESULT then fr.scripts.OnEvent(fr, "SPELL_DATA_LOAD_RESULT", 1) end
    end
    assert.are.equal(0, GameTooltip.refreshed)
  end)
end)

describe("scrollable lists (bags, here, Métier)", function()
  local function lineTexts(ns)
    local out = {}
    for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = (l.left.text or "") .. " " .. (l.right.text or "") end
    return table.concat(out, "\n")
  end
  local function filled(ns)
    local n = 0
    for _, l in ipairs(ns.Window.Lines()) do if (l.left.text or "") ~= "" or (l.right.text or "") ~= "" then n = n + 1 end end
    return n
  end
  -- 30 known recipes, so the tab has far more rows than the 19 lines that used to fit
  local function big()
    local recipes = {}
    for i = 1, 30 do recipes[i] = { id = i, name = "Recette " .. i, d = 0, out = 118, oq = 1, mats = { { 2447, i } } } end
    return { skill = 50, max = 75, recipes = recipes }
  end
  local function start(data)
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = data }, goal = "level" }
    ns.Window.recipesOpen = true                                       -- the known-recipes list is the long one
    ns.Window.Toggle(); ns.Window.SetTab("job")
    return ns
  end

  it("produces every row (no cap, no 'et N autres') and the scroll content grows with them", function()
    local few = start({ skill = 50, max = 75, recipes = { [1] = { id = 1, name = "Potion", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } } } })
    local fewHeight, fewRows = few.Window.ContentHeight(), filled(few)
    local ns = start(big())
    assert.is_true(filled(ns) > 19)                                   -- more than the old fixed pool
    assert.is_true(ns.Window.ContentHeight() > fewHeight)
    assert.are.equal(filled(ns) * 17, ns.Window.ContentHeight())      -- one 17 px line per row
    assert.are.equal(fewRows * 17, fewHeight)
    assert.is_nil(lineTexts(ns):find("autres", 1, true))
    for i = 1, 30 do assert.matches("Recette " .. i .. " ", lineTexts(ns) .. " ") end -- every known recipe is listed
    assert.matches("Recettes connues", lineTexts(ns))
  end)

  it("recycles lines: shrinking the list empties the leftover lines completely", function()
    local ns = start(big())
    local many = #ns.Window.Lines()
    ns.char.profs.Alchimie = { skill = 50, max = 75, recipes = { [1] = { id = 1, name = "Potion", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } } } }
    ns.Window.recipesOpen = false
    ns.Window.Refresh()
    local lines = ns.Window.Lines()
    assert.are.equal(many, #lines)                                    -- lines are kept, not destroyed
    local used = filled(ns)
    assert.is_true(used < many)
    for i = used + 1, #lines do
      assert.are.equal("", lines[i].left.text); assert.are.equal("", lines[i].right.text)
    end
  end)

  it("scrolls with the mouse wheel, three lines a notch, clamped to the content", function()
    local ns = start(big())
    local frame
    for _, fr in ipairs(frames) do if fr.scripts.OnMouseWheel then frame = fr end end
    assert.is_not_nil(frame)
    frame.vrange = 100
    frame.scripts.OnMouseWheel(frame, -1)
    assert.are.equal(51, frame.vscroll)                               -- 3 x 17
    frame.scripts.OnMouseWheel(frame, -1); frame.scripts.OnMouseWheel(frame, -1)
    assert.are.equal(100, frame.vscroll)                              -- clamped to the range
    frame.scripts.OnMouseWheel(frame, 1)
    assert.are.equal(49, frame.vscroll)
    frame.vscroll = 0
    frame.scripts.OnMouseWheel(frame, 1)
    assert.are.equal(0, frame.vscroll)                                -- never above the top
  end)

  it("uses the classic scroll template, and a plain scroll frame when the template is missing", function()
    local ns = start(big())
    assert.are.equal("UIPanelScrollFrameTemplate", ns.Window.ScrollKind())
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } } })
    local base = _G.CreateFrame
    _G.CreateFrame = function(kind, name, parent, template)
      if template == "UIPanelScrollFrameTemplate" then error("no such template") end
      return base(kind, name, parent, template)
    end
    ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = big() } }
    ns.Window.Toggle(); ns.Window.SetTab("job")
    assert.are.equal("plain ScrollFrame", ns.Window.ScrollKind())
    assert.is_true(filled(ns) > 19)
    local logged = {}
    for _, e in ipairs(ns.LogRecent(50)) do logged[#logged + 1] = e.text end
    assert.matches("scroll frame: plain ScrollFrame", table.concat(logged, "\n"))
  end)
end)
