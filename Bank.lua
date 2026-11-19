-- The bank, counted: a snapshot of the bank contents per character (ns.char.bank = { time, items = { [itemID] = count } }), written
-- while the bank is open (BankEvents.lua) and read anywhere. Pure Lua: the game is given by the caller, so the tests give their own.
local _, ns = ...

local B = {}
ns.Bank = B

B.DAY = 86400

-- Reads the bank through `api` = { containers = { bagID, ... }, main = the bank's own container, slots(bag) -> number of slots,
-- item(bag, slot) -> itemID, count | nil }. Returns { [itemID] = count }, or nil when the bank cannot be read (its own container
-- reports no slot: the window is closing), so a failed read never replaces a good snapshot.
function B.Scan(api)
  local items = {}
  for _, bag in ipairs(api.containers) do
    local n = api.slots(bag) or 0
    if bag == api.main and n == 0 then return nil end
    for slot = 1, n do
      local id, count = api.item(bag, slot)
      if id then items[id] = (items[id] or 0) + (count or 1) end
    end
  end
  return items
end

function B.Save(char, items, now) char.bank = { time = now, items = items } end

-- How many of an item the bank held when it was last seen on this character (0 when never seen).
function B.Count(id)
  local bank = ns.char and ns.char.bank
  return bank and bank.items[id] or 0
end

-- nil = the bank was never seen on this character, else whole days since it was (0 = today).
function B.AgeDays(char, now)
  local bank = char and char.bank
  return bank and math.max(0, math.floor((now - bank.time) / B.DAY)) or nil
end
