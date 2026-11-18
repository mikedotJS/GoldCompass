-- HAND-MAINTAINED DATA, written from memory of the original Classic zones, NOT verified on Forever.
-- ns.Zones[uiMapID] = { English zone name, lowest level, highest level }.
-- Map IDs follow the Classic numbering that GatherMate2 uses (1411 = Durotar, PLAN.md section 3). The English name
-- is what Data/QuestItems.lua uses; the levels drive the "my level only" filter. Spike S4 checks the IDs in game.
local _, ns = ...

ns.Zones = {
  [1411] = { "Durotar", 1, 10 },
  [1412] = { "Mulgore", 1, 10 },
  [1413] = { "The Barrens", 10, 25 },
  [1416] = { "Alterac Mountains", 30, 40 },
  [1417] = { "Arathi Highlands", 30, 40 },
  [1418] = { "Badlands", 35, 45 },
  [1419] = { "Blasted Lands", 45, 55 },
  [1420] = { "Tirisfal Glades", 1, 10 },
  [1421] = { "Silverpine Forest", 10, 20 },
  [1422] = { "Western Plaguelands", 51, 58 },
  [1423] = { "Eastern Plaguelands", 53, 60 },
  [1424] = { "Hillsbrad Foothills", 20, 30 },
  [1425] = { "The Hinterlands", 40, 50 },
  [1426] = { "Dun Morogh", 1, 10 },
  [1427] = { "Searing Gorge", 43, 50 },
  [1428] = { "Burning Steppes", 50, 58 },
  [1429] = { "Elwynn Forest", 1, 10 },
  [1430] = { "Deadwind Pass", 55, 60 },
  [1431] = { "Duskwood", 18, 30 },
  [1432] = { "Loch Modan", 10, 20 },
  [1433] = { "Redridge Mountains", 15, 25 },
  [1434] = { "Stranglethorn Vale", 30, 45 },
  [1435] = { "Swamp of Sorrows", 35, 45 },
  [1436] = { "Westfall", 10, 20 },
  [1437] = { "Wetlands", 20, 30 },
  [1438] = { "Teldrassil", 1, 10 },
  [1439] = { "Darkshore", 10, 20 },
  [1440] = { "Ashenvale", 18, 30 },
  [1441] = { "Thousand Needles", 25, 35 },
  [1442] = { "Stonetalon Mountains", 15, 27 },
  [1443] = { "Desolace", 30, 40 },
  [1444] = { "Feralas", 40, 50 },
  [1445] = { "Dustwallow Marsh", 35, 45 },
  [1446] = { "Tanaris", 40, 50 },
  [1447] = { "Azshara", 45, 55 },
  [1448] = { "Felwood", 48, 55 },
  [1449] = { "Un'Goro Crater", 48, 55 },
  [1450] = { "Moonglade", 55, 60 },
  [1451] = { "Silithus", 55, 60 },
  [1452] = { "Winterspring", 53, 60 },

  -- Forever-only zones found in GatherMate2_Data (forever\HerbalismData.lua and MiningData.lua). Neither the name nor
  -- the level range could be verified (the Warcraft Wiki UiMapID page does not list these IDs, GatherMate2 has no
  -- zone names), so they carry no level: the "my level only" filter hides them and the window says so. What the node
  -- data suggests, NOT verified: 2482 Dreamfoil/Silversage/Demonsage/Heavy Thorium (endgame), 2521 Peacebloom/Silverleaf/
  -- Copper (starting), 2548 Steelbloom/Khadgar's Whisker/Iron/Mithril (mid), 2652 Bruiseweed/Grave Moss/Mithril (mid).
  [2482] = { "?" }, [2521] = { "?" }, [2548] = { "?" }, [2652] = { "?" },
}
