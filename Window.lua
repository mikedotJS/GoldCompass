-- The window (PLAN.md steps 2, 5, 6), styled after docs/mockup.html: gold frame, tabs hanging below, red buttons.
-- Thin glue: all numbers come from Core.lua (ns.Run, ns.RunBags, ns.RunHere) and the pure modules.
-- Every element is placed from the rectangles in W.Layout (frame coordinates, y downward), so a test can check that
-- nothing overlaps and nothing leaves the frame. The frame is a child of UIParent, so it follows the UI scale.
local _, ns = ...
local S = ns.S

local W = {}
ns.Window = W

local FRAME_W, FRAME_H, PAD = 460, 500, 14
local ROWS, ROW_H, LINES, LINE_H = 10, 30, 19, 17
local GOLD, MUTED, WHITE = { 1, 0.82, 0 }, { 0.62, 0.62, 0.62 }, { 0.96, 0.96, 0.96 }

local function rect(l, t, r, b) return { l = l, t = t, r = r, b = b } end

-- Rectangles { l, t, r, b } from the frame's top-left corner. Groups that can be visible together:
-- common + map, common + list (bags, here), common + panel (+ the map controls and button).
W.Layout = {
  frame = rect(0, 0, FRAME_W, FRAME_H),
  common = {
    title = rect(30, 8, 430, 26), close = rect(436, 6, 454, 24), subtitle = rect(PAD, 34, FRAME_W - PAD, 48),
    banner = rect(PAD, 394, FRAME_W - PAD, 420), footer = rect(PAD, 424, FRAME_W - PAD, 462),
    refresh = rect(356, 468, 446, 490),
  },
  map = {
    levelBox = rect(PAD, 52, 230, 70), profBtn = rect(296, 50, 446, 72),
    rows = rect(PAD, 76, FRAME_W - PAD, 76 + ROWS * ROW_H),
    toMap = rect(PAD, 468, 144, 490), note = rect(152, 466, 348, 492),
  },
  list = { lines = rect(PAD, 52, FRAME_W - PAD, 52 + LINES * LINE_H) },
  -- Métier tab: the checkbox and "Voir sans filtre" sit above the scroll area
  -- second row: the objective toggle "Objectif : Monter le métier | Gagner de l'or"
  job = { bagBox = rect(PAD, 52, 230, 52 + LINE_H - 1), bagOff = rect(296, 50, 446, 68),
    goalLabel = rect(PAD, 76, 72, 92), goalLevel = rect(74, 72, 254, 94), goalGold = rect(258, 72, 446, 94),
    lines = rect(PAD, 98, FRAME_W - PAD, 52 + LINES * LINE_H) },
  panel = { panel = rect(PAD, 80, FRAME_W - PAD, 300) },
}

-- Inside one map row (432 x 30) and one list line (432 x 17).
W.RowParts = {
  rank = rect(0, 2, 18, 28), zone = rect(24, 2, 240, 15), sub = rect(24, 16, 240, 28),
  gph = rect(246, 2, 432, 15), bar = rect(246, 19, 316, 24), age = rect(320, 16, 432, 28),
}
-- The lines of the bags, here and Métier tabs live in a scroll frame: the bar takes SCROLLBAR_W on the right of the slot.
local SCROLLBAR_W = 20
-- go = the small map button of a recipe to learn ("Où l'apprendre").
W.LineParts = { left = rect(0, 0, 222, LINE_H), right = rect(226, 0, 386, LINE_H), go = rect(390, 0, 406, 16) }
-- Long sentences take the whole line (the right slot is then empty), so coin icons never push them into the figure.
W.LineWide = rect(0, 0, 406, LINE_H)

-- Scale that keeps the whole frame on screen whatever the UI scale makes of UIParent's size.
function W.FitScale(parentWidth, parentHeight)
  return math.min(1, parentHeight * 0.9 / FRAME_H, parentWidth * 0.9 / FRAME_W)
end

local function solid(parent, layer, r, g, b, a)
  local t = parent:CreateTexture(nil, layer)
  t:SetColorTexture(r, g, b, a or 1)
  return t
end

-- A font string that never wraps outside its slot: one line, cut with an ellipsis when too long.
local function text(parent, template, color, justify, wrap)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
  if color then fs:SetTextColor(color[1], color[2], color[3]) end
  fs:SetJustifyH(justify or "LEFT")
  fs:SetJustifyV("TOP")
  fs:SetWordWrap(wrap or false)
  if not wrap then fs:SetMaxLines(1) end
  return fs
end

local function place(region, r, parent)
  region:ClearAllPoints()
  region:SetPoint("TOPLEFT", parent, "TOPLEFT", r.l, -r.t)
  region:SetSize(r.r - r.l, r.b - r.t)
end

-- Red game-style button. SetBusy(true): flat dark grey with dim text, clearly not clickable.
local function button(parent, label, width)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(width, 22)
  b.edge = solid(b, "BACKGROUND", 0.6, 0.23, 0.17)
  b.edge:SetAllPoints()
  b.fill = solid(b, "BORDER", 0.35, 0.06, 0.04)
  b.fill:SetPoint("TOPLEFT", 1, -1)
  b.fill:SetPoint("BOTTOMRIGHT", -1, 1)
  b.label = text(b, "GameFontNormalSmall", GOLD, "CENTER")
  b.label:SetPoint("CENTER")
  b.label:SetText(label)
  function b:SetBusy(busy)
    self:SetEnabled(not busy)
    if busy then
      self.edge:SetColorTexture(0.25, 0.25, 0.25)
      self.fill:SetColorTexture(0.13, 0.13, 0.13)
      self.label:SetTextColor(0.45, 0.45, 0.45)
    else
      self.edge:SetColorTexture(0.6, 0.23, 0.17)
      self.fill:SetColorTexture(0.35, 0.06, 0.04)
      self.label:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    end
  end
  return b
end

local TABS = {
  { key = "map", label = S.tab_map, title = S.title, footer = S.footer },
  { key = "bags", label = S.tab_bags, title = S.title_bags, footer = S.bags_total_note },
  { key = "here", label = S.tab_here, title = S.title_here, footer = S.footer },
  { key = "job", label = S.tab_job, title = S.title_job, footer = S.job_footer },
}

local f, rows, lines, panel, selected, titleFS
local scroll, content, scrollKind, contentHeight = nil, nil, nil, 0
local current, token = "map", 0
local lastMap, renderMap, jobRefreshPending
local mapState = "loading" -- loading | off | ready: drives the "Voir sur la carte" button

-- Opening the map is a protected UI-panel operation when done through Blizzard's FrameXML (ShowUIPanel is protected in
-- combat). C_Map.OpenWorldMap is the restricted API meant to open it without tainting it; it cannot run in combat.
-- No fallback to the FrameXML OpenWorldMap: a failure is reported, never worked around.
local function openMap(zone)
  if InCombatLockdown() then return ns.Print(S.map_combat) end
  local open = C_Map and C_Map.OpenWorldMap
  if not open then return ns.Print(S.map_fail) end
  ns.LogOnce("openmap", "frame", "calling C_Map.OpenWorldMap from a click (first time)")
  if not pcall(open, zone) then ns.Print(S.map_blocked) end
end
W.OpenMap = openMap -- exposed for tests

