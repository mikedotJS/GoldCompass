-- Pure helpers for the Here tab (PLAN.md step 6): comparison with another zone, profession hint, quest pick-ups.
local _, ns = ...

local H = {}
ns.Here = H

-- rows = the full ranking (best first). Returns nil when the zone has no data.
-- { row, rank, other, ratio, best = bool }: best = this zone is the top one, other = the runner-up (or the top zone).
function H.Compare(rows, zone)
  for i, row in ipairs(rows) do
    if row.zone == zone then
      local best = i == 1
      local other = best and rows[2] or rows[1]
      local ratio
      if other and row.copperPerHour > 0 and other.copperPerHour > 0 then
        ratio = best and row.copperPerHour / other.copperPerHour or other.copperPerHour / row.copperPerHour
      end
      return { row = row, rank = i, other = other, ratio = ratio, best = best }
    end
  end
end

-- Gold per hour this zone would add if the character also had `profession` at `skill`. input = a ZoneRank.Rank input.
-- Returns copper per hour (>= 0), or nil when it adds nothing.
function H.ProfessionGain(input, zone, profession, skill)
  local counts = input.zones[zone]
  if not counts then return end
  local function rank(skills)
    local copy = {}
    for k, v in pairs(input) do copy[k] = v end
    copy.zones, copy.skills = { [zone] = counts }, skills
    local r = ns.ZoneRank.Rank(copy)
    return r.rows[1] and r.rows[1].copperPerHour or 0
  end
  local base = rank(input.skills)
  local with = {}
  for k, v in pairs(input.skills) do with[k] = v end
  with[profession] = skill
  local gain = rank(with) - base
  if gain > 0 then return gain end
end

-- Items that quests of this zone (English name) ask for, still relevant for the character, best AH value first.
-- Returns { { item, count, quest, unit } }.
function H.Pickups(zoneName, questItems, ctx)
  local list = {}
  for item, quests in pairs(questItems) do
    for _, q in ipairs(quests) do
      if q.zone == zoneName and ns.Advice.QuestRelevant(q, ctx) then
        local unit = ns.ZoneRank.UnitValue(item, ctx.price, ctx.vendor, ns.ZoneRank.DEFAULTS, ctx.ageKnown)
        list[#list + 1] = { item = item, count = q.count, quest = q.quest, unit = unit }
        break
      end
    end
  end
  table.sort(list, function(a, b)
    if a.unit ~= b.unit then return a.unit > b.unit end
    return a.item < b.item
  end)
  return list
end
