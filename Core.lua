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

-- Name of a rank book or rank quest: the teaching item in the client's language when the game has it cached, else its English name
-- (pfQuest, Data/Npcs.lua), else the name of the recipe it teaches.
function ns.BookName(rec)
  local item = rec.teachItem
  local name = item and ((C_Item and C_Item.GetItemInfo) or GetItemInfo)(item)
  return name or (item and ns.ItemNames and ns.ItemNames[item]) or ns.Fmt.RecipeName(rec)
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
    owned = function(id) return C_Item.GetItemCount(id, false, false, false) end,   -- what the bags hold (bags only, no bank)
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

-- Name of the profession whose window is open and ready ("" nothing), as the game names it. Linked, guild and NPC
-- windows are ignored (nothing of ours can be crafted there).
function ns.OpenTradeSkill()
  local T = C_TradeSkillUI
  if not T then return end
  local function pass(ok, ...) if ok then return ... end end        -- every value of the call, nothing on an error
  local function call(fn, ...) if fn then return pass(pcall(fn, ...)) end end
  if call(T.IsTradeSkillLinked) or call(T.IsTradeSkillGuild) or call(T.IsTradeSkillNPC) then return end
  if T.IsTradeSkillReady and not call(T.IsTradeSkillReady) then return end
  local base = call(T.GetBaseProfessionInfo)
  if type(base) == "table" and base.professionName then return base.professionName, base.professionID end
  if T.GetTradeSkillLine then
    local _, name = call(T.GetTradeSkillLine)
    return name
  end
end

-- Environment for Where.Target: faction, the continent the player is on and a distance function (world coordinates of
-- the player and of a map position; nil when the game cannot tell, then only the continent decides).
local function whereEnv(ctx)
  local env = { trainers = ns.Trainers, npcs = ns.NPCs, where = ns.RecipeWhere, maps = ns.MapIDs, faction = ctx.faction,
    db = ns.Npcs, byName = ns.NpcByName, ntrainers = ns.NpcTrainers, auctioneers = ns.NpcAuctioneers, recorded = ns.db and ns.db.npcs, contOf = {},
    fdb = ns.FdbNpcs, fdbVendors = ns.FdbVendors, fdbTrainers = ns.FdbTrainers, fdbQuests = ns.FdbQuests }
  for _, m in pairs(ns.MapIDs) do env.contOf[m[1]] = m[2] end
  local C = C_Map
  local here = C and C.GetBestMapForUnit and C.GetBestMapForUnit("player")
  for _, m in pairs(ns.MapIDs) do if m[1] == here then env.continent = m[2] end end
  if not (here and C.GetWorldPosFromMapPos and C.GetPlayerMapPosition and CreateVector2D) then return env end
  local function world(mapID, x, y)
    local ok, instance, pos = pcall(C.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))
    if ok and instance and pos then
      local wx, wy = pos:GetXY()
      return instance, wx, wy
    end
  end
  local ok, p = pcall(C.GetPlayerMapPosition, here, "player")
  local instance, mx, my
  if ok and p then instance, mx, my = world(here, p:GetXY()) end
  if instance then
    env.dist = function(mapID, x, y)
      local i, wx, wy = world(mapID, x / 100, y / 100)
      if i == instance and wx then return math.sqrt((wx - mx) ^ 2 + (wy - my) ^ 2) end
    end
  end
  return env
end

-- Crafts of a profession from the vendored Forever data (ForeverDB.lua): nil when it has none for this profession.
local libCache = {}
local function libCrafts(p, faction)
  local DB = ns.ForeverDB
  if not DB:HasProfession(p.line) then return end
  local key = p.line .. faction
  if not libCache[key] then
    local english, byId = SKILL_LINES[p.line], {}
    for _, c in ipairs(english and ns.Leveling.Crafts(ns.RecipeRows or {}, english) or {}) do byId[c.id] = c end
    libCache[key] = ns.Leveling.LibCrafts(DB, p.line, faction, function(id) return byId[id] end, ns.ForeverTrainers,
      ns.Where.Who({ db = ns.Npcs or {}, byName = ns.NpcByName, maps = ns.MapIDs, fdb = ns.FdbNpcs, fdbVendors = ns.FdbVendors,
        fdbQuests = ns.FdbQuests, fdbPrice = ns.FdbPrice, fdbFavor = ns.FdbFavor }), ns.ForeverFixes)
  end
  return libCache[key]
