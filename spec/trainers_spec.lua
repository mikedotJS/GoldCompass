-- Trainer windows recorded in game: reading, saving, and reading back (pure parts, stubbed services).
local ns = {}
_G.CreateFrame = function() return setmetatable({}, { __index = function() return function() end end }) end
_G.C_Timer = { After = function() end }
_G.date = os.date
_G.geterrorhandler = function() return function() end end
_G.seterrorhandler = function() end
for _, f in ipairs({ "Strings", "Log", "Data/Recipes" }) do assert(loadfile(f .. ".lua"))("GoldCompass", ns) end
assert(loadfile("Trainers.lua"))("GoldCompass", ns)
local T = ns.TrainerLog

-- The owner's Forever Leatherworking trainer (Kamari, skill 61): one rank service and four recipes
local function kamari()
  local services = {
    { "Apprenti artisan du cuir", "", "used", 0, 0, nil },
    { "Petite giberne en cuir", "", "available", 25, 100, "|cff1eff00|Hitem:7279::::::::|h[Petite giberne en cuir]|h|r" },
    { "Bottes lueur-de-lune", "", "available", 35, 500, "|Hitem:252427::::::::|h[Bottes lueur-de-lune]|h" },
    { "Chaussures en écailles de Murloc", "", "available", 35, 500, "|Hitem:252426::::::::|h[x]|h" },
    { "Mules de dragonnet noir", "", "available", 35, 500, "|Hitem:252424::::::::|h[x]|h" },
  }
  return {
    count = function() return #services end,
    service = function(i) return services[i][1], services[i][2], services[i][3] end,
    req = function(i) return "Travail du cuir", services[i][4] end,
    cost = function(i) return services[i][5] end,
    link = function(i) return services[i][6] end,
  }
end
-- crafts by output item, as Trainers.lua builds them
local index = {}
for _, r in ipairs(ns.RecipeRows) do
  index[r[4]] = index[r[4]] or {}
  table.insert(index[r[4]], { id = r[1], prof = r[2], name = r[8] })
end

describe("Trainers.Read", function()
  it("matches each service to a craft through the item of its link, with skill, cost and status", function()
    local rec, skipped = T.Read(kamari(), index)
    assert.are.equal("Leatherworking", rec.prof)
    assert.are.same({ skill = 25, cost = 100, status = "available", name = "Petite giberne en cuir" }, rec.offers[9062])
    assert.are.equal(35, rec.offers[1255143].skill)           -- Moonglow Boots: a Forever recipe the Classic data does not teach
    assert.are.equal(500, rec.offers[1255144].cost)
    assert.is_not_nil(rec.offers[1255146])
    assert.are.same({ "Apprenti artisan du cuir" }, skipped)  -- the rank service has no recipe: skipped
  end)

  it("reads the state of a service on the Forever client too (name, state, icon, level): never the icon's number", function()
    local api = kamari()
    local classic = api.service
    api.service = function(i)
      local name, _, state = classic(i)
      return name, i == 3 and "unavailable" or state, 321409, 0     -- what the owner's client returned: the icon in third place
    end
    local rec = T.Read(api, index)
    assert.are.equal("available", rec.offers[9062].status)
    assert.are.equal("unavailable", rec.offers[1255143].status)
    api.service = function(i) return (classic(i)), nil, 321409 end   -- no state at all: unknown, not a number
    assert.is_nil(T.Read(api, index).offers[9062].status)
  end)

  it("skips a service whose item matches no recipe, and falls back on the localized name", function()
    local api = kamari()
    local real = api.link
    api.link = function(i) if i == 3 then return "|Hitem:999999::::|h[x]|h" end return real(i) end
    local rec, skipped = T.Read(api, index)
    assert.is_nil(rec.offers[1255143])
    assert.are.equal(2, #skipped)                                        -- the rank service + the unknown one
    local byName = function(prof, name) if prof == "Leatherworking" and name == "Bottes lueur-de-lune" then return { id = 1255143 } end end
    rec = T.Read(api, index, byName)
    assert.are.equal(35, rec.offers[1255143].skill)
  end)

  it("returns nothing when no service matches (class trainer) or the API gives no link", function()
    local api = kamari()
    api.link = function() return nil end
    local rec, skipped = T.Read(api, index)
    assert.is_nil(rec); assert.are.equal(5, #skipped)
    api.count = function() return 0 end
    assert.is_nil((T.Read(api, index)))
  end)
end)

describe("Trainers.Save and Offers", function()
  local where = { mapID = 1411, x = 50, y = 25, zone = "Durotar" }
  it("replaces the previous record of the same trainer on each visit", function()
    local db = {}
    local rec = T.Read(kamari(), index)
    T.Save(db, rec, "Kamari", "H", where, 100)
    rec.offers[9062] = nil
    T.Save(db, rec, "Kamari", "H", where, 200)
    local n = 0
    for _ in pairs(db.trainers) do n = n + 1 end
    assert.are.equal(1, n)
    assert.is_nil(db.trainers["H|Kamari|Leatherworking"].offers[9062])   -- the new visit is the truth
    assert.are.equal(200, db.trainers["H|Kamari|Leatherworking"].seen)
  end)

  it("reads offers back for one profession and faction, cheapest trainer first, 'used' marks known", function()
    local db = {}
    local rec = T.Read(kamari(), index)
    T.Save(db, rec, "Kamari", "H", where, 1)
    local other = { prof = "Leatherworking", offers = { [9062] = { skill = 20, cost = 50, status = "available", name = "x" } } }
    T.Save(db, other, "Cheap", "H", { mapID = 1412, x = 1, y = 2 }, 1)
    T.Save(db, other, "Alliance", "A", where, 1)
    local offers = T.Offers(db, "Leatherworking", "H")
    assert.are.equal("Cheap", offers[9062].npc)                           -- cheaper than Kamari's 100
    assert.are.equal("Kamari", offers[1255143].npc)
    assert.are.equal(1411, offers[1255143].mapID)
    assert.is_nil(T.Offers(db, "Tailoring", "H")[9062])
    assert.are.equal("Alliance", T.Offers(db, "Leatherworking", "A")[9062].npc)
  end)
end)
