-- Startup, saved settings, data pipeline and the /gc command.
local addonName, ns = ...
local S = ns.S
ns.TOP = 10

-- Everything GoldCompass shows in chat goes through ns.Say, so the log holds exactly what the chat showed.
function ns.Say(text)
  print(text)
  ns.Log("chat", text)
end
function ns.Print(msg) ns.Say(S.prefix .. " : " .. msg) end

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
  [202] = "Engineering", [165] = "Leatherworking", [197] = "Tailoring", [185] = "Cooking", [129] = "First Aid",
  [356] = "Fishing", [393] = "Skinning" } -- Classic skill line IDs, unverified on Forever (spike S4)
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
  local supposed = math.min(300, 5 * UnitLevel("player"))
  if only then
    if real[only] then return { [only] = real[only] } end
    return { [only] = supposed }, supposed, { only }
  end
  -- Per node type: Mining and Herbalism use the real skill, or the supposed one when the character lacks the profession.
  -- Fishing counts only with a real skill (and only recorded pools exist anyway). Having Fishing alone must not hide
  -- the other two: that was the "Tous says GatherMate has no data" bug.
  local skills, missing = { ["Fishing"] = real["Fishing"] }, {}
  for _, t in ipairs({ "Mining", "Herb Gathering" }) do
    if real[t] then skills[t] = real[t] else skills[t] = supposed; missing[#missing + 1] = t end
  end
  return skills, #missing > 0 and supposed or nil, missing
end

-- "Si tu apprends Minage (niveau de métier supposé : 80)" for the professions the character lacks.
function ns.SupposedText(res)
  if not res.supposed then return nil end
  local names = {}
  for i, t in ipairs(res.supposedTypes or {}) do names[i] = S.prof_names[t] or t end
  return S.hypothetical:format(table.concat(names, " / "), res.supposed)
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
    known = function(id)
      return (ns.char and ns.char.learned[id]) or (IsPlayerSpell ~= nil and IsPlayerSpell(id)) or false
    end,
    buy = function(id) return (ns.db and ns.db.buy and ns.db.buy[id]) or ns.Prices.VendorBuy(id) end,
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
  local skills, supposed, supposedTypes = gatherSkills(opts and opts.profession)
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
  -- fishing is ranked only from pools GatherMate2 has recorded for this player (its Forever data has none)
  if result.status == "no_nodes" then return { state = opts and opts.profession == "Fishing" and "nofishing" or "nogather" } end
  if result.status == "no_scan" then return { state = "noscan" } end
  for _, row in ipairs(result.rows) do
    row.name = ns.Nodes.ZoneName(row.zone)
    row.itemNames = {}
    for i, id in ipairs(row.items) do row.itemNames[i] = ns.ItemName(id) end
  end
  -- all = every ranked zone (Here tab); rows = the best ns.TOP (map tab, chat)
  local top = {}
  for i = 1, math.min(ns.TOP, #result.rows) do top[i] = result.rows[i] end
  return { state = "ok", rows = top, all = result.rows, input = input, supposed = supposed, supposedTypes = supposedTypes,
    fishing = opts and opts.profession == "Fishing",
    ageUnknown = not ns.Prices.HasAge() }
end

-- done(result) is called once the data is read. Keeps the last result for /gc dump.
function ns.Run(done, opts)
  ns.LoadItems(nodeItems(), function()
    local ok, res = pcall(compute, opts)
    if not ok then
      res = res == "price_api" and { state = "price_error" } or { state = "error", message = tostring(res) }
    end
    ns.last = res
    done(res)
  end)
end

-- One sentence per cause of a partial estimate, for the rows given.
function ns.PartialText(rows)
  local stale, unseen, unpriced = false, false, false
  for _, r in ipairs(rows) do
    stale, unseen, unpriced = stale or r.stale, unseen or r.unseen, unpriced or r.unpriced
  end
  local out = {}
  if stale then out[#out + 1] = S.banner_stale end
  if unseen then out[#out + 1] = S.banner_unseen end
  if unpriced then out[#out + 1] = S.banner_unpriced end
  return table.concat(out, " ")
end

-- The one money formatter: the game's coin icons when available (C_CurrencyInfo.GetCoinTextureString, else the global
-- GetCoinTextureString), plain text ("1g 20s") as the last fallback. 0 or nil is "prix inconnu", never a price.
local function money(copper)
  if not copper or copper <= 0 then return S.price_unknown end
  local coin = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
  if coin then return coin(ns.ZoneRank.RoundCopper(copper)) end
  return ns.ZoneRank.FormatMoney(copper)
end
ns.Money = money

local function ageText(age)
  if not age then return S.none end
  return age < 1 and S.age_fresh or S.age_days:format(math.floor(age))
end
ns.AgeText = ageText

-- Price freshness for a ranking row, worded so it cannot be read as a price.
function ns.PriceAgeText(age)
  if not age then return S.price_unknown_age end
  return age < 1 and S.price_today or S.price_days:format(math.floor(age))
end

local STATE_TEXT = {
  nogather = { S.nogather_t, S.nogather_p }, noscan = { S.noscan_t, S.noscan_p },
  no_gathermate_addon = { S.nogm_t, S.nogm_p }, no_auctionator_addon = { S.noauc_t, S.noauc_p },
  price_error = { S.error_t, S.error_p }, error = { S.unexpected_t, "" },
  empty = { S.bags_empty_t, S.bags_empty_p }, nofishing = { S.nofish_t, S.nofish_p }, empty_prof = { S.job_empty_t, S.job_empty_p }, here_nodata = { S.here_nodata_t, S.here_nodata_p },
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

local HEARTHSTONE = 6948 -- also flagged hasNoValue by the game; listed explicitly in case Forever omits the flag

-- Items in the backpack and the four bags, merged by item ID. Returns the list and the IDs, or nil when the API is missing.
function ns.BagItems()
  if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo) then return end
  local byId, items = {}, {}
  for bag = 0, 4 do
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID and not info.hasNoValue and info.itemID ~= HEARTHSTONE then
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
  local items = ns.BagItems()
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
-- Quest items of the zone are loaded BEFORE they are priced, so unloaded items are not valued at 0.
function ns.RunHere(done)
  ns.Run(function(res)
    if res.state ~= "ok" then return done(res) end
    local zone = C_Map.GetBestMapForUnit("player")
    local cmp = zone and ns.Here.Compare(res.all, zone)
    if not cmp then return done({ state = "here_nodata" }) end
    local info = ns.Zones[zone]
    local ids = {}
    for item, quests in pairs(ns.QuestItems) do
      for _, q in ipairs(quests) do
        if info and q.zone == info[1] then ids[#ids + 1] = item; break end
      end
    end
    ns.LoadItems(ids, function()
      local ok, here = pcall(function()
        local ctx = ns.Context()
        local out = { state = "ok", cmp = cmp, level = ctx.level, supposed = res.supposed, supposedTypes = res.supposedTypes, nodes = {} }
        for i = 1, math.min(4, #cmp.row.detail) do
          local d = cmp.row.detail[i]
          out.nodes[i] = { name = ns.ItemName(d.item), unit = d.unit }
        end
        out.pickups = info and ns.Here.Pickups(info[1], ns.QuestItems, ctx) or {}
        while #out.pickups > 4 do out.pickups[#out.pickups] = nil end
        for _, p in ipairs(out.pickups) do p.name = ns.ItemName(p.item) end
        -- what each profession the character lacks would add here, on top of the skills it has
        for _, prof in ipairs(res.supposedTypes or {}) do
          local without = {}
          for k, v in pairs(res.input) do without[k] = v end
          without.skills = {}
          for k, v in pairs(res.input.skills) do without.skills[k] = v end
          without.skills[prof] = nil
          local gain = ns.Here.ProfessionGain(without, cmp.row.zone, prof, res.supposed)
          if gain and (not out.hint or gain > out.hint.gain) then out.hint = { prof = prof, gain = gain } end
        end
        return out
      end)
      done(ok and here or { state = "error", message = tostring(here) })
    end)
  end)
end

-- Professions of the character as the game names them (localized), with their skill.
local NO_WINDOW = { [182] = true, [393] = true, [356] = true } -- Herbalism, Skinning, Fishing: no craft window
function ns.ProfessionList()
  local out = {}
  if GetProfessions and GetProfessionInfo then
    for _, index in pairs({ GetProfessions() }) do
      local name, _, skill, max, _, _, line = GetProfessionInfo(index)
      if name then out[#out + 1] = { name = name, skill = skill, max = max, line = line } end
    end
  end
  return out
end

-- "Monter un métier" data: for each profession, a plan from what its window showed (remembered by Learned.lua).
function ns.RunLeveling(done)
  if not ns.Prices.Installed() then return done({ state = "no_auctionator_addon" }) end
  local list = ns.ProfessionList()
  if #list == 0 then return done({ state = "empty_prof" }) end
  local ids = {}
  for _, p in ipairs(list) do
    local data = ns.char and ns.char.profs[p.name]
    for _, rec in pairs(data and data.recipes or {}) do
      if rec.out then ids[#ids + 1] = rec.out end
      for _, m in ipairs(rec.mats or {}) do ids[#ids + 1] = m[1] end
    end
  end
  ns.LoadItems(ids, function()
    local ok, res = pcall(function()
      local ctx = ns.Context()
      local profs = {}
      for _, p in ipairs(list) do
        local entry = { name = p.name, skill = p.skill, max = p.max }
        local data = ns.char.profs[p.name]
        if NO_WINDOW[p.line] then
          entry.status = "norecipes"
        elseif not data then
          entry.status = "unseen"
        else
          entry.status = "plan"
          -- "Avec mon sac": count what is carried (bags only: no bank, no reagent bank)
          local count = ns.char.onlyBag and function(id) return C_Item.GetItemCount(id, false, false, false) end or nil
          entry.filtered = count ~= nil
          entry.plan = ns.Leveling.Plan(data, ctx, 5, count)
          for _, row in ipairs(entry.plan.rows) do row.name = ns.Fmt.RecipeName(row.rec) end
          local almost = entry.plan.almost
          if almost then
            entry.almost = { name = ns.Fmt.RecipeName(almost.rec), missing = {} }
            for i, s in ipairs(almost.short) do entry.almost.missing[i] = { ns.ItemName(s[1]), s[2] } end
          end
          local seen, names = {}, {}
          for i = 1, math.min(3, #entry.plan.unpriced) do
            for _, id in ipairs(entry.plan.unpriced[i].missing) do
              if not seen[id] then seen[id] = true; names[#names + 1] = ns.ItemName(id) end
            end
          end
          entry.missingNames = names
        end
        profs[#profs + 1] = entry
      end
      return { state = "ok", profs = profs }
    end)
    done(ok and res or { state = "error", message = tostring(res) })
  end)
end

-- Zones to show on the map tab, best first, at most ns.TOP. With "my level only", a zone whose lowest level is more than
-- 4 above the character is left out; a zone whose level is unknown (Data/Zones.lua) is left out too and counted in the
-- second result so the window can say so. Zones missing from the table (cities) are always shown.
function ns.VisibleZones(all, onlyLevel)
  local level, list, hidden = UnitLevel("player"), {}, 0
  for _, row in ipairs(all) do
    local info = ns.Zones[row.zone]
    local skip = false
    if onlyLevel and info then
      if not info[2] then skip, hidden = true, hidden + 1 elseif info[2] - level > 4 then skip = true end
    end
    if not skip and #list < ns.TOP then list[#list + 1] = row end
  end
  return list, hidden
end

local function printMap()
  ns.Print(S.loading_p)
  ns.Run(function(res)
    if res.state ~= "ok" then
      local title, text = ns.StateText(res)
      return ns.Print(title .. " : " .. text)
    end
    ns.Print(ns.SupposedText(res) or S.mine)
    for i, row in ipairs(res.rows) do
      local tags = (row.old and (" (" .. S.tag_old .. ")") or "") .. (row.partial and (" (" .. S.tag_partial .. ")") or "")
      ns.Say(("%d. %s  %s  %s  [%s]%s"):format(i, row.name, S.per_hour:format(money(row.copperPerHour)),
        table.concat(row.itemNames, ", "), S.price_age:format(ageText(row.maxAge)), tags))
    end
    local partial = ns.PartialText(res.rows)
    if partial ~= "" then ns.Print(partial) end
    if res.ageUnknown then ns.Print(S.age_unknown) end
    ns.Say("|cff9d9d9d" .. S.footer .. "|r")
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
  elseif cmd == "log" then
    -- raw print on purpose: showing the log must not add entries to it
    if (msg or ""):lower():match("^%s*log%s+clear") then
      ns.LogClear()
      print(S.prefix .. " : " .. S.log_cleared)
    else
      local entries, total = ns.LogRecent(20)
      print(S.prefix .. " : " .. S.log_header:format(#entries, total))
      for _, e in ipairs(entries) do print(("%s [%s] %s"):format(e.time, e.kind, e.text)) end
    end
  elseif cmd == "" and ns.Window then ns.Window.Toggle()
  else ns.Print("/gc (fenêtre) · /gc map · /gc spike · /gc dump · /gc log [clear]") end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, _, name)
  if name ~= addonName then return end
  GoldCompassDB = GoldCompassDB or {}
  ns.db = GoldCompassDB
  ns.db.buy = ns.db.buy or {}            -- [itemID] = vendor buy price of one unit, learned at merchants
  ns.db.chars = ns.db.chars or {}
  local key = (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?")
  ns.db.chars[key] = ns.db.chars[key] or { learned = {} }  -- [recipeID] = true, learned from profession windows
  ns.char = ns.db.chars[key]
  ns.char.learned = ns.char.learned or {}
  ns.char.profs = ns.char.profs or {}         -- [professionName] = what its window showed (Learned.lua)
  ns.LogInit(ns.db)
  ns.Print("chargé. Tape /gc.")
end)
