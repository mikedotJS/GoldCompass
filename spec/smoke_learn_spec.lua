-- Smoke: recipes to learn, "Ou l'apprendre" map button, "Fabriquer" craft button.
local H = require("spec.helper_smoke")
local loadAddon = H.loadAddon
local printed, handlers, frames, timers
local function setup(opts)
  printed, handlers, frames, timers = {}, {}, {}, {}
  H.setup(opts, function() return printed, handlers, frames, timers end)
end

describe("recipes to learn without prices, footer and line slots", function()
  local function lineTexts(ns)
    local out = {}
    for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = (l.left.text or "") .. " " .. (l.right.text or "") end
    return table.concat(out, "\n")
  end
  local alchemy = { skill = 50, max = 75, recipes = {
    [1] = { id = 1, name = "Potion de soins", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } } } }
  local function start(opts)
    opts.scanned, opts.profs = true, { { 171, 50, "Alchimie", 75 } }
    setup(opts)
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = alchemy } }
    return ns
  end

  it("shows recipes to learn with 'prix inconnu' and the way to get prices, instead of dropping them", function()
    local ns = start({ pickupNoAh = true, noVendor = true })   -- no AH price, no vendor value for most reagents
    local res
    ns.RunLeveling(function(r) res = r end)
    local lr = res.profs[1].learn
    assert.is_true(lr.unpriced > 0)
    assert.is_true(#lr.now + #lr.soon > 0)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local text = lineTexts(ns)
    assert.matches("prix inconnu", text)
    assert.matches("lance un scan Auctionator", text)
    assert.is_nil(text:match("sans prix pour leurs composants"))
  end)

  it("values reagents without AH price at their vendor sell value (a floor), and levelling shows ingredients, not a gold figure", function()
    local ns = start({ pickupNoAh = true })                    -- vendor sell value 25 for every item
    ns.char.goal = "level"
    local res
    ns.RunLeveling(function(r) res = r end)
    local found
    for _, e in ipairs(res.profs[1].learn.now) do if e.floor then found = true end end
    assert.is_true(found)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    assert.is_nil(lineTexts(ns):find("dès ~", 1, true))          -- levelling: no gold figure, no per-point figure
    assert.is_nil(lineTexts(ns):find("ingr%./pt"))
    assert.matches("Ton parcours", lineTexts(ns))
  end)

  it("keeps the footer within two lines of the footer slot (character budget), with and without the bag filter", function()
    -- the slot shows about 83 characters per line at the real font (photo): two lines = at most 160 here
    local ns = start({})
    assert.is_true(#ns.Window.JobFooter(false) <= 160)
    assert.is_true(#ns.Window.JobFooter(true) <= 160)
  end)

  it("draws every line of the tab on its own single-line slot: no wrapping text, no shared slot", function()
    local ns = start({ counts = { [2447] = 1 } })
    ns.char.onlyBag = true
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local slots = ns.Window.Layout.list.lines
    local used = 0
    for _, l in ipairs(ns.Window.Lines()) do
      local t = (l.left.text or "")
      assert.is_nil(t:find("\n"))                              -- a line never contains a line break
      if t ~= "" then used = used + 1 end
    end
    assert.is_true(used > 0)
    assert.is_true(used <= math.floor((slots.b - slots.t) / 17))
  end)
end)

describe("empty states of the recipes to learn say the real reason", function()
  local function lineTexts(ns)
    local out = {}
    for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = (l.left.text or "") .. " " .. (l.right.text or "") end
    return table.concat(out, "\n")
  end
  local function show(learn, filtered)
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, onlyBag = filtered, profs = { Alchimie = { skill = 50, max = 75, recipes = {
      [1] = { id = 1, name = "Potion", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } } } } } }
    ns.LearnFor = function() return learn end
    ns.Window.Toggle(); ns.Window.SetTab("job")
    return lineTexts(ns)
  end
  local function lr(t) return setmetatable(t, { __index = { now = {}, soon = {}, candidates = 0, unpriced = 0, nowTotal = 0, soonTotal = 0 } }) end

  it("nothing to learn", function()
    assert.matches("Aucune recette à apprendre pour ce métier", show(lr({})))
  end)
  it("everything in reach is gray", function()
    local grayRow = { gray = true, name = "Potion grise", chance = 0, rec = { id = 5, name = "Potion grise", learn = 10, d = 3 } }
    local text = show(lr({ nowTotal = 4, gray = { grayRow } }))
    assert.matches("ne font plus monter le métier", text)
    assert.matches("Déjà grises à ton niveau", text)             -- the gray recipes are listed, never ranked
    assert.matches("Potion grise", text)
    assert.is_nil(text:match("Aucune recette à apprendre"))
  end)
  it("hidden by the bag filter", function()
    local text = show(lr({ nowTotal = 4, candidates = 2 }), true)
    assert.matches("cache les recettes à apprendre", text)
    assert.is_nil(text:match("Aucune recette à apprendre"))
  end)
end)

