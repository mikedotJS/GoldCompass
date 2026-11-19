-- Data/ForeverGather.lua (tools/build-gather.py): shape and a few known items.
local ns = {}
assert(loadfile("Data/ForeverGather.lua"))("GoldCompass", ns)

describe("ForeverGather data", function()
  it("has the documented shape, at most 8 zones per item, sorted by Forever points", function()
    local n = 0
    for item, s in pairs(ns.GatherSources) do
      n = n + 1
      assert.is_number(item); assert.is_table(s.nodes); assert.is_table(s.zones)
      assert.is_true(#s.zones <= 8)
      for _, node in ipairs(s.nodes) do
        assert.is_string(node[1]); assert.is_number(node[2]); assert.is_boolean(node.forever)
      end
      for i, z in ipairs(s.zones) do
        assert.is_number(z[1]); assert.is_number(z[2]); assert.is_number(z[3]); assert.is_true(z[2] + z[3] > 0)
        assert.is_true(z.best[1] >= 0 and z.best[1] <= 100 and z.best[2] >= 0 and z.best[2] <= 100)
        if i > 1 then assert.is_true(s.zones[i - 1][2] >= z[2]) end
      end
    end
    assert.is_true(n >= 60)
  end)

  it("knows Peacebloom and Copper Ore from Forever points", function()
    local pb = ns.GatherSources[2447]
    assert.are.same({ "Peacebloom", 1 }, { pb.nodes[1][1], pb.nodes[1][2] }); assert.is_true(pb.nodes[1].forever)
    assert.is_true(pb.zones[1][2] > 0)
    local found = false
    for _, z in ipairs(pb.zones) do if z[1] == 1411 then found = true end end
    assert.is_true(found)                                           -- Durotar
    local cu = ns.GatherSources[2770]
    assert.are.equal("Copper Vein", cu.nodes[1][1]); assert.are.equal(1, cu.nodes[1][2]); assert.is_true(cu.nodes[1].forever)
  end)

  it("lists Forever-only items with no known source as empty", function()
    assert.are.same({ nodes = {}, zones = {} }, ns.GatherSources[248821])   -- Demonsage
  end)

  it("gives the zone fishing skill and its source", function()
    assert.are.equal(25, ns.FishZones[1411].skill); assert.are.equal("wowforever", ns.FishZones[1411].src)
    assert.are.equal(25, ns.FishZones[2521].skill)                     -- Zephras Isle: only wowforever.be has it
    for _, f in pairs(ns.FishZones) do assert.is_table(f.items); assert.is_number(f.foreverPoints) end
  end)
end)
