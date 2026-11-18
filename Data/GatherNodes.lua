-- HAND-MAINTAINED DATA. Not generated, not copied from any addon.
-- One row per GatherMate2 node (key = GatherMate2's own numeric node ID, language independent):
--   type  = GatherMate2 node type ("Herb Gathering" or "Mining")
--   item  = item ID the node gives (nil = unknown, the node is counted as "unknown" and ignored)
--   skill = gathering skill needed
--   yield = average items per node (PLAN.md section 5 assumption: 2, unverified on Forever)
-- Sources: node IDs read in GatherMate2/Constants.lua (master, 2026-11-18); item IDs checked
-- against the item names in Forever Ledger's ClassicItems.lua (MIT); skill levels are the
-- original Classic requirements and are NOT verified on Forever. The three Forever-only nodes
-- have no known item ID yet (PLAN.md section 3).
local _, ns = ...

local H, M = "Herb Gathering", "Mining"

ns.GatherNodes = {
  [401] = { type = H, item = 2447, skill = 1, yield = 2 }, -- Peacebloom
  [402] = { type = H, item = 765, skill = 1, yield = 2 }, -- Silverleaf
  [403] = { type = H, item = 2449, skill = 15, yield = 2 }, -- Earthroot
  [404] = { type = H, item = 785, skill = 50, yield = 2 }, -- Mageroyal
  [405] = { type = H, item = 2450, skill = 70, yield = 2 }, -- Briarthorn
  [407] = { type = H, item = 3820, skill = 85, yield = 2 }, -- Stranglekelp
  [408] = { type = H, item = 2453, skill = 100, yield = 2 }, -- Bruiseweed
  [409] = { type = H, item = 3355, skill = 115, yield = 2 }, -- Wild Steelbloom
  [410] = { type = H, item = 3369, skill = 120, yield = 2 }, -- Grave Moss
  [411] = { type = H, item = 3356, skill = 125, yield = 2 }, -- Kingsblood
  [412] = { type = H, item = 3357, skill = 150, yield = 2 }, -- Liferoot
  [413] = { type = H, item = 3818, skill = 160, yield = 2 }, -- Fadeleaf
  [414] = { type = H, item = 3821, skill = 170, yield = 2 }, -- Goldthorn
  [415] = { type = H, item = 3358, skill = 185, yield = 2 }, -- Khadgar's Whisker
  [416] = { type = H, item = 3819, skill = 195, yield = 2 }, -- Wintersbite
  [417] = { type = H, item = 4625, skill = 205, yield = 2 }, -- Firebloom
  [418] = { type = H, item = 8831, skill = 210, yield = 2 }, -- Purple Lotus
  [420] = { type = H, item = 8836, skill = 220, yield = 2 }, -- Arthas' Tears
  [421] = { type = H, item = 8838, skill = 230, yield = 2 }, -- Sungrass
  [422] = { type = H, item = 8839, skill = 235, yield = 2 }, -- Blindweed
  [423] = { type = H, item = 8845, skill = 245, yield = 2 }, -- Ghost Mushroom
  [424] = { type = H, item = 8846, skill = 250, yield = 2 }, -- Gromsblood
  [425] = { type = H, item = 13464, skill = 260, yield = 2 }, -- Golden Sansam
  [426] = { type = H, item = 13463, skill = 270, yield = 2 }, -- Dreamfoil
  [427] = { type = H, item = 13465, skill = 280, yield = 2 }, -- Mountain Silversage
  [428] = { type = H, item = 13466, skill = 285, yield = 2 }, -- Plaguebloom
  [429] = { type = H, item = 13467, skill = 290, yield = 2 }, -- Icecap
  [431] = { type = H, item = 13468, skill = 300, yield = 2 }, -- Black Lotus
  [4401] = { type = H, item = nil, skill = nil, yield = 2 }, -- Demonsage (Forever only)
  [4402] = { type = H, item = nil, skill = nil, yield = 2 }, -- Marefoil (Forever only)
  [201] = { type = M, item = 2770, skill = 1, yield = 2 }, -- Copper Vein
  [202] = { type = M, item = 2771, skill = 65, yield = 2 }, -- Tin Vein
  [219] = { type = M, item = 3340, skill = 65, yield = 2 }, -- Incendicite Mineral Vein
  [218] = { type = M, item = 4278, skill = 75, yield = 2 }, -- Lesser Bloodstone Deposit
  [204] = { type = M, item = 2775, skill = 75, yield = 2 }, -- Silver Vein
  [209] = { type = M, item = 2775, skill = 75, yield = 2 }, -- Ooze Covered Silver Vein
  [203] = { type = M, item = 2772, skill = 125, yield = 2 }, -- Iron Deposit
  [220] = { type = M, item = 5833, skill = 150, yield = 2 }, -- Indurium Mineral Vein
  [205] = { type = M, item = 2776, skill = 155, yield = 2 }, -- Gold Vein
  [210] = { type = M, item = 2776, skill = 155, yield = 2 }, -- Ooze Covered Gold Vein
  [206] = { type = M, item = 3858, skill = 175, yield = 2 }, -- Mithril Deposit
  [207] = { type = M, item = 3858, skill = 175, yield = 2 }, -- Ooze Covered Mithril Deposit
  [208] = { type = M, item = 7911, skill = 230, yield = 2 }, -- Truesilver Deposit
  [211] = { type = M, item = 7911, skill = 230, yield = 2 }, -- Ooze Covered Truesilver Deposit
  [217] = { type = M, item = 11370, skill = 230, yield = 2 }, -- Dark Iron Deposit
  [214] = { type = M, item = 10620, skill = 245, yield = 2 }, -- Small Thorium Vein
  [213] = { type = M, item = 10620, skill = 245, yield = 2 }, -- Ooze Covered Thorium Vein
  [215] = { type = M, item = 10620, skill = 275, yield = 2 }, -- Rich Thorium Vein
  [212] = { type = M, item = 10620, skill = 275, yield = 2 }, -- Ooze Covered Rich Thorium Vein
  [4201] = { type = M, item = nil, skill = nil, yield = 2 }, -- Heavy Thorium Vein (Forever only)
}
