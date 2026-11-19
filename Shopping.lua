-- "Liste de courses": what the roadmap of "Monter le métier" still needs, summed over the professions. Pure Lua (the counts come in
-- through `env`), so the tests give their own.
local _, ns = ...

local Sh = {}
ns.Shopping = Sh

-- profs = the professions of ns.RunLeveling (each with its `road`); env = { bag(id), bank(id), name(id) }, what the character carries,
-- what the bank held when last seen, and the item name. Returns
--   rows  = { { item, name, have = bag + bank, need, bank = banked count, fetch = the part the roadmap takes from the bank, ok, tip } }
--           incomplete first (most missing first), then the ones to fetch from the bank, then the complete ones
--   missing = number of distinct items still short, fetch = { { item, name, n } } the roadmap takes from the bank,
--   upTo = { { name, skill } } the skill each roadmap runs to
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
    if not row.ok then missing = missing + 1 end
    rows[#rows + 1] = row
    if row.fetch > 0 then take[#take + 1] = { item = item, name = row.name, n = row.fetch } end
  end
  local function group(r) return (not r.ok and 0) or (r.fetch > 0 and 1) or 2 end
  table.sort(rows, function(a, b)
    if group(a) ~= group(b) then return group(a) < group(b) end
    if not a.ok and a.need - a.have ~= b.need - b.have then return a.need - a.have > b.need - b.have end
    if a.name ~= b.name then return a.name < b.name end
    return a.item < b.item
  end)
  table.sort(take, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.item < b.item end)
  return { rows = rows, missing = missing, fetch = take, upTo = upTo }
end

-- "6 × Peau légère, 12 × Cuir léger": what to take at the bank, the biggest quantity first.
function Sh.FetchText(fetch)
  local parts = {}
  for i, f in ipairs(fetch) do parts[i] = ("%d × %s"):format(f.n, f.name) end
  return table.concat(parts, ", ")
end
