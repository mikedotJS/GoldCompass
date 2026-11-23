-- Keeps the bank snapshot (Bank.lua) up to date: read when the bank opens and each time its contents change while it is open, never
-- after it closes (its slots read as empty then). At the banker, one chat line says what the roadmap takes from it.
local _, ns = ...
local B = ns.Bank

local open, announced, pending = false, false, false

-- The bank's containers: its own (-1) and its bag slots, which come right after the character's bags (and the reagent bag where the
-- game has one). Event names and container IDs are read from the game's constants, with the Classic values as the fallback.
local function liveApi()
  local first = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) + 1
  local main = BANK_CONTAINER or -1
  local containers = { main }
  for bag = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do containers[#containers + 1] = bag end
  return { containers = containers, main = main,
    slots = function(bag) return C_Container.GetContainerNumSlots(bag) end,
    item = function(bag, slot)
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info then return info.itemID, info.stackCount end
    end }
end

-- The roadmap's need at the banker: "Gold Compass : prends 6 × Peau légère, 12 × Cuir léger".
local function announce()
  ns.RunLeveling(function(res)
    if res.state ~= "ok" then return end
    local built = ns.Shopping.Build(res.profs, { bag = function() return 0 end, bank = ns.Bank.Count, name = ns.ItemName })
    if #built.fetch > 0 then ns.Print(ns.S.bank_take:format(ns.Shopping.FetchText(built.fetch))) end
  end)
end

local function scan(first)
  if not (open and ns.char) then return end
  local ok, items = pcall(B.Scan, liveApi())
  if not (ok and items) then
    if first then ns.Log("bank", "bank scan failed: " .. tostring(items)) end
    return
  end
  B.Save(ns.char, items, time())
  if first then
    -- checked against the game's own count (bags + bank minus bags) on a few items, so a wrong container range shows in /gc log
    local n, agree, checked = 0, 0, 0
    for id, count in pairs(items) do
      n = n + 1
      if checked < 20 then
        checked = checked + 1
        local own = C_Item.GetItemCount(id, true, false, false) - C_Item.GetItemCount(id, false, false, false)
        if own == count then agree = agree + 1 end
      end
    end
    ns.Log("bank", ("bank snapshot: %d distinct items, %d of %d checked agree with the game's count (containers %s..%s)"):format(
      n, agree, checked, tostring(liveApi().containers[1]), tostring(liveApi().containers[#liveApi().containers])))
  end
  ns.ShoppingList.Update()
  ns.Window.OnBank()
  if not announced then announced = true; announce() end
end

local frame = CreateFrame("Frame")
-- a burst of events (moving a stack fires several) is one scan
local function later()
  if pending then return end
  pending = true
  C_Timer.After(0.2, function() pending = false; scan() end)
end
-- The bag and bank slot events are listened to only while the bank is open (they fire at every loot and every sale otherwise).
local WHILE_OPEN = { "PLAYERBANKSLOTS_CHANGED", "PLAYERBANKBAGSLOTS_CHANGED", "BAG_UPDATE", "BAG_UPDATE_DELAYED" }
local function watch(on)
  for _, e in ipairs(WHILE_OPEN) do pcall(on and frame.RegisterEvent or frame.UnregisterEvent, frame, e) end
end
frame:SetScript("OnEvent", function(_, event, kind)
  -- newer clients tell a banker window by the interaction manager instead of BANKFRAME_*
  if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
    local banker = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Banker
    if not banker or kind ~= banker then return end
    event = event:find("SHOW", 1, true) and "BANKFRAME_OPENED" or "BANKFRAME_CLOSED"
  end
  if event == "BANKFRAME_OPENED" then
    if not open then announced = false end
    open = true
    watch(true)
    scan(true)
    C_Timer.After(0.5, function() scan() end)   -- the contents may settle a moment after the window opens
  elseif event == "BANKFRAME_CLOSED" then
    open = false
    watch(false)
  elseif open then
    later()
  end
end)
-- in a pcall: an event this client does not know must never break the addon
for _, e in ipairs({ "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }) do
  pcall(frame.RegisterEvent, frame, e)
end
