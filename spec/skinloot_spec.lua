-- Unit tests of the in-game skinning yield recorder (SkinLoot.lua) with a stub loot API, and of its use by SkinRank.
local ns = {}
assert(loadfile("ZoneRank.lua"))("GoldCompass", ns)
assert(loadfile("SkinLoot.lua"))("GoldCompass", ns)
assert(loadfile("SkinRank.lua"))("GoldCompass", ns)
local SL = ns.SkinLoot

ns.SkinZones = { [10] = { { 1, "Boar", 5, 6, 1, spots = 60, items = { { 100, 0.5 }, { 200, 0.5 } } }, { 2, "Bear", 5, 6, 1, spots = 10, items = { { 300, 1 } } } } }

local function skins(store, npc, n, items)
  for _ = 1, n do SL.Record(store, npc, items, 20000) end
end

describe("SkinLoot.Record / Measured / Yields", function()
  it("counts skins and quantities per beast, and trusts a beast only from 20 skins", function()
    local store = {}
    skins(store, 1, 19, { { 100, 2 } })
    assert.is_nil(SL.Measured(store, 1))
    assert.is_nil(SL.Yields(store, ns.SkinZones[10][1]))
    SL.Record(store, 1, { { 100, 1 }, { 999, 3 } }, 20001)
    assert.are.equal(20, SL.Measured(store, 1))
    assert.are.same({ n = 20, d = 20001, i = { [100] = 39, [999] = 3 } }, store[1])
    -- Classic list: 100 -> 39/20, 200 never seen -> 0 (measured), 999 unknown to Classic -> added
    local y = SL.Yields(store, ns.SkinZones[10][1])
    assert.are.equal(3, #y)
    assert.are.same({ 100, 1.95 }, { y[1][1], y[1][2] })
    assert.are.same({ 200, 0 }, { y[2][1], y[2][2] })
    assert.are.same({ 999, 0.15 }, { y[3][1], y[3][2] })
  end)

  it("keeps at most 8 items per beast and 400 beasts, dropping the least measured one", function()
    local store = {}
    local many = {}
    for i = 1, 12 do many[i] = { 1000 + i, 1 } end
    SL.Record(store, 5, many, 1)
    local kinds = 0
    for _ in pairs(store[5].i) do kinds = kinds + 1 end
    assert.are.equal(8, kinds)
    for id = 1, 400 do SL.Record(store, 10000 + id, { { 1, 1 } }, 5) end   -- 5 is already in: 399 new ones, the 400th evicts
    local count = 0
    for _ in pairs(store) do count = count + 1 end
    assert.are.equal(400, count)
    skins(store, 10001, 3, { { 1, 1 } })        -- 10001 now has 4 skins: not the least measured
    SL.Record(store, 99999, { { 1, 1 } }, 6)
    count = 0
    for _ in pairs(store) do count = count + 1 end
    assert.are.equal(400, count)
    assert.is_truthy(store[10001])
    assert.is_truthy(store[99999])
  end)

  it("ignores an empty loot and a corrupt table", function()
    assert.is_false(SL.Record({}, 1, {}, 1))
    assert.is_false(SL.Record(nil, 1, { { 1, 1 } }, 1))
    assert.is_nil(SL.Measured({ [1] = { n = "x" } }, 1))
    assert.is_nil(SL.Measured(nil, 1))
  end)
end)

-- a loot window stub: slots = { { link =, qty = }, ... }, sources = what GetLootSourceInfo(1) returns
local function env(slots, sources, store, clock)
  local api = {
    count = function() return #slots end,
    link = function(i) return slots[i].link end,
    info = function(i) return "icon", "name", slots[i].qty end,
    source = function() return table.unpack(sources) end,
    npcID = function(guid) return tonumber((guid or ""):match("%-(%d+)%-%x+$")) end,
  }
  return { api = api, store = function() return store end, now = function() return clock.t end, day = function() return 20000 end,
    isSkin = function(id) return id == 10768 end }
end

describe("SkinLoot.Handler", function()
  local slots = { { link = "|cff|Hitem:100::::|h[Leather]|h|r", qty = 2 }, { link = nil, qty = 1 }, { link = "|Hitem:100:|h", qty = 1 } }
  local guid = "Creature-0-4379-1-76-1-00001A2B3C"

  it("records the loot window that follows a skinning cast, coins skipped, same item added up", function()
    local store, clock = {}, { t = 100 }
    local h = SL.Handler(env(slots, { guid, 1 }, store, clock))
    h("UNIT_SPELLCAST_SENT", "player", "Boar", "cg", 10768)
    clock.t = 102
    h("LOOT_OPENED", 0)
    assert.are.same({ n = 1, d = 20000, i = { [100] = 3 } }, store[1])
    h("LOOT_OPENED", 0)                                   -- the window is armed once only
    assert.are.equal(1, store[1].n)
  end)

  it("ignores corpse loot (no skinning cast), other spells, a cancelled or late cast, other units", function()
    local store, clock = {}, { t = 100 }
    local h = SL.Handler(env(slots, { guid, 1 }, store, clock))
    h("LOOT_OPENED", 0)
    h("UNIT_SPELLCAST_SENT", "player", "Boar", "cg", 1234)
    h("LOOT_OPENED", 0)
    h("UNIT_SPELLCAST_SENT", "party1", "Boar", "cg", 10768)
    h("LOOT_OPENED", 0)
    h("UNIT_SPELLCAST_SENT", "player", "Boar", "cg", 10768)
    h("UNIT_SPELLCAST_INTERRUPTED", "player", "cg", 10768)
    h("LOOT_OPENED", 0)
    h("UNIT_SPELLCAST_SENT", "player", "Boar", "cg", 10768)
    clock.t = 200
    h("LOOT_OPENED", 0)
    assert.is_nil(next(store))
  end)

  it("ignores a creature that is not a skinnable beast, several corpses, and a missing store", function()
    local clock = { t = 1 }
    local store = {}
    local h = SL.Handler(env(slots, { "Creature-0-4379-1-76-77777-00001A2B3C", 1 }, store, clock))
    h("UNIT_SPELLCAST_SENT", "player", "x", "cg", 10768); h("LOOT_OPENED", 0)
    h = SL.Handler(env(slots, { guid, 1, "Creature-0-4379-1-76-2-00001A2B3C", 1 }, store, clock))
    h("UNIT_SPELLCAST_SENT", "player", "x", "cg", 10768); h("LOOT_OPENED", 0)
    h = SL.Handler(env(slots, { guid, 1 }, nil, clock))
    h("UNIT_SPELLCAST_SENT", "player", "x", "cg", 10768)
    assert.has_no.errors(function() h("LOOT_OPENED", 0) end)
    assert.is_nil(next(store))
  end)
end)

describe("SkinRank uses a measured beast", function()
  local function run(skinLoot)
    return ns.SkinRank.Rank({ zones = ns.SkinZones, skill = 300, skinLoot = skinLoot,
      price = function(id) return 1000, 0 end, vendor = function() end })
  end
  it("replaces the Classic yield by the recorded one from 20 skins only", function()
    -- Boar weight 60, Bear weight 10; unit = 1000 x 0.95 = 950. Classic: Boar 0.5 + 0.5 = 1 item/skin, Bear 1.
    -- Zone average per skin = (60 x 950 + 10 x 950) / 70 = 950, pace 60 x 70/100 = 42 -> 39900
    assert.is_near(39900, run(nil).rows[1].copperPerHour, 1e-6)
    local store = {}
    skins(store, 1, 19, { { 100, 4 } })
    assert.is_near(39900, run(store).rows[1].copperPerHour, 1e-6)            -- 19 skins: still Classic
    skins(store, 1, 1, { { 100, 4 } })
    -- Boar measured: item 100 at 80/20 = 4 per skin, 200 -> 0: 4 x 950 = 3800 per skin
    -- (60 x 3800 + 10 x 950) / 70 = 3436.43, x pace 42
    assert.is_near(42 * (60 * 3800 + 10 * 950) / 70, run(store).rows[1].copperPerHour, 1e-6)
  end)
end)
