-- Remembers which recipes this character knows, and what vendors charge for items (both read from game windows).
-- The recipe approach follows Forever Ledger's Professions.lua (MIT, see NOTICE): when a profession window opens,
-- C_TradeSkillUI.GetAllRecipeIDs and GetRecipeInfo(id).learned tell which recipes are learned. Nothing is clicked.
local _, ns = ...

local L = {}
ns.Learned = L

-- pcall without the status: every value of the call comes back (GetTradeSkillLine returns several), nothing on an error.
local function passThrough(ok, ...) if ok then return ... end end
local function safe(fn, ...)
  if not fn then return end
  return passThrough(pcall(fn, ...))
end

-- Name, skill and maximum of the open profession window.
local function readProfession(T)
  local base = safe(T.GetBaseProfessionInfo)
  if type(base) == "table" and base.professionName and base.professionName ~= "" then
    return base.professionName, base.skillLevel, base.maxSkillLevel, base.professionID
  end
  if T.GetTradeSkillLine then
    local line, name, skill, max = safe(T.GetTradeSkillLine)
    if name and name ~= "" then return name, skill, max, line end
  end
end

-- Reagents and output of one recipe from its schematic (same approach as Forever Ledger's ReadRecipe, MIT, see NOTICE).
local function readSchematic(T, id)
  local s = safe(T.GetRecipeSchematic, id, false)
  if type(s) ~= "table" then return end
  local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
  local mats = {}
  for _, slot in ipairs(s.reagentSlotSchematics or {}) do
    local first = slot.reagents and slot.reagents[1]
    if (slot.reagentType == nil or basic == nil or slot.reagentType == basic) and first and first.itemID then
      mats[#mats + 1] = { first.itemID, slot.quantityRequired or 1 }
    end
  end
  local oq = s.quantityMin and ((s.quantityMin or 1) + (s.quantityMax or s.quantityMin or 1)) / 2 or 1
  return s.outputItemID, oq, mats
end

-- Adds every learned recipe of the open profession window to `learned` ([recipeID] = true), and, when `profs` is
-- given, remembers the profession's skill and each learned recipe's difficulty, output and reagents there
-- (profs[professionName] = { skill, max, updated, recipes = { [id] = { id, name, d, out, oq, mats, greenAt } } }).
-- Returns the number of recipes added to `learned`, and whether anything the addon keeps changed (`entry.updated` moves only then: it tells
-- the plans that the window brought something new). `quick` (the window's list refreshed on its own: a craft, a filter) skips the reading
-- of every recipe when the profession's skill, maximum and recipe count are those of the last reading less than QUICK_TTL seconds ago.
-- `T` is C_TradeSkillUI (a parameter so it can be tested).
local seen = {}   -- [profession name] = { sig, at, entry } of the last full reading
local QUICK_TTL = 60
function L.Capture(T, learned, profs, quick)
  if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo) then return 0 end
  -- skip other players' linked windows, guild windows and NPC crafting
  if safe(T.IsTradeSkillLinked) or safe(T.IsTradeSkillGuild) or safe(T.IsNPCCrafting) then return 0 end
  local ids, added = safe(T.GetAllRecipeIDs), 0
  if type(ids) ~= "table" then return 0 end
  local profName, skill, max, line
  if profs then profName, skill, max, line = readProfession(T) end
  local sig = profName and ("%s:%s:%d"):format(tostring(skill), tostring(max), #ids)
  local now = time()
  local last = profName and seen[profName]
  if quick and last and last.sig == sig and last.entry == profs[profName] and now - last.at < QUICK_TTL then return 0, false end
  local entry = profName and (profs[profName] or { recipes = {} })
  local changed = false
  if entry then
    changed = profs[profName] == nil or entry.skill ~= skill or entry.max ~= max
    profs[profName] = entry
    entry.skill, entry.max = skill, max
  end
  for _, id in ipairs(ids) do
    local info = safe(T.GetRecipeInfo, id)
    -- a recipe the Forever data places in ANOTHER profession is not this window's (Skinning and Leatherworking share leather)
    local foreign = line and ns.ForeverDB and ns.ForeverDB:BelongsTo(line, id) == false
    if type(info) == "table" and info.learned and not foreign then
      if not learned[id] then
        learned[id] = true
        added = added + 1
        changed = true
      end
      if entry then
        local rec = entry.recipes[id]
        if not rec then rec = { id = id }; changed = true end
        entry.recipes[id] = rec
        if rec.name ~= info.name or rec.d ~= info.relativeDifficulty then changed = true end
        rec.name, rec.d = info.name, info.relativeDifficulty
        -- the lowest skill at which the recipe was seen green is when it turns green (or earlier)
        if rec.d == 2 and skill and (not rec.greenAt or skill < rec.greenAt) then rec.greenAt, changed = skill, true end
        if not rec.mats then
          rec.out, rec.oq, rec.mats = readSchematic(T, id)
          changed = changed or rec.mats ~= nil
        end
      end
    end
  end
  if entry then
    if changed then entry.updated = now end
    seen[profName] = { sig = sig, at = now, entry = entry }
  end
  return added, changed
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

local pending = {}   -- one debounce flag per kind of event: a burst of merchant events must not swallow a profession window's
local function later(kind, fn)
  if pending[kind] then return end
  pending[kind] = true
  C_Timer.After(0.6, function() pending[kind] = false; fn() end)
end

local frame = CreateFrame("Frame")
for _, e in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED", "MERCHANT_SHOW", "MERCHANT_UPDATE" }) do
  frame:RegisterEvent(e)
end
local opened = false   -- the window was opened within the debounce: read it in full
frame:SetScript("OnEvent", function(_, event)
  if not ns.db then return end
  if event:sub(1, 8) == "MERCHANT" then
    local api = merchantApi()
    if api then later("merchant", function() pcall(L.RecordMerchant, api, ns.db.buy) end) end
  else
    opened = opened or event == "TRADE_SKILL_SHOW"
    later("trade", function()
      local full = opened
      opened = false
      local ok, _, changed = pcall(L.Capture, C_TradeSkillUI, ns.char.learned, ns.char.profs, not full)
      if ok and changed and ns.Window and ns.Window.OnData then ns.Window.OnData() end
    end)
  end
end)
