-- tools/datacheck.lua (run by tools/check-data.lua, the gate of the update bot): the committed data passes, and each rule fires on a
-- copy of the data that was damaged on purpose.
package.path = "tools/?.lua;" .. package.path
local datacheck = require("datacheck")
local known = dofile("tools/check-data-known.lua")

local function sh(cmd) assert(os.execute(cmd)) end
local function read(path) local h = assert(io.open(path, "rb")); local t = h:read("*a"); h:close(); return t end
local function write(path, text) local h = assert(io.open(path, "wb")); h:write(text); h:close() end

-- a copy of Data/ in a temporary folder, one file damaged by `change(text) -> text`
local function damaged(file, change)
  local dir = os.tmpname()
  os.remove(dir)
  sh('mkdir -p "' .. dir .. '" && cp Data/*.lua "' .. dir .. '/"')
  local text = read(dir .. "/" .. file)
  local new = change(text)
  assert.is_not.equals(text, new, "the damage changed nothing")
  write(dir .. "/" .. file, new)
  return dir
end
local function errorsOf(dir, baseline)
  local report = datacheck.run(dir, baseline, known)
  sh('rm -rf "' .. dir .. '"')
  return report
end
local function mentions(report, text)
  for _, e in ipairs(report.errors) do if e:find(text, 1, true) then return true end end
  return false
end

describe("tools/datacheck", function()
  it("finds nothing new in the committed data, and looks at all of it", function()
    local report = datacheck.run("Data", "Data", known)
    assert.same({}, report.errors)
    assert.same({}, report.warnings)
    assert.is_true(report.counts.files >= 16 and report.counts.npcs > 400 and report.counts.recipes > 4000 and report.counts.points > 10000)
  end)

  it("flags a point outside 0..100", function()
    local dir = damaged("Npcs.lua", function(t) return (t:gsub('{ { 1429, 54, 52.2 } }', '{ { 1429, 154, 52.2 } }', 1)) end)
    assert.is_true(mentions(errorsOf(dir), "outside 0..100"))
  end)

  it("flags a packed skin point outside 0..100", function()
    local dir = damaged("ForeverSkinPoints.lua", function(t) return (t:gsub('(\n  %[%d+%] = ")', '%1zz00', 1)) end)
    assert.is_true(mentions(errorsOf(dir), "outside 0..100"))
  end)

  it("flags a uiMapID that neither ns.Zones nor ns.MapIDs has", function()
    local dir = damaged("Npcs.lua", function(t) return (t:gsub('{ { 1429, 54, 52.2 } }', '{ { 9999, 54, 52.2 } }', 1)) end)
    assert.is_true(mentions(errorsOf(dir), "uiMapID 9999"))
  end)

  it("flags a recipe source npc that has no position", function()
    local dir = damaged("ForeverRecipes.lua", function(t) return (t:gsub('%[16745%] = { "q", {  }, { 7649 } }', '[16745] = { "q", {  }, { 7649, 987654 } }', 1)) end)
    assert.is_true(mentions(errorsOf(dir), "npc 987654"))
  end)

  it("flags a recipe with no reagent", function()
    local dir = damaged("Recipes.lua", function(t) return (t:gsub('"Elixir of Minor Strength", "2449:1,765:1,3371:1"', '"Elixir of Minor Strength", ""', 1)) end)
    assert.is_true(mentions(errorsOf(dir), "empty reagent list"))
  end)

  it("flags a beast of the skin points that the skin zones lack, and a duplicated key", function()
    local dir = damaged("ForeverSkinPoints.lua", function(t) return (t:gsub('ns.SkinPoints = {\n', 'ns.SkinPoints = {\n  [999990001] = ".",\n  [999990001] = ".",\n', 1)) end)
    local report = errorsOf(dir)
    assert.is_true(mentions(report, "beast 99999 is not in ForeverSkinZones.lua"))
    assert.is_true(mentions(report, "duplicated key 999990001"))
  end)

  it("warns, without failing, when a file changes size by more than 30 percent", function()
    local dir = damaged("Zones.lua", function(t) return t .. ("-- padding\n"):rep(1000) end)
    local report = datacheck.run(dir, "Data", known)
    sh('rm -rf "' .. dir .. '"')
    assert.same({}, report.errors)
    assert.equals(1, #report.warnings)
    assert.is_truthy(report.warnings[1]:find("Zones.lua", 1, true))
  end)
end)
