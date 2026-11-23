-- Data/ForeverSkinPoints.lua (tools/build-skin-points.py): shape, a beast with points, the zones of the beasts of skill 200+, and the
-- loop through the real points (Route.Loop keeps at most Route.MAX_POINTS merged points).
local ns = {}
for _, f in ipairs({ "Data/Zones", "Data/ForeverSkinZones", "Data/ForeverSkinPoints", "Route" }) do assert(loadfile(f .. ".lua"))("GoldCompass", ns) end
local R = ns.Route

local function packed(npc, zone) return ns.SkinPoints[npc * 10000 + zone] end
local function points(npc, zone) return R.Unpack(packed(npc, zone)) end

describe("ForeverSkinPoints data", function()
  it("is a string of whole points per beast and map, on maps of Data/Zones.lua, inside the map", function()
    local n = 0
    for key, str in pairs(ns.SkinPoints) do
      local npc, zone = math.floor(key / 10000), key % 10000
      n = n + 1
      assert.is_truthy(ns.Zones[zone], "map " .. zone)
      assert.is_truthy(str:match("^[0-9a-z]*%.[0-9a-z]*$"), "npc " .. npc)
      local f, c = R.Unpack(str)
      assert.equals(#str - 1, (#f + #c) * 4)                           -- whole points only, nothing cut
      assert.is_true(#f + #c >= 1 and #f + #c <= 80, "npc " .. npc .. " map " .. zone)
      for _, p in ipairs(f) do assert.is_true(p.x >= 0 and p.x <= 100 and p.y >= 0 and p.y <= 100) end
      for _, p in ipairs(c) do assert.is_true(p.x >= 0 and p.x <= 100 and p.y >= 0 and p.y <= 100) end
    end
    assert.is_true(n > 500)
  end)

  it("only holds beasts and maps of Data/ForeverSkinZones.lua, and covers almost all of them", function()
    local listed, total, have = {}, 0, 0
    for zone, beasts in pairs(ns.SkinZones) do
      for _, b in ipairs(beasts) do
        listed[b[1] .. ":" .. zone] = true
        total = total + 1
        if packed(b[1], zone) then have = have + 1 end
      end
    end
    for key in pairs(ns.SkinPoints) do
      local npc, zone = math.floor(key / 10000), key % 10000
      assert.is_true(listed[npc .. ":" .. zone], npc .. " on " .. zone)
    end
    assert.is_true(have / total > 0.9, ("%d of %d"):format(have, total))
  end)

  it("keeps the points of a beast apart by about 1.5 percent of the map (clustered, not the raw spawns)", function()
    for _, zone in ipairs({ 1411, 1413 }) do
      for _, b in ipairs(ns.SkinZones[zone]) do
        if packed(b[1], zone) then
          local f = points(b[1], zone)
          for i = 1, #f do
            for j = i + 1, #f do
              -- the greedy cluster centres drift a little, but never end up on top of each other
              assert.is_true(math.sqrt((f[i].x - f[j].x) ^ 2 + (f[i].y - f[j].y) ^ 2) > 0.5, "npc " .. b[1])
            end
          end
        end
      end
    end
  end)

  it("has Forever-seen points for a common beast (Dire Mottled Boar, Durotar) and flags the Classic ones apart", function()
    local f, c = points(3099, 1411)
    assert.is_true(#f >= 5)
    assert.is_true(#f + #c <= 80)
  end)

  it("gives the beasts valid at skill 200 and above known points in several zones", function()
    for _, skill in ipairs({ 200, 225, 250, 275, 299 }) do
      local withPoints = 0
      for _, z in ipairs(R.SkinZones(skill, ns.SkinZones)) do
        local n = 0
        for _, b in ipairs(z.all) do
          if packed(b.id, z.zone) then n = n + 1 end
        end
        if n > 0 then withPoints = withPoints + 1 end
      end
      assert.is_true(withPoints >= 3, ("skill %d: %d zones with points"):format(skill, withPoints))
    end
  end)

  it("loops through the real points of a zone in at most MAX_POINTS merged points, inside the map, none lost", function()
    for _, zone in ipairs({ 1411, 1413, 1443 }) do
      local pts = {}
      for _, b in ipairs(ns.SkinZones[zone] or {}) do
        if packed(b[1], zone) then
          local f, c = points(b[1], zone)
          for _, p in ipairs(f) do pts[#pts + 1] = p end
          for _, p in ipairs(c) do pts[#pts + 1] = p end
        end
      end
      if #pts > 0 then
        local loop = R.Loop(pts, { x = 50, y = 50 }, { aspect = 1.5 })
        assert.is_true(#loop.points >= 1 and #loop.points <= R.MAX_POINTS, "zone " .. zone)
        local total = 0
        for _, p in ipairs(loop.points) do
          total = total + p.n
          assert.is_true(p.x >= 0 and p.x <= 100 and p.y >= 0 and p.y <= 100)
        end
        assert.equals(#pts, total)
      end
    end
  end)
end)
