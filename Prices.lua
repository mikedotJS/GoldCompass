-- The only file that talks to Auctionator (public API v1, PLAN.md section 3 S3).
local _, ns = ...

local P = {}
ns.Prices = P

local CALLER = "GoldCompass"

local function api() return Auctionator and Auctionator.API and Auctionator.API.v1 end

function P.Installed() return api() ~= nil and api().GetAuctionPriceByItemID ~= nil end

-- False when this Auctionator version has no age call: prices are then used without a freshness check.
function P.HasAge() return api() ~= nil and api().GetAuctionAgeByItemID ~= nil end

-- Returns copper|nil (nil = never scanned) and age in days|nil (nil = older than 21 days or never seen).
-- Raises "price_api" when Auctionator itself fails, so the caller can show the error state.
function P.Get(itemID)
  local a = api()
  local ok, price = pcall(a.GetAuctionPriceByItemID, CALLER, itemID)
  if not ok then error("price_api", 0) end
  if not price then return nil end
  if not P.HasAge() then return price end
  local okAge, age = pcall(a.GetAuctionAgeByItemID, CALLER, itemID)
  return price, okAge and age or nil
end

-- What a vendor pays, from the game's own item data (11th value of GetItemInfo); nil when not loaded or worthless.
function P.Vendor(itemID)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local sell = select(11, getInfo(itemID))
  if sell and sell > 0 then return sell end
end

-- Disenchant value in copper, or nil when Auctionator cannot say (the call is unverified, spike S3).
function P.Disenchant(itemID)
  local a = api()
  if not (a and a.GetDisenchantPriceByItemID) then return end
  local ok, v = pcall(a.GetDisenchantPriceByItemID, CALLER, itemID)
  if ok and v and v > 0 then return v end
end
