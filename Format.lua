-- Wording shared by the tooltip and the bags tab: turns an Advice decision or recipe evaluation into French text.
local _, ns = ...
local S = ns.S

local F = {}
ns.Fmt = F

local SALE = { ah = S.act_ah, vendor = S.act_vendor, disenchant = S.act_de, none = S.act_none }

-- Recipe name in the client's language: the game's spell name for the craft spell (C_Spell.GetSpellName, or the older
-- GetSpellInfo), and the English name from Data/Recipes.lua when the game returns nothing (not cached yet, unknown ID).
function F.LocalName(recipe)
  local name
  if C_Spell and C_Spell.GetSpellName then
    name = C_Spell.GetSpellName(recipe.id)
  elseif GetSpellInfo then
    name = GetSpellInfo(recipe.id)
  end
  if type(name) == "table" then name = name.name end
  if type(name) == "string" and name ~= "" then return name end
end

function F.RecipeName(recipe) return F.LocalName(recipe) or recipe.name end

-- Headline of a decision, e.g. "Fabriquer : Huile ×2", "Garder 20, vendre le reste à l'HV".
function F.Action(d, withCount)
  local text
  if d.action == "craft" then
    text = (withCount and d.crafts > 1) and S.act_craft_n:format(F.RecipeName(d.recipe.recipe), d.crafts) or S.act_craft:format(F.RecipeName(d.recipe.recipe))
  else
    text = SALE[d.action]
  end
  if d.keep > 0 then
    return d.action == "none" and S.act_keep:format(d.keep) or S.act_keep_rest:format(d.keep, text:gsub("^%u", string.lower))
  end
  return text
end

-- One-line reason under the headline.
function F.Reason(d, sale)
  if d.keep > 0 then return S.sub_keep:format(d.quest) end
  if d.action == "craft" then return S.sub_craft:format(ns.Money(math.max(0, d.unit - sale))) end
  if d.action == "vendor" then return S.sub_vendor end
  if d.maybe then return S.sub_maybe:format(F.RecipeName(d.maybe)) end
  if d.action == "none" then return S.sub_none end
end

-- Where a recipe is learned, e.g. "entraîneur, niv. 5".
function F.Where(recipe)
  local kind = recipe.src
  if kind == "v" then return S.where_v elseif kind == "m" then return S.where_m
  elseif kind == "d" then return S.where_d elseif kind == "q" then return S.where_q end
  if recipe.guessed then return S.where_unknown end
  return S.where_trainer:format(recipe.learn or recipe.skill)
end

-- Name of a currency: the game's own (C_CurrencyInfo), else the French name known for it, else "monnaie <id>".
function F.Currency(id)
  local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(id)
  if info and info.name and info.name ~= "" then return info.name end
  return S.currency_names[id] or ("monnaie " .. tostring(id))
end

-- What learning a vendor recipe costs, as a short phrase: gold, a currency ("240 Faveur du marchand"), or "prix de la recette inconnu".
function F.VendorPrice(way)
  if way.vendorCost then return ns.Money(way.vendorCost) end
  local c = way.currency
  if c and c.id then return ("%d %s"):format(c.amount or 0, F.Currency(c.id)) end
  if c and c.item then return ("%d × %s"):format(c.amount or 0, ns.ItemName and ns.ItemName(c.item) or ("objet " .. c.item)) end
  return S.price_recipe_unknown
end

-- Age of an auction price: "prix HV du jour", "prix HV de 3 j", "prix HV sans date".
function F.AgeNote(age)
  if not age then return S.ah_age_unknown end
  return age < 1 and S.job_ah_today or S.job_ah_age:format(math.floor(age + 0.5))
end

