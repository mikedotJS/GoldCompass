-- "Liste de courses": a small movable tracker with what the whole roadmap of "Monter le métier" still needs (Shopping.lua does the
-- sums), shown on screen even when the Gold Compass window is closed. It follows the bags, the bank and the skills by itself.
-- Position and shown / hidden are saved in ns.db.shop. Rows reuse the roadmap's "comment l'obtenir" tooltip and its map pin (Window.lua).
local _, ns = ...
local S = ns.S

local SL = {}
ns.ShoppingList = SL

local WIDTH, PAD, TITLE_H, ROW_H, ROW_SUB_H, MAX_ROWS, NOTE_LINE_H = 262, 8, 24, 17, 29, 10, 13
local COUNT_W = 84
local TIMEOUT = 10           -- seconds before a calculation that never answers becomes an error
local GOLD, DIM, WHITE = { 1, 0.82, 0 }, { 0.62, 0.62, 0.62 }, { 0.91, 0.88, 0.8 }

local f, rowFrames = nil, {}
local state                  -- nil = not computed yet, { error = res } or the result of Shopping.Build
local pending, token, dirty = false, 0, false
local sawMissing = false     -- something was short since the list was opened: "Tout est réuni." rather than "Rien ne manque"

local function saved()
  ns.db.shop = ns.db.shop or {}
  return ns.db.shop
end

local env = {
  bag = function(id) return C_Item.GetItemCount(id, false, false, false) end,
  bank = function(id) return ns.Bank.Count(id) end,
  name = function(id) return ns.ItemName(id) end,
  vendor = function(id) return ((ns.db and ns.db.buy and ns.db.buy[id]) or ns.Prices.VendorBuy(id)) and true or false end,
}

-- A font string on `parent`, one line unless `wrap`.
local function label(parent, template, colour, justify, wrap)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
  if colour then fs:SetTextColor(colour[1], colour[2], colour[3]) end
  fs:SetJustifyH(justify or "LEFT")
  fs:SetJustifyV("TOP")
  fs:SetWordWrap(wrap or false)
  if not wrap then fs:SetMaxLines(1) end
  return fs
end

local function colour(hex, str) return "|cff" .. hex .. str .. "|r" end

-- ---------------------------------------------------------------------------------------------------------------------
-- What the Métier tab shows of the list: its button, and the line about the bank under the roadmap.

-- The label and visibility of the "Liste de courses (N)" button: N items short, hidden when nothing is short nor waits in the bank.
function SL.ButtonInfo()
  if not state or state.error then return S.shop_button0, false end
  return state.missing > 0 and S.shop_button:format(state.missing) or S.shop_button0, state.missing > 0 or #state.fetch > 0
end

-- The dim line under the roadmap: the bank was never opened on this character, or not for a day or more. nil when there is nothing to say.
function SL.BankNote()
  if not (state and not state.error and #state.upTo > 0) then return nil end
  local age = ns.Bank.AgeDays(ns.char, time())
  if not age then return S.bank_unseen end
  if age >= 1 then return S.bank_age:format(age) end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- The frame.

local function sourceOf(r)
  local ok, tip = pcall(r.tip or function() return ns.HowTo.Reagent(r.item, 0, ns.HowToEnv()) end)
  return ok and tip and tip.source or nil
end

local function makeRow()
  local row = CreateFrame("Button", nil, f)
  row:EnableMouse(true)
  row:RegisterForClicks("LeftButtonUp")
  row.hover = row:CreateTexture(nil, "BACKGROUND")
  row.hover:SetColorTexture(1, 0.82, 0, 0.1)
  row.hover:SetAllPoints()
  row.hover:Hide()
  row.count = label(row, "GameFontHighlightSmall", WHITE, "RIGHT")
  row.count:SetPoint("TOPRIGHT", row, "TOPRIGHT", -2, -1)
  row.count:SetSize(COUNT_W, 14)
  row.name = label(row, "GameFontHighlightSmall", WHITE)
  row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 2, -1)
  row.name:SetSize(WIDTH - 2 * PAD - COUNT_W - 8, 14)
  row.sub = label(row, "GameFontHighlightSmall", DIM)
  row.sub:SetPoint("TOPLEFT", row, "TOPLEFT", 2, -14)
  row.sub:SetSize(WIDTH - 2 * PAD - 4, 12)
  -- hover = the roadmap's "comment l'obtenir" tooltip, click = its map pin
  row:SetScript("OnEnter", function(self) self.hover:Show(); ns.Window.ShowTip(self) end)
  row:SetScript("OnLeave", function(self) self.hover:Hide(); ns.Window.HideTip(self) end)
  row:SetScript("OnHide", function(self) self.hover:Hide(); ns.Window.HideTip(self) end)
  row:SetScript("OnClick", function(self)
    local tip = ns.Window.tipOf(self)
    if tip and tip.target then ns.Window.GoTo(tip.target, tip.title) end
  end)
  return row
end

