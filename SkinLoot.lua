-- Skinning yield measured in game. No source gives what one skin gives on WoW Forever (Data/ForeverSkinZones.lua carries the Classic
-- yield), so the addon counts it: when the player skins a beast of ns.SkinZones, the loot window is read and counters are kept per NPC
-- in ns.db.skinLoot[npcID] = { n = skins, d = day number of the last skin, i = { [itemID] = total quantity } }. Counters only.
-- SkinRank uses the measured rate in place of the Classic one for a beast with at least SL.MIN_SKINS recorded skins.
-- Pure functions (db and API passed in) are unit tested outside the game; the event glue at the bottom is registered in a pcall.
local _, ns = ...

local SL = {}
ns.SkinLoot = SL

SL.MIN_SKINS = 20   -- below this the sample says nothing: the Classic yield stays
SL.MAX_NPCS = 400   -- bound of the saved table (621 skinnable beasts are known)
SL.MAX_ITEMS = 8    -- distinct items kept per beast
local ARM_SECONDS = 15
local SKIN_SPELLS = { [8613] = true, [8617] = true, [8618] = true, [10768] = true } -- Classic ids of Skinning; the name is checked too

-- Adds one skin of npcID that gave items = { { itemID, quantity }, ... }. Returns true when it was kept.
function SL.Record(store, npcID, items, day)
  if type(store) ~= "table" or not npcID or #items == 0 then return false end
  local e = store[npcID]
  if not e then
    local count, worst = 0, nil
    for id, o in pairs(store) do
      count = count + 1
      if not worst or o.n < store[worst].n or (o.n == store[worst].n and o.d < store[worst].d) then worst = id end
    end
    if count >= SL.MAX_NPCS then store[worst] = nil end   -- the least measured beast makes room
    e = { n = 0, d = day, i = {} }
    store[npcID] = e
  end
  e.n, e.d = e.n + 1, day
  local kinds = 0
  for _ in pairs(e.i) do kinds = kinds + 1 end
  for _, it in ipairs(items) do
    if e.i[it[1]] then e.i[it[1]] = e.i[it[1]] + it[2]
    elseif kinds < SL.MAX_ITEMS then e.i[it[1]] = it[2]; kinds = kinds + 1 end
  end
  return true
end

-- Number of skins measured for the beast, nil below MIN_SKINS (or no record).
function SL.Measured(store, npcID)
  local e = store and store[npcID]
  return e and type(e.n) == "number" and e.n >= SL.MIN_SKINS and e.n or nil
end

-- Items per skin measured for the beast = { { itemID, perSkin }, ... }, nil when it is not measured. Items never seen count 0 in
-- the Classic list (measured: this beast does not give it), items Classic does not know are added.
function SL.Yields(store, beast)
  local n = SL.Measured(store, beast[1])
  if not n then return nil end
  local e, out, seen = store[beast[1]], {}, {}
  for _, it in ipairs(beast.items) do
    seen[it[1]] = true
    out[#out + 1] = { it[1], (e.i[it[1]] or 0) / n, forever = true }
  end
  for item, qty in pairs(e.i) do
    if not seen[item] then out[#out + 1] = { item, qty / n, forever = true } end
  end
  return out
end

local skinnable
local function isSkinnable(npcID)
  if not skinnable then
    skinnable = {}
    for _, beasts in pairs(ns.SkinZones or {}) do
      for _, b in ipairs(beasts) do skinnable[b[1]] = true end
    end
  end
  return skinnable[npcID]
end

-- Reads an open loot window: npcID, { { itemID, quantity }, ... } of a skinnable beast, nil for anything else (several corpses, coins only).
-- api = { count = GetNumLootItems, link = GetLootSlotLink, info = GetLootSlotInfo, source = GetLootSourceInfo, npcID = guid -> id }
function SL.Collect(api)
  local n = api.count and api.count() or 0
  if n < 1 then return nil end
  local guid, _, other = api.source(1)
  local npcID = api.npcID(guid)
  if other or not npcID or not isSkinnable(npcID) then return nil end
  local items, byID = {}, {}
  for slot = 1, n do
    local item = (api.link(slot) or ""):match("item:(%d+)")
    if item then
      local _, _, qty = api.info(slot)
      item = tonumber(item)
      qty = tonumber(qty) or 1
      if byID[item] then byID[item][2] = byID[item][2] + qty
      else byID[item] = { item, qty }; items[#items + 1] = byID[item] end
    end
  end
  return npcID, items
end

-- Event handler: env = { api =, store = function -> table or nil, now = function, day = function, isSkin = spellID -> bool }.
-- A skinning cast arms the next loot window for a few seconds, so corpse loot is never counted.
function SL.Handler(env)
  local armedAt
  return function(event, unit, _, _, spellID)
    if event == "UNIT_SPELLCAST_SENT" then
      if unit == "player" and env.isSkin(spellID) then armedAt = env.now() end
    elseif event == "LOOT_OPENED" then
      local at = armedAt
      armedAt = nil
      if at and env.now() - at <= ARM_SECONDS then
        local store = env.store()
        local npcID, items = SL.Collect(env.api)
        if store and npcID then SL.Record(store, npcID, items, env.day()) end
      end
    elseif unit == "player" then armedAt = nil end   -- interrupted, failed: no skin
  end
end

if CreateFrame and GetTime then
  local isSkin = function(id)
    if SKIN_SPELLS[id] then return true end
    local name = GetSpellInfo and id and GetSpellInfo(id)
    return name ~= nil and name == (GetSpellInfo and GetSpellInfo(10768))
  end
  local handler = SL.Handler({
    api = { count = GetNumLootItems, link = GetLootSlotLink, info = GetLootSlotInfo,
      source = GetLootSourceInfo or function() return UnitGUID and UnitGUID("target") end,
      npcID = function(guid) return ns.TrainerLog and ns.TrainerLog.NpcID(guid) end },
    store = function() if ns.db then ns.db.skinLoot = ns.db.skinLoot or {}; return ns.db.skinLoot end end,
    now = GetTime,
    day = function() return math.floor(time() / 86400) end,
    isSkin = isSkin,
  })
  local frame = CreateFrame("Frame")
  for _, e in ipairs({ "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_FAILED_QUIET", "LOOT_OPENED" }) do
    pcall(frame.RegisterEvent, frame, e)
  end
  frame:SetScript("OnEvent", function(_, ...) pcall(handler, ...) end)
end