-- The note under a recipe whose figure rests on an AH price of the crafted item: "prix HV incertain · prix HV de 5 j"; nil otherwise.
function F.PriceNote(e)
  if not e.ahSale then return end
  local parts = {}
  if e.uncertain then parts[#parts + 1] = S.ah_uncertain end
  parts[#parts + 1] = F.AgeNote(e.saleAge)
  return table.concat(parts, " · ")
end

-- What the site (wowforever.be) says about where a recipe comes from, as "butin : <zone> / pickpocket / pêche / quête : <nom>"; nil when
-- it says nothing. `way.kinds` are its source letters (v vendor, q quest, d drop, p pickpocket, f fished).
-- Name of the quest that gives a recipe: the game's own title in the client's language when the quest id is known (ForeverDB)
-- and the client has it, else the English name of the site.
function F.QuestName(way)
  local get = way.questID and C_QuestLog and C_QuestLog.GetTitleForQuestID
  local title = get and get(way.questID)
  return title and title ~= "" and title or way.questName
end

function F.SiteSources(way)
  local k = way and way.kinds
  if not k or k == "" then return end
  local zones = {}
  for part in (way.zone or ""):gmatch("[^,]+") do
    local z = part:match("^%s*(.-)%s*$")
    zones[#zones + 1] = ns.ZoneLabel({ mapID = ns.MapIDs[z] and ns.MapIDs[z][1], zone = z })
  end
  if way.zoneMore and #zones > 0 then zones[#zones + 1] = S.zone_more end   -- the site cut the list
  local out, zoneUsed = {}, #zones == 0
  for letter, label in pairs({ d = S.site_d, p = S.site_p, f = S.site_f }) do
    if k:find(letter, 1, true) then out[#out + 1] = { letter, label } end
  end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  local parts = {}
  for _, o in ipairs(out) do
    parts[#parts + 1] = zoneUsed and o[2] or (o[2] .. " : " .. table.concat(zones, ", "))
    zoneUsed = true
  end
  if k:find("q", 1, true) and way.questName then parts[#parts + 1] = S.site_q .. " : " .. F.QuestName(way) end
  if k:find("v", 1, true) and way.where then parts[#parts + 1] = S.site_v .. " : " .. way.where end
  return #parts > 0 and table.concat(parts, " / ") or nil
end

-- Where a recipe to learn comes from, in French ("entraîneur", "vendeur", ...). Classic data, not confirmed on Forever.
-- `long`: the full wording (trainer not confirmed on Forever, teaching item with its name).
function F.Source(recipe, long)
  local key = ns.Leveling.Source(recipe)
  local way = recipe.way
  if key == "trainer" and way and way.cost and not recipe.trainer then   -- Forever table: real fee, rank when above Apprentice
    local cost = ns.Money(way.cost)
    if way.rank and way.rank ~= "Apprentice" then
      return (long and S.src_trainer_rank_long or S.src_trainer_rank):format(S.rank_names[way.rank] or way.rank, cost)
    end
    return S.src_trainer_cost:format(cost)
  end
  if key == "trainer" and way and not way.confirmed and not recipe.trainer then
    return long and S.src_trainer_unc or S.src_trainer_unc_short
  end
  if key == "v" and way then return S.src_v_price:format(F.VendorPrice(way)) end
  if key == "i" and recipe.fee and way and way.kind == "item" then   -- a pattern bought at the auction house
    if not long then return S.src_i_ah:format(ns.Money(recipe.fee)) end
    return S.src_i_ah_long:format(ns.Money(recipe.fee), F.AgeNote(recipe.feeAge))
  end
  if key == "i" and long and recipe.itemName then return S.src_i_named:format(recipe.itemName) end
  return S["src_" .. key]
end

-- Colored status of an evaluated recipe.
function F.Status(e)
  local st, r = e.status, e.recipe
  if st == "known" then return S.st_known end
  if st == "learn" then return S.st_learn:format(F.Where(r)) end
  if st == "quest" then return S.st_quest end
  if st == "locked" then return S.st_locked:format(r.learn or r.skill) end
  return S.st_noprof:format(S.prof_names[r.prof] or r.prof)
end
