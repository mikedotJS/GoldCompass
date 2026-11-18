-- /gc spike: prints what spikes S1 to S4 of PLAN.md need, from the real game. Read-only, throwaway diagnostic.
local _, ns = ...

local function out(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  ns.Say("|cff3fe0c5[spike]|r " .. table.concat(parts, " "))
end
local function try(label, fn, ...)
  local ok, a, b, c = pcall(fn, ...)
  out(label, ok and (tostring(a) .. " " .. tostring(b) .. " " .. tostring(c)) or ("ERROR " .. tostring(a)))
end

function ns.Spike()
  -- S1: the addon loaded, which TOC the client picked, client identity
  local meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  try("S1 build (version, build, date, interface):", GetBuildInfo)
  out("S1 WOW_PROJECT_ID:", tostring(WOW_PROJECT_ID), " TOC used (X-TocFile):", tostring(meta and meta("GoldCompass", "X-TocFile")))
  out("S1 GatherMate2 global:", tostring(GatherMate2 ~= nil), " Auctionator global:", tostring(Auctionator ~= nil))

  -- S2: node counts through GatherMate2 for Durotar (1411) and the whole database
  if ns.Nodes.Installed() then
    local okc, zones, total = pcall(ns.Nodes.Counts)
    if okc then
      local zoneCount, known, unknown = 0, 0, 0
      for _, nodes in pairs(zones) do
        zoneCount = zoneCount + 1
        for nodeID, spots in pairs(nodes) do
          if ns.GatherNodes[nodeID] and ns.GatherNodes[nodeID].item then known = known + spots else unknown = unknown + spots end
        end
      end
      local herb, ore = 0, 0
      for nodeID, spots in pairs(zones[1411] or {}) do
        local t = ns.GatherNodes[nodeID] and ns.GatherNodes[nodeID].type
        if t == "Herb Gathering" then herb = herb + spots elseif t == "Mining" then ore = ore + spots end
      end
      out(("S2 Durotar (1411): %d herb spots, %d ore spots (before the import this must be 0 and 0)"):format(herb, ore))
      out(("S2 all zones: %d zones, %d spots, %d in the item table, %d not in it"):format(zoneCount, total, known, unknown))
    else
      out("S2 ERROR reading GatherMate2:", tostring(zones))
    end
  else
    out("S2 GatherMate2 not installed")
  end

  -- S3: Auctionator calls, for Copper Ore (2770) and Peacebloom (2447)
  local v1 = Auctionator and Auctionator.API and Auctionator.API.v1
  if v1 then
    for _, fn in ipairs({ "GetAuctionPriceByItemID", "GetAuctionAgeByItemID", "GetVendorPriceByItemID", "GetDisenchantPriceByItemID" }) do
      out("S3 Auctionator.API.v1." .. fn .. ":", v1[fn] and "present" or "MISSING")
    end
    for _, id in ipairs({ 2770, 2447 }) do
      try(("S3 item %d price, age (nil before any scan):"):format(id), ns.Prices.Get, id)
      out(("S3 item %d vendor price from item data:"):format(id), tostring((ns.Prices.Vendor(id))))
    end
  else
    out("S3 Auctionator API not found")
  end

  -- S4: zone, level, professions (Core.lua matches skill lines 182 Herbalism and 186 Mining)
  try("S4 current map ID:", C_Map.GetBestMapForUnit, "player")
  out("S4 player level:", tostring(UnitLevel("player")))
  if GetProfessions and GetProfessionInfo then
    for slot, index in pairs({ GetProfessions() }) do
      local name, _, skill, _, _, _, skillLine = GetProfessionInfo(index)
      out(("S4 profession slot %s: %s skill %s skillLine %s"):format(tostring(slot), tostring(name), tostring(skill), tostring(skillLine)))
    end
  else
    out("S4 GetProfessions / GetProfessionInfo missing")
  end
  -- S5: APIs the tooltip, bags and here tabs rely on
  out("S5 TooltipDataProcessor:", tostring(TooltipDataProcessor ~= nil), " C_Container:", tostring(C_Container ~= nil),
    " IsPlayerSpell:", tostring(IsPlayerSpell ~= nil), " OpenWorldMap:", tostring(OpenWorldMap ~= nil), " ForeverLedger loaded:",
    tostring((C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("ForeverLedger")) or false))
  if IsPlayerSpell then
    try("S5 IsPlayerSpell(2329 Elixir of Minor Strength; true only if you know it):", IsPlayerSpell, 2329)
  end
  out("S5 profession window API:", tostring(C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs ~= nil), " merchant API:",
    tostring(GetMerchantNumItems ~= nil), tostring(C_MerchantFrame ~= nil), " vendor buy price of item 3371 (Auctionator):",
    tostring((ns.Prices.VendorBuy(3371))))
  out("done. Send back every [spike] line.")
end
