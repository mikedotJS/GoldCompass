-- Data/ForeverSkinning.lua (tools/build-skinning.py): shape, and the Forever evidence the ForeverDB data allows.
local ns = {}
assert(loadfile("Data/ForeverSkinning.lua"))("GoldCompass", ns)

local MAIN = { 2934, 2318, 783, 2319, 4232, 4234, 4235, 4304, 8169, 8170, 8171 }

describe("ForeverSkinning data", function()
  it("lists at most 15 beasts per item, Forever-seen first, each with a spot table of the right shape", function()
    for _, item in ipairs(MAIN) do
      local rows = ns.Skinning[item]
      assert.is_true(#rows >= 1 and #rows <= 15, "item " .. item)
      local classicSeen = false
      for _, r in ipairs(rows) do
        assert.are.equal("number", type(r[1])); assert.are.equal("string", type(r[2]))
        assert.is_true(r[3] <= r[4]); assert.are.equal("boolean", type(r.forever))
        assert.is_nil(r.observed)                       -- ForeverDB publishes no per-beast count
        if not r.forever then classicSeen = true else assert.is_false(classicSeen, "Forever row after a Classic one") end
      end
    end
    for npc, spots in pairs(ns.SkinSpots) do
      assert.is_true(#spots >= 1 and #spots <= 3, "npc " .. npc)
      for _, s in ipairs(spots) do
        assert.is_true(s[1] > 0 and s[2] >= 0 and s[2] <= 100 and s[3] >= 0 and s[3] <= 100)
        assert.are.equal("boolean", type(s.forever))
      end
    end
  end)

  it("has Forever evidence for Light Leather and Light Hide", function()
    for _, item in ipairs({ 2318, 783 }) do
      local forever = 0
      for _, r in ipairs(ns.Skinning[item]) do if r.forever then forever = forever + 1 end end
      assert.is_true(forever >= 1, "item " .. item)
    end
    assert.are.same({ 1022, "Mottled Scytheclaw", 25, 26, forever = true }, ns.Skinning[2318][1])
  end)

  it("has no Forever evidence for the scales: Classic data only (documents the gap)", function()
    for _, item in ipairs({ 8154, 8167 }) do
      for _, r in ipairs(ns.Skinning[item] or {}) do assert.is_false(r.forever) end
    end
  end)
end)
