-- "Liste de courses": what the roadmap of "Monter le métier" still needs, summed over the professions. Pure Lua (the counts come in
-- through `env`), so the tests give their own.
local _, ns = ...

local Sh = {}
ns.Shopping = Sh

-- profs = the professions of ns.RunLeveling (each with its `road`); env = { bag(id), bank(id), name(id) }, what the character carries,
-- what the bank held when last seen, and the item name; optional env.hint(id, missing) (Synergy.lua: the character's own gathering gives
-- it) and env.vendor(id) (a merchant sells it). Returns
--   rows  = { { item, name, have = bag + bank, need, bank = banked count, fetch = the part the roadmap takes from the bank, ok, tip, hint } }
--           incomplete first (most missing first, or own gathering first when a hint says so), then the ones to fetch from the bank,
--           then the complete ones
--   missing = number of distinct items still short, fetch = { { item, name, n } } the roadmap takes from the bank,
--   upTo = { { name, skill } } the skill each roadmap runs to,
--   farm = { zone, prof, hours, units } the zone that covers the most units of what the character's own gathering gives within a few hours
--          (only when there is one)
function Sh.Build(profs, env)
  local need, fetch, tips, upTo = {}, {}, {}, {}
  for _, p in ipairs(profs) do
    local road = p.road
    local crafts = false
    for _, s in ipairs(road and not road.capped and road.steps or {}) do
      if s.kind == "craft" then
        crafts = true
        for item, n in pairs(s.used or {}) do need[item] = (need[item] or 0) + n end
        for _, m in ipairs(s.missing) do
          need[m.item] = (need[m.item] or 0) + m.n
          tips[m.item] = tips[m.item] or m.tip
        end
        for _, m in ipairs(s.banked or {}) do
          fetch[m.item] = (fetch[m.item] or 0) + m.n
          tips[m.item] = tips[m.item] or m.tip
        end
      end
    end
    if crafts then upTo[#upTo + 1] = { name = p.name, skill = road.skillEnd } end
  end
  local rows, missing, take = {}, 0, {}
  for item, n in pairs(need) do
    local bank = env.bank(item)
    local row = { item = item, name = env.name(item), have = env.bag(item) + bank, need = n, bank = bank, fetch = fetch[item] or 0, tip = tips[item] }
    row.ok = row.have >= n
    if not row.ok then
      missing = missing + 1
      row.hint = env.hint and env.hint(item, n - row.have) or nil
    end
    rows[#rows + 1] = row
    if row.fetch > 0 then take[#take + 1] = { item = item, name = row.name, n = row.fetch } end
  end
  local function group(r) return (not r.ok and 0) or (r.fetch > 0 and 1) or 2 end
  -- farm order inside the incomplete rows, only when some row has something to farm: 0 own gathering in the roadmap's zone, 1 own
  -- gathering elsewhere (within the hour limit), 2 merchant, 3 the rest (auction, drop, rare). Without a hint the order is the plain one.
  local farmable = false
  for _, r in ipairs(rows) do farmable = farmable or (r.hint ~= nil and not r.hint.rare) end
  local function rank(r)
    if r.hint and not r.hint.rare then return r.hint.here and 0 or 1 end
    return env.vendor and env.vendor(r.item) and 2 or 3
  end
  table.sort(rows, function(a, b)
    if group(a) ~= group(b) then return group(a) < group(b) end
    if farmable and not a.ok then
      local ra, rb = rank(a), rank(b)
      if ra ~= rb then return ra < rb end
      if ra < 2 and a.hint.hours ~= b.hint.hours then return a.hint.hours < b.hint.hours end
    end
    if not a.ok and a.need - a.have ~= b.need - b.have then return a.need - a.have > b.need - b.have end
    if a.name ~= b.name then return a.name < b.name end
    return a.item < b.item
  end)
  table.sort(take, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.item < b.item end)
  local result = { rows = rows, missing = missing, fetch = take, upTo = upTo }
  -- where to farm first: the (zone, profession) pair that covers the most missing units of the rows ranked 0 or 1
  local per, bestKey = {}, nil
  for _, r in ipairs(farmable and rows or {}) do
    local h = r.hint
    if not r.ok and h and not h.rare then
      local key = h.zone .. ":" .. h.prof
      local e = per[key] or { zone = h.zone, prof = h.prof, hours = 0, units = 0 }
      per[key] = e
      e.units, e.hours = e.units + (r.need - r.have), math.max(e.hours, h.hours)
      if not bestKey or e.units > per[bestKey].units or (e.units == per[bestKey].units and key < bestKey) then bestKey = key end
    end
  end
  result.farm = bestKey and per[bestKey] or nil
  return result
end

-- "6 × Peau légère, 12 × Cuir léger": what to take at the bank, the biggest quantity first.
function Sh.FetchText(fetch)
  local parts = {}
  for i, f in ipairs(fetch) do parts[i] = ("%d × %s"):format(f.n, f.name) end
  return table.concat(parts, ", ")
end