-- "Où l'apprendre": pins the NPC with a user waypoint and opens the map on it. Out of combat only (in combat the place
-- is only written in the chat). Without a precise place, only the free text of the data is written in the chat.
-- "<NPC> (<Zone>) ; <NPC> (<Zone>)": the vendors of a target, zones in the client's language when the game knows the map.
function W.VendorText(t)
  local parts = {}
  for _, v in ipairs(t.vendors or {}) do
    parts[#parts + 1] = ("%s (%s)"):format(v.name, v.mapID and ns.ZoneLabel(v) or S.zone_names[v.zone] or v.zone)
  end
  return table.concat(parts, " ; ")
end

-- Name of the NPC of a target in the client's language (French names of pfQuest on a French client), else English.
function W.NpcName(t)
  local french = GetLocale and GetLocale() == "frFR" and t.fr
  return french or t.name or "?"
end

function W.GoTo(t, recipe)
  local function log(decision) ns.Log("frame", ("where click: %s -> %s (%s)"):format(tostring(recipe), decision, tostring(t.name or t.text))) end
  if not t.mapID then
    log("text")
    if t.onlyFaction then return ns.Print(S.where_only:format(t.onlyFaction == "A" and S.faction_a or S.faction_h)) end
    if t.vendors then return ns.Print(S.where_zone_only:format(W.VendorText(t))) end
    if t.unverified then   -- no Forever source names a place: said plainly, what Classic says only as an unverified hint
      ns.Print(S.where_no_source)
      if t.hint then ns.Print(S.where_classic_hint:format(t.hint)) end
      return
    end
    return ns.Print(t.text and S.where_text:format(t.text) or S.where_none)
  end
  local label = ns.ZoneLabel(t) or t.zone or ""   -- pfQuest NPCs carry a map ID but no zone name
  if not t.x then   -- zone only: say the position is unknown, open the map on the zone (out of combat)
    log("zone")
    if t.dropZone then ns.Print(S.where_drop:format(t.text or label))
    else ns.Print(S.where_zone_only:format(t.vendors and W.VendorText(t) or ("%s (%s)"):format(W.NpcName(t), label))) end
    return openMap(t.mapID)
  end
  log("pin")
  if InCombatLockdown() then return ns.Print(S.where_combat:format(("%s, %s (%.1f, %.1f)"):format(W.NpcName(t), label, t.x, t.y))) end
  local pinned = false
  local C = C_Map
  if C and C.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates
    and (not C.CanSetUserWaypointOnMap or C.CanSetUserWaypointOnMap(t.mapID)) then
    pinned = pcall(function()
      C.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(t.mapID, t.x / 100, t.y / 100))
      if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
    end)
  end
  ns.Log("frame", ("where: %s (%s) map %d %.1f,%.1f pinned=%s"):format(tostring(t.name), label, t.mapID, t.x, t.y, tostring(pinned)))
  ns.Print((pinned and S.where_pinned or S.where_coords):format(W.NpcName(t), label, t.x, t.y, S.where_src[t.source or "classic"]))
  if not t.confirmed then ns.Print(S.where_unconfirmed) end   -- a Classic position: never shown as a sure one
  if t.text then ns.Print(t.text) end                -- "Patron en vente à l'HV : ~2g (prix HV de 3 j)"
  openMap(t.mapID)
end
function W.Rows() return rows end
function W.Lines() return lines end
-- "Fabriquer": inputs of Leveling.CraftButton for a craft entry { id, times, prof, line }, read from the game.
local crafting, craftClicks, craftSpell = false, 0, nil

-- Is this spell a craft? The recipe handed to CraftRecipe, or one of the recipes the character knows (a craft started in the
-- profession window itself). A Hearthstone, a mount or a heal is not.
function W.IsCraftSpell(spellID)
  if not spellID then return false end
  if spellID == craftSpell then return true end
  for _, p in pairs(ns.char and ns.char.profs or {}) do
    if p.recipes and p.recipes[spellID] then return true end
  end
  return false
end
local function craftInputs(c)
  local open, openID = ns.OpenTradeSkill()
  return { times = c.times, open = open ~= nil and (open == c.prof or openID == c.line), combat = InCombatLockdown(),
    crafting = crafting }
end

-- Label, enabled state and reason text of a craft entry in the current conditions.
function W.CraftState(c)
  local st = ns.Leveling.CraftButton(craftInputs(c))
  local canOpen = C_TradeSkillUI and C_TradeSkillUI.OpenTradeSkill ~= nil
  if st.state == "busy" then st.label, st.reason = S.craft_busy, S.craft_busy
  elseif st.state == "combat" then st.label, st.reason = c.times > 0 and S.craft_btn:format(c.times) or S.craft_btn_none, S.craft_r_combat
  elseif st.state == "none" then st.label, st.reason = S.craft_btn_none, S.craft_r_none
  elseif st.state == "closed" then st.label, st.reason = S.craft_open:format(c.prof), (not canOpen) and S.craft_r_manual or ""
  else st.label, st.reason = S.craft_btn:format(c.times), "" end
  return st
end

-- Click on the craft button (a hardware event): opens the profession window, or crafts the recipe as many times as
-- the bags allow. Only public functions, each in a pcall; the result is logged (a blocked action shows right after it).
function W.Craft(c)
  local st = W.CraftState(c)
  if not st.enabled then return end
  local T = C_TradeSkillUI
  if st.action == "open" then
    local ok = T and T.OpenTradeSkill and pcall(T.OpenTradeSkill, c.line)
    ns.Log("frame", ("craft: OpenTradeSkill(%s) for %s -> %s"):format(tostring(c.line), c.prof, tostring(ok)))
    ns.Print((ok and S.craft_opening or S.craft_open_fail):format(c.prof))
    return
  end
  local ok, err = pcall(T.CraftRecipe, c.id, c.times)
  ns.Log("frame", ("craft: CraftRecipe(%d, %d) -> %s %s"):format(c.id, c.times, tostring(ok), ok and "" or tostring(err)))
  if not ok then return ns.Print(S.craft_fail) end
  crafting, craftSpell = true, c.id
  craftClicks = craftClicks + 1
  local click = craftClicks
  -- no cast started after 2 s: nothing is being crafted, release the button; 60 s at most in any case
  C_Timer.After(2, function() if crafting and click == craftClicks and not W.CastSeen then crafting = false; W.UpdateCraft() end end)
  C_Timer.After(60, function() if crafting and click == craftClicks then crafting = false; W.UpdateCraft() end end)
  W.CastSeen = false
  W.UpdateCraft()
end

