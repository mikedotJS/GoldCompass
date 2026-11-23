-- Smoke: diagnostic log, Learned.Capture, bank and item-data listeners, RouteMap driver.
local H = require("spec.helper_smoke")
local loadAddon = H.loadAddon
local printed, handlers, frames, timers
local function setup(opts)
  printed, handlers, frames, timers = {}, {}, {}, {}
  H.setup(opts, function() return printed, handlers, frames, timers end)
end

describe("diagnostic log", function()
  local function fire(event, ...)
    for _, fr in ipairs(frames) do
      if fr.events and fr.events[event] then fr.scripts.OnEvent(fr, event, ...) end
    end
  end
  local function start(opts)
    setup(opts or {})
    local ns = loadAddon()
    fire("ADDON_LOADED", "GoldCompass")
    return ns
  end

  it("keeps the newest 300 entries: trimmed in one pass once 50 over, and down to 300 when the game saves", function()
    local ns = start()
    for i = 1, 350 do ns.Log("test", "entry " .. i) end
    assert.is_true(#ns.db.log <= 350)
    assert.are.equal("entry 350", ns.db.log[#ns.db.log].text)
    assert.are.equal("entry 349", ns.db.log[#ns.db.log - 1].text)                   -- chronological
    local removes, real = 0, table.remove
    table.remove = function(...) removes = removes + 1; return real(...) end
    for i = 351, 700 do ns.Log("test", "entry " .. i) end
    table.remove = real
    assert.are.equal(0, removes)                                                    -- nothing shifts at each entry
    assert.is_true(#ns.db.log <= 350)
    fire("PLAYER_LOGOUT")
    assert.are.equal(300, #ns.db.log)
    assert.are.equal("entry 401", ns.db.log[1].text)
    assert.are.equal("entry 700", ns.db.log[300].text)
    assert.matches("^%d%d:%d%d:%d%d$", ns.db.log[1].time)
  end)

  it("logs what was printed before the saved variables existed, without color codes", function()
    setup({})
    local ns = loadAddon()
    ns.Print("avant le chargement")
    fire("ADDON_LOADED", "GoldCompass")
    local found
    for _, e in ipairs(ns.db.log) do
      if e.kind == "chat" and e.text:find("avant le chargement", 1, true) then found = e end
    end
    assert.is_not_nil(found)
    assert.is_nil(found.text:find("|c", 1, true))
  end)

  it("routes the spike and map output through the log", function()
    local ns = start({ scanned = true })
    SlashCmdList["GOLDCOMPASS"]("spike")
    SlashCmdList["GOLDCOMPASS"]("map")
    local kinds = {}
    for _, e in ipairs(ns.db.log) do kinds[e.text:match("^%[spike%]") and "spike" or e.kind] = true end
    assert.is_true(kinds.chat)
    local spike = false
    for _, e in ipairs(ns.db.log) do spike = spike or e.text:find("[spike] S2", 1, true) ~= nil end
    assert.is_true(spike)
  end)

  it("chains the error handler: ours logs, the previous one is still called with the message", function()
    setup({})
    local received
    _G.errorHandler = function(m) received = m; return "prev-result" end
    local ns = loadAddon()
    fire("ADDON_LOADED", "GoldCompass")
    fire("PLAYER_LOGIN")
    assert.are_not.equal(_G.errorHandler, nil)
    local result = _G.errorHandler("Interface\\AddOns\\Other\\x.lua:1: boom")
    assert.are.equal("Interface\\AddOns\\Other\\x.lua:1: boom", received)
    assert.are.equal("prev-result", result)
    local last = ns.db.log[#ns.db.log]
    assert.are.equal("lua-error", last.kind)
    assert.matches("boom", last.text)
    -- installing twice does not stack a second wrapper
    local handler = _G.errorHandler
    ns.LogChainErrorHandler()
    assert.are.equal(handler, _G.errorHandler)
  end)

  it("writes the login header with the client build, the TOC and the addon versions", function()
    setup({})
    _G.C_AddOns = { GetAddOnMetadata = function(name, field)
      return ({ ["GoldCompass:X-TocFile"] = "plain", ["GoldCompass:Version"] = "0.1.0", ["GatherMate2:Version"] = "1.52.7", ["Auctionator:Version"] = "347" })[name .. ":" .. field] end }
    local ns = loadAddon()
    fire("ADDON_LOADED", "GoldCompass")
    fire("PLAYER_LOGIN")
    local h
    for _, e in ipairs(ns.db.log) do if e.kind == "login" then h = e.text end end
    assert.matches("build 70938", h)
    assert.matches("TOC used: plain", h)
    assert.matches("GatherMate2 1.52.7", h)
    assert.matches("Auctionator 347", h)
    _G.C_AddOns = nil
  end)

  it("logs blocked and forbidden actions with the addon, the function and a short stack", function()
    local ns = start()
    fire("ADDON_ACTION_BLOCKED", "Auctionator", "C_AuctionHouse.PostItem")
    fire("ADDON_ACTION_FORBIDDEN", "Other", "UseAction")
    local blocked, forbidden = ns.db.log[#ns.db.log - 1], ns.db.log[#ns.db.log]
    assert.are.equal("blocked", blocked.kind)
    assert.matches("Auctionator", blocked.text)
    assert.matches("C_AuctionHouse.PostItem", blocked.text)
    assert.matches("stack line 1 < stack line 2", blocked.text)
    assert.are.equal("forbidden", forbidden.kind)
  end)

  it("prints the last 20 entries with /gc log and empties the log with /gc log clear", function()
    local ns = start()
    for i = 1, 30 do ns.Log("test", "line " .. i) end
    printed = {}
    SlashCmdList["GOLDCOMPASS"]("log")
    local text = table.concat(printed, "\n")
    assert.matches("line 30", text)
    assert.matches("line 11", text)
    assert.is_nil(text:find("line 10\n", 1, true))   -- only the last 20
    local before = #ns.db.log
    SlashCmdList["GOLDCOMPASS"]("log") -- showing the log does not add to it
    assert.are.equal(before, #ns.db.log)
    printed = {}
    SlashCmdList["GOLDCOMPASS"]("log clear")
    assert.are.equal(0, #ns.db.log)
    assert.matches("journal vidé", table.concat(printed, "\n"))
  end)

  it("never raises and never recurses when logging itself fails", function()
    local ns = start()
    local calls = 0
    local received
    _G.errorHandler = function(m) received = m end
    ns.db = ns.db -- keep the saved table
    fire("PLAYER_LOGIN")
    -- logging fails (date raises) and, while it runs, an error reaches the handler: no recursion, previous handler called
    _G.date = function()
      calls = calls + 1
      if calls == 1 then _G.errorHandler("inner error") end
      error("date broke")
    end
    assert.has_no.errors(function() ns.Log("test", "x") end)
    assert.has_no.errors(function() _G.errorHandler("later error") end)
    assert.are.equal("later error", received)
    assert.is_true(calls < 10)
    -- the log works again afterwards
    _G.date = os.date
    ns.Log("test", "back")
    assert.are.equal("back", ns.db.log[#ns.db.log].text)
  end)
end)

describe("Learned.Capture stays quiet when the window did not change", function()
  local function window(skill, ids, counter)
    return {
      GetBaseProfessionInfo = function() return { professionName = "Alchimie", skillLevel = skill(), maxSkillLevel = 75 } end,
      GetAllRecipeIDs = function() return ids() end,
      GetRecipeInfo = function(id) counter.n = counter.n + 1; return { learned = true, name = "Recette " .. id, relativeDifficulty = 1 } end,
      GetRecipeSchematic = function() return { outputItemID = 30, quantityMin = 1, quantityMax = 1, reagentSlotSchematics = { { reagents = { { itemID = 10 } }, quantityRequired = 2 } } } end,
    }
  end

  it("a quick read with the same skill and recipe count reads no recipe and reports no change", function()
    setup({ scanned = true })
    local ns = loadAddon()
    local skill, list, counter, clock = 50, { 1, 2 }, { n = 0 }, 5000
    _G.time = function() return clock end
    local T = window(function() return skill end, function() return list end, counter)
    local learned, profs = {}, {}
    local added, changed = ns.Learned.Capture(T, learned, profs, true)
    assert.are.equal(2, added); assert.is_true(changed)                              -- the first reading is a full one
    local updated, reads = profs.Alchimie.updated, counter.n
    clock = clock + 5
    added, changed = ns.Learned.Capture(T, learned, profs, true)
    assert.are.equal(0, added); assert.is_false(changed)
    assert.are.equal(reads, counter.n)                                              -- no GetRecipeInfo at all
    assert.are.equal(updated, profs.Alchimie.updated)                               -- the plans are not told to start again
    added, changed = ns.Learned.Capture(T, learned, profs)                          -- a full read finds nothing new either
    assert.is_false(changed)
    assert.are.equal(updated, profs.Alchimie.updated)
    skill = 51                                                                      -- a skill-up: read again
    _G.time = function() return clock + 1 end
    _, changed = ns.Learned.Capture(T, learned, profs, true)
    assert.is_true(changed)
    assert.are.equal(51, profs.Alchimie.skill)
    list = { 1, 2, 3 }                                                              -- a recipe more
    added, changed = ns.Learned.Capture(T, learned, profs, true)
    assert.are.equal(1, added); assert.is_true(changed)
    clock = clock + 100                                                             -- a minute later the quick read looks again
    _G.time = function() return clock end
    local before = counter.n
    ns.Learned.Capture(T, learned, profs, true)
    assert.is_true(counter.n > before)
    _G.time = os.time
  end)

  it("the window events: a refresh only when something changed, the opening always read in full, merchant bursts apart", function()
    setup({ scanned = true })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = {} }
    local counter = { n = 0 }
    _G.C_TradeSkillUI = window(function() return 50 end, function() return { 1, 2 } end, counter)
    local onData = 0
    ns.Window.OnData = function() onData = onData + 1 end
    local function fire(event)
      for _, fr in ipairs(frames) do
        if fr.events and fr.events.TRADE_SKILL_SHOW and fr.scripts.OnEvent then fr.scripts.OnEvent(fr, event) end
      end
    end
    local function drain() local t = timers; timers = {}; for _, fn in ipairs(t) do pcall(fn) end end
    timers = {}
    fire("TRADE_SKILL_SHOW"); drain()
    assert.are.equal(1, onData)                                                     -- first reading: new
    fire("TRADE_SKILL_LIST_UPDATE"); drain()
    fire("TRADE_SKILL_LIST_UPDATE"); drain()
    assert.are.equal(1, onData)                                                     -- the list refreshed, nothing changed: no redraw
    local reads = counter.n
    fire("TRADE_SKILL_SHOW"); drain()
    assert.is_true(counter.n > reads)                                               -- opening the window reads every recipe again
    assert.are.equal(1, onData)
    _G.GetMerchantNumItems, _G.GetMerchantItemLink = function() return 0 end, function() end
    fire("MERCHANT_UPDATE")                                                         -- a merchant burst does not swallow the window event
    fire("TRADE_SKILL_LIST_UPDATE")
    assert.are.equal(2, #timers)
    _G.C_TradeSkillUI, _G.GetMerchantNumItems, _G.GetMerchantItemLink = nil, nil, nil
  end)
end)

describe("BankEvents listens to the bags only while the bank is open", function()
  local function bankFrame()
    for _, fr in ipairs(frames) do if fr.events and fr.events.BANKFRAME_OPENED then return fr end end
  end

  it("registers the bag and bank slot events at the opening and drops them at the closing", function()
    setup({ scanned = true })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = {}, bank = nil }
    local fr = bankFrame()
    for _, e in ipairs({ "BAG_UPDATE", "BAG_UPDATE_DELAYED", "PLAYERBANKSLOTS_CHANGED", "PLAYERBANKBAGSLOTS_CHANGED" }) do assert.is_nil(fr.events[e]) end
    assert.is_true(fr.events.BANKFRAME_CLOSED)                                      -- the window events stay
    fr.scripts.OnEvent(fr, "BANKFRAME_OPENED")
    for _, e in ipairs({ "BAG_UPDATE", "BAG_UPDATE_DELAYED", "PLAYERBANKSLOTS_CHANGED", "PLAYERBANKBAGSLOTS_CHANGED" }) do assert.is_true(fr.events[e]) end
    local before = #timers
    fr.scripts.OnEvent(fr, "BAG_UPDATE")                                            -- a change while open is scanned (debounced)
    assert.are.equal(before + 1, #timers)
    fr.scripts.OnEvent(fr, "BANKFRAME_CLOSED")
    for _, e in ipairs({ "BAG_UPDATE", "BAG_UPDATE_DELAYED", "PLAYERBANKSLOTS_CHANGED", "PLAYERBANKBAGSLOTS_CHANGED" }) do assert.is_nil(fr.events[e]) end
  end)
end)

describe("the item-data listener of the row tooltips", function()
  it("listens to GET_ITEM_INFO_RECEIVED only while a tooltip waits for an item", function()
    setup({ scanned = true })
    local ns = loadAddon()
    for _, k in ipairs({ "SetOwner", "ClearAllPoints", "SetPoint", "SetText", "Show", "Hide" }) do GameTooltip[k] = function() end end
    local loading, shows = true, 0
    local row = { tip = function() shows = shows + 1; return { title = "Peau", lines = {}, loading = loading, item = 123 } end }
    local W = ns.Window
    local function listening() return W.itemEvents and W.itemEvents.events and W.itemEvents.events.GET_ITEM_INFO_RECEIVED end
    W.ShowTip(row)
    assert.is_true(listening())
    loading = false
    W.itemEvents.scripts.OnEvent(W.itemEvents, "GET_ITEM_INFO_RECEIVED", 123)       -- the item arrived: redrawn, nothing left to wait for
    assert.are.equal(2, shows)
    assert.is_nil(listening())
    loading = true
    W.ShowTip(row)
    assert.is_true(listening())
    W.HideTip(row)                                                                  -- the mouse left
    assert.is_nil(listening())
  end)
end)

describe("RouteMap driver runs only where it has something to follow", function()
  local function started(opts)
    setup(opts or { scanned = true })
    local ns = loadAddon()
    ns.db = { buy = {} }
    ns.char = { learned = {}, profs = {} }
    ns.Window.OpenMap = function() end
    local at = { GetXY = function() return 0.5, 0.5 end }
    local reads = 0
    _G.C_Map.GetPlayerMapPosition = function() reads = reads + 1; return at end
    ns.RouteMap.Start({ zone = 1411, points = { { x = 10, y = 10 }, { x = 20, y = 20 } } })
    local driver
    for _, fr in ipairs(frames) do if fr.events and fr.events.ZONE_CHANGED_NEW_AREA then driver = fr end end
    return ns, driver, function() return reads end, function(v) at = v end
  end

  it("is armed by the route, stopped when the player is elsewhere, started again by a zone change, ended by Clear", function()
    local ns, driver, reads, setAt = started()
    assert.is_function(driver.scripts.OnUpdate)
    assert.is_true(driver.events.PLAYER_ENTERING_WORLD)
    setAt(nil)                                                                      -- the player left the zone
    ns.RouteMap.Tick()
    assert.is_nil(driver.scripts.OnUpdate)                                          -- no more OnUpdate calls
    driver.scripts.OnEvent(driver, "ZONE_CHANGED_NEW_AREA")
    assert.is_nil(driver.scripts.OnUpdate)                                          -- a zone change that does not bring the player back
    setAt({ GetXY = function() return 0.4, 0.4 end })
    driver.scripts.OnEvent(driver, "ZONE_CHANGED_NEW_AREA")
    assert.is_function(driver.scripts.OnUpdate)                                     -- back on the route's map
    ns.RouteMap.Clear()
    assert.is_nil(driver.scripts.OnUpdate)
    assert.is_nil(driver.events.ZONE_CHANGED_NEW_AREA)
    assert.is_nil(driver.events.PLAYER_ENTERING_WORLD)
    assert.is_nil(ns.RouteMap.Active())
    local before = reads()
    driver.scripts.OnEvent(driver, "ZONE_CHANGED_NEW_AREA")                         -- an event arriving late changes nothing
    assert.is_nil(driver.scripts.OnUpdate)
    assert.are.equal(before, reads())
  end)

  it("a tick in combat reads nothing", function()
    local ns, _, reads = started()
    ns.RouteMap.Tick()
    assert.is_true(reads() > 1)                                                     -- out of combat the tick reads the position
    local before = reads()
    _G.InCombatLockdown = function() return true end
    ns.RouteMap.Tick()
    assert.are.equal(before, reads())
    _G.InCombatLockdown = function() return false end
  end)
end)
