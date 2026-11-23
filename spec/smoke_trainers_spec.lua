-- Smoke: trainer windows, NPC positions and Forever-confirmed places of "Ou l'apprendre".
local H = require("spec.helper_smoke")
local loadAddon = H.loadAddon
local printed, handlers, frames, timers
local function setup(opts)
  printed, handlers, frames, timers = {}, {}, {}, {}
  H.setup(opts, function() return printed, handlers, frames, timers end)
end

describe("trainer windows recorded in game (owner's case: Kamari, Travail du cuir 61)", function()
  local services = {
    { "Apprenti artisan du cuir", "used", 0, 0, nil },
    { "Petite giberne en cuir", "available", 25, 100, "|Hitem:7279::::::::|h[x]|h" },
    { "Bottes lueur-de-lune", "available", 35, 500, "|Hitem:252427::::::::|h[x]|h" },
    { "Chaussures en écailles de Murloc", "available", 35, 500, "|Hitem:252426::::::::|h[x]|h" },
    { "Mules de dragonnet noir", "available", 35, 500, "|Hitem:252424::::::::|h[x]|h" },
  }
  local function start()
    setup({ scanned = true, profs = { { 165, 61, "Travail du cuir", 75 } } })
    _G.GetNumTrainerServices = function() return #services end
    _G.GetTrainerServiceInfo = function(i) return services[i][1], "", services[i][2] end
    _G.GetTrainerServiceSkillReq = function(i) return "Travail du cuir", services[i][3] end
    _G.GetTrainerServiceCost = function(i) return services[i][4] end
    _G.GetTrainerServiceItemLink = function(i) return services[i][5] end
    _G.UnitName = function(unit) return unit == "npc" and "Kamari" or "Tester" end
    _G.C_Map.GetPlayerMapPosition = function() return { x = 0.5, y = 0.25 } end
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { ["Travail du cuir"] = { skill = 61, max = 75, recipes = {
      [2149] = { id = 2149, name = "Bottes en cuir cousu main", d = 2, out = 2302, oq = 1, mats = { { 2318, 2 } } } } } } }
    return ns
  end
  local function visit()
    for _, fr in ipairs(frames) do
      if fr.events and fr.events.TRAINER_SHOW then fr.scripts.OnEvent(fr, "TRAINER_SHOW") end
    end
    for _, fn in ipairs(timers) do fn() end
  end

  it("records the trainer: recipes by item, skill, cost, status, NPC, map, position, faction", function()
    local ns = start()
    visit()
    local t = ns.db.trainers["A|Kamari|Leatherworking"]
    assert.is_not_nil(t)
    assert.are.equal("Kamari", t.npc); assert.are.equal("A", t.f); assert.are.equal(1411, t.mapID)
    assert.are.equal(50, t.x); assert.are.equal(25, t.y)
    assert.are.same({ skill = 35, cost = 500, status = "available", name = "Bottes lueur-de-lune" }, t.offers[1255143])
    local logged = {}
    for _, e in ipairs(ns.LogRecent(50)) do logged[#logged + 1] = e.text end
    assert.matches("Kamari %(Leatherworking%)", table.concat(logged, "\n"))
    assert.matches("skipped %(no matching recipe%): Apprenti artisan du cuir", table.concat(logged, "\n"))   -- logged
  end)

  it("lists the four Forever recipes with the real fee and the recorded NPC, and writes 'chez Kamari'", function()
    local ns = start()
    visit()
    local res
    ns.RunLeveling(function(r) res = r end)
    local lr = res.profs[1].learn
    local found = {}
    for _, bucket in ipairs({ lr.now, lr.soon, lr.gray }) do
      for _, e in ipairs(bucket) do found[e.rec.id] = e end
    end
    for id, skill in pairs({ [9062] = 25, [1255143] = 35, [1255144] = 35, [1255146] = 35 }) do
      assert.is_not_nil(found[id], "recipe " .. id)
      assert.are.equal(skill, found[id].rec.learn)                 -- the trainer's skill, not the Classic one
      assert.are.equal("Kamari", found[id].target.name)             -- pinned where the window was opened
      assert.is_true(found[id].target.recorded)
    end
    assert.are.equal(500, found[1255143].rec.fee)
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local out = {}
    for _, l in ipairs(ns.Window.Lines()) do out[#out + 1] = (l.left.text or "") end
    assert.matches("chez Kamari", table.concat(out, "\n"))
  end)

  it("does not record anything for a window with no recipe of ours, and ignores class trainers", function()
    local ns = start()
    _G.GetTrainerServiceItemLink = function() return "|Hitem:999999::::|h[x]|h" end
    visit()
    assert.is_nil(ns.db.trainers)
    _G.IsTradeskillTrainer = function() return false end
    _G.GetTrainerServiceItemLink = function(i) return services[i][5] end
    visit()
    assert.is_nil(ns.db.trainers)
    _G.IsTradeskillTrainer = nil
  end)

  it("S9 spike line says which trainer APIs exist and how many trainers are recorded", function()
    local ns = start()
    visit()
    SlashCmdList.GOLDCOMPASS("spike")
    assert.matches("S9 trainer APIs: GetNumTrainerServices true.*GetTrainerServiceItemLink true.*trainers recorded: 1", table.concat(printed, "\n"))
    assert.is_not_nil(ns)
  end)
end)

describe("Où l'apprendre: every map button answers (real Forever data, Horde, Leatherworking 61)", function()
  local known = dofile("spec/fixtures/owner_profiles.lua")[1].known
  local function start()
    setup({ scanned = true, faction = "Horde", profs = { { 165, 61, "Travail du cuir", 75 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    local recipes = {}
    for _, id in ipairs(known) do recipes[id] = { id = id, name = "known" .. id, d = 3, out = 2302, oq = 1, mats = { { 2318, 1 } } } end
    ns.char = { learned = {}, profs = { ["Travail du cuir"] = { skill = 61, max = 75, recipes = recipes } } }
    return ns
  end
  local function logged(ns)
    local out = {}
    for _, e in ipairs(ns.LogRecent(200)) do out[#out + 1] = e.text end
    return table.concat(out, "\n")
  end

  it("gives every learnable row a target of kind pin, zone or text, a Horde trainer for trainer rows", function()
    local ns = start()
    local res
    ns.RunLeveling(function(r) res = r end)
    local lr = res.profs[1].learn
    local seen, kinds = 0, {}
    for _, bucket in ipairs({ lr.now, lr.soon, lr.gray }) do
      for _, row in ipairs(bucket) do
        seen = seen + 1
        local t = row.target
        assert.is_true(t.kind == "pin" or t.kind == "zone" or t.kind == "text", row.rec.name)
        assert.is_true(t.mapID ~= nil or t.text ~= nil, row.rec.name .. " has neither a map nor a text")
        kinds[row.rec.id] = t.kind
        if row.rec.way.kind == "trainer" then
          assert.are.equal("pin", t.kind, row.rec.name)
          for _, tr in ipairs(ns.Trainers.Leatherworking) do
            if tr[1] == t.name then assert.is_true(tr[5] == nil or tr[5] == "H", t.name .. " is not a Horde trainer") end
          end
        end
      end
    end
    assert.is_true(seen > 60)
    assert.are.equal("pin", kinds[3763])           -- Ceinture élégante: a Journeyman trainer
    assert.are.equal("pin", kinds[9062])           -- Petite giberne: a trainer
    assert.are.equal("pin", kinds[1301431])        -- Gustwoven (Vayn Moongaze, Zephras Isle): new to Forever, ForeverDB saw where she stands
  end)

  it("a click always answers: pin, zone or text in the chat, and one log line with the recipe and the decision", function()
    local ns = start()
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local n = 0
    for _, l in ipairs(ns.Window.Lines()) do
      if l.go.target then
        n = n + 1
        local before = #printed
        l.go.scripts.OnClick(l.go)
        assert.is_true(#printed > before, "no answer for " .. tostring(l.go.recipe))
        local kind = l.go.target.kind
        assert.matches("where click: " .. l.go.recipe:gsub("%p", "%%%0") .. " %-> " .. kind, logged(ns))
      end
    end
    assert.is_true(n > 10)
  end)

  it("a recycled line rebinds its own target: the click goes to the recipe now shown on that line", function()
    local ns = start()
    ns.Window.Toggle(); ns.Window.SetTab("job")
    local function check()
      local checked = 0
      for _, l in ipairs(ns.Window.Lines()) do
        if l.go.target and l.left.text ~= "" then
          assert.is_not_nil(l.left.text:find(l.go.recipe, 1, true), l.left.text .. " is bound to " .. tostring(l.go.recipe))
          checked = checked + 1
        end
      end
      return checked
    end
    assert.is_true(check() > 10)
    ns.Window.SetGoal("gold")                      -- every line is recycled for another list
    assert.is_true(check() > 10)
    local line
    for _, l in ipairs(ns.Window.Lines()) do if l.go.target and not line then line = l end end
    local before = #printed
    line.go.scripts.OnClick(line.go)
    assert.is_true(#printed > before)
    assert.matches("where click: " .. line.go.recipe:gsub("%p", "%%%0"), logged(ns))
  end)
end)

describe("Où l'apprendre: the site's location text (real Forever data, Horde, Cooking 124)", function()
  it("a drop shows where it drops, a quest recipe the quest", function()
    setup({ scanned = true, faction = "Horde", profs = { { 185, 124, "Cuisine", 150 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Cuisine = { skill = 124, max = 150, recipes = { [2538] = { id = 2538, name = "x", d = 3, out = 2302, oq = 1, mats = { { 2318, 1 } } } } } } }
    local res
    ns.RunLeveling(function(r) res = r end)
    local lr, by = res.profs[1].learn, {}
    for _, bucket in ipairs({ lr.now, lr.soon, lr.gray }) do for _, row in ipairs(bucket) do by[row.rec.id] = row end end
    assert.is_not_nil(by[8238])
    -- Savory Deviate Delight: a pattern no vendor sells, with an auction price, pins the auction house; the site's drop zone stays on the line
    assert.is_true(by[8238].target.auction)
    assert.matches("Patron en vente à l'HV", by[8238].target.text)
    assert.matches("butin", by[8238].target.extra)                       -- the site says "drop" (and the zone when it names one)
    assert.is_not_nil(by[6417])
    assert.are.equal("quête : Dig Rat Stew (niv. 23)", by[6417].target.text)
  end)

  it("the map button of a priced pattern pins the Horde auction house: chat and tooltip give the price, its age, the site's sources", function()
    setup({ scanned = true, faction = "Horde", profs = { { 185, 124, "Cuisine", 150 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Cuisine = { skill = 124, max = 150, recipes = { [2538] = { id = 2538, name = "x", d = 3, out = 2302, oq = 1, mats = { { 2318, 1 } } } } } } }
    local res
    ns.RunLeveling(function(r) res = r end)
    local row
    for _, bucket in ipairs({ res.profs[1].learn.now, res.profs[1].learn.soon, res.profs[1].learn.gray }) do
      for _, r in ipairs(bucket) do if r.rec.id == 8238 then row = r end end
    end
    assert.is_true(row.target.auction); assert.are.equal("pin", row.target.kind)
    assert.is_truthy(row.target.name:find("^Auctioneer"))
    local before = #printed
    ns.Window.GoTo(row.target, "Feu de camp")
    local chat = table.concat(printed, "\n", before + 1)
    assert.matches("Auctioneer", chat); assert.matches("Source : pfQuest", chat); assert.matches("Patron en vente à l'HV : ~", chat)
    local tip = table.concat(ns.Window.TargetTooltipLines(row.target), "\n")
    assert.matches("Patron en vente à l'HV : ~", tip); assert.matches("prix HV", tip); assert.matches("butin", tip)
    assert.matches("Source : pfQuest %(positions Classic%)%.", tip)
    assert.matches("position Classic, non confirmée sur Forever", tip)     -- pfQuest's auctioneer position: never shown as a sure one
    assert.matches("position Classic, non confirmée sur Forever", chat)
  end)
end)

describe("Où l'apprendre: vendors of the site, by faction (Cooking 124)", function()
  local function rows(faction)
    setup({ scanned = true, faction = faction, profs = { { 185, 124, "Cuisine", 150 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { Cuisine = { skill = 124, max = 150, recipes = { [2538] = { id = 2538, name = "x", d = 3, out = 2302, oq = 1, mats = { { 2318, 1 } } } } } } }
    local res
    ns.RunLeveling(function(r) res = r end)
    local by = {}
    for _, bucket in ipairs({ res.profs[1].learn.now, res.profs[1].learn.soon, res.profs[1].learn.gray }) do
      for _, row in ipairs(bucket) do by[row.rec.id] = row end
    end
    return ns, by
  end

  it("a Horde player gets the Horde vendors of the site, formatted '<NPC> (<Zone>) ; <NPC> (<Zone>) - position exacte inconnue'", function()
    local ns, by = rows("Horde")
    local row = by[7755]                                      -- Poisson-chat moustachu
    assert.is_not_nil(row)
    assert.are.equal("Derak Nightfall (Hillsbrad Foothills), Naal Mistrunner (Thunder Bluff)", row.rec.way.where)
    assert.are.equal("pin", row.target.kind)                  -- an exact pin on one of ForeverDB's vendors of the recipe, never Lindea (Alliance)
    local listed = false
    for _, id in ipairs(ns.FdbVendors[7755]) do listed = listed or id == row.target.id end
    assert.is_true(listed); assert.are_not.equal("A", ns.FdbNpcs[row.target.id][5]); assert.is_true(row.target.confirmed)
    local before = #printed
    ns.Window.GoTo(row.target, "Poisson-chat moustachu")
    assert.is_nil(table.concat(printed, "\n", before + 1):find("Lindea", 1, true))
  end)

  it("an Alliance player gets the Alliance list", function()
    local ns, by = rows("Alliance")
    assert.are.equal("Lindea Rabonne (Hillsbrad Foothills), Kilxx (The Barrens)", by[7755].rec.way.where)
    assert.is_not_nil(ns)
  end)

  it("zones with no known map are written as they are, without opening a map, and no stray parenthesis", function()
    local ns = rows("Horde")
    local before = #printed
    ns.Window.GoTo({ kind = "text", name = "Vayn Moongaze", zone = "Zephras Isle",
      vendors = { { name = "Vayn Moongaze", zone = "Zephras Isle" } } }, "Chausses")
    assert.matches("Où l'apprendre : Vayn Moongaze %(île de Zephras%) %- position exacte inconnue%.$", printed[before + 1])
  end)

  it("the vendor of another faction is filtered out when the Classic data knows its faction", function()
    local W = loadfile("Where.lua")
    local ns = {}
    W("GoldCompass", ns)
    local env = { trainers = {}, npcs = { ["Alli Vendor"] = { "Elwynn Forest", 0, 0, "A" }, ["Horde Vendor"] = { "Durotar", 0, 0, "H" } },
      where = {}, maps = { ["Elwynn Forest"] = { 1429, "E" }, Durotar = { 1411, "K" } }, faction = "H" }
    local t = ns.Where.Target({ id = 1, src = "v", way = { site = true, where = "Alli Vendor (Elwynn Forest), Horde Vendor (Durotar), Someone (Durotar)" } }, "Cooking", env)
    assert.are.equal(2, #t.vendors)
    assert.are.equal("Horde Vendor", t.vendors[1].name); assert.are.equal("Someone", t.vendors[2].name)
    assert.are.equal("zone", t.kind)
  end)
end)

describe("the craft button belongs to its own section (Travail du cuir vs Dépeçage, same leather)", function()
  local lw = { skill = 61, max = 75, recipes = {
    [2149] = { id = 2149, name = "Bottes en cuir cousu main", d = 2, out = 2302, oq = 1, mats = { { 2318, 2 } } } } }
  -- the Skinning data holds its own recipe and, from an old capture, a Leatherworking one that uses the same leather
  local skin = { skill = 110, max = 150, recipes = {
    [1229517] = { id = 1229517, name = "Chaise du camp", d = 3, out = 2302, oq = 1, mats = { { 2318, 2 } } },
    [2152] = { id = 2152, name = "Cape cousu main", d = 2, out = 2302, oq = 1, mats = { { 2318, 1 } } } } }
  local function start()
    setup({ scanned = true, counts = { [2318] = 10 }, profs = { { 165, 61, "Travail du cuir", 75 }, { 393, 110, "Dépeçage", 150 } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { ["Travail du cuir"] = lw, ["Dépeçage"] = skin }, onlyBag = true, goal = "level" }
    return ns
  end

  it("each section's craft entry carries its own profession and skill line; foreign recipes are not in the section", function()
    local ns = start()
    local res
    ns.RunLeveling(function(r) res = r end)
    local a, b = res.profs[1], res.profs[2]
    assert.are.equal("Travail du cuir", a.craft.prof); assert.are.equal(165, a.craft.line); assert.are.equal(2149, a.craft.id)
    assert.are.equal("Dépeçage", b.name)
    assert.is_nil(b.plan.best and b.plan.best.rec.id == 2152 and true)      -- the Leatherworking recipe is not Skinning's
    if b.craft then assert.are.equal("Dépeçage", b.craft.prof); assert.are.equal(393, b.craft.line) end
    local label = ns.Window.CraftState(a.craft).label
    assert.matches("Travail du cuir", label)                                  -- "Ouvrir Travail du cuir", never "Ouvrir Dépeçage"
    assert.is_nil(label:find("Dépeçage", 1, true))
  end)

  it("a profession window records only the recipes of its own skill line, and ignores an unnamed window", function()
    local ns = start()
    local function window(name, id, ids)
      return { GetBaseProfessionInfo = function() return { professionName = name, professionID = id, skillLevel = 5, maxSkillLevel = 75 } end,
        GetAllRecipeIDs = function() return ids end, GetRecipeInfo = function(i) return { learned = true, name = "r" .. i, relativeDifficulty = 2 } end }
    end
    local learned, profs = {}, {}
    ns.Learned.Capture(window("Dépeçage", 393, { 1229517, 2149 }), learned, profs)
    assert.is_not_nil(profs["Dépeçage"].recipes[1229517])
    assert.is_nil(profs["Dépeçage"].recipes[2149])                           -- a leather recipe is not Skinning's
    ns.Learned.Capture(window("", 165, { 2149 }), learned, profs)
    assert.is_nil(profs[""])                                                  -- no entry under an empty name
  end)
end)

describe("NPC positions recorded in game", function()
  it("reads the NPC id of a creature GUID, nothing else", function()
    setup({}); local ns = loadAddon()
    assert.are.equal(3497, ns.TrainerLog.NpcID("Creature-0-4379-1-76-3497-00001A2B3C"))
    assert.is_nil(ns.TrainerLog.NpcID("Player-4379-0123ABCD")); assert.is_nil(ns.TrainerLog.NpcID(nil))
  end)

  it("a merchant window records the vendor (id, name, map position) account-wide, a new visit replaces it", function()
    setup({}); local ns = loadAddon()
    ns.db = {}
    _G.UnitGUID = function() return "Creature-0-1-1-1-3497-0000000001" end
    _G.UnitName = function() return "Kilxx" end
    _G.C_Map.GetBestMapForUnit = function() return 1413 end
    _G.C_Map.GetMapInfo = function() return { name = "Les Tarides" } end
    _G.C_Map.GetPlayerMapPosition = function() return { x = 0.628, y = 0.382 } end
    ns.TrainerLog.ScanMerchant()
    local r = ns.db.npcs[3497]
    assert.are.equal("Kilxx", r.name); assert.are.equal(1413, r.mapID); assert.are.equal("Alliance" == nil and "" or "A", r.f)
    assert.is_true(math.abs(r.x - 62.8) < 0.01)
    _G.C_Map.GetPlayerMapPosition = function() return { x = 0.5, y = 0.5 } end
    ns.TrainerLog.ScanMerchant()
    assert.are.equal(50, ns.db.npcs[3497].x)
  end)
end)

-- Forever truth of "Où l'apprendre" (real data, the owner's Horde professions): a pin is confident only on a position seen on
-- Forever (ForeverDB.net) or recorded in game; everything else is flagged. GC_REPORT=1 busted prints the table recipe -> place -> evidence.
describe("Où l'apprendre: Forever-confirmed places (real data, Horde, Cooking 124 and Leatherworking 69)", function()
  local known = dofile("spec/fixtures/owner_profiles.lua")[1].known
  local function rows(line, skill, name, max, recipes)
    setup({ scanned = true, faction = "Horde", profs = { { line, skill, name, max } } })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = { [name] = { skill = skill, max = max, recipes = recipes } } }
    local res
    ns.RunLeveling(function(r) res = r end)
    local by, list = {}, {}
    for _, bucket in ipairs({ res.profs[1].learn.now, res.profs[1].learn.soon, res.profs[1].learn.gray }) do
      for _, row in ipairs(bucket) do by[row.rec.id] = row; list[#list + 1] = row end
    end
    return ns, by, list, res.profs[1].learn
  end
  local function cooking()
    return rows(185, 124, "Cuisine", 150, { [2538] = { id = 2538, name = "x", d = 3, out = 2302, oq = 1, mats = { { 2318, 1 } } } })
  end
  local function leather()
    local recipes = {}
    for _, id in ipairs(known) do recipes[id] = { id = id, name = "known" .. id, d = 3, out = 2302, oq = 1, mats = { { 2318, 1 } } } end
    return rows(165, 69, "Travail du cuir", 75, recipes)
  end
  local function report(title, ns, list)
    if not os.getenv("GC_REPORT") then return end
    io.write("\n== " .. title .. "\n")
    table.sort(list, function(a, b) return a.rec.id < b.rec.id end)
    for _, row in ipairs(list) do
      local t = row.target
      local place = t.mapID and t.x and ("%s, map %d %.1f/%.1f"):format(tostring(t.name), t.mapID, t.x, t.y)
        or t.mapID and ("zone map %d (%s)"):format(t.mapID, tostring(t.name or t.text))
        or t.vendors and ns.Window.VendorText(t) or tostring(t.text)
      local evidence = t.mapID and t.x and ((t.confirmed and "CONFIRMED " or "UNCONFIRMED ") .. tostring(t.source))
        or t.unverified and ("NO FOREVER SOURCE" .. (t.hint and (" (Classic hint: " .. t.hint .. ")") or ""))
        or t.onlyFaction and ("only faction " .. t.onlyFaction) or tostring(t.source or "text")
      io.write(("%-8d %-38s %-9s %-7s %-52s %s\n"):format(row.rec.id, tostring(row.rec.name):sub(1, 38), tostring(row.rec.way and row.rec.way.kind),
        t.kind .. (t.auction and "/AH" or ""), place, evidence))
    end
  end

  it("the catfish recipe (7755) pins Naal Mistrunner IN Thunder Bluff (map 1456), a position seen on Forever, never Mulgore", function()
    local ns, by = cooking()
    local row = by[7755]                                      -- Poisson-chat moustachu
    assert.is_not_nil(row)
    assert.are.same({ 5494, 2397, 260487, 3497, 2383, 3027, 4553, 3029 }, ns.FdbVendors[7755])   -- ForeverDB: who sells it
    assert.are.same({ "Naal Mistrunner", 1456, 50.8, 52.2, "H", true }, ns.FdbNpcs[3027])
    -- a Tauren standing in Mulgore: the Thunder Bluff vendors are the nearest ones
    local env = { trainers = ns.Trainers, npcs = ns.NPCs, where = ns.RecipeWhere, maps = ns.MapIDs, faction = "H", db = ns.Npcs,
      byName = ns.NpcByName, ntrainers = ns.NpcTrainers, fdb = ns.FdbNpcs, fdbVendors = ns.FdbVendors, fdbTrainers = ns.FdbTrainers,
      contOf = { [1456] = "K", [1412] = "K", [1413] = "K", [1424] = "E", [1458] = "E" }, continent = "K",
      dist = function(m, x) return m == 1456 and (x == 50.8 and 10 or 20) or 900 end }
    local t = ns.Where.Target(row.rec, "Cooking", env)
    assert.are.equal("pin", t.kind); assert.are.equal("Naal Mistrunner", t.name); assert.are.equal(3027, t.id)
    assert.are.equal(1456, t.mapID); assert.are.equal(50.8, t.x); assert.are.equal(52.2, t.y)
    assert.is_true(t.confirmed); assert.are.equal("foreverdb", t.source)
    local before = #printed
    ns.Window.GoTo(t, "Poisson-chat moustachu")
    local chat = table.concat(printed, "\n", before + 1)
    assert.matches("Source : ForeverDB.net %(vu en jeu sur Forever%)", chat)
    assert.is_nil(chat:find("non confirmée", 1, true)); assert.is_nil(chat:find("Lindea", 1, true))
    -- whoever the player is, no Horde answer is on the Mulgore map (the projection of the city) or an Alliance vendor
    for _, e in ipairs({ {}, { continent = "E" }, { continent = "K", dist = function() return 5 end } }) do
      local o = {}
      for k, v in pairs(env) do o[k] = v end
      o.continent, o.dist = e.continent, e.dist
      local any = ns.Where.Target(row.rec, "Cooking", o)
      assert.are.equal("pin", any.kind); assert.are_not.equal(1412, any.mapID); assert.is_true(any.confirmed)
      assert.is_true(any.id ~= 2383 and any.id ~= 5494)
    end
    -- without ForeverDB's place, pfQuest's Classic one is used on the city map and flagged as unconfirmed
    env.fdb, env.fdbVendors, env.fdbTrainers = nil, nil, nil
    local c = ns.Where.Target({ id = 7755, src = "v", way = { site = true, where = "Naal Mistrunner (Thunder Bluff)" } }, "Cooking", env)
    assert.are.equal(1456, c.mapID); assert.is_false(c.confirmed); assert.are.equal("pfquest", c.source)
    before = #printed
    ns.Window.GoTo(c, "Poisson-chat moustachu")
    assert.matches("position Classic, non confirmée sur Forever", table.concat(printed, "\n", before + 1))
    assert.matches("position Classic, non confirmée sur Forever", table.concat(ns.Window.TargetTooltipLines(c), "\n"))
  end)

  it("every Cooking and Leatherworking pin is confirmed on Forever or says it is not; nothing is pinned from Classic names alone", function()
    for _, p in ipairs({ { "Cooking 124 Horde", cooking }, { "Leatherworking 69 Horde", leather } }) do
      local ns, _, list = p[2]()
      assert.is_true(#list > 10)
      local confirmed = 0
      for _, row in ipairs(list) do
        local t = row.target
        if t.kind == "pin" then
          assert.is_true(t.confirmed == (t.source == "foreverdb" or t.source == "recorded"), row.rec.name)
          if t.confirmed then confirmed = confirmed + 1 end
          local tip = table.concat(ns.Window.TargetTooltipLines(t), "\n")
          assert.are.equal(not t.confirmed, tip:find("position Classic, non confirmée sur Forever", 1, true) ~= nil, row.rec.name)
          if row.rec.src == "v" and t.id and not t.auction and ns.FdbVendors[row.rec.id] then   -- a vendor: one a Forever source names for this recipe
            local listed = (row.rec.way.where or ""):find(t.name, 1, true) ~= nil      -- the site's list
            for _, id in ipairs(ns.FdbVendors[row.rec.id]) do listed = listed or id == t.id end
            assert.is_true(listed, row.rec.name .. ": " .. tostring(t.name))
          end
          if t.id and ns.FdbNpcs[t.id] then assert.are_not.equal("A", ns.FdbNpcs[t.id][5], row.rec.name) end
        end
      end
      assert.is_true(confirmed > 5, p[1])
      report(p[1], ns, list)
    end
  end)

  it("a vendor or a quest of the other faction is no way to learn a recipe: never the best pick, said as Alliance only", function()
    local ns, by, list = cooking()
    -- Crocolisk Steak: Kendor Kabonka (Stormwind) and the quest Crocolisk Hunting (Loch Modan) are the Alliance's
    local croc = by[3370]
    assert.is_not_nil(croc)
    assert.are.equal("A", croc.rec.way.onlyFaction); assert.are.equal("item", croc.rec.way.kind)
    assert.is_false(croc.recommend and croc.rec.fee == nil)          -- only an auction price could make it worth proposing
    assert.is_true(croc.target.auction or croc.target.onlyFaction == "A")
    assert.is_not_nil(ns.Fmt.SiteSources(croc.rec.way):find("Kendor Kabonka (Stormwind City) (côté Alliance uniquement)", 1, true))
    for _, row in ipairs(list) do
      local way = row.rec.way
      if way.kind == "vendor" or way.kind == "quest" then
        assert.is_nil(way.onlyFaction, row.rec.name)
        assert.are_not.equal("A", row.target.onlyFaction, row.rec.name .. " is proposed to the Horde but only the Alliance can get it")
      end
    end
    -- Cooking at 10: the Alliance quest Recipe of the Kaldorei (Zarrin, Teldrassil) is not offered to the Horde, nor the best pick
    local ns10, by10 = rows(185, 10, "Cuisine", 75, { [2538] = { id = 2538, name = "x", d = 3, out = 2302, oq = 1, mats = { { 2318, 1 } } } })
    local kabob = by10[6412]                                  -- listed only as a pattern to buy at the auction house, when it has a price there
    if kabob then
      assert.are.equal("item", kabob.rec.way.kind); assert.are.equal("A", kabob.rec.way.onlyFaction)
      assert.is_true(kabob.target.auction); assert.is_not_nil(kabob.rec.fee)
    end
    local horde = ns10.Leveling.Way(ns10.ForeverDB, 6412, { requiredSkill = 10 }, "H", ns10.ForeverTrainers,
      ns10.Where.Who({ db = ns10.Npcs, byName = ns10.NpcByName, maps = ns10.MapIDs, fdb = ns10.FdbNpcs, fdbVendors = ns10.FdbVendors, fdbQuests = ns10.FdbQuests }))
    assert.are_not.equal("quest", horde.kind); assert.are.equal("A", horde.onlyFaction); assert.is_nil(horde.questID)
    assert.are.same({ { 4161, "A", 6286, "Zarrin", 1438, 57.1, 61.3, "Recipe of the Kaldorei", 7 } }, ns10.FdbQuests[6412])
    local way = ns10.Leveling.Way(ns10.ForeverDB, 6412, { requiredSkill = 10 }, "A", ns10.ForeverTrainers,
      ns10.Where.Who({ db = ns10.Npcs, byName = ns10.NpcByName, maps = ns10.MapIDs, fdb = ns10.FdbNpcs, fdbVendors = ns10.FdbVendors, fdbQuests = ns10.FdbQuests }))
    assert.are.equal("quest", way.kind); assert.are.equal(4161, way.questID); assert.is_nil(way.onlyFaction)
  end)

  it("a Horde quest recipe pins the quest giver where Forever players were offered the quest, with the quest named", function()
    local ns, by = cooking()
    local t = by[6417].target                                 -- Dig Rat Stew: Grub, east of the Crossroads
    assert.are.equal("pin", t.kind); assert.are.equal("Grub", t.name); assert.are.equal(1413, t.mapID)
    assert.is_true(t.confirmed); assert.are.equal("foreverdb", t.source); assert.are.equal("quête : Dig Rat Stew (niv. 23)", t.text)
    assert.are.equal(862, by[6417].rec.way.questID)
    _G.C_QuestLog = { GetTitleForQuestID = function(id) return id == 862 and "Ragoût de rat" or nil end }   -- the client's own title
    assert.are.equal("Ragoût de rat (niv. 23)", ns.Fmt.QuestName(by[6417].rec.way))
    _G.C_QuestLog = nil
    assert.are.equal("Dig Rat Stew (niv. 23)", ns.Fmt.QuestName(by[6417].rec.way))
  end)

  it("a Merchant's Favor vendor of the site is read as NPC, zone and price: Pawani (The Barrens), 30 Faveur du marchand", function()
    local ns, by = leather()
    local row = by[1255139]                                   -- Totemic Leather Belt
    assert.is_not_nil(row)
    assert.are.equal("vendor", row.rec.way.kind); assert.are.equal("Pawani (The Barrens)", row.rec.way.where)
    assert.are.same({ id = 3402, amount = 30 }, row.rec.way.currency)
    assert.are.equal("Pawani", row.target.name); assert.is_true(row.target.confirmed)
    assert.matches("30 Faveur du marchand", ns.Fmt.Source(row.rec, true))
    -- the site's text alone (no ForeverDB data) gives the same reading
    local way = ns.Leveling.Way(ns.ForeverDB, 1255139, { requiredSkill = 70 }, "H", ns.ForeverTrainers)
    assert.are.equal("Pawani (The Barrens)", way.where); assert.are.equal("Pawani", way.npcs[1])
    assert.are.same({ id = 3402, amount = 30 }, way.currency)
  end)

  it("the rank book pins its Forever vendor of the player's faction (Expert Cookbook: Wulan in Desolace, not Shandrina)", function()
    local ns, _, _, lr = cooking()
    local book
    for _, b in ipairs(lr.books or {}) do if b.rec.id == 3413 then book = b end end
    assert.is_not_nil(book)
    assert.are.same({ 3955, 12033 }, ns.FdbVendors[3413])
    local t = book.target
    assert.are.equal("pin", t.kind); assert.are.equal("Wulan", t.name); assert.are.same({ 1443, 26.1, 69.7 }, { t.mapID, t.x, t.y })
    assert.is_true(t.confirmed); assert.are.equal("foreverdb", t.source)
    assert.are.equal(10000, book.rec.way.vendorCost)          -- 1 gold, ForeverDB's vendor price
  end)

  it("the Leatherworking trainer rows pin a Horde trainer ForeverDB lists, at the place it was seen on Forever", function()
    local ns, by = leather()
    local t = by[3763].target                                 -- Ceinture élégante en cuir: a trainer recipe
    assert.are.equal("pin", t.kind); assert.is_true(t.confirmed); assert.are.equal("foreverdb", t.source)
    assert.is_true(ns.FdbTrainers.Leatherworking[t.id]); assert.are.equal("H", ns.FdbNpcs[t.id][5])
    assert.are.same({ ns.FdbNpcs[t.id][2], ns.FdbNpcs[t.id][3], ns.FdbNpcs[t.id][4] }, { t.mapID, t.x, t.y })
  end)
end)

describe("/gc pnj lists the NPCs recorded in game", function()
  it("says when nothing is recorded, then lists merchants and trainers with their place, one line per NPC", function()
    setup({ scanned = true, faction = "Horde", profs = {} })
    local ns = loadAddon()
    ns.db = {}
    printed = {}
    SlashCmdList["GOLDCOMPASS"]("pnj")
    assert.matches("Aucun PNJ enregistré", table.concat(printed, "\n"))
    ns.db.npcs = { [3027] = { name = "Naal Mistrunner", mapID = 1456, x = 50.84, y = 52.21, f = "H" } }
    ns.db.trainers = {
      ["H|Kamari|Leatherworking"] = { npc = "Kamari", mapID = 1454, x = 63.16, y = 45.01, zone = "Orgrimmar", f = "H", prof = "Leatherworking", offers = {} },
      ["H|Naal Mistrunner|Cooking"] = { npc = "Naal Mistrunner", mapID = 1456, x = 50.8, y = 52.2, f = "H", prof = "Cooking", offers = {} },
    }
    assert.are.same({ "Kamari", "Naal Mistrunner" }, { ns.TrainerLog.Recorded(ns.db)[1].name, ns.TrainerLog.Recorded(ns.db)[2].name })
    printed = {}
    SlashCmdList["GOLDCOMPASS"]("pnj")
    local text = table.concat(printed, "\n")
    assert.matches("2 PNJ enregistrés en jeu", text)
    assert.matches("Kamari · [^\n]- 63%.2, 45%.0", text); assert.matches("Naal Mistrunner · [^\n]- 50%.8, 52%.2", text)
  end)
end)
