-- Startup, saved settings, data pipeline and the /gc command.
local addonName, ns = ...
local S = ns.S
ns.TOP = 10

function ns.Print(msg) print(S.prefix .. " : " .. msg) end

-- Request item data from the game for these item IDs, then call cb. Gives up after 5 seconds (PLAN.md step 1):
-- items that did not load show as "objet #id".
function ns.LoadItems(list, cb)
  local ids, seen = {}, {}
  for _, id in ipairs(list) do
    if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
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

local function nodeItems()
  local ids = {}
  for _, node in pairs(ns.GatherNodes) do
    if node.item then ids[#ids + 1] = node.item end
  end
  return ids
end

function ns.ItemName(id)
  local name = ((C_Item and C_Item.GetItemInfo) or GetItemInfo)(id)
  return name or S.item_unknown:format(id)
end

-- Skills of the character by profession (English names, as in Data/Recipes.lua and the node types).
local SKILL_LINES = { [182] = "Herb Gathering", [186] = "Mining", [171] = "Alchemy", [164] = "Blacksmithing", [333] = "Enchanting",
  [202] = "Engineering", [165] = "Leatherworking", [197] = "Tailoring", [185] = "Cooking", [129] = "First Aid" } -- Classic skill line IDs, unverified on Forever (spike S4)
function ns.Skills()
  local skills = {}
  if GetProfessions and GetProfessionInfo then
    for _, index in pairs({ GetProfessions() }) do
      local _, _, skill, _, _, _, skillLine = GetProfessionInfo(index)
      if SKILL_LINES[skillLine] then skills[SKILL_LINES[skillLine]] = skill end
    end
  end
  return skills
end

-- Gathering skills for the ranking: the real ones, or a supposed skill (5 per level, max 300) when the character has
-- neither gathering profession. `only` restricts to one node type ("Mining" or "Herb Gathering").
local function gatherSkills(only)
  local real = ns.Skills()
  local skills = { ["Mining"] = real["Mining"], ["Herb Gathering"] = real["Herb Gathering"] }
  local supposed
  if not next(skills) then
    supposed = math.min(300, 5 * UnitLevel("player"))
    skills = { ["Mining"] = supposed, ["Herb Gathering"] = supposed }
  end
  if only then
    for k in pairs(skills) do if k ~= only then skills[k] = nil end end
  end
  return skills, supposed
end

-- Context for the pure Advice module, read from the game.
local function safePrice(id)
  local ok, price, age = pcall(ns.Prices.Get, id)
  if ok then return price, age end
end
function ns.Context()
  local skills = ns.Skills()
  ns.index = ns.index or ns.Advice.NewIndex(ns.RecipeRows)
  local faction = UnitFactionGroup and UnitFactionGroup("player") == "Horde" and "H" or "A"
  return {
    price = safePrice, vendor = ns.Prices.Vendor, ageKnown = ns.Prices.HasAge(), skills = skills,
    known = function(id) return IsPlayerSpell ~= nil and IsPlayerSpell(id) or false end,
    quests = function(id) return ns.QuestItems[id] end, level = UnitLevel("player"), faction = faction,
    disenchant = function(id) return skills["Enchanting"] and ns.Prices.Disenchant(id) or nil end,
    index = ns.index,
  }
end

-- Runs the whole pipeline. Always returns a table { state = ... }, never raises.
-- states: ok, nogather, noscan, no_gathermate_addon, no_auctionator_addon, price_error, error
local function compute(opts)
  if not ns.Nodes.Installed() then return { state = "no_gathermate_addon" } end
  if not ns.Prices.Installed() then return { state = "no_auctionator_addon" } end
  local zones = ns.Nodes.Counts()
  local skills, supposed = gatherSkills(opts and opts.profession)
  local cache = {}
  local function price(id)
    if not cache[id] then cache[id] = { ns.Prices.Get(id) } end
    return cache[id][1], cache[id][2]
  end
  local input = {
    zones = zones, nodes = ns.GatherNodes, skills = skills, price = price,
    vendor = ns.Prices.Vendor, ageKnown = ns.Prices.HasAge(), constants = { maxRows = math.huge },
  }
  local result = ns.ZoneRank.Rank(input)
  if result.status == "no_nodes" then return { state = "nogather" } end
  if result.status == "no_scan" then return { state = "noscan" } end
  for _, row in ipairs(result.rows) do
    row.name = ns.Nodes.ZoneName(row.zone)
    row.itemNames = {}
    for i, id in ipairs(row.items) do row.itemNames[i] = ns.ItemName(id) end
  end
  -- all = every ranked zone (Here tab); rows = the best ns.TOP (map tab, chat)
  local top = {}
  for i = 1, math.min(ns.TOP, #result.rows) do top[i] = result.rows[i] end
  return { state = "ok", rows = top, all = result.rows, input = input, supposed = supposed, anyPartial = false,
    ageUnknown = not ns.Prices.HasAge() }
end

-- done(result) is called once the data is read. Keeps the last result for /gc dump.
function ns.Run(done, opts)
  ns.LoadItems(nodeItems(), function()
    local ok, res = pcall(compute, opts)
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
  empty = { S.bags_empty_t, S.bags_empty_p }, here_nodata = { S.here_nodata_t, S.here_nodata_p },
}
ns.StateText = function(res)
  local t = STATE_TEXT[res.state]
  return t[1], res.message or t[2]
end

function ns.IsGear(id)
  local getQuality = (C_Item and C_Item.GetItemQualityByID) or function(i) return select(3, GetItemInfo(i)) end
  local _, _, _, _, _, class = C_Item.GetItemInfoInstant(id)
  return (class == 2 or class == 4) and (getQuality(id) or 0) >= 2
end

-- Items in the backpack and the four bags, merged by item ID. Returns the list and the IDs, or nil when the API is missing.
local function scanBags()
  if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo) then return end
  local byId, items = {}, {}
  for bag = 0, 4 do
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID then
        local item = byId[info.itemID]
        if not item then
          item = { id = info.itemID, count = 0 }
          byId[info.itemID] = item
          items[#items + 1] = item
        end
        item.count = item.count + (info.stackCount or 1)
        item.bound = item.bound or info.isBound
      end
    end
  end
  return items
end

-- Bags tab data: done({ state = "ok" | "empty" | ..., groups, totals, total, anyAh }) (PLAN.md step 5).
function ns.RunBags(done)
  if not ns.Prices.Installed() then return done({ state = "no_auctionator_addon" }) end
  local items = scanBags()
  if not items then return done({ state = "error", message = S.bags_api }) end
  if #items == 0 then return done({ state = "empty" }) end
  local ids = {}
  for i, item in ipairs(items) do ids[i] = item.id end
  ns.LoadItems(ids, function()
    local ok, res = pcall(function()
      for _, item in ipairs(items) do
        item.name = ns.ItemName(item.id)
        item.gear = ns.IsGear(item.id)
      end
      local bags = ns.Advice.Bags(items, ns.Context())
      bags.state = "ok"
      return bags
    end)
    done(ok and res or { state = "error", message = tostring(res) })
  end)
end

-- Here tab data (PLAN.md step 6): the ranking, narrowed to the zone the character stands in.
function ns.RunHere(done)
  ns.Run(function(res)
    if res.state ~= "ok" then return done(res) end
    local ok, here, ids = pcall(function()
      local zone = C_Map.GetBestMapForUnit("player")
      local cmp = zone and ns.Here.Compare(res.all, zone)
      if not cmp then return { state = "here_nodata" } end
      local ctx = ns.Context()
      local here = { state = "ok", cmp = cmp, level = ctx.level, supposed = res.supposed, nodes = {}, pickups = {} }
      for i = 1, math.min(4, #cmp.row.detail) do
        local d = cmp.row.detail[i]
        here.nodes[i] = { name = ns.ItemName(d.item), unit = d.unit }
      end
      local info = ns.Zones[zone]
      here.pickups = info and ns.Here.Pickups(info[1], ns.QuestItems, ctx) or {}
      while #here.pickups > 4 do here.pickups[#here.pickups] = nil end
      -- the gathering profession the character lacks, and what it would add here
      local skills = ns.Skills()
      if not res.supposed then
        for _, prof in ipairs({ "Mining", "Herb Gathering" }) do
          if not skills[prof] then
            local gain = ns.Here.ProfessionGain(res.input, cmp.row.zone, prof, math.min(300, 5 * ctx.level))
            if gain then here.hint = { prof = prof, gain = gain } end
          end
        end
      end
      local ids = {}
      for i, p in ipairs(here.pickups) do ids[i] = p.item end
      return here, ids
    end)
    if not ok then return done({ state = "error", message = tostring(here) }) end
    if here.state ~= "ok" then return done(here) end
    ns.LoadItems(ids, function()
      for _, p in ipairs(here.pickups) do p.name = ns.ItemName(p.item) end
      done(here)
    end)
  end)
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