local function build()
  ns.LogOnce("frame-shop", "frame", "creating GoldCompassShoppingList (own frame, parent UIParent, no secure template)")
  f = CreateFrame("Frame", "GoldCompassShoppingList", UIParent)
  f:SetSize(WIDTH, 80)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    if type(point) == "string" then saved().pos = { point, relPoint, x, y } end
  end)
  local pos = saved().pos
  if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("LEFT", UIParent, "LEFT", 24, 120) end
  f:Hide()
  local edge = f:CreateTexture(nil, "BACKGROUND")
  edge:SetColorTexture(0.29, 0.239, 0.149)
  edge:SetAllPoints()
  local bg = f:CreateTexture(nil, "BORDER")
  bg:SetColorTexture(0.039, 0.031, 0.02, 0.8)
  bg:SetPoint("TOPLEFT", 1, -1)
  bg:SetPoint("BOTTOMRIGHT", -1, 1)

  f.title = label(f, "GameFontNormal", GOLD)
  f.title:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -7)
  f.title:SetText(S.shop_title)
  f.upTo = label(f, "GameFontHighlightSmall", DIM)
  f.upTo:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 108, -9)
  f.upTo:SetSize(WIDTH - PAD - 108 - 26, 12)
  f.close = CreateFrame("Button", nil, f)
  f.close:SetSize(18, 18)
  f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
  f.close.x = label(f.close, "GameFontNormal", GOLD, "CENTER")
  f.close.x:SetAllPoints()
  f.close.x:SetText("×")
  f.close:SetScript("OnClick", function() SL.Hide() end)
  f.close:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(S.shop_close, 1, 1, 1); GameTooltip:Show() end)
  f.close:SetScript("OnLeave", function() GameTooltip:Hide() end)

  f.note = label(f, "GameFontHighlightSmall", DIM, "LEFT", true)
  f.note:SetWidth(WIDTH - 2 * PAD)
  f.farm = label(f, "GameFontHighlightSmall", DIM, "LEFT", true)   -- "À farmer d'abord : ..." (Synergy.lua), above the rows
  f.farm:SetWidth(WIDTH - 2 * PAD)
  f.farm:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(TITLE_H + 2))
  f.retry = CreateFrame("Button", nil, f)
  f.retry:SetSize(90, 18)
  f.retry.label = label(f.retry, "GameFontNormalSmall", GOLD, "LEFT")
  f.retry.label:SetAllPoints()
  f.retry.label:SetText("[ " .. S.shop_retry .. " ]")
  f.retry:SetScript("OnClick", function() SL.Compute() end)
  f.retry:Hide()
end

