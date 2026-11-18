-- Remembers which recipes this character knows, and what vendors charge for items (both read from game windows).
-- The recipe approach follows Forever Ledger's Professions.lua (MIT, see NOTICE): when a profession window opens,
-- C_TradeSkillUI.GetAllRecipeIDs and GetRecipeInfo(id).learned tell which recipes are learned. Nothing is clicked.
local _, ns = ...

local L = {}
ns.Learned = L

local function safe(fn, ...)
  if not fn then return end
  local ok, v = pcall(fn, ...)
  if ok then return v end
end

-- Adds every learned recipe of the open profession window to `learned` ([recipeID] = true).
-- Returns the number of recipes added. `T` is C_TradeSkillUI (a parameter so it can be tested).
function L.Capture(T, learned)
  if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo) then return 0 end
  -- skip other players' linked windows, guild windows and NPC crafting
  if safe(T.IsTradeSkillLinked) or safe(T.IsTradeSkillGuild) or safe(T.IsNPCCrafting) then return 0 end
  local ids, added = safe(T.GetAllRecipeIDs), 0
  if type(ids) ~= "table" then return 0 end
  for _, id in ipairs(ids) do
    local info = safe(T.GetRecipeInfo, id)
    if type(info) == "table" and info.learned and not learned[id] then
      learned[id] = true
      added = added + 1
    end
  end
  return added
end

-- Vendor buy prices: while a merchant window is open, remember what each item costs for one unit.
-- `api` = { count = function() -> n, item = function(i) -> itemID, price, quantity }.
function L.RecordMerchant(api, buy)
  for i = 1, api.count() or 0 do
    local id, price, qty = api.item(i)
    if id and price and price > 0 then buy[id] = price / math.max(1, qty or 1) end
  end
end

local function merchantApi()
  if not (GetMerchantNumItems and GetMerchantItemLink) then return end
  return {
    count = GetMerchantNumItems,
    item = function(i)
      local link = GetMerchantItemLink(i)
      local id = link and tonumber(link:match("item:(%d+)"))
      local price, qty
      if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(i)
        if type(info) == "table" then price, qty = info.price, info.stackCount end
      elseif GetMerchantItemInfo then
        local _, _, p, q = GetMerchantItemInfo(i)
        price, qty = p, q
      end
      return id, price, qty
    end,
  }
end

local pending = false
local function later(fn)
  if pending then return end
  pending = true
  C_Timer.After(0.6, function() pending = false; fn() end)
end

local frame = CreateFrame("Frame")
for _, e in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED", "MERCHANT_SHOW", "MERCHANT_UPDATE" }) do
  frame:RegisterEvent(e)
end
frame:SetScript("OnEvent", function(_, event)
  if not ns.db then return end
  if event:sub(1, 8) == "MERCHANT" then
    local api = merchantApi()
    if api then later(function() pcall(L.RecordMerchant, api, ns.db.buy) end) end
  else
    later(function() pcall(L.Capture, C_TradeSkillUI, ns.char.learned) end)
  end
end)