describe("Où l'apprendre (map button on recipes to learn)", function()
  local alchemy = { skill = 50, max = 75, recipes = {
    [1] = { id = 1, name = "Potion de soins", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } } } }
  local function start()
    setup({ scanned = true, profs = { { 171, 50, "Alchimie", 75 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = alchemy } }
    ns.Window.Toggle(); ns.Window.SetTab("job")
    return ns
  end
  local function goButtons()
    local out = {}
    for _, fr in ipairs(frames) do if fr.target and fr.shown then out[#out + 1] = fr end end
    return out
  end
  local pin = { name = "Mallory", zone = "Elwynn Forest", mapID = 1429, x = 32.8, y = 49 }

  it("puts a button with a target on rows to learn (and on the best one), nothing on the other rows", function()
    local ns = start()
    local res
    ns.RunLeveling(function(r) res = r end)
    local lr = res.profs[1].learn
    assert.is_true(#lr.now > 0)
    for _, row in ipairs(lr.now) do assert.is_table(row.target) end
    local buttons = goButtons()
    assert.is_true(#buttons >= #lr.now)                      -- best line + rows (+ soon rows)
    local pins = 0
    for _, b in ipairs(buttons) do if b.target.mapID then pins = pins + 1 end end
    assert.is_true(pins > 0)
    -- a recycled line shows no button when its new content has no target
    ns.char.onlyBag = true
    _G.C_Item.GetItemCount = function() return 0 end
    ns.Window.Refresh()
    assert.are.equal(0, #goButtons())                         -- bag filter on, nothing carried: no learn rows left
  end)

  it("pins the NPC with a user waypoint, super tracks it and opens the map (out of combat)", function()
    local ns = start()
    local calls = {}
    _G.UiMapPoint = { CreateFromCoordinates = function(map, x, y) return { map = map, x = x, y = y } end }
    _G.C_Map.SetUserWaypoint = function(p) calls.pin = p end
    _G.C_Map.OpenWorldMap = function(id) calls.open = id end
    _G.C_SuperTrack = { SetSuperTrackedUserWaypoint = function(on) calls.track = on end }
    ns.Window.GoTo(pin)
    assert.are.equal(1429, calls.pin.map)
    assert.is_near(0.328, calls.pin.x, 1e-9); assert.is_near(0.49, calls.pin.y, 1e-9)   -- percentages become 0..1
    assert.is_true(calls.track)
    assert.are.equal(1429, calls.open)
    assert.matches("Repère posé : Mallory", table.concat(printed, "\n"))
  end)

  it("pins a pfQuest NPC that has no zone name (spec/helper_wow_lua51.lua makes %s with nil raise, as in WoW)", function()
    local ns = start()
    local calls = {}
    _G.UiMapPoint = { CreateFromCoordinates = function(map, x, y) return { map = map, x = x, y = y } end }
    _G.C_Map.SetUserWaypoint = function(p) calls.pin = p end
    _G.C_Map.OpenWorldMap = function(id) calls.open = id end
    _G.C_Map.GetMapInfo = function() return nil end
    local ok, err = pcall(ns.Window.GoTo, { name = "Naal Mistrunner", mapID = 1412, x = 40.2, y = 27.5, kind = "pin" }, "Poisson-chat")
    assert.is_true(ok, tostring(err))
    assert.are.equal(1412, calls.pin.map); assert.are.equal(1412, calls.open)
    assert.matches("Naal Mistrunner", table.concat(printed, "\n"))
  end)

  it("in combat only writes the place in the chat: no pin, no map", function()
    local ns = start()
    local calls = {}
    _G.UiMapPoint = { CreateFromCoordinates = function() return {} end }
    _G.C_Map.SetUserWaypoint = function() calls.pin = true end
    _G.C_Map.OpenWorldMap = function() calls.open = true end
    _G.InCombatLockdown = function() return true end
    ns.Window.GoTo(pin)
    assert.is_nil(calls.pin); assert.is_nil(calls.open)
    assert.matches("Indisponible en combat : Mallory", table.concat(printed, "\n"))
  end)

  it("without SetUserWaypoint opens the map on the zone and prints the coordinates", function()
    local ns = start()
    local opened
    _G.C_Map.SetUserWaypoint = nil
    _G.C_Map.OpenWorldMap = function(id) opened = id end
    ns.Window.GoTo(pin)
    assert.are.equal(1429, opened)
    assert.matches("32.8, 49.0%) : repère indisponible", table.concat(printed, "\n"))
  end)

  it("with only a text: prints it with 'lieu non précis', opens nothing", function()
    local ns = start()
    local opened
    _G.C_Map.OpenWorldMap = function() opened = true end
    ns.Window.GoTo({ text = "World drop (level 15-25)" })
    ns.Window.GoTo({})
    assert.is_nil(opened)
    local chat = table.concat(printed, "\n")
    assert.matches("World drop %(level 15%-25%)", chat)
    assert.matches("lieu non précis", chat)
  end)

  it("builds the tooltip: NPC, zone (client language when known), coordinates, and the real source (no 'Données Classic')", function()
    local ns = start()
    _G.C_Map.GetMapInfo = function() return { name = "Forêt d'Elwynn" } end
    local function tip(t) return table.concat(ns.Window.TargetTooltipLines(t), "\n") end
    local base = { name = "Mallory", zone = "Elwynn Forest", mapID = 1429, x = 32.8, y = 49, kind = "pin" }
    local function with(source) local t = {}; for k, v in pairs(base) do t[k] = v end; t.source = source; return t end
    assert.matches("Mallory", tip(with("pfquest")))
    assert.matches("Forêt d'Elwynn : 32.8, 49.0", tip(with("pfquest")))
    assert.matches("Source : pfQuest %(positions Classic%)%.", tip(with("pfquest")))
    assert.matches("Source : observé en jeu%.", tip(with("recorded")))
    assert.matches("Source : wowforever%.be%.", tip({ kind = "zone", mapID = 1411, name = "Vayn", zone = "Durotar", source = "site", vendors = { { name = "Vayn", zone = "Durotar", mapID = 1411 } } }))
    for _, src in ipairs({ "pfquest", "recorded", "site", "classic" }) do
      assert.is_nil(tip(with(src)):find("Données Classic", 1, true)); assert.is_nil(tip(with(src)):find("à vérifier", 1, true))
    end
    local textual = tip({ text = "World drop" })
    assert.matches("World drop", textual); assert.matches("Lieu non précis", textual)
    assert.is_nil(textual:find("Classic", 1, true))
  end)

  it("clicking the button of a row calls GoTo with that row's target", function()
    local ns = start()
    local seen
    local real = ns.Window.GoTo
    ns.Window.GoTo = function(t) seen = t end
    local b
    for _, fr in ipairs(goButtons()) do b = b or fr end
    assert.is_not_nil(b)
    b.scripts.OnClick(b)
    assert.are.equal(b.target, seen)
    ns.Window.GoTo = real
  end)
end)

describe("Fabriquer (craft button on the recommended recipe)", function()
  local alchemy = { skill = 50, max = 75, recipes = {
    [1] = { id = 1, name = "Potion de soins", d = 0, out = 118, oq = 1, mats = { { 2447, 2 } } } } }
  local calls
  local function start(opts, tradeskill)
    opts = opts or {}
    opts.scanned, opts.profs = true, { { 171, 50, "Alchimie", 75 } }
    if opts.noSpell == nil then opts.noSpell = true end       -- the game knows only the recipe of the window
    setup(opts)
    calls = { craft = {}, open = {} }
    _G.C_TradeSkillUI = {
      CraftRecipe = function(id, n) calls.craft[#calls.craft + 1] = { id, n } end,
      OpenTradeSkill = function(line) calls.open[#calls.open + 1] = line end,
    }
    for k, v in pairs(tradeskill or {}) do _G.C_TradeSkillUI[k] = v end
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Alchimie = alchemy }, goal = "level" }   -- the roadmap carries the craft buttons
    ns.Window.Toggle(); ns.Window.SetTab("job")
    return ns
  end
  local function craftButton()
    for _, fr in ipairs(frames) do if fr.entry and fr.label and fr.shown then return fr end end
  end
  local function fire(event, ...)
    for _, fr in ipairs(frames) do
      if fr.events and fr.events[event] and fr.scripts.OnEvent and fr.events.UNIT_SPELLCAST_START then fr.scripts.OnEvent(fr, event, ...) end
    end
  end
  local openAlchemy = { IsTradeSkillReady = function() return true end,
    GetBaseProfessionInfo = function() return { professionName = "Alchimie", professionID = 171 } end }

  it("asks for the window first: 'Ouvrir <métier>', and opens it through OpenTradeSkill", function()
    local ns = start()
    local b = craftButton()
    assert.are.equal("Ouvrir Alchimie", b.label.text)
    assert.are.equal(2, b.entry.times)                       -- 4 carried, 2 needed each
    b.scripts.OnClick(b)
    assert.are.same({ 171 }, calls.open)
    assert.are.equal(0, #calls.craft)
    assert.matches("Ouverture de Alchimie", table.concat(printed, "\n"))
    assert.is_not_nil(ns)
  end)

  it("tells the user to open the window by hand when OpenTradeSkill does not exist or fails", function()
    local ns = start({}, { OpenTradeSkill = false })
    _G.C_TradeSkillUI.OpenTradeSkill = nil
    ns.Window.UpdateCraft()
    local b = craftButton()
    assert.matches("à la main", ns.Window.CraftState(b.entry).reason)
    b.scripts.OnClick(b)
    assert.matches("Impossible d'ouvrir Alchimie", table.concat(printed, "\n"))
    _G.C_TradeSkillUI.OpenTradeSkill = function() error("blocked") end
    printed = {}
    b.scripts.OnClick(b)
    assert.matches("Impossible d'ouvrir Alchimie", table.concat(printed, "\n"))
  end)

  it("crafts with the recipe id and the count the bags allow when the matching window is open", function()
    local ns = start({}, openAlchemy)
    local b = craftButton()
    assert.are.equal("Fabriquer ×2", b.label.text)
    b.scripts.OnClick(b)
    assert.are.same({ { 1, 2 } }, calls.craft)               -- CraftRecipe(recipeID, N)
    assert.are.equal("Fabrication en cours...", b.label.text)
    assert.is_false(b.enabled ~= false and ns.Window.CraftState(b.entry).enabled)
    b.scripts.OnClick(b)                                     -- a second click while busy does nothing
    assert.are.equal(1, #calls.craft)
  end)

  it("does not treat another profession's window as the right one", function()
    start({}, { IsTradeSkillReady = function() return true end,
      GetBaseProfessionInfo = function() return { professionName = "Forge", professionID = 164 } end })
    assert.are.equal("Ouvrir Alchimie", craftButton().label.text)
  end)

  it("ignores linked and guild windows, and a window that is not ready", function()
    start({}, { IsTradeSkillReady = function() return false end,
      GetBaseProfessionInfo = function() return { professionName = "Alchimie", professionID = 171 } end })
    assert.are.equal("Ouvrir Alchimie", craftButton().label.text)
    local ns = start({}, { IsTradeSkillReady = function() return true end, IsTradeSkillLinked = function() return true end,
      GetBaseProfessionInfo = function() return { professionName = "Alchimie", professionID = 171 } end })
    assert.is_nil(ns.OpenTradeSkill())
  end)

  it("is disabled with a reason in combat, and when nothing can be crafted", function()
    local ns = start({ combat = true }, openAlchemy)
    local st = ns.Window.CraftState(craftButton().entry)
    assert.is_false(st.enabled); assert.are.equal("Indisponible en combat.", st.reason)
    craftButton().scripts.OnClick(craftButton())
    assert.are.equal(0, #calls.craft)
    -- an empty bag: no step can be crafted now, so the roadmap offers no button, only what is missing
    ns = start({ counts = {} }, openAlchemy)
    assert.is_nil(craftButton())
    local all = {}
    for _, l in ipairs(ns.Window.Lines()) do all[#all + 1] = l.left.text or "" end
    assert.matches("il te manque", table.concat(all, "\n"))
  end)

  it("reports a failed CraftRecipe and stays usable", function()
    local ns = start({}, openAlchemy)
    _G.C_TradeSkillUI.CraftRecipe = function() error("blocked") end
    local b = craftButton()
    b.scripts.OnClick(b)
    assert.matches("Fabrication impossible", table.concat(printed, "\n"))
    assert.is_true(ns.Window.CraftState(b.entry).enabled)
  end)

  it("is disabled while the player casts, then released with the counts refreshed (no redraw in combat)", function()
    local ns = start({}, openAlchemy)
    local runs, real = 0, ns.RunLeveling
    ns.RunLeveling = function(...) runs = runs + 1; return real(...) end
    local recipe = craftButton().entry.id
    fire("UNIT_SPELLCAST_START", "player", "guid", recipe)
    local b = craftButton()
    assert.is_false(ns.Window.CraftState(b.entry).enabled)
    assert.are.equal("Fabrication en cours...", b.label.text)
    fire("UNIT_SPELLCAST_START", "someone", "guid", recipe)  -- other units are ignored (start already seen: still busy)
    timers = {}
    fire("UNIT_SPELLCAST_STOP", "player", "guid", recipe)
    for _, fn in ipairs(timers) do fn() end                  -- the release debounce, then the throttled refresh
    for _, fn in ipairs(timers) do fn() end
    assert.is_true(ns.Window.CraftState(craftButton().entry).enabled)
    assert.is_true(runs >= 1)                                -- quantities redrawn
  end)

  it("a cast that is not a craft (Hearthstone, mount) never disables the button nor redraws the tab", function()
    local ns = start({}, openAlchemy)
    local runs, real = 0, ns.RunLeveling
    ns.RunLeveling = function(...) runs = runs + 1; return real(...) end
    timers = {}
    for _, event in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_SUCCEEDED" }) do fire(event, "player", "guid", 8690) end
    assert.is_true(ns.Window.CraftState(craftButton().entry).enabled)
    for _, fn in ipairs(timers) do fn() end
    assert.are.equal(0, runs); assert.are.equal(0, #timers)
    assert.is_false(ns.Window.IsCraftSpell(nil))
    -- the recipe handed to CraftRecipe counts, even when the character has not recorded it
    ns.Window.Craft(craftButton().entry)
    assert.is_true(ns.Window.IsCraftSpell(craftButton().entry.id))
  end)

  it("a cast of another unit alone never disables the button", function()
    local ns = start({}, openAlchemy)
    fire("UNIT_SPELLCAST_START", "target")
    assert.is_true(ns.Window.CraftState(craftButton().entry).enabled)
  end)

  it("follows the window opening: TRADE_SKILL_SHOW turns 'Ouvrir' into 'Fabriquer'", function()
    local ready = false
    local ns = start({}, { IsTradeSkillReady = function() return ready end,
      GetBaseProfessionInfo = function() return { professionName = "Alchimie", professionID = 171 } end })
    assert.are.equal("Ouvrir Alchimie", craftButton().label.text)
    ready = true
    for _, fr in ipairs(frames) do
      if fr.events and fr.events.TRADE_SKILL_SHOW and fr.events.UNIT_SPELLCAST_START then fr.scripts.OnEvent(fr, "TRADE_SKILL_SHOW") end
    end
    assert.are.equal("Fabriquer ×2", craftButton().label.text)
    assert.is_not_nil(ns)
  end)

  it("S8 spike line lists the APIs", function()
    local ns = start({}, openAlchemy)
    SlashCmdList.GOLDCOMPASS("spike")
    assert.matches("S8 APIs: C_Map.SetUserWaypoint.*CraftRecipe true.*OpenTradeSkill true.*IsTradeSkillReady true", table.concat(printed, "\n"))
  end)
end)

describe("recipes to learn (stubbed recipe data)", function()
  local function lineTexts(ns)
    local out = {}
    for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = (l.left.text or "") .. " " .. (l.right.text or "") end
    return table.concat(out, "\n")
  end
  local cuir = { skill = 61, max = 75, recipes = {
    [2149] = { id = 2149, name = "Bottes en cuir cousu main", d = 2, out = 2302, oq = 1, mats = { { 2318, 2 } } } } }
  local function start(opts)
    opts = opts or {}
    opts.scanned, opts.profs = true, { { 165, 61, "Travail du cuir", 75 } }
    if opts.stubLib == nil then opts.stubLib = true end
    setup(opts)
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { ["Travail du cuir"] = cuir } }
    return ns
  end

  it("Fine Leather Boots (drop) is listed as a drop, never as a trainer recipe, never recommended", function()
    local ns = start({ libOverrides = { skill = { [2158] = 60 }, sources = { [2158] = { drop = { { id = 2, name = "Mob" }, total = 951 } } } } })
    local res
    ns.RunLeveling(function(r) res = r end)
    local lr = res.profs[1].learn
    local fine
    for _, bucket in ipairs({ lr.now, lr.soon, lr.gray }) do for _, e in ipairs(bucket) do if e.rec.id == 2158 then fine = e end end end
    assert.is_not_nil(fine)
    assert.are.equal("d", fine.rec.src)
    assert.is_false(fine.recommend)
    if lr.best then assert.are_not.equal(2158, lr.best.rec.id) end
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local line
    local all = ns.Window.Lines()
    for i, l in ipairs(all) do if (l.left.text or ""):find("Fine Leather Boots", 1, true) then line = l.left.text .. " " .. (all[i + 1].left.text or "") end end   -- name line + detail line
    assert.is_not_nil(line)
    assert.matches("butin", line)
    assert.is_nil(line:find("entraîneur", 1, true))
  end)

  it("Forever table: a trainer recipe shows its real fee and no 'non confirmé'; a trainer source absent from the table is dropped", function()
    local ns = start({ libOverrides = { borrowed = { ["9062requiredSkill"] = "Vanilla" } } })
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local text = lineTexts(ns)
    assert.matches("Small Leather Ammo Pouch.-entraîneur · ", text)       -- 9062 (Small Leather Ammo Pouch) is in the table: 1s
    assert.is_nil(text:find("non confirmé", 1, true))
    local res
    ns.RunLeveling(function(r) res = r end)
    local lr = res.profs[1].learn
    for _, bucket in ipairs({ lr.now, lr.soon, lr.gray }) do
      for _, e in ipairs(bucket) do
        if e.rec.id == 2158 then assert.is_not.equal("trainer", e.rec.way.kind) end   -- Fine Leather Boots: no trainer on Forever
      end
    end
  end)

  it("unconfirmed trainer sources are labelled as such on the recommended line", function()
    local ns = start({ libOverrides = { borrowed = {} } })
    local res
    ns.RunLeveling(function(r) res = r end)
    local best = res.profs[1].learn.best
    assert.is_not_nil(best)
    -- a trainer recipe whose required skill is borrowed from Vanilla: "(non confirmé sur Forever)"
    assert.are.equal("entraîneur (non confirmé sur Forever)", ns.Fmt.Source({ src = nil, way = { kind = "trainer", confirmed = false } }, true))
    assert.are.equal("entraîneur", ns.Fmt.Source({ src = nil, way = { kind = "trainer", confirmed = true } }, true))
    assert.are.equal("objet d'apprentissage : Cuir", ns.Fmt.Source({ src = "i", itemName = "Cuir" }, true))
  end)

  it("/gc spike reports the vendored data: version, build, counts and the recipes of each profession", function()
    local ns = start({ stubLib = false })     -- the real vendored data
    ns.db = { buy = {} }
    SlashCmdList.GOLDCOMPASS("spike")
    local chat = table.concat(printed, "\n")
    assert.matches("S10 Forever recipe data %(LibProfessionDB v1%.10%.1%), build 1%.60%.1%.70938 recipes 2517 trainer table %d+", chat)
    assert.matches("S10 Travail du cuir %d+ recipes", chat)
  end)
end)
