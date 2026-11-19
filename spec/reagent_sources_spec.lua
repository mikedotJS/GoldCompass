-- Data/ForeverReagentSources.lua (tools/build-reagent-sources.py): the shape the reagent tooltip reads, and Coarse Thread's case.
local ns = {}
assert(loadfile("Data/ForeverReagentSources.lua"))("GoldCompass", ns)
local R = ns.ReagentSources

describe("reagent sources", function()
  it("has the documented shape for every reagent", function()
    local n = 0
    for item, e in pairs(R) do
      n = n + 1
      assert.is_number(item)
      assert.is_true(e.vendors ~= nil or e.drops ~= nil or e.quest ~= nil)
      if e.vendors then
        assert.is_true(#e.vendors >= 1 and #e.vendors <= 60)
        local forever = true
        for _, v in ipairs(e.vendors) do
          assert.is_number(v[1]); assert.is_string(v[2]); assert.is_number(v[3]); assert.is_number(v[4]); assert.is_number(v[5])
          assert.is_truthy(v[6] == "A" or v[6] == "H" or v[6] == "AH"); assert.is_number(v[7])
          assert.is_boolean(v.forever); assert.is_truthy(v.limited == nil or v.limited == true)
          assert.is_false(v.forever and not forever)                    -- Forever-seen vendors come first
          forever = v.forever
        end
        assert.is_true(e.total >= #e.vendors); assert.is_true(e.seen >= 0)
      end
      for _, d in ipairs(e.drops or {}) do
        assert.is_string(d[1]); assert.is_number(d[2]); assert.is_boolean(d[3])
      end
      if e.quest then assert.is_string(e.quest[1]); assert.is_boolean(e.quest[4]) end
    end
    assert.is_true(n > 200)
  end)

  it("sells Coarse Thread (2320) at 10c through Forever-seen vendors open to both factions, and faction ones", function()
    local e = R[2320]
    local seen, side = 0, { A = false, H = false }
    for _, v in ipairs(e.vendors) do
      assert.are.equal(10, v[7])
      if v.forever then
        seen = seen + 1
        for s in v[6]:gmatch("[AH]") do side[s] = true end
      end
    end
    assert.is_true(seen >= 5); assert.is_true(side.A); assert.is_true(side.H)
    local a, h = false, false
    for _, v in ipairs(e.vendors) do a = a or v[6] == "A"; h = h or v[6] == "H" end
    assert.is_true(a and h)                                              -- city vendors kept for each faction
    assert.is_true(e.total > 100)
  end)

  it("keeps Coarse Thread vendors of both capitals, so a Horde or Alliance player gets a nearby one", function()
    local function has(side, maps)
      for _, v in ipairs(R[2320].vendors) do
        if v[6] == side and maps[v[3]] then return true end
      end
      return false
    end
    assert.is_true(has("H", { [1454] = true, [1456] = true }))           -- Orgrimmar, Thunder Bluff
    assert.is_true(has("A", { [1453] = true, [1455] = true }))           -- Stormwind, Ironforge
  end)

  it("caps every item at 60 vendors, each with a place", function()
    for item, e in pairs(R) do
      assert.is_true(#(e.vendors or {}) <= 60, tostring(item))
      for _, v in ipairs(e.vendors or {}) do
        assert.is_true(v[3] > 0 and v[4] > 0 and v[5] > 0, item .. " " .. v[2])
      end
    end
  end)

  it("gives a reagent no vendor sells its Forever drop sources", function()
    local e = R[723]                                                     -- Goretusk Liver
    assert.is_nil(e.vendors)
    assert.are.equal("Young Goretusk", e.drops[1][1]); assert.is_true(e.drops[1][3]); assert.is_true(e.drops[1][2] > 100)
  end)
end)