-- Tooltip of the map button: NPC, zone (client language when known), coordinates, and the Classic caveat.
function W.TargetTooltipLines(t)
  local tip = { S.where_title }
  if t.vendors then
    tip[#tip + 1] = W.VendorText(t)
    tip[#tip + 1] = S.where_zone_tip
  elseif t.dropZone then
    tip[#tip + 1] = t.text or ns.ZoneLabel(t)
    tip[#tip + 1] = S.where_zone_tip
  elseif t.mapID and not t.x then
    tip[#tip + 1] = W.NpcName(t)
    tip[#tip + 1] = S.where_zone_tip
  elseif t.mapID then
    tip[#tip + 1] = W.NpcName(t)
    tip[#tip + 1] = ("%s : %.1f, %.1f"):format(ns.ZoneLabel(t) or "?", t.x, t.y)
    if not t.confirmed then tip[#tip + 1] = S.where_unconfirmed end
    if t.text then tip[#tip + 1] = t.text end
  else
    if t.onlyFaction then tip[#tip + 1] = S.where_only:format(t.onlyFaction == "A" and S.faction_a or S.faction_h) end
    if t.text then tip[#tip + 1] = t.text end
    if t.unverified then
      tip[#tip + 1] = S.where_no_source_tip
      if t.hint then tip[#tip + 1] = S.where_classic_hint:format(t.hint) end
    else
      tip[#tip + 1] = S.where_unclear
    end
  end
  if t.extra then tip[#tip + 1] = t.extra end       -- what the site says: butin, pickpocket, pêche, quête
  if t.note then tip[#tip + 1] = t.note end         -- the AH price of the crafted item: its age, "prix HV incertain"
  if t.source then tip[#tip + 1] = S.where_source:format(S.where_src[t.source]) end
  return tip
end

function W.ContentHeight() return contentHeight end -- height of the scrolled content (rows shown x line height)
function W.ScrollKind() return scrollKind end
function W.Footer() return f.footer end

-- Lines of the row tooltip: full name, level range, nodes with their value, price freshness, assumptions.
function W.RowTooltipLines(row)
  local out = { row.name }
  local info = ns.Zones[row.zone]
  -- a level range no Forever source gives is the Classic one: said as such
  out[#out + 1] = S.tt_spots:format(row.spots, info and info[2] and (S.far_tag:format(info[2], info[3]) .. ns.Fmt.LevelNote(info))
    or S.unknown_level_tag)
  out[#out + 1] = S.tt_nodes
  for _, d in ipairs(row.detail or {}) do
    -- what the node gives is the Classic pairing when ForeverDB's gathering data does not have it: said as such
    local doubt = ns.ForeverFixes and ns.ForeverFixes.gatherDoubt and ns.ForeverFixes.gatherDoubt[d.item]
    out[#out + 1] = S.tt_per_node:format(ns.ItemName(d.item), ns.Money(d.unit * 2)) .. (doubt and S.node_unverified or "")
  end
  out[#out + 1] = ns.PriceAgeText(row.maxAge)
  local partial = ns.PartialText({ row })
  if partial ~= "" then out[#out + 1] = partial end
  out[#out + 1] = S.tt_assume
  out[#out + 1] = S.tt_estimate
  return out
end

local function selectRow(i)
  selected = i
  for n, row in ipairs(rows) do row.sel:SetShown(n == i) end
end

local function updateMapButton()
  if not f then return end
  local reason
  if mapState == "loading" then reason = S.map_off_loading
  elseif mapState == "off" then reason = S.map_off_state
  elseif InCombatLockdown() then reason = S.map_off_combat end
  f.toMap:SetBusy(reason ~= nil)
  f.note:SetText(reason or S.map_note)
end

local function build()
  ns.LogOnce("frame-main", "frame", "creating GoldCompassFrame (own frame, parent UIParent, no secure template)")
  f = CreateFrame("Frame", "GoldCompassFrame", UIParent)
  f:SetSize(FRAME_W, FRAME_H)
  f:SetScale(W.FitScale(UIParent:GetWidth(), UIParent:GetHeight()))
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    if ns.db then ns.db.pos = { point, relPoint, x, y } end
  end)
  -- default: right side of the screen, away from the unit frames (left), the action bars (bottom) and the minimap (top)
  local pos = ns.db and ns.db.pos
  if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("RIGHT", UIParent, "RIGHT", -130, -40) end
  f:Hide()
  ns.LogOnce("uispecial", "frame", "inserting GoldCompassFrame in UISpecialFrames (Escape closes it)")
  tinsert(UISpecialFrames, "GoldCompassFrame") -- Escape closes it

  local edge = solid(f, "BACKGROUND", 0.416, 0.333, 0.149)
  edge:SetAllPoints()
  local bg = solid(f, "BORDER", 0.075, 0.063, 0.035, 0.97)
  bg:SetPoint("TOPLEFT", 1, -1)
  bg:SetPoint("BOTTOMRIGHT", -1, 1)

  local L = W.Layout
  titleFS = text(f, "GameFontNormal", GOLD, "CENTER")
  place(titleFS, L.common.title, f)
  local line = solid(f, "ARTWORK", 0.227, 0.184, 0.078)
  line:SetPoint("TOPLEFT", 1, -30)
  line:SetPoint("TOPRIGHT", -1, -30)
  line:SetHeight(1)
  local close = button(f, "X", 18)
  place(close, L.common.close, f)
  close:SetScript("OnClick", function() f:Hide() end)

  f.subtitle = text(f, "GameFontNormalSmall", { 0.79, 0.73, 0.54 })
  place(f.subtitle, L.common.subtitle, f)

  -- map tab: ranked rows. Line 1 = zone name and figure, line 2 = nodes and level (dim), price age and bar.
  rows = {}
  local P = W.RowParts
  for i = 1, ROWS do
    local r = CreateFrame("Button", nil, f)
    place(r, rect(L.map.rows.l, L.map.rows.t + (i - 1) * ROW_H, L.map.rows.r, L.map.rows.t + i * ROW_H), f)
    -- decorations live in BACKGROUND (below the BORDER bar and the OVERLAY text), translucent, never over the text
    r.sel = r:CreateTexture(nil, "BACKGROUND", nil, 0)
    r.sel:SetColorTexture(0.165, 0.129, 0.063, 0.8)
    r.sel:SetAllPoints()
    r.sel:Hide()
    r.hover = r:CreateTexture(nil, "BACKGROUND", nil, 1)
    r.hover:SetColorTexture(1, 0.82, 0, 0.1)
    r.hover:SetAllPoints()
    r.hover:Hide()
    r.rank = text(r, "GameFontNormalSmall", MUTED, "RIGHT")
    place(r.rank, P.rank, r)
    r.zone = text(r, "GameFontNormalSmall", WHITE)
    place(r.zone, P.zone, r)
    r.sub = text(r, "GameFontHighlightSmall", MUTED)
    place(r.sub, P.sub, r)
    r.gph = text(r, "GameFontNormalSmall", { 0.12, 1, 0 }, "RIGHT")
    place(r.gph, P.gph, r)
    r.bar = solid(r, "BORDER", 0.12, 0.8, 0.1)
    r.bar:SetPoint("TOPLEFT", r, "TOPLEFT", P.bar.l, -P.bar.t)
    r.bar:SetHeight(P.bar.b - P.bar.t)
    r.age = text(r, "GameFontHighlightSmall", MUTED, "RIGHT")
    place(r.age, P.age, r)
    r.index = i
    r:SetScript("OnClick", function(self)
      selectRow(self.index)
      if self.zoneID then openMap(self.zoneID) end
    end)
    -- the full zone name and details, since the row cuts long text
    r:SetScript("OnEnter", function(self)
      self.hover:Show()
      if not self.tip then return end
      -- to the left of the row: the window sits on the right of the screen, and the hovered row stays visible
      GameTooltip:SetOwner(self, "ANCHOR_LEFT")
      GameTooltip:SetText(self.tip[1], 1, 1, 1)
      for j = 2, #self.tip do GameTooltip:AddLine(self.tip[j], 0.8, 0.8, 0.8, true) end
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function(self)
      self.hover:Hide()
      GameTooltip:Hide()
    end)
    r:Hide()
    rows[i] = r
  end

  -- checkboxes: a box with a real check mark (green when on) and a label
  local function makeCheck(r, label)
    local box = CreateFrame("Button", nil, f)
    place(box, r, f)
    local frame = solid(box, "BACKGROUND", 0.54, 0.455, 0.22)
    frame:SetSize(16, 16)
    frame:SetPoint("LEFT")
    box.boxFill = solid(box, "BORDER", 0.04, 0.03, 0.016)
    box.boxFill:SetPoint("TOPLEFT", frame, 1, -1)
    box.boxFill:SetPoint("BOTTOMRIGHT", frame, -1, 1)
    box.check = box:CreateTexture(nil, "OVERLAY")
    box.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    box.check:SetSize(26, 26)
    box.check:SetPoint("CENTER", frame, "CENTER", 0, 0)
    box.label = text(box, "GameFontHighlightSmall", { 0.79, 0.73, 0.54 })
    box.label:SetPoint("LEFT", 22, 0)
    box.label:SetSize(190, 16)
    box.label:SetText(label)
    function box:SetOn(on)
      self.check:SetShown(on)
      if on then self.boxFill:SetColorTexture(0.1, 0.35, 0.1) else self.boxFill:SetColorTexture(0.04, 0.03, 0.016) end
      self.label:SetTextColor(on and 1 or 0.79, on and 1 or 0.73, on and 1 or 0.54)
    end
    return box
  end
  -- map controls: "my level only" checkbox and a profession selector that cycles
  f.levelBox = makeCheck(L.map.levelBox, S.only_level)
  f.levelBox:SetScript("OnClick", function()
    ns.db.onlyLevel = not ns.db.onlyLevel
    W.UpdateControls()
    if lastMap then renderMap(lastMap) end
  end)
  -- Métier tab: "Avec mon sac" (remembered per character) and a way out of the empty state
  f.bagBox = makeCheck(L.job.bagBox, S.job_bag_box)
  f.bagBox:SetScript("OnClick", function()
    ns.char.onlyBag = not ns.char.onlyBag
    W.UpdateControls()
    W.Refresh()
  end)
  f.bagOff = button(f, S.job_bag_off, L.job.bagOff.r - L.job.bagOff.l)
  place(f.bagOff, L.job.bagOff, f)
  f.bagOff:SetScript("OnClick", function()
    ns.char.onlyBag = false
    W.UpdateControls()
    W.Refresh()
  end)
  -- objective toggle: two buttons, the active one lit (remembered per character, default "Monter le métier")
  f.goalLabel = text(f, "GameFontHighlightSmall", { 0.79, 0.73, 0.54 })
  place(f.goalLabel, L.job.goalLabel, f)
  f.goalLabel:SetText(S.goal_label)
  f.goalBtns = {}
  for _, g in ipairs({ { "level", S.goal_level, L.job.goalLevel }, { "gold", S.goal_gold, L.job.goalGold } }) do
    local b = button(f, g[2], g[3].r - g[3].l)
    place(b, g[3], f)
    b:SetScript("OnClick", function() W.SetGoal(g[1]) end)
    f.goalBtns[g[1]] = b
  end
  f.profBtn = button(f, "", L.map.profBtn.r - L.map.profBtn.l)
  place(f.profBtn, L.map.profBtn, f)
  f.profBtn:SetScript("OnClick", function()
    local order = { [false] = "Herb Gathering", ["Herb Gathering"] = "Mining", ["Mining"] = "Fishing", ["Fishing"] = false }
    ns.db.profession = order[ns.db.profession or false] or nil
    W.UpdateControls()
    W.Refresh()
  end)

  -- bags, here and Métier tabs: plain lines (left text, right text) in a scroll frame. The frame is the classic
  -- UIPanelScrollFrameTemplate (its bar sits right of the slot); without the template a plain scroll frame still scrolls
  -- with the mouse wheel. Lines are created as needed and recycled by setLines.
  for _, template in ipairs({ "UIPanelScrollFrameTemplate", false }) do
    local ok, frame = pcall(CreateFrame, "ScrollFrame", nil, f, template or nil)
    if ok and frame then scroll, scrollKind = frame, template or "plain ScrollFrame"; break end
  end
  ns.LogOnce("scroll", "frame", "scroll frame: " .. tostring(scrollKind))
  content = CreateFrame("Frame", nil, scroll)
  scroll:SetScrollChild(content)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local top = math.max(0, self:GetVerticalScrollRange() or 0)
    self:SetVerticalScroll(math.min(top, math.max(0, (self:GetVerticalScroll() or 0) - delta * LINE_H * 3)))
  end)
  scroll:Hide()
  lines = {}

  -- loading / empty / error panel
  panel = CreateFrame("Frame", nil, f)
  place(panel, L.panel.panel, f)
  panel.title = text(panel, "GameFontNormal", GOLD, "CENTER")
  panel.title:SetPoint("TOP", 0, -30)
  panel.title:SetWidth(400)
  panel.body = text(panel, "GameFontHighlightSmall", { 0.85, 0.8, 0.64 }, "CENTER", true)
  panel.body:SetPoint("TOP", panel.title, "BOTTOM", 0, -12)
  panel.body:SetWidth(360)
  panel.retry = button(panel, S.retry, 120)
  panel.retry:SetPoint("TOP", panel.body, "BOTTOM", 0, -16)
  panel.retry:SetScript("OnClick", function() W.Refresh() end)
  panel.pulse = panel.title:CreateAnimationGroup()
  panel.pulse:SetLooping("BOUNCE")
  local alpha = panel.pulse:CreateAnimation("Alpha")
  alpha:SetFromAlpha(1)
  alpha:SetToAlpha(0.35)
  alpha:SetDuration(0.8)
  panel:Hide()

  -- banner (causes of a partial estimate) and footer: own slots, wrapped inside the width, never under a button
  f.banner = text(f, "GameFontNormalSmall", GOLD, "LEFT", true)
  place(f.banner, L.common.banner, f)
  f.banner:SetMaxLines(2)
  f.footer = text(f, "GameFontHighlightSmall", MUTED, "LEFT", true)
  place(f.footer, L.common.footer, f)
  f.footer:SetMaxLines(3)

  f.toMap = button(f, S.to_map, L.map.toMap.r - L.map.toMap.l)
  place(f.toMap, L.map.toMap, f)
  f.toMap:SetScript("OnClick", function()
    local row = selected and rows[selected]
    if row and row.zoneID then openMap(row.zoneID) end
  end)
  f.note = text(f, "GameFontHighlightSmall", MUTED, "LEFT", true)
  place(f.note, L.map.note, f)
  f.note:SetMaxLines(2)
  f.refresh = button(f, S.refresh, L.common.refresh.r - L.common.refresh.l)
  place(f.refresh, L.common.refresh, f)
  f.refresh:SetScript("OnClick", function() W.Refresh() end)

  -- tabs hang below the frame, side by side, touching neither the body nor the border
  f.tabs = {}
  for i, def in ipairs(TABS) do
    local tab = CreateFrame("Button", nil, f)
    tab:SetSize(70, 20)
    tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 10 + (i - 1) * 74, 0)
    tab.edge = solid(tab, "BACKGROUND", 0.416, 0.333, 0.149)
    tab.edge:SetAllPoints()
    tab.fill = solid(tab, "BORDER", 0.114, 0.09, 0.047)
    tab.fill:SetPoint("TOPLEFT", 1, 0)
    tab.fill:SetPoint("BOTTOMRIGHT", -1, 1)
    tab.label = text(tab, "GameFontNormalSmall", GOLD, "CENTER")
    tab.label:SetPoint("CENTER")
    tab.label:SetText(def.label)
    tab:SetScript("OnClick", function() W.SetTab(def.key) end)
    f.tabs[def.key] = tab
  end
end

local function showPanel(title, body, canRetry, loading)
  for _, r in ipairs(rows) do r:Hide() end
  scroll:Hide()
  f.subtitle:SetText("")
  f.banner:SetText("")
  panel:Show()
  panel.title:SetText(title)
  panel.body:SetText(body)
  panel.retry:SetShown(canRetry)
  if loading then panel.pulse:Play() else panel.pulse:Stop() panel.title:SetAlpha(1) end
end

-- Refreshes the craft buttons (label, enabled, reason) without recomputing the tab: window opened or closed, combat,
-- a cast started or stopped.
function W.UpdateCraft()
  for _, l in ipairs(lines) do
    local c = l.craft and l.craft.entry
    if c then
      local st = W.CraftState(c)
      l.craft.label:SetText(st.label)
      l.craft:SetBusy(not st.enabled)
      l.left:SetText("|cff9d9d9d" .. st.reason .. "|r")
    end
  end
end

-- Fills the scrolled lines: every entry then every tail entry, none cut. entries = { { left, right, head, wide }, ... }.
-- `area` is the slot of the scroll frame (the Métier tab starts lower than the other tabs, under its checkbox).
-- A recycled line is fully reset (width, font, both texts), so nothing from the previous row leaks.
local function setLines(entries, tail, area)
  for _, r in ipairs(rows) do r:Hide() end
  panel:Hide()
  panel.pulse:Stop()
  area = area or W.Layout.list.lines
  local all = {}
  -- a sentence too long for its slot goes on a second line (about 5.5 px a character), never cut: the map button stays on the first
  local function add(e)
    local plain = e.left and e.left:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local cap = math.floor(((e.target and W.LineParts.go.l - 4) or W.LineWide.r) / 5.5)
    if not (e.wide and not e.craft and plain and #plain:gsub("[\128-\191]", "") > cap) then all[#all + 1] = e; return end
    local colour, body = e.left:match("^(|c%x%x%x%x%x%x%x%x)(.*)|r$")
    body = body or e.left
    local line, first = "", true
    local function flush()
      local copy = { wide = true, left = (colour or "") .. line .. (colour and "|r" or "") }
      if first then copy.target, copy.recipe = e.target, e.recipe; first = false end
      all[#all + 1] = copy
    end
    for word in body:gmatch("%S+") do
      local joined = line == "" and word or (line .. " " .. word)
      if line ~= "" and #joined:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("[\128-\191]", "") > cap then flush(); line = word else line = joined end
    end
    flush()
  end
  for _, e in ipairs(entries) do add(e) end
  for _, e in ipairs(tail) do add(e) end
  place(scroll, rect(area.l, area.t, area.r - SCROLLBAR_W, area.b), f)
  contentHeight = #all * LINE_H
  content:SetSize(area.r - area.l - SCROLLBAR_W, math.max(contentHeight, 1))
  for i = 1, math.max(#lines, #all) do
    local l = lines[i]
    if not l then
      local top = (i - 1) * LINE_H
      l = { left = text(content, "GameFontHighlightSmall"), right = text(content, "GameFontHighlightSmall", nil, "RIGHT") }
      place(l.left, rect(W.LineParts.left.l, top, W.LineParts.left.r, top + LINE_H), content)
      place(l.right, rect(W.LineParts.right.l, top, W.LineParts.right.r, top + LINE_H), content)
      -- small map button, shown only on rows that have a place to go to
      local go = CreateFrame("Button", nil, content)
      place(go, rect(W.LineParts.go.l, top, W.LineParts.go.r, top + W.LineParts.go.b), content)
      go.icon = go:CreateTexture(nil, "ARTWORK")
      go.icon:SetAllPoints()
      go.icon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
      go.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      go:EnableMouse(true)
      go:RegisterForClicks("LeftButtonUp")
      local level = content:GetFrameLevel()
      go:SetFrameLevel((type(level) == "number" and level or 1) + 5)  -- above the line's text and the craft button
      go:SetScript("OnClick", function(self)
        -- a recycled line shows another recipe each refresh: always the button's current target, never the first row's
        if self.target then W.GoTo(self.target, self.recipe) else ns.Log("frame", "where click: no target on this line") end
      end)
      go:SetScript("OnEnter", function(self)
        if not self.target then return end
        local tip = W.TargetTooltipLines(self.target)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(tip[1], 1, 1, 1)
        for j = 2, #tip do GameTooltip:AddLine(tip[j], 0.8, 0.8, 0.8, true) end
        GameTooltip:Show()
      end)
      go:SetScript("OnLeave", function() GameTooltip:Hide() end)
      l.go = go
      l.top = top
      lines[i] = l
    end
    local e = all[i]
    -- the craft button (recommended recipe) is created when a line first needs it
    if e and e.craft and not l.craft then
      l.craft = button(content, "", 150)
      place(l.craft, rect(W.LineWide.r - 150, l.top, W.LineWide.r, l.top + LINE_H), content)
      l.craft:SetScript("OnClick", function(self) if self.entry then W.Craft(self.entry) end end)
    end
    if l.craft then
      l.craft.entry = e and e.craft or nil
      l.craft:SetShown(l.craft.entry ~= nil)
    end
    l.go.target = e and e.target or nil
    l.go.recipe = e and e.recipe or nil
    l.go:SetShown(l.go.target ~= nil)
    -- a line with a map button leaves its room (the button sits at the right end)
    l.left:SetWidth((e and e.wide) and (l.go.target and W.LineParts.go.l - 4 or W.LineWide.r)
      or (e and e.craft and W.LineWide.r - 154) or W.LineParts.left.r)
    l.left:SetFontObject(e and e.head and GameFontNormalSmall or GameFontHighlightSmall)
    l.left:SetText(e and e.left or "")
    l.right:SetText(e and e.right or "")
  end
  W.UpdateCraft()
  scroll:Show()
  scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll() or 0, math.max(0, contentHeight - (area.b - area.t))))
  -- the bar only when there is something to scroll
  local bar = scroll.ScrollBar
  if type(bar) == "table" then bar:SetShown(contentHeight > area.b - area.t) end
end

local function render(res, kind)
  f.refresh:SetBusy(false)
  mapState = (kind == "map" and res.state == "ok") and "ready" or "off"
  updateMapButton()
end

function renderMap(res)
  lastMap = res
  render(res, "map")
  if res.state ~= "ok" then
    local title, body = ns.StateText(res)
    return showPanel(title, body, true)
  end
  scroll:Hide()
  panel:Hide()
  panel.pulse:Stop()
  f.subtitle:SetText(ns.SupposedText(res) or S.mine)
  local shown, hidden = ns.VisibleZones(res.all, ns.db.onlyLevel)
  local banner = {}
  local partial = ns.PartialText(shown)
  if partial ~= "" then banner[#banner + 1] = partial end
  if hidden > 0 then banner[#banner + 1] = S.unknown_level_hidden:format(hidden) end
  if res.fishing then banner[#banner + 1] = S.fish_note end
  if res.ageUnknown then banner[#banner + 1] = S.age_unknown end
  f.banner:SetText(table.concat(banner, " "))
  if #shown == 0 then
    mapState = "off"
    updateMapButton()
    return showPanel(S.nolevel_t, S.nolevel_p, true)
  end
  local best = shown[1].copperPerHour
  local level = UnitLevel("player")
  for i, r in ipairs(rows) do
    local row = shown[i]
    if row then
      local info = ns.Zones[row.zone]
      local lo = info and info[2]
      local tags = (row.old and (" · " .. S.tag_old) or "") .. (row.partial and (" · " .. S.tag_partial) or "")
        .. (info and not lo and (" · " .. S.unknown_level_tag) or "")
        .. (lo and lo > level and (" · " .. S.far_tag:format(lo, info[3]) .. ns.Fmt.LevelNote(info)) or "")
      local sub = table.concat(row.itemNames, ", ") .. tags
      r.zoneID = row.zone
      r.tip = W.RowTooltipLines(row)
      r:SetAlpha(lo and lo - level > 3 and 0.45 or 1)
      r.rank:SetText(i)
      r.zone:SetText(row.name)
      r.sub:SetText(sub)
      r.gph:SetText(S.per_hour_row:format(ns.Money(row.copperPerHour)))
      r.age:SetText(ns.PriceAgeText(row.maxAge))
      r.bar:SetWidth(math.max(2, (W.RowParts.bar.r - W.RowParts.bar.l) * row.copperPerHour / best))
      r:Show()
    else
      r:Hide()
    end
  end
  selectRow(1)
end

local GROUPS = { { "ah", S.g_ah }, { "craft", S.g_craft }, { "keep", S.g_keep }, { "vendor", S.g_vendor }, { "none", S.g_none } }

local function renderBags(res)
  render(res, "bags")
  if res.state ~= "ok" then
    local title, body = ns.StateText(res)
    return showPanel(title, body, true)
  end
  f.subtitle:SetText("")
  f.banner:SetText(res.anyAh and "" or S.bags_noscan)
  local entries = {}
  for _, g in ipairs(GROUPS) do
    local list = res.groups[g[1]]
    if #list > 0 then
      entries[#entries + 1] = { head = true, left = g[2], right = g[1] ~= "keep" and g[1] ~= "none" and ns.Money(res.totals[g[1]]) or "" }
      for _, e in ipairs(list) do
        entries[#entries + 1] = { left = ("%s ×%d"):format(e.item.name, e.item.count), right = "|cff9d9d9d" .. ns.Fmt.Action(e.decision, true) .. "|r" }
      end
    end
  end
  setLines(entries, { { head = true, left = S.bags_total, right = ns.Money(res.total) } })
end

local function fmtRatio(r) return (("%.1f"):format(r):gsub("%.", ",")) end

local function renderHere(res)
  render(res, "here")
  if res.state ~= "ok" then
    local title, body = ns.StateText(res)
    return showPanel(title, body, true)
  end
  local cmp = res.cmp
  f.subtitle:SetText(ns.SupposedText(res) or "")
  f.banner:SetText(ns.PartialText({ cmp.row }))
  local entries = {
    { head = true, left = cmp.row.name, right = S.here_level:format(res.level) },
    { left = "|cff1eff00" .. S.here_you:format(ns.Money(cmp.row.copperPerHour)) .. "|r", right = "|cff9d9d9d" .. S.estimate .. "|r" },
  }
  if cmp.ratio and cmp.other then
    local other = cmp.other.name
    entries[#entries + 1] = { wide = true, left = "|cff9d9d9d" .. (cmp.best and S.here_best:format(fmtRatio(cmp.ratio), other)
      or S.here_behind:format(other, fmtRatio(cmp.ratio), ns.Money(cmp.other.copperPerHour))) .. "|r" }
  end
  entries[#entries + 1] = { head = true, left = S.here_nodes }
  for _, n in ipairs(res.nodes) do entries[#entries + 1] = { left = n.name, right = ns.Money(n.unit) } end
  if #res.pickups > 0 then
    entries[#entries + 1] = { head = true, left = S.here_pickups }
    for _, p in ipairs(res.pickups) do
      entries[#entries + 1] = { left = ("%s ×%d |cff9d9d9d(%s)|r"):format(p.name, p.count, ns.Fmt.QuestLabel(p.quest)), right = ns.Money(p.unit) }
    end
  end
  setLines(entries, res.hint and { { wide = true, left = "|cff9d9d9d" .. S.here_hint:format(S.prof_names[res.hint.prof], ns.Money(res.hint.gain)) .. "|r" } } or {})
end

-- Profession leveling tab: per profession the cheapest known recipe per skill point, all labelled as estimates.
-- Footer of the Métier tab. Must fit two lines of the footer slot (about 79 characters each at the real font).
-- Footer of the Métier tab: the active objective in one short line, the caveat, and the bag note when the filter is on.
function W.JobFooter(filtered, goal)
  return (goal == "gold" and S.job_goal_gold or S.job_goal_level) .. " " .. S.job_footer .. (filtered and (" " .. S.job_footer_bag) or "")
end

-- Recipes to learn of one profession (Leveling.Learnable result): best one, then the others, then the "soon" ones.
-- Returns true when the bag filter left nothing to show (the empty state with its way out).
-- Expected skill points, one decimal at most, French comma: 7, 1,3
local function fmtPoints(n) return ((("%.1f"):format(n):gsub("%.0$", "")):gsub("%.", ",")) end

local addLearnMain
local function addLearn(entries, p)
  local result = addLearnMain(entries, p)
  -- the recipes only the other faction can get: one dim line at the end, never a recipe to learn
  local other = p.learn.otherFaction or {}
  if #other > 0 then
    local names, shown = {}, math.min(#other, 5)
    for i = 1, shown do names[i] = other[i].name or ns.Fmt.RecipeName(other[i].rec) end
    local list = table.concat(names, ", ") .. (#other > shown and (" (+" .. (#other - shown) .. ")") or "")
    entries[#entries + 1] = { wide = true, left = "|cff9d9d9d" .. (other[1].faction == "A" and S.learn_other_a or S.learn_other_h):format(list) .. "|r" }
  end
  return result
end
function addLearnMain(entries, p)
  local lr, L, gold = p.learn, ns.Leveling, p.goal == "gold"
  -- a dim sentence on as many lines as it needs: a line holds about 68 characters (the slot is ~5.5 px a character), none is cut
  local function grey(msg)
    local line = ""
    for word in msg:gmatch("%S+") do
      local chars = #(line .. " " .. word):gsub("[\128-\191]", "")
      if line ~= "" and chars > 68 then entries[#entries + 1] = { wide = true, left = "|cff9d9d9d" .. line .. "|r" }; line = word
      else line = line == "" and word or (line .. " " .. word) end
    end
    entries[#entries + 1] = { wide = true, left = "|cff9d9d9d" .. line .. "|r" }
  end
  local function perPoint(e)
    if e.gray then return S.learn_pp_gray end
    if e.unpriced then return S.learn_pp_unknown end
    if not gold then return S.job_ingr_row:format(fmtPoints(e.unitsPerPoint)) end      -- levelling: effort, never gold
    if gold then return (e.profit >= 0 and S.job_gold_row_gain or S.job_gold_row_cost):format(ns.Money(math.abs(e.profit))) end
    local gain = e.perPoint < 0
    local fmt = e.floor and (gain and S.learn_pp_floor_gain or S.learn_pp_floor) or (gain and S.learn_pp_gain or S.learn_pp)
    return fmt:format(ns.Money(math.abs(e.perPoint))) .. (e.uncertain and S.ah_uncertain_tag or "")
  end
  -- rank books (listed near the cap, whatever the bag filter says) and the rank that lifts the cap: never gray crafts
  for _, b in ipairs(lr.books or {}) do
    entries[#entries + 1] = { wide = true, left = "|cffffd100" .. S.learn_book:format(p.max or 0, b.name or ns.Fmt.RecipeName(b.rec)) .. "|r",
      target = b.target, recipe = b.name }
    entries[#entries + 1] = { wide = true, left = S.learn_book2:format(ns.Fmt.Source(b.rec, true), b.rec.learn) }
  end
  if lr.beyond and lr.beyond.rank then
    entries[#entries + 1] = { wide = true, left = "|cff9d9d9d" .. S.learn_beyond:format(lr.beyond.max, S.rank_names[lr.beyond.rank] or lr.beyond.rank) .. "|r",
      target = lr.beyond.target, recipe = S.rank_names[lr.beyond.rank] }
  end
  local total = #lr.now + #lr.soon + #(lr.gray or {})
  if total == 0 then
    -- say the real reason: nothing to learn, or hidden by the bag filter
    if lr.nowTotal + lr.soonTotal == 0 or not p.filtered then return grey(S.learn_none) end
    entries[#entries + 1] = { wide = true, left = "|cffffd100" .. S.learn_nothing_bag .. "|r" }
    return true
  end
  if #lr.now + #lr.soon == 0 then grey(S.learn_gray) end   -- everything in reach is gray
  local function row(e)
    local t, name = e.rec.trainer, e.name or ns.Fmt.RecipeName(e.rec)
    -- two lines like a known recipe: name and figure, then the dim details (the left slot is too narrow for both)
    entries[#entries + 1] = { left = S.learn_row:format(name), right = perPoint(e), target = e.target, recipe = name }
    entries[#entries + 1] = { wide = true, left = t and ("  |cff9d9d9d" .. S.learn_row_seen:format(ns.Money(e.rec.fee or 0), t.npc) .. ", niv. " .. e.rec.learn .. "|r")
      or S.learn_row2:format(ns.Fmt.Source(e.rec), e.rec.learn) }
  end
  if #lr.now > 0 then
    entries[#entries + 1] = { wide = true, left = "|cffffd100" .. S.learn_now .. "|r" }
    local e = lr.best
    if e then -- "Meilleure à apprendre": a priced recipe with a known way to get it (trainer, vendor, quest, teaching item)
      local label = e.name or ns.Fmt.RecipeName(e.rec)
      local fmt = e.floor and (e.perPoint < 0 and S.learn_best_floor_gain or S.learn_best_floor)
        or (e.perPoint < 0 and S.learn_best_gain or S.learn_best)
      local line = fmt:format(label, ns.Money(math.abs(e.perPoint)))
      if not gold then line = S.learn_best_effort:format(label, fmtPoints(e.unitsPerPoint), fmtPoints(e.craftsPerPoint)) end
      if gold then   -- money: the profit per craft (the learning fee is in the ranking, not in the figure)
        line = (e.profit >= 0 and S.learn_gold_best or S.learn_gold_best_cost):format(label, ns.Money(math.abs(e.profit)))
          .. (e.priceKnown and "" or " " .. S.learn_gold_excl)
      end
      entries[#entries + 1] = { wide = true, left = "|cff1eff00" .. line .. "|r", target = e.target, recipe = label }
      local t = e.rec.trainer
      if t then -- the real trainer: its name, the real skill and the real fee
        grey(S.learn_detail_seen:format(ns.Money(e.rec.fee or 0), t.npc, e.rec.learn, L.COLOR[e.d or e.rec.d] or "?",
          math.floor(e.chance * 100 + 0.5), e.exact and "" or S.chance_estimate))
      else
        grey(S.learn_detail:format(ns.Fmt.Source(e.rec, true), e.rec.learn, L.MayNeedRank(e.rec) and S.learn_rank or "",
          L.COLOR[e.d or e.rec.d] or "?", math.floor(e.chance * 100 + 0.5), e.exact and "" or S.chance_estimate) .. ((e.rec.fee and e.rec.fee > 0 and not (e.rec.way and (e.rec.way.cost or e.rec.way.kind == "vendor" or e.rec.way.kind == "item"))) and S.learn_fee:format(ns.Money(e.rec.fee)) or ""))
      end
      if e.target and e.target.extra then grey(e.target.extra) end          -- the site's butin / pickpocket / pêche / quête
      local note = ns.Fmt.PriceNote(e)
      if note then grey(note) end                                           -- "prix HV incertain · prix HV de 5 j"
      if lr.gain then
        entries[#entries + 1] = { wide = true, left = "|cff1eff00" .. (gold and S.learn_gold_beats:format(label, ns.Money(lr.gain))
          or S.learn_beats_effort:format(label, fmtPoints(lr.gainFrom), fmtPoints(lr.gainTo))) .. "|r" }
      end
    end
    for _, o in ipairs(lr.now) do if o ~= e then row(o) end end
  end
  if #lr.soon > 0 then
    entries[#entries + 1] = { wide = true, left = "|cffffd100" .. S.learn_soon:format(L.SOON) .. "|r" }
    for _, o in ipairs(lr.soon) do row(o) end
  end
  if #(lr.gray or {}) > 0 then
    entries[#entries + 1] = { wide = true, left = "|cff9d9d9d" .. S.learn_gray_title .. "|r" }
    for _, o in ipairs(lr.gray) do row(o) end
  end
  for _, list in ipairs({ lr.now, lr.soon }) do
    for _, o in ipairs(list) do
      if o.unpriced then return grey(S.learn_no_price) end
    end
  end
end

-- The dim note under the recommended recipe about where its sale value comes from: an AH resale (with the price age), an old or
-- undated AH price. nil when the value is the vendor's.
local function saleNote(e)
  local parts = {}
  if e.oldAh then parts[#parts + 1] = S.job_ah_old end
  if e.noAge then parts[#parts + 1] = S.job_ah_noage end
  if e.ahSale then
    parts[#parts + 1] = S.job_resale
    if e.saleAge then parts[#parts + 1] = e.saleAge < 1 and S.job_ah_today or S.job_ah_age:format(math.floor(e.saleAge + 0.5)) end
  end
  return #parts > 0 and table.concat(parts, " · ") or nil
end

local function renderJob(res)
  render(res, "job")
  if res.state ~= "ok" then
    f.bagOff:Hide()
    local title, body = ns.StateText(res)
    return showPanel(title, body, true)
  end
  f.subtitle:SetText("")
  f.banner:SetText("")
  local filtered = ns.char.onlyBag
  f.footer:SetText(W.JobFooter(filtered, ns.Goal()))
  local entries, nothing = {}, false -- the checkbox sits above the scroll area
  for _, p in ipairs(res.profs) do
    entries[#entries + 1] = { head = true, left = S.job_head:format(p.name, tostring(p.skill or "?"), tostring(p.max or "?")) }
    if p.status == "unseen" then
      entries[#entries + 1] = { wide = true, left = "|cff9d9d9d" .. S.job_unseen:format(p.name) .. "|r" }
    elseif p.status == "norecipes" then
      entries[#entries + 1] = { wide = true, left = "|cff9d9d9d" .. S.job_norecipes .. "|r" }
    else
      local plan, gold = p.plan, p.goal == "gold"
      if plan.best and gold then
        local e = plan.best
        local name, money = e.name or ns.Fmt.RecipeName(e.rec), ns.Money(math.abs(e.profit))
        entries[#entries + 1] = { wide = true, left = "|cff1eff00" .. (p.filtered
          and S.job_gold_best_bag:format(name, e.times or 0, money, ns.Money(math.max(0, e.total or 0)))
          or S.job_gold_best:format(name, money)) .. "|r" }
        entries[#entries + 1] = { wide = true, left = "|cff9d9d9d" .. (saleNote(e) or S.job_vendor_sale) .. "|r" }
        if p.craft then entries[#entries + 1] = { left = "", craft = p.craft } end
        if #plan.rows > 1 then
          entries[#entries + 1] = { wide = true, left = "|cffffd100" .. S.job_others .. "|r" }
          for i = 2, #plan.rows do
            local o = plan.rows[i]
            entries[#entries + 1] = { left = S.job_other_row:format(o.name or ns.Fmt.RecipeName(o.rec), ns.Leveling.COLOR[o.d or o.rec.d] or "?"),
              right = (o.profit >= 0 and S.job_gold_row_gain or S.job_gold_row_cost):format(ns.Money(math.abs(o.profit))) }
          end
        end
      elseif plan.best then
        local e = plan.best
        local name = e.name or ns.Fmt.RecipeName(e.rec)
        -- the effort first: ingredients and crafts per skill point; the gold cost is a dim secondary figure
        local ingredients = {}
        for i, m in ipairs(e.rec.mats or {}) do
          if i > 3 then ingredients[#ingredients + 1] = "..."; break end
          ingredients[#ingredients + 1] = ("%d %s"):format(m[2], ns.ItemName(m[1]))
        end
        entries[#entries + 1] = { wide = true, left = "|cff1eff00" .. (p.filtered
          and S.job_best_bag:format(name, e.times or 0, fmtPoints(e.points or 0), (e.points or 0) >= 1.5 and "s" or "",
            fmtPoints(e.unitsPerPoint), fmtPoints(e.craftsPerPoint), (e.craftsPerPoint or 0) >= 1.5 and "s" or "")
          or S.job_best:format(name, fmtPoints(e.unitsPerPoint), table.concat(ingredients, ", "), fmtPoints(e.craftsPerPoint))) .. "|r" }
        entries[#entries + 1] = { wide = true, left = "|cff9d9d9d" .. S.job_detail:format(ns.Leveling.COLOR[e.d or e.rec.d] or "?", math.floor(e.chance * 100 + 0.5),
          e.exact and "" or S.chance_estimate, ((e.d or e.rec.d) == 2 and e.rec.greenAt) and S.job_green:format(e.rec.greenAt) or "") .. "|r" }
        for _, sub in ipairs(e.subs or {}) do      -- an intermediate reagent to make first (or buy): "Peau légère traitée"
          entries[#entries + 1] = { wide = true, left = "|cffffd100" .. S.job_subcraft:format(sub.need, ns.ItemName(sub.item)) .. "|r" }
        end
        local note = (e.resale or e.oldAh) and saleNote(e)
        if note then entries[#entries + 1] = { wide = true, left = "|cff9d9d9d" .. note .. "|r" } end
        if plan.second then
          local s2 = plan.second
          entries[#entries + 1] = { wide = true, left = "|cff9d9d9d" .. S.job_then:format(s2.e.name or ns.Fmt.RecipeName(s2.e.rec),
            s2.times, fmtPoints(s2.points)) .. "|r" }
        end
        if p.craft then entries[#entries + 1] = { left = "", craft = p.craft } end
        if #plan.rows > 1 then
          entries[#entries + 1] = { wide = true, left = "|cffffd100" .. S.job_others .. "|r" }
          for i = 2, #plan.rows do
            local o = plan.rows[i]
            entries[#entries + 1] = { left = S.job_other_row:format(o.name or ns.Fmt.RecipeName(o.rec), ns.Leveling.COLOR[o.d or o.rec.d] or "?"),
              right = S.job_ingr_row:format(fmtPoints(o.unitsPerPoint)) }
          end
        end
      elseif p.filtered and plan.known > 0 and (plan.craftable or 0) == 0 then
        nothing = true
        entries[#entries + 1] = { wide = true, left = "|cffffd100" .. S.job_nothing_t .. "|r" }
      else
        entries[#entries + 1] = { wide = true, left = "|cff9d9d9d" .. (plan.known == 0 and S.job_none_known
          or (gold and S.job_gold_none or S.job_no_best)) .. "|r" }
      end
      if p.almost then
        local parts = {}
        for i, m in ipairs(p.almost.missing) do parts[i] = ("%d × %s"):format(m[2], m[1]) end
        entries[#entries + 1] = { wide = true, left = "|cff9d9d9d" .. S.job_almost:format(p.almost.name, table.concat(parts, ", ")) .. "|r" }
      end
      if #(p.missingNames or {}) > 0 then
        entries[#entries + 1] = { wide = true, left = "|cffffd100" .. S.job_missing:format(table.concat(p.missingNames, ", ")) .. "|r" }
      end
      if p.learn then nothing = addLearn(entries, p) or nothing end
    end
  end
  f.bagOff:SetShown(filtered and nothing)
  setLines(entries, {}, W.Layout.job.lines)
end

-- Called by Learned.lua when a profession window was read: refresh the leveling tab if it is the one shown.
function W.OnData()
  if f and f:IsShown() and current == "job" then W.Refresh() end
end

function W.UpdateControls()
  f.levelBox:SetOn(ns.db.onlyLevel and true or false)
  f.bagBox:SetOn(ns.char and ns.char.onlyBag and true or false)
  for key, b in pairs(f.goalBtns) do        -- the active objective is lit gold, the other dim
    local on = ns.Goal() == key
    b.edge:SetColorTexture(on and 0.83 or 0.35, on and 0.69 or 0.15, on and 0.22 or 0.1)
    b.fill:SetColorTexture(on and 0.55 or 0.16, on and 0.1 or 0.05, on and 0.06 or 0.03)
    b.label:SetTextColor(on and 1 or 0.6, on and 1 or 0.5, on and 1 or 0.4)
  end
  f.profBtn.label:SetText(S.prof_label:format(ns.db.profession and S.prof_names[ns.db.profession] or S.prof_all))
end

-- Objective of the Métier tab ("level" or "gold"), remembered per character.
function W.SetGoal(goal)
  if ns.Goal() == goal then return end
  ns.char.goal = goal
  ns.Log("frame", "objective: " .. goal)
  W.UpdateControls()
  W.Refresh()
end

function W.Refresh()
  if not f then return end
  token = token + 1
  local mine = token
  f.refresh:SetBusy(true)
  mapState = "loading"
  updateMapButton()
  local function guard(fn) return function(res) if mine == token then fn(res) end end end
  if current == "map" then
    showPanel(S.loading_t, S.loading_p, false, true)
    ns.Run(guard(renderMap), { profession = ns.db.profession })
  elseif current == "bags" then
    showPanel(S.loading_t, S.bags_loading, false, true)
    ns.RunBags(guard(renderBags))
  elseif current == "job" then
    showPanel(S.loading_t, S.loading_p, false, true)
    ns.RunLeveling(guard(renderJob))
  else
    showPanel(S.loading_t, S.loading_p, false, true)
    ns.RunHere(guard(renderHere))
  end
end

function W.SetTab(key)
  current = key
  ns.LogOnce("tab-" .. key, "frame", "first display of tab " .. key)
  for _, def in ipairs(TABS) do
    if def.key == key then
      titleFS:SetText(def.title)
      f.footer:SetText(def.footer)
    end
    local on = def.key == key
    f.tabs[def.key].fill:SetColorTexture(on and 0.114 or 0.07, on and 0.09 or 0.056, on and 0.047 or 0.03)
  end
  f.toMap:SetShown(key == "map")
  f.note:SetShown(key == "map")
  f.levelBox:SetShown(key == "map")
  f.profBtn:SetShown(key == "map")
  f.bagBox:SetShown(key == "job")
  f.goalLabel:SetShown(key == "job")
  for _, b in pairs(f.goalBtns) do b:SetShown(key == "job") end
  f.bagOff:Hide()
  scroll:SetVerticalScroll(0) -- each tab starts at its top
  W.UpdateControls()
  W.Refresh()
end

function W.Toggle()
  if not f then build() end
  if f:IsShown() then return f:Hide() end
  f:Show()
  W.SetTab(current)
end

-- The bags tab follows the bags and the here tab follows the zone while the window is open; the map button follows combat.
local watcher = CreateFrame("Frame")
for _, e in ipairs({ "BAG_UPDATE_DELAYED", "ZONE_CHANGED_NEW_AREA", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
  watcher:RegisterEvent(e)
end
-- Craft button: the profession window opening or closing, and the player's own casts. Registered in a pcall, so an
-- event this client does not know can never break the addon.
for _, e in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "TRADE_SKILL_LIST_UPDATE" }) do pcall(watcher.RegisterEvent, watcher, e) end
for _, e in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED",
  "UNIT_SPELLCAST_SUCCEEDED" }) do
  pcall(watcher.RegisterUnitEvent or watcher.RegisterEvent, watcher, e, "player")
end

-- One redraw of the Métier tab per second at most, never in combat.
local function refreshJobLater()
  if InCombatLockdown() or jobRefreshPending then return end
  jobRefreshPending = true
  C_Timer.After(1, function()
    jobRefreshPending = false
    if f and f:IsShown() and current == "job" and not InCombatLockdown() then W.Refresh() end
  end)
end

local castToken = 0
watcher:SetScript("OnEvent", function(_, event, unit, _, spellID)
  if not (f and f:IsShown()) then return end
  if event:sub(1, 13) == "PLAYER_REGEN_" then
    if current == "job" then W.UpdateCraft() end
    return updateMapButton()
  end
  if event:sub(1, 14) == "UNIT_SPELLCAST" then
    if unit ~= "player" or current ~= "job" then return end
    -- only a craft counts: a Hearthstone, a mount or a heal changes nothing here (no busy state, no redraw)
    if not W.IsCraftSpell(spellID) then return end
    castToken = castToken + 1
    if event == "UNIT_SPELLCAST_START" then
      W.CastSeen, crafting = true, true
    else
      -- a batch starts the next cast right after one stops: only release when nothing new started for a moment
      local mine = castToken
      C_Timer.After(0.6, function()
        if mine == castToken then
          crafting = false
          W.UpdateCraft()
          refreshJobLater()                         -- the counts changed: redraw the tab with the new quantities
        end
      end)
    end
    return W.UpdateCraft()
  end
  if event:sub(1, 11) == "TRADE_SKILL" then
    if current == "job" then W.UpdateCraft() end
    return
  end
  if event == "BAG_UPDATE_DELAYED" and current == "job" then return refreshJobLater() end
  if (event == "BAG_UPDATE_DELAYED" and current == "bags") or (event == "ZONE_CHANGED_NEW_AREA" and current == "here") then W.Refresh() end
end)
