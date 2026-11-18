-- Smart item tooltip (PLAN.md step 4, docs/mockup.html "Infobulle"): a Gold Compass section under the normal tooltip.
-- Thin glue: the decisions come from Advice.lua. Silent in combat. With Forever Ledger loaded, its verdict is left
-- alone and only the recipes it lacks are added (PLAN.md Q1).
local _, ns = ...
local S = ns.S

local SHOWN = 3
local GOOD, KEEP, MUTE = { 0.12, 1, 0 }, { 1, 0.82, 0 }, { 0.62, 0.62, 0.62 }
local ACTION_COLOR = { craft = GOOD, ah = GOOD, disenchant = GOOD, vendor = MUTE, none = MUTE }
local failed

local function ledgerLoaded()
  local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  return isLoaded and isLoaded("ForeverLedger")
end

local function addSection(tt, id)
  if InCombatLockdown() or not (ns.Prices.Installed() and ns.RecipeRows) then return end
  local ctx = ns.Context()
  local count = math.max(1, (C_Item.GetItemCount and C_Item.GetItemCount(id)) or 1)
  local d = ns.Advice.Decide({ id = id, count = count, gear = ns.IsGear(id) }, ctx)
  local uses = ns.Advice.Uses(id, ctx)
  local showVerdict = not ledgerLoaded() and (d.action ~= "none" or d.keep > 0)
  if not showVerdict and uses.total == 0 then return end

  tt:AddLine(" ")
  tt:AddLine(S.gc_header)
  if showVerdict then
    local c = d.keep > 0 and KEEP or ACTION_COLOR[d.action]
    tt:AddDoubleLine(ns.Fmt.Action(d, false), ns.Money(d.unit), c[1], c[2], c[3], 1, 1, 1)
    local reason = ns.Fmt.Reason(d, d.sale)
    if reason then tt:AddLine(reason, MUTE[1], MUTE[2], MUTE[3]) end
  end
  if uses.total > 0 then
    local more = IsShiftKeyDown()
    tt:AddDoubleLine(S.uses:format(uses.total, uses.total > 1 and "s" or ""), S.uses_price, 1, 0.82, 0, 0.62, 0.62, 0.62)
    local classic = false
    for i = 1, more and uses.total or math.min(SHOWN, uses.total) do
      local e = uses.list[i]
      classic = classic or e.recipe.src ~= nil
      tt:AddDoubleLine(e.recipe.name .. "  " .. ns.Fmt.Status(e), ns.Money(e.result), 1, 1, 1, 1, 1, 1)
    end
    if not more and uses.total > SHOWN then tt:AddLine(S.uses_more:format(uses.total - SHOWN), MUTE[1], MUTE[2], MUTE[3]) end
    if classic then tt:AddLine(S.tip_unconfirmed, MUTE[1], MUTE[2], MUTE[3]) end
  end
  local _, age = ctx.price(id)
  tt:AddLine(age and S.tip_estimate:format(ns.AgeText(age)) or S.tip_estimate_nodate, MUTE[1], MUTE[2], MUTE[3])
end

local function onItem(tt, id)
  if tt ~= GameTooltip or not id then return end
  local ok, err = pcall(addSection, tt, id)
  if not ok and not failed then
    failed = true
    ns.Print(S.tip_error:format(tostring(err)))
  end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data) onItem(tt, data and data.id) end)
else
  GameTooltip:HookScript("OnTooltipSetItem", function(tt)
    local _, link = tt:GetItem()
    onItem(tt, link and tonumber(link:match("item:(%d+)")))
  end)
end

-- Holding or releasing Shift redraws the tooltip, so the full recipe list appears without moving the mouse.
local shift = CreateFrame("Frame")
shift:RegisterEvent("MODIFIER_STATE_CHANGED")
shift:SetScript("OnEvent", function()
  if GameTooltip:IsShown() and GameTooltip.RefreshData then GameTooltip:RefreshData() end
end)