-- Lines a note takes in the frame (about 44 characters a line, the colour codes and the second byte of an accent do not count).
local function lineCount(text)
  return math.ceil(#(text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("[\128-\191]", "")) / 44)
end

-- Draws `state`: one row per item (name left, have / need right, a dim line under it), then a note for the states without rows.
function SL.Render()
  if not (f and f:IsShown()) then return end
  local st = state
  local y, notes, shown = TITLE_H, {}, 0
  local rows = {}
  f.upTo:SetText("")
  f.retry:Hide()
  f.farm:SetText("")
  if st == nil then
    notes[1] = colour("9d9d9d", S.shop_loading)
  elseif st.error then
    local title, body = ns.StateText(st.error)
    notes[1] = colour("ff8040", title) .. "\n" .. colour("9d9d9d", body)
    f.retry:Show()
  else
    local up = {}
    for i, u in ipairs(st.upTo) do up[i] = #st.upTo == 1 and S.shop_until:format(u.skill or 0) or S.shop_until_prof:format(u.name, u.skill or 0) end
    f.upTo:SetText(#up == 1 and up[1] or (#up > 1 and S.shop_until_many:format(table.concat(up, " · ")) or ""))
    if st.missing > 0 then sawMissing = true end
    if st.missing == 0 and #st.fetch == 0 then
      -- nothing to find: either everything was gathered since the list was opened, or nothing was ever missing
      if #st.rows > 0 and sawMissing then
        notes[1] = colour("7fd36a", S.shop_all)
        notes[2] = colour("9d9d9d", S.shop_all_sub)
      else
        notes[1] = colour("9d9d9d", S.shop_none)
      end
    else
      rows = st.rows
      -- where to farm first (Synergy.lua): one dim line above the rows, nothing when the hint cannot be written
      local ok, farm = false, nil
      if st.farm then ok, farm = pcall(ns.Synergy.FarmText, st.farm, S, ns.SynergyNames) end
      if ok and farm then
        f.farm:SetText(colour("9d9d9d", farm))
        y = y + 2 + lineCount(farm) * NOTE_LINE_H
      end
      if st.missing == 0 then notes[1] = colour("7fb8ff", S.shop_fetch) end
      if ns.Bank.AgeDays(ns.char, time()) == nil and st.missing > 0 then notes[#notes + 1] = colour("9d9d9d", S.shop_unseen) end
    end
  end
  for i = 1, math.min(#rows, MAX_ROWS) do
    local r = rows[i]
    local row = rowFrames[i]
    if not row then row = makeRow(); rowFrames[i] = row end
    local bankPart = (r.bank > 0 and (r.fetch > 0 or not r.ok)) and colour("7fb8ff", S.shop_bank_part:format(math.min(r.bank, r.have))) or nil
    -- the character's own gathering gives it (Synergy.lua): says where, and replaces the source unless it is rare there
    local hint
    if not r.ok and r.hint then
      local ok, text = pcall(ns.Synergy.Short, r.hint, S, ns.SynergyNames)
      hint = ok and text or nil
    end
    local source = not (r.ok or (hint and not r.hint.rare)) and sourceOf(r) or nil
    local dim = hint and source and (hint .. " · " .. source) or hint or source
    local sub = bankPart and dim and (bankPart .. colour("9d9d9d", " · " .. dim)) or bankPart or (dim and colour("9d9d9d", dim)) or nil
    row.tip = r.tip or function() return ns.HowTo.Reagent(r.item, 0, ns.HowToEnv()) end
    row.name:SetText(r.name)
    row.count:SetText(r.ok and colour("7fd36a", ("%d / %d %s"):format(r.have, r.need, S.shop_ok)) or ("%d / %d"):format(r.have, r.need))
    row.sub:SetText(sub or "")
    local h = sub and ROW_SUB_H or ROW_H
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y)
    row:SetSize(WIDTH - 2 * PAD, h)
    row:Show()
    y, shown = y + h, shown + 1
  end
  for i = shown + 1, #rowFrames do rowFrames[i]:Hide() end
  if #rows > MAX_ROWS then notes[#notes + 1] = colour("9d9d9d", S.shop_more:format(#rows - MAX_ROWS)) end
  local text = table.concat(notes, "\n")
  f.note:ClearAllPoints()
  f.note:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(y + 2))
  f.note:SetText(text)
  local noteLines = 0
  for _, n in ipairs(notes) do noteLines = noteLines + lineCount(n) end
  f.retry:ClearAllPoints()
  f.retry:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(y + 2 + noteLines * NOTE_LINE_H))
  y = y + 2 + noteLines * NOTE_LINE_H + (f.retry:IsShown() and 20 or 0)
  f:SetHeight(y + PAD)
end

-- Rows for the harness and the tests.
function SL.Rows() return rowFrames end
function SL.Frame() return f end
function SL.State() return state end

-- ---------------------------------------------------------------------------------------------------------------------
-- The data: the roadmap of every profession, whatever the tab shows, recomputed on demand.

-- A result of ns.RunLeveling (from the Métier tab or from here).
function SL.Feed(res)
  env.hint = res.synergy and res.synergy.hint or nil   -- the hints of this calculation (Synergy.lua), none when it failed
  state = res.state == "ok" and ns.Shopping.Build(res.profs, env) or { error = res }
  SL.Render()
  ns.Window.UpdateShopButton()
end

function SL.Compute()
  if InCombatLockdown() then dirty = true; return end
  token = token + 1
  local mine = token
  ns.RunLeveling(function(res) if mine == token then SL.Feed(res) end end, true)
  -- a wait that never ends is an error with a way out (only while nothing is shown yet)
  C_Timer.After(TIMEOUT, function()
    if mine == token and state == nil then SL.Feed({ state = "error", message = S.shop_timeout }) end
  end)
end

-- Recomputes (at most once per 0.5 s) when the list is on screen.
function SL.Update()
  if pending or not (f and f:IsShown()) then return end
  if ns.Window.JobFeeds() then return end          -- the Métier tab is on screen: it computes the roadmaps and feeds the list
  pending = true
  C_Timer.After(0.5, function()
    pending = false
    SL.Compute()
  end)
end

function SL.Show()
  if not f then build() end
  saved().shown = true
  f:Show()
  SL.Render()
  SL.Compute()
end

function SL.Hide()
  if f then f:Hide() end
  saved().shown = false
  sawMissing = false
end

function SL.Toggle()
  if f and f:IsShown() then SL.Hide() else SL.Show() end
end

-- Bags, skills and fights: bank changes call SL.Update from BankEvents.lua. Registered in a pcall, so an event this client does not
-- know can never break the addon.
local watcher = CreateFrame("Frame")
watcher:SetScript("OnEvent", function(self, event)
  if event == "PLAYER_ENTERING_WORLD" then
    self:UnregisterEvent(event)
    if ns.db and saved().shown then SL.Show() end
  elseif event == "PLAYER_REGEN_ENABLED" then
    if dirty then dirty = false; SL.Update() end
  else
    SL.Update()
  end
end)
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "BAG_UPDATE_DELAYED", "SKILL_LINES_CHANGED", "CHAT_MSG_SKILL" }) do
  pcall(watcher.RegisterEvent, watcher, e)
end
