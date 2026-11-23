-- Smart item tooltip (PLAN.md step 4, docs/mockup.html "Infobulle"): a Gold Compass section under the normal tooltip.
-- Thin glue: the decisions come from Advice.lua. Silent in combat. With Forever Ledger loaded, its verdict is left
-- alone and only the recipes it lacks are added (PLAN.md Q1).
local _, ns = ...
local S = ns.S

local SHOWN = 3
local GOOD, KEEP, MUTE = { 0.12, 1, 0 }, { 1, 0.82, 0 }, { 0.62, 0.62, 0.62 }
local ACTION_COLOR = { craft = GOOD, ah = GOOD, disenchant = GOOD, vendor = MUTE, none = MUTE }
local failed
local current, requested, waiting = nil, {}, {}  -- item of the section drawn last; spells asked for; spells awaited

-- Spell names are not cached for recipes the player does not know: ask the game once per spell and redraw on arrival.
local function requestSpell(id)
  if requested[id] or not (C_Spell and C_Spell.RequestLoadSpellData) then return end
  requested[id] = true
  waiting[id] = true
  pcall(C_Spell.RequestLoadSpellData, id)
end

local function ledgerLoaded()
  local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  return isLoaded and isLoaded("ForeverLedger")
end

-- Which items of the bags are soulbound: the game's item count has no such flag, so the same scan as the Bags tab runs once after each change of
-- the bags (BAG_UPDATE_DELAYED), not at each hover.
local boundIds, boundStale = {}, true
local function isBound(id)
  if boundStale then
    boundIds, boundStale = {}, false
    for _, it in ipairs(ns.BagItems() or {}) do if it.bound then boundIds[it.id] = true end end
  end
  return boundIds[id]
end

-- What an item is used for (the price of every recipe that takes it) is the costly part of a tooltip: kept for a few seconds, so a redraw
-- (Shift) or a second look at the same item costs nothing. The whole table is dropped when the window is over.
local USES_TTL = 5
local usesCache, usesFrom = {}, 0
local function usesOf(id, ctx)
  local now = time()
  if now - usesFrom >= USES_TTL then usesCache, usesFrom = {}, now end
  local uses = usesCache[id]
  if not uses then uses = ns.Advice.Uses(id, ctx); usesCache[id] = uses end
  return uses
end

local function addSection(tt, id)
  if InCombatLockdown() or not (ns.Prices.Installed() and ns.RecipeRows) then return end
  current = id
  local ctx = ns.Context()
  local owned = ctx.owned(id)   -- what the bags hold, from the game's own count
  local d = ns.Advice.Decide({ id = id, count = owned > 0 and owned or 1, gear = ns.IsGear(id), bound = owned > 0 and isBound(id) or nil }, ctx)
  local uses = usesOf(id, ctx)
  local showVerdict = not ledgerLoaded()
  if not showVerdict and uses.total == 0 then return end

  tt:AddLine(" ")
  tt:AddLine(S.gc_header)
  if showVerdict then
    local c = d.keep > 0 and KEEP or ACTION_COLOR[d.action]
    if d.action == "none" and d.keep == 0 then
      tt:AddLine(ns.Fmt.Action(d, false), c[1], c[2], c[3])
    else
      tt:AddDoubleLine(ns.Fmt.Action(d, false), ns.Money(d.unit), c[1], c[2], c[3], 1, 1, 1)
    end
    local reason = ns.Fmt.Reason(d, d.sale)
    if reason then tt:AddLine(reason, MUTE[1], MUTE[2], MUTE[3]) end
  end
  if uses.total > 0 then
    local more = IsShiftKeyDown()
    tt:AddDoubleLine(S.uses:format(uses.total, uses.total > 1 and "s" or ""), S.uses_price, 1, 0.82, 0, 0.62, 0.62, 0.62)
    local unconfirmed = false
    for i = 1, more and uses.total or math.min(SHOWN, uses.total) do
      local e = uses.list[i]
      unconfirmed = unconfirmed or e.status ~= "known"
      if not ns.Fmt.LocalName(e.recipe) then requestSpell(e.recipe.id) end
      -- name and result price on the same row; the status, dim, on the line below
      tt:AddDoubleLine(ns.Fmt.RecipeName(e.recipe), ns.Money(e.result), 1, 1, 1, 1, 1, 1)
      tt:AddLine("  " .. ns.Fmt.Status(e))
    end
    if not more and uses.total > SHOWN then tt:AddLine(S.uses_more:format(uses.total - SHOWN), MUTE[1], MUTE[2], MUTE[3]) end
    if unconfirmed then tt:AddLine(S.tip_unconfirmed, MUTE[1], MUTE[2], MUTE[3]) end
  end
  local _, age = ctx.price(id)
  tt:AddLine(age and (age < 1 and S.tip_estimate_today or S.tip_estimate:format(ns.AgeText(age))) or S.tip_estimate_nodate, MUTE[1], MUTE[2], MUTE[3])
end

local function onItem(tt, id)
  if tt ~= GameTooltip or not id then return end
  local ok, err = pcall(addSection, tt, id)
  ns.LogOnce("tooltip-first", "hook", "first item tooltip section added")
  if not ok and not failed then
    failed = true
    ns.Print(S.tip_error:format(tostring(err)))
  end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
  ns.Log("hook", "TooltipDataProcessor.AddTooltipPostCall(Item) registered")
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data) onItem(tt, data and data.id) end)
else
  ns.Log("hook", "GameTooltip:HookScript(OnTooltipSetItem) registered (legacy path)")
  GameTooltip:HookScript("OnTooltipSetItem", function(tt)
    local _, link = tt:GetItem()
    onItem(tt, link and tonumber(link:match("item:(%d+)")))
  end)
end

-- Holding or releasing Shift redraws the tooltip, so the full recipe list appears without moving the mouse.
ns.Log("hook", "MODIFIER_STATE_CHANGED listener registered (calls GameTooltip:RefreshData outside combat)")
local shift = CreateFrame("Frame")
shift:RegisterEvent("MODIFIER_STATE_CHANGED")
shift:RegisterEvent("SPELL_DATA_LOAD_RESULT")
pcall(shift.RegisterEvent, shift, "BAG_UPDATE_DELAYED")
shift:SetScript("OnEvent", function(_, event, spellID)
  if event == "BAG_UPDATE_DELAYED" then boundStale = true; return end
  if InCombatLockdown() or not GameTooltip:IsShown() or not GameTooltip.RefreshData then return end
  if not GameTooltip.GetItem then return end
  local _, link = GameTooltip:GetItem()
  if not link then return end -- item tooltips only
  if event == "SPELL_DATA_LOAD_RESULT" then
    -- a spell name arrived: redraw once, and only if the tooltip still shows the item the request was made for
    if not waiting[spellID] or tonumber(link:match("item:(%d+)")) ~= current then return end
    waiting[spellID] = nil
  end
  GameTooltip:RefreshData()
end)
