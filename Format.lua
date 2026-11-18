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

-- Where a recipe to learn comes from, in French ("entraîneur", "vendeur", ...). Classic data, not confirmed on Forever.
-- `long`: the full wording (trainer not confirmed on Forever, teaching item with its name).
function F.Source(recipe, long)
  local key = ns.Leveling.Source(recipe)
  local way = recipe.way
  if key == "trainer" and way and not way.confirmed and not recipe.trainer then
    return long and S.src_trainer_unc or S.src_trainer_unc_short
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
