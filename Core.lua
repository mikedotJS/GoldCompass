-- Startup, saved settings, data pipeline and the /gc command.
local addonName, ns = ...
local S = ns.S

function ns.Print(msg) print(S.prefix .. " : " .. msg) end

-- Request item data from the game for every item in the node table, then call cb. Gives up after 5 seconds
-- (PLAN.md step 1): items that did not load show as "objet #id".
local function loadItems(cb)
  local ids, seen = {}, {}
  for _, node in pairs(ns.GatherNodes) do
    if node.item and not seen[node.item] then seen[node.item] = true; ids[#ids + 1] = node.item end
  end
  local pending, finished = #ids, false
  local function finish() if not finished then finished = true; cb() end end
  if not (Item and C_Timer) or pending == 0 then return finish() end
  C_Timer.After(5, finish)
  for _, id in ipairs(ids) do
    Item:CreateFromItemID(id):ContinueOnItemLoad(function()
      pending = pending - 1
      if pending == 0 then finish() end
    end)
  end
end

local function itemName(id)
  local name = ((C_Item and C_Item.GetItemInfo) or GetItemInfo)(id)
  return name or S.item_unknown:format(id)
end

-- Gathering skills of the character, or a supposed skill (5 per level, max 300) when it has neither profession.
local SKILL_LINES = { [182] = "Herb Gathering", [186] = "Mining" } -- Classic skill line IDs, unverified on Forever (spike S4)
local function playerSkills()
  local skills = {}
  if GetProfessions and GetProfessionInfo then
    for _, index in pairs({ GetProfessions() }) do
      local _, _, skill, _, _, _, skillLine = GetProfessionInfo(index)
      if SKILL_LINES[skillLine] then skills[SKILL_LINES[skillLine]] = skill end
    end
  end
  if next(skills) then return skills, false end
  local supposed = math.min(300, 5 * UnitLevel("player"))
  return { ["Mining"] = supposed, ["Herb Gathering"] = supposed }, supposed
end

-- Runs the whole pipeline. Always returns a table { state = ... }, never raises.
-- states: ok, nogather, noscan, no_gathermate_addon, no_auctionator_addon, price_error, error
local function compute()
  if not ns.Nodes.Installed() then return { state = "no_gathermate_addon" } end
  if not ns.Prices.Installed() then return { state = "no_auctionator_addon" } end
  local zones = ns.Nodes.Counts()
  local skills, supposed = playerSkills()
  local cache = {}
  local function price(id)
    if not cache[id] then cache[id] = { ns.Prices.Get(id) } end
    return cache[id][1], cache[id][2]
  end
  local result = ns.ZoneRank.Rank({
    zones = zones, nodes = ns.GatherNodes, skills = skills, price = price,
    vendor = ns.Prices.Vendor, ageKnown = ns.Prices.HasAge(),
  })
  if result.status == "no_nodes" then return { state = "nogather" } end
  if result.status == "no_scan" then return { state = "noscan" } end
  for _, row in ipairs(result.rows) do
    row.name = ns.Nodes.ZoneName(row.zone)
    row.itemNames = {}
    for i, id in ipairs(row.items) do row.itemNames[i] = itemName(id) end
  end
  return { state = "ok", rows = result.rows, supposed = supposed, anyPartial = false, ageUnknown = not ns.Prices.HasAge() }
end

-- done(result) is called once the data is read. Keeps the last result for /gc dump.
function ns.Run(done)
  loadItems(function()
    local ok, res = pcall(compute)
    if not ok then
      res = res == "price_api" and { state = "price_error" } or { state = "error", message = tostring(res) }
    end
    for _, row in ipairs(res.rows or {}) do res.anyPartial = res.anyPartial or row.partial end
    ns.last = res
    done(res)
  end)
end

local function money(copper) return ns.ZoneRank.FormatMoney(copper) end
ns.Money = money

local function ageText(age)
  if not age then return S.none end
  return age < 1 and S.age_fresh or S.age_days:format(math.floor(age))
end
ns.AgeText = ageText

local STATE_TEXT = {
  nogather = { S.nogather_t, S.nogather_p }, noscan = { S.noscan_t, S.noscan_p },
  no_gathermate_addon = { S.nogm_t, S.nogm_p }, no_auctionator_addon = { S.noauc_t, S.noauc_p },
  price_error = { S.error_t, S.error_p }, error = { S.unexpected_t, "" },
}
ns.StateText = function(res)
  local t = STATE_TEXT[res.state]
  return t[1], res.message or t[2]
end

local function printMap()
  ns.Print(S.loading_p)
  ns.Run(function(res)
    if res.state ~= "ok" then
      local title, text = ns.StateText(res)
      return ns.Print(title .. " : " .. text)
    end
    ns.Print(res.supposed and S.hypothetical:format(res.supposed) or S.mine)
    for i, row in ipairs(res.rows) do
      local tags = (row.old and (" (" .. S.tag_old .. ")") or "") .. (row.partial and (" (" .. S.tag_partial .. ")") or "")
      print(("%d. %s  %s  %s  [%s]%s"):format(i, row.name, S.per_hour:format(money(row.copperPerHour)),
        table.concat(row.itemNames, ", "), S.price_age:format(ageText(row.maxAge)), tags))
    end
    if res.anyPartial then ns.Print(S.stale_banner) end
    if res.ageUnknown then ns.Print(S.age_unknown) end
    print("|cff9d9d9d" .. S.footer .. "|r")
  end)
end

local function dump()
  if not ns.last then return ns.Print("Rien à enregistrer : tape /gc map d'abord.") end
  ns.db.last = { time = time(), state = ns.last.state, message = ns.last.message, supposed = ns.last.supposed, rows = {} }
  for i, row in ipairs(ns.last.rows or {}) do
    ns.db.last.rows[i] = { zone = row.zone, name = row.name, copperPerHour = row.copperPerHour,
      spots = row.spots, items = row.itemNames, old = row.old, partial = row.partial, maxAge = row.maxAge }
  end
  ns.Print("Dernier résultat enregistré. Tape /reload pour l'écrire sur le disque (SavedVariables\\GoldCompass.lua).")
end

SLASH_GOLDCOMPASS1 = "/gc"
SlashCmdList["GOLDCOMPASS"] = function(msg)
  local cmd = (msg or ""):match("^%s*(%S*)"):lower()
  if cmd == "map" then printMap()
  elseif cmd == "spike" then ns.Spike()
  elseif cmd == "dump" then dump()
  elseif cmd == "" and ns.Window then ns.Window.Toggle()
  else ns.Print("/gc (fenêtre) · /gc map · /gc spike · /gc dump") end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, _, name)
  if name ~= addonName then return end
  GoldCompassDB = GoldCompassDB or {}
  ns.db = GoldCompassDB
  ns.Print("chargé. Tape /gc.")
end)