end

-- The objective of the Métier tab, remembered per character: "level" (Monter le métier, default) or "gold" (Gagner de l'or).
function ns.Goal() return ns.char and ns.char.goal == "gold" and "gold" or "level" end

-- Recipes to learn for a profession of ProfessionList (see Leveling.Learnable); nil when it has no recipe data.
function ns.LearnFor(p, ctx, count, knownBest)
  local english = SKILL_LINES[p.line]
  local crafts = libCrafts(p, ctx.faction)
  if not crafts then return end
  local data = ns.char and ns.char.profs[p.name]
  local offers = english and ns.TrainerLog.Offers(ns.db or {}, english, ctx.faction) or {}   -- trainer windows recorded in game
  local own = setmetatable({ known = function(id) return ctx.known(id) or (data and data.recipes[id]) and true or false end,
    offer = function(id) return offers[id] end, maxSkill = p.max, goal = ns.Goal() }, { __index = ctx })
  -- where to go to learn each one (a pin, or a text only): recorded trainer, library NPC, Classic coordinates, text
  local env = whereEnv(ctx)
  -- intermediate reagents the character knows how to make (a Cured Light Hide from a Light Hide): valued by their crafting cost
  local byOut = {}
  for _, r in pairs(data and data.recipes or {}) do if r.out then byOut[r.out] = r end end
  own.sub = function(item) return byOut[item] end
  own.place = function(rec) return ns.Where.Target(rec, english, env) end
  local result = ns.Leveling.Learnable(crafts, p.skill or 0, own, count, nil, knownBest)
  if result.beyond and result.beyond.rank then   -- where to train the rank that lifts the cap
    local b = result.beyond
    b.target = ns.Where.Target({ id = 0, learn = b.max + 1, src = nil, way = { rank = b.rank } }, english, env)
  end
  for _, bucket in ipairs({ result.now, result.soon, result.gray, result.books }) do
    for _, row in ipairs(bucket) do
      row.target = row.target or ns.Where.Target(row.rec, english, env)
      -- never an empty answer: the source itself ("butin", "conteneur", ...) when no place is known
      local t, way = row.target, row.rec.way
      if not t.mapID or t.dropZone then
        -- the site's location text: where it drops ("butin : Les Mortemines") or the quest that gives it
        if way and way.zone and (way.kind == "drop" or way.kind == "container" or way.kind == "item") then
          local zones = {}
          for part in way.zone:gmatch("[^,]+") do
            local z = part:match("^%s*(.-)%s*$")
            zones[#zones + 1] = ns.ZoneLabel({ mapID = ns.MapIDs[z] and ns.MapIDs[z][1], zone = z })
          end
          if way.zoneMore then zones[#zones + 1] = S.zone_more end   -- the site cut the list
          t.text = way.kind == "item" and ("%s (%s : %s)"):format(ns.Fmt.Source(row.rec, true), S.src_d, table.concat(zones, ", "))
            or ns.Fmt.Source(row.rec, true) .. " : " .. table.concat(zones, ", ")
        elseif way and way.questName and way.kind == "quest" then
          t.text = ns.Fmt.Source(row.rec, true) .. " : " .. ns.Fmt.QuestName(way)
        end
        if not t.text then t.text = ns.Fmt.Source(row.rec, true) end
      end
      if t.mapID and t.x and not t.text and way and way.kind == "quest" and way.questName then   -- a pinned quest giver: which quest
        t.text = ns.Fmt.Source(row.rec, true) .. " : " .. ns.Fmt.QuestName(way)
      end
      if t.auction then t.text = ns.Fmt.Source(row.rec, true) end   -- "Patron en vente à l'HV : ~2g (prix HV de 3 j)"
      t.extra = way and way.kind == "item" and ns.Fmt.SiteSources(way) or nil   -- what the site says: butin, pickpocket, pêche, quête
      t.note = ns.Fmt.PriceNote(row)
      if row.rec.src == "i" and row.rec.teachItem then row.rec.itemName = ns.ItemName(row.rec.teachItem) end
    end
  end
  return result
end

-- Zone name in the client's language when the game knows the map, else the English name of the data.
function ns.ZoneLabel(target)
  local info = C_Map and C_Map.GetMapInfo and target.mapID and C_Map.GetMapInfo(target.mapID)
  return info and info.name or target.zone
end

-- The recipes remembered for a profession, without the ones the Forever data places in another skill line (older saved data may
-- hold leather recipes under Skinning): a copy; the section keeps its own profession name and skill line.
function ns.SectionData(data, line)
  local recipes = {}
  for id, rec in pairs(data.recipes or {}) do
    if not (line and ns.ForeverDB:HasProfession(line)) or ns.ForeverDB:BelongsTo(line, id) ~= false then recipes[id] = rec end
  end
  return { skill = data.skill, max = data.max, updated = data.updated, recipes = recipes }
end

-- Where a missing reagent comes from, for the roadmap: "vendor" (a merchant sells it), "skin", "herb", "ore", "ah" (an auction price is
-- known) or nil. Read from the item class (Trade Goods: leather 6, metal and stone 7, herb 9).
local function reagentHow(ctx, id)
  if ctx.buy(id) then return "vendor" end
  local _, _, _, _, _, class, sub = C_Item.GetItemInfoInstant(id)
  if class == 7 and sub == 6 then return "skin" end
  if class == 7 and sub == 9 then return "herb" end
  if class == 7 and sub == 7 then return "ore" end
  if (ctx.price(id)) then return "ah" end
end

-- What the "comment l'obtenir" tooltips (HowTo.lua) read from the game, built at hover time: faction, position, names, prices, the player's
-- own GatherMate2 spots (counted at most once a minute: it asks the addon about every map).
local nodeCache
function ns.HowToEnv()
  local faction = UnitFactionGroup and UnitFactionGroup("player") == "Horde" and "H" or "A"
  local fr = GetLocale and GetLocale() == "frFR" or false
  local w = whereEnv({ faction = faction })
  local function local_(id, english) local n = ns.Npcs and ns.Npcs[id]; return fr and n and n[4] or english end
  return {
    faction = faction, fr = fr, dist = w.dist, mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"),
    itemName = function(id) return ((C_Item and C_Item.GetItemInfo) or GetItemInfo)(id) end,
    owned = function(id) return C_Item.GetItemCount(id, false, false, false) end,
    price = safePrice, money = ns.Money,
    exact = function(copper)
      local coin = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
      return coin and copper and copper > 0 and coin(copper) or ns.Money(copper)
    end,
    zone = function(mapID) return ns.ZoneLabel({ mapID = mapID }) end,
    npcName = local_,
    -- a creature by its English name: the client-language name and its zone, when a single NPC has that name and one zone
    creature = function(english)
      local ids = ns.NpcByName and ns.NpcByName[english]
      local npc = ids and #ids == 1 and ns.Npcs[ids[1]]
      local map = npc and npc[3][1] and npc[3][1][1]
      for _, s in ipairs(npc and npc[3] or {}) do if s[1] ~= map then map = nil end end
      return fr and npc and npc[4] or english, map
    end,
    npc = function(id)   -- ForeverDB's NPC (seen in Forever or not), else pfQuest's Classic one
      local f, n = ns.FdbNpcs and ns.FdbNpcs[id], ns.Npcs and ns.Npcs[id]
      if f then return { name = local_(id, f[1]), mapID = f[2], x = f[3], y = f[4], side = f[5], seen = f[6] } end
      local spawn = n and n[3][1]
      if n then return { name = local_(id, n[1]), mapID = spawn and spawn[1], x = spawn and spawn[2], y = spawn and spawn[3], side = n[2], seen = false } end
    end,
    nodeCounts = function()
      if not (nodeCache and time() - nodeCache.at < 60) then
        local ok, zones = pcall(function() return ns.Nodes.Installed() and (ns.Nodes.Counts()) or {} end)
        nodeCache = { at = time(), zones = ok and zones or {} }
      end
      return nodeCache.zones
    end,
  }
end

-- "Monter le métier": the roadmap of one profession (Leveling.Roadmap) with the names the window shows, the known recipes by colour
-- (the collapsible list) and the trainer to visit when the cap is reached.
function ns.BuildRoadmap(p, data, ctx, entry, thresholds)
  local L = ns.Leveling
  local rctx = setmetatable({ how = function(id) return reagentHow(ctx, id) end }, { __index = ctx })
  local learn = {}
  for _, bucket in ipairs({ entry.learn and entry.learn.now or {}, entry.learn and entry.learn.soon or {} }) do
    for _, row in ipairs(bucket) do learn[#learn + 1] = row end
  end
  -- the gathering professions have nothing to craft the way the roadmap means it: only their rank is followed
  local GATHERING = { [393] = true, [182] = true, [186] = true, [356] = true }
  local gathering = GATHERING[p.line] or false
  local road = L.Roadmap(gathering and { skill = data.skill, max = data.max, recipes = {} } or data, rctx,
    { thresholds = thresholds, learn = gathering and {} or learn })
  road.gathering = gathering
  -- where to train the next rank (the rank trainer of the profession)
  if road.nextRank then
    road.rankTarget = ns.Where.Target({ id = 0, learn = (data.max or 0) + 1, src = nil, way = { rank = road.nextRank } }, SKILL_LINES[p.line], whereEnv(ctx))
  end
  -- hover tooltips ("comment l'obtenir"): built when the mouse is over the row, with what the game knows by then
  local byOut = {}
  for _, rec in pairs(data.recipes) do if rec.out then byOut[rec.out] = rec end end
  local function reagentTip(m, need)
    local made = byOut[m.item]
    local make = made and { name = ns.Fmt.RecipeName(made), mats = made.mats }
    m.tip = function() return ns.HowTo.Reagent(m.item, need, ns.HowToEnv(), make) end
  end
  for _, s in ipairs(road.steps) do
    if s.kind == "craft" then
      s.name = ns.Fmt.RecipeName(s.rec)
      s.craft = { id = s.rec.id, times = s.times, prof = p.name, line = p.line }
      for _, m in ipairs(s.missing) do m.name = ns.ItemName(m.item); reagentTip(m, m.n) end
      for _, m in ipairs(s.subs) do m.name = ns.ItemName(m.item); reagentTip(m, m.need) end
    elseif s.kind == "learn" then
      s.name, s.target = s.row.name or ns.Fmt.RecipeName(s.rec), s.row.target
      local spec = ns.HowTo.LearnSpec(s.rec, s.name, s.target, p.name)
      s.tip = function() return ns.HowTo.Step(spec, ns.HowToEnv()) end
    end
  end
  -- the rank that lifts the cap: its requirements, and for a book the vendor of the player's faction (the pin goes there)
  if road.nextRank then
    local spec = ns.HowTo.RankSpec(p.line, road.nextRank, ns.HowToEnv(), road.rankTarget, p.name)
    road.rankTarget = spec.target
    road.rankTip = function() return ns.HowTo.Step(spec, ns.HowToEnv()) end
  end
  local lr = entry.learn
  road.trainer = road.rankTarget or (lr and ((lr.beyond and lr.beyond.target) or (lr.books and lr.books[1] and lr.books[1].target))) or nil
  road.recipes = {}
  for _, rec in pairs(data.recipes) do
    local th = thresholds(rec.id)
    road.recipes[#road.recipes + 1] = { name = ns.Fmt.RecipeName(rec), d = th and p.skill and L.ColorAt(p.skill, th) or rec.d or 0, id = rec.id }
  end
  table.sort(road.recipes, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.id < b.id end)
  return road
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
    -- reagents, outputs and teaching items of the recipes that may be learned (within reach of the skill)
    local faction = UnitFactionGroup("player") == "Horde" and "H" or "A"
    local offers = data and SKILL_LINES[p.line] and ns.TrainerLog.Offers(ns.db or {}, SKILL_LINES[p.line], faction) or {}
    for _, craft in ipairs(data and libCrafts(p, faction) or {}) do
      local at = offers[craft.id] and math.max(1, offers[craft.id].skill or 1) or craft.learn
      if at and at <= (p.skill or 0) + ns.Leveling.SOON then
        ids[#ids + 1] = craft.out
        if craft.how and craft.how.itemID then ids[#ids + 1] = craft.how.itemID end
        for _, m in ipairs(craft.mats) do ids[#ids + 1] = m[1] end
      end
    end
  end
  ns.LoadItems(ids, function()
    local ok, res = pcall(function()
      local ctx = ns.Context()
      local profs = {}
      for _, p in ipairs(list) do
        local entry = { name = p.name, skill = p.skill, max = p.max }
        local data = ns.char.profs[p.name]
        data = data and ns.SectionData(data, p.line)
        -- What the game said when the window was read decides: no remembered window = "open it once"; a window that
        -- listed no known recipe = "no recipes" (learned from the game, not assumed per profession).
        if not data then
          entry.status = "unseen"
        elseif next(data.recipes) == nil then
          entry.status = "norecipes"
        else
          entry.status = "plan"
          -- "Avec mon sac": count what is carried (bags only: no bank, no reagent bank)
          -- the roadmap of "Monter le métier" always uses the bag first: the checkbox only belongs to "Gagner de l'or"
          local count = ns.char.onlyBag and ns.Goal() == "gold" and function(id) return C_Item.GetItemCount(id, false, false, false) end or nil
          entry.filtered = count ~= nil
          local function thresholds(id)
            local r = ns.ForeverDB:GetRecipes(p.line)
            local e = r and r[id]
            return e and ns.Leveling.Difficulty(e.difficulty, e.requiredSkill, ns.ForeverTrainers[id])
          end
          entry.plan = ns.Leveling.Plan(data, ctx, nil, count, thresholds, ns.Goal())
          -- the "Fabriquer" button crafts the recommended recipe as many times as the bags allow, filter or not
          local best = entry.plan.best
          if best then
            local times = ns.Leveling.Craftable(best.rec, function(id) return C_Item.GetItemCount(id, false, false, false) end)
            entry.craft = { id = best.rec.id, times = times, prof = p.name, line = p.line }
          end
          for _, row in ipairs(entry.plan.rows) do row.name = ns.Fmt.RecipeName(row.rec) end
          if entry.plan.second then entry.plan.second.e.name = entry.plan.second.e.name or ns.Fmt.RecipeName(entry.plan.second.e.rec) end
          local almost = entry.plan.almost
          if almost then
            entry.almost = { name = ns.Fmt.RecipeName(almost.rec), missing = {} }
            for i, s in ipairs(almost.short) do entry.almost.missing[i] = { ns.ItemName(s[1]), s[2] } end
          end
          entry.goal = entry.plan.goal
          entry.learn = ns.LearnFor(p, ctx, count, best and not best.uncertain and (entry.goal == "gold" and -best.profit or best.unitsPerPoint) or nil)
          if entry.learn then
            for _, bucket in ipairs({ entry.learn.now or {}, entry.learn.soon or {}, entry.learn.gray or {}, entry.learn.books or {} }) do
              for _, row in ipairs(bucket) do row.name = ns.Fmt.RecipeName(row.rec) end
            end
            for _, row in ipairs(entry.learn.otherFaction or {}) do row.name = ns.Fmt.RecipeName(row.rec) end
            for _, row in ipairs(entry.learn.books or {}) do row.name = ns.BookName(row.rec) end
          end
          local seen, names = {}, {}
          for i = 1, math.min(3, #entry.plan.unpriced) do
            for _, id in ipairs(entry.plan.unpriced[i].missing) do
              if not seen[id] then seen[id] = true; names[#names + 1] = ns.ItemName(id) end
            end
          end
          entry.missingNames = names
          if entry.goal ~= "gold" then entry.road = ns.BuildRoadmap(p, data, ctx, entry, thresholds) end
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
  elseif cmd == "pnj" or cmd == "npc" then
    -- the NPCs recorded in game: their place is the confirmed one on Forever (raw print: one line per NPC)
    local list = ns.TrainerLog.Recorded(ns.db or {})
    ns.Print(#list == 0 and S.npc_none or S.npc_header:format(#list))
    for _, n in ipairs(list) do
      local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(n.mapID)
      print(S.npc_line:format(n.name, info and info.name or n.zone or tostring(n.mapID), n.x, n.y))
    end
  elseif cmd == "" and ns.Window then ns.Window.Toggle()
  else ns.Print("/gc (fenêtre) · /gc map · /gc pnj · /gc spike · /gc dump · /gc log [clear]") end
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
