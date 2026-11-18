-- luacheck: ignore 212/self (the methods keep the library's DB:method() call shape)
-- Accessor over Data/ForeverRecipes.lua (WoW Forever data of LibProfessionDB v1.10.1, vendored): the same answers the
-- library gave, without the library. Pure Lua, no WoW API. Used by Leveling.Way / Leveling.LibCrafts as their `DB`.
local _, ns = ...

local D = ns.ForeverData
local KINDS = { { "t", "trainer" }, { "v", "vendor" }, { "q", "quest" }, { "c", "container" }, { "d", "drop" } }
local FACTION = { A = "Alliance", H = "Horde" }

local DB = { MINOR = D.version }
ns.ForeverDB = DB

local byLine, flags, cache = {}, {}, {}   -- byLine[line][spellID] = row; flags[spellID] = flag string
local count, counts, englishName = 0, {}, nil
for line, rows in pairs(D.recipes) do
  byLine[line], counts[line] = {}, #rows
  for _, r in ipairs(rows) do
    byLine[line][r[1]] = r
    flags[r[1]] = r[10]
  end
  count = count + #rows
end

-- English name of Data/Recipes.lua (built on first use), else the vendored last-resort name, else "#spellID".
local function nameOf(id)
  if not englishName then
    englishName = {}
    for _, r in ipairs(ns.RecipeRows or {}) do englishName[r[1]] = r[8] end
  end
  return englishName[id] or D.name[id] or ("#" .. id)
end

function DB:IsReady() return count > 0 end
function DB:Count() return count end
function DB:GetGameVersion() return "Forever" end
function DB:GetVersion() return D.version, D.build end
function DB:HasProfession(line) return byLine[line] ~= nil end
function DB:ProfessionCount(line) return counts[line] or 0 end

-- Recipes of a skill line: { [spellID] = { name, craftedItemId, reagents = { [item] = count }, requiredSkill, difficulty } }
function DB:GetRecipes(line)
  if not byLine[line] then return nil end
  if not cache[line] then
    local out = {}
    for id, r in pairs(byLine[line]) do
      local reagents = {}
      for item, n in r[8]:gmatch("(%d+):(%d+)") do reagents[tonumber(item)] = tonumber(n) end
      out[id] = { name = nameOf(id), craftedItemId = r[7] ~= 0 and r[7] or nil, reagents = reagents,
        requiredSkill = r[2] ~= 0 and r[2] or nil, difficulty = { r[3], r[4], r[5], r[6] } }
    end
    cache[line] = out
  end
  return cache[line]
end

local function has(id, flag) local f = flags[id]; return f ~= nil and f:find(flag, 1, true) ~= nil end
function DB:IsHiddenRecipe(id) return has(id, "h") end
function DB:IsAutoTaughtRecipe(id) return has(id, "a") end

-- "Vanilla" when the value is not Forever's own (field: requiredSkill, sources, hidden), else nil
function DB:IsBorrowed(id, field)
  local flag = ({ requiredSkill = "r", sources = "s", hidden = "x" })[field]
  return flag and has(id, flag) and "Vanilla" or nil
end

-- Are this recipe's vendors Forever's own (seen on live merchants), although the library lists its sources as borrowed?
function DB:HasOwnVendors(id) return has(id, "o") end

local function find(id)
  for _, rows in pairs(byLine) do if rows[id] then return rows[id] end end
end
function DB:GetRecipeItem(id)
  local r = find(id)
  return r and r[9] ~= 0 and r[9] or nil
end

function DB:GetSourceFaction(npc) return FACTION[D.faction[npc]] end

-- What a vendor charges: a list of { currencyID | itemID, amount } | { copper } parts, or nil.
function DB:GetVendorCost(id, npc)
  local parts = D.cost[id] and D.cost[id][npc]
  if not parts then return nil end
  local out = {}
  for i, p in ipairs(parts) do
    out[i] = p.c and { currencyID = p.c, amount = p.n } or p.i and { itemID = p.i, amount = p.n } or { copper = p.g }
  end
  return out
end

-- Where a recipe comes from: { trainer = { total = 1 }, vendor = { { id, name, faction, cost } , total }, quest = ... } or nil.
-- Only vendor and quest entries list NPCs (the others are present with a total of 1 and no entries).
function DB:GetRecipeSources(id)
  local s = D.src[id]
  if not s then return nil end
  local kinds, vendors, quests = s, {}, {}
  if type(s) == "table" then kinds, vendors, quests = s[1], s[2], s[3] end
  local out = {}
  for _, k in ipairs(KINDS) do
    if kinds:find(k[1], 1, true) then
      local list = { total = 1 }
      for _, npc in ipairs(k[1] == "v" and vendors or k[1] == "q" and quests or {}) do
        list[#list + 1] = { id = npc, name = D.npc[npc], faction = self:GetSourceFaction(npc), cost = k[1] == "v" and self:GetVendorCost(id, npc) or nil }
      end
      if #list > 0 then list.total = #list end
      out[k[2]] = list
    end
  end
  return out
end
