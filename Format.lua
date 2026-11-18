-- Wording shared by the tooltip and the bags tab: turns an Advice decision or recipe evaluation into French text.
local _, ns = ...
local S = ns.S

local F = {}
ns.Fmt = F

local SALE = { ah = S.act_ah, vendor = S.act_vendor, disenchant = S.act_de, none = S.act_none }

-- Headline of a decision, e.g. "Fabriquer : Huile ×2", "Garder 20, vendre le reste à l'HV".
function F.Action(d, withCount)
  local text
  if d.action == "craft" then
    text = (withCount and d.crafts > 1) and S.act_craft_n:format(d.recipe.recipe.name, d.crafts) or S.act_craft:format(d.recipe.recipe.name)
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
  if d.action == "none" then return S.sub_none end
end

-- Where a recipe is learned, e.g. "entraîneur, niv. 5".
function F.Where(recipe)
  local kind = recipe.src
  if kind == "v" then return S.where_v elseif kind == "m" then return S.where_m
  elseif kind == "d" then return S.where_d elseif kind == "q" then return S.where_q end
  return S.where_trainer:format(recipe.learn or recipe.skill)
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
