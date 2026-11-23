-- Diagnostic log: a ring buffer in GoldCompassDB.log (SavedVariables), readable from the Mac with scripts/fetch-logs.sh.
-- Holds what GoldCompass printed in chat, blocked/forbidden-action events, Lua errors, and a login header.
-- Taint: this file calls no protected function, writes to no Blizzard frame, hooks nothing, and only CHAINS the error handler.
local addonName, ns = ...

local MAX, SLACK = 300, 50   -- the newest MAX entries are kept; the list may run SLACK over before one pass drops the oldest (no shifting per entry)
local pending, db = {}, nil   -- entries logged before the SavedVariables are loaded wait in `pending`
local busy = false            -- true while an entry is being written: stops any recursion
local seen = {}

local function clock() return date("%H:%M:%S") end

-- Adds one entry { time, kind, text }. Never raises, never recurses. Chat color codes are stripped for readability.
-- Keeps the newest MAX entries of a chronological list, in one pass.
local function trim(list)
  local n = #list
  if n <= MAX then return end
  local drop = n - MAX
  for i = 1, MAX do list[i] = list[i + drop] end
  for i = MAX + 1, n do list[i] = nil end
end

function ns.Log(kind, text)
  if busy then return end
  busy = true
  pcall(function()
    local entry = { time = clock(), kind = kind, text = tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") }
    local list = db and db.log or pending
    list[#list + 1] = entry
    if #list > MAX + SLACK then trim(list) end
  end)
  busy = false
end

-- Logs `key` only the first time (first frame opened, first hook registered, ...).
function ns.LogOnce(key, kind, text)
  if seen[key] then return end
  seen[key] = true
  ns.Log(kind, text)
end

-- Called from Core.lua once GoldCompassDB exists: moves the early entries into the saved buffer.
function ns.LogInit(saved)
  db = saved
  db.log = db.log or {}
  local early = pending
  pending = {}
  busy = false
  for _, e in ipairs(early) do
    db.log[#db.log + 1] = e
  end
  trim(db.log)
end

function ns.LogRecent(n)
  local list = db and db.log or pending
  local out = {}
  for i = math.max(1, #list - n + 1), #list do out[#out + 1] = list[i] end
  return out, #list
end

function ns.LogClear()
  if db then db.log = {} end
  pending = {}
end

local function short(stack)
  return (tostring(stack or ""):gsub("\n", " < "):sub(1, 300))
end

-- Chain the error handler: ours runs first, then the previous one, which always gets the same message back.
local installed
local function chainErrorHandler()
  if installed or not (geterrorhandler and seterrorhandler) then return end
  installed = true
  local prev = geterrorhandler()
  seterrorhandler(function(message)
    ns.Log("lua-error", message)
    return prev(message)
  end)
end

local function meta(name, field)
  local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  return get and get(name, field) or "-"
end

local function header()
  local version, build, built, interface = GetBuildInfo()
  ns.Log("login", ("client %s build %s (%s) interface %s; project %s; TOC used: %s; GoldCompass %s; GatherMate2 %s; Auctionator %s"):format(
    tostring(version), tostring(build), tostring(built), tostring(interface), tostring(WOW_PROJECT_ID),
    tostring(meta(addonName, "X-TocFile")), tostring(meta(addonName, "Version")),
    tostring(meta("GatherMate2", "Version")), tostring(meta("Auctionator", "Version"))))
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event, a, b)
  if event == "PLAYER_LOGIN" then
    chainErrorHandler()
    header()
  elseif event == "PLAYER_LOGOUT" then
    if db and db.log then trim(db.log) end   -- the saved file holds MAX entries, not MAX + SLACK
  else
    ns.Log(event == "ADDON_ACTION_BLOCKED" and "blocked" or "forbidden",
      ("addon %s, function %s | %s"):format(tostring(a), tostring(b), short(debugstack and debugstack(2, 6, 0))))
  end
end)

-- exposed so tests can install the chain without a login event
ns.LogChainErrorHandler = chainErrorHandler
