-- The window (PLAN.md steps 2, 5, 6), styled after docs/mockup.html: gold frame, bottom tabs, red buttons.
-- Thin glue: all numbers come from Core.lua (ns.Run, ns.RunBags) and the pure modules.
local _, ns = ...
local S = ns.S

local W = {}
ns.Window = W

local ROWS, ROW_H, LINES, LINE_H = 10, 34, 20, 17
local GOLD, MUTED = { 1, 0.82, 0 }, { 0.62, 0.62, 0.62 }

local function solid(parent, layer, r, g, b, a)
  local t = parent:CreateTexture(nil, layer)
  t:SetColorTexture(r, g, b, a or 1)
  return t
end

local function text(parent, template, color, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
  if color then fs:SetTextColor(color[1], color[2], color[3]) end
  fs:SetJustifyH(justify or "LEFT")
  return fs
end

-- Red game-style button; SetBusy(true) greys it out and makes it unclickable.
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
    self.fill:SetColorTexture(busy and 0.2 or 0.35, busy and 0.2 or 0.06, busy and 0.2 or 0.04)
    self.label:SetTextColor(busy and 0.5 or GOLD[1], busy and 0.5 or GOLD[2], busy and 0.5 or GOLD[3])
  end
  return b
end

local TABS = {
  { key = "map", label = S.tab_map, title = S.title, footer = S.footer },
  { key = "bags", label = S.tab_bags, title = S.title_bags, footer = S.bags_total_note },
  { key = "here", label = S.tab_here, title = S.title_here, footer = S.footer },
}

local f, rows, lines, panel, selected, titleFS
local current, token = "map", 0
local lastMap, renderMap

-- Opening the map is protected in combat; say so instead of failing silently.
local function openMap(zone)
  if InCombatLockdown() then return ns.Print(S.map_combat) end
  if not OpenWorldMap then return ns.Print(S.map_fail) end
  ns.LogOnce("openmap", "frame", "calling OpenWorldMap from a click (first time)")
  if not pcall(OpenWorldMap, zone) then ns.Print(S.map_blocked) end
end

W.OpenMap = openMap -- exposed for tests

local function selectRow(i)
  selected = i
  for n, row in ipairs(rows) do row.sel:SetShown(n == i) end
end

local function build()
  ns.LogOnce("frame-main", "frame", "creating GoldCompassFrame (own frame, parent UIParent, no secure template)")
  f = CreateFrame("Frame", "GoldCompassFrame", UIParent)
  f:SetSize(480, 520)
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
  local pos = ns.db and ns.db.pos
  if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("CENTER") end
  f:Hide()
  ns.LogOnce("uispecial", "frame", "inserting GoldCompassFrame in UISpecialFrames (Escape closes it)")
  tinsert(UISpecialFrames, "GoldCompassFrame") -- Escape closes it

  local edge = solid(f, "BACKGROUND", 0.416, 0.333, 0.149)
  edge:SetAllPoints()
  local bg = solid(f, "BORDER", 0.075, 0.063, 0.035, 0.97)
  bg:SetPoint("TOPLEFT", 1, -1)
  bg:SetPoint("BOTTOMRIGHT", -1, 1)

  titleFS = text(f, "GameFontNormal", GOLD, "CENTER")
  titleFS:SetPoint("TOP", 0, -9)
  local line = solid(f, "ARTWORK", 0.227, 0.184, 0.078)
  line:SetPoint("TOPLEFT", 1, -30)
  line:SetPoint("TOPRIGHT", -1, -30)
  line:SetHeight(1)
  local close = button(f, "X", 20)
  close:SetPoint("TOPRIGHT", -5, -5)
  close:SetScript("OnClick", function() f:Hide() end)

  f.subtitle = text(f, "GameFontNormalSmall", { 0.79, 0.73, 0.54 })
  f.subtitle:SetPoint("TOPLEFT", 14, -38)

  -- map tab: ranked rows
  rows = {}
  for i = 1, ROWS do
    local r = CreateFrame("Button", nil, f)
    r:SetSize(452, ROW_H)
    r:SetPoint("TOPLEFT", 14, -82 - (i - 1) * ROW_H)
    r.sel = solid(r, "BACKGROUND", 0.165, 0.129, 0.063)
    r.sel:SetAllPoints()
    r.sel:Hide()
    r.hover = solid(r, "HIGHLIGHT", 0.125, 0.102, 0.055)
    r.hover:SetAllPoints()
    r.rank = text(r, "GameFontNormalSmall", MUTED, "RIGHT")
    r.rank:SetPoint("LEFT", 0, 5)
    r.rank:SetWidth(18)
    r.zone = text(r, "GameFontNormal", { 0.96, 0.96, 0.96 })
    r.zone:SetPoint("LEFT", 26, 7)
    r.zone:SetWidth(210)
    r.sub = text(r, "GameFontHighlightSmall", MUTED)
    r.sub:SetPoint("LEFT", 26, -8)
    r.sub:SetWidth(250)
    r.bar = solid(r, "ARTWORK", 0.12, 0.8, 0.1)
    r.bar:SetHeight(5)
    r.bar:SetPoint("BOTTOMRIGHT", -4, 3)
    r.gph = text(r, "GameFontNormalSmall", { 0.12, 1, 0 }, "RIGHT")
    r.gph:SetPoint("RIGHT", -4, 5)
    r.age = text(r, "GameFontHighlightSmall", MUTED, "RIGHT")
    r.age:SetPoint("RIGHT", -110, 5)
    r.index = i
    r:SetScript("OnClick", function(self)
      selectRow(self.index)
      if self.zoneID then openMap(self.zoneID) end
    end)
    r:Hide()
    rows[i] = r
  end

  -- map controls: "my level only" checkbox and a profession selector that cycles All / Herbalism / Mining
  f.levelBox = CreateFrame("Button", nil, f)
  f.levelBox:SetSize(220, 16)
  f.levelBox:SetPoint("TOPLEFT", 14, -58)
  local boxEdge = solid(f.levelBox, "BACKGROUND", 0.54, 0.455, 0.22)
  boxEdge:SetSize(12, 12)
  boxEdge:SetPoint("LEFT")
  local boxFill = solid(f.levelBox, "BORDER", 0.04, 0.03, 0.016)
  boxFill:SetPoint("TOPLEFT", boxEdge, 1, -1)
  boxFill:SetPoint("BOTTOMRIGHT", boxEdge, -1, 1)
  f.levelBox.mark = solid(f.levelBox, "ARTWORK", 1, 0.82, 0)
  f.levelBox.mark:SetPoint("TOPLEFT", boxEdge, 3, -3)
  f.levelBox.mark:SetPoint("BOTTOMRIGHT", boxEdge, -3, 3)
  local boxLabel = text(f.levelBox, "GameFontHighlightSmall", { 0.79, 0.73, 0.54 })
  boxLabel:SetPoint("LEFT", 18, 0)
  boxLabel:SetText(S.only_level)
  f.levelBox:SetScript("OnClick", function()
    ns.db.onlyLevel = not ns.db.onlyLevel
    W.UpdateControls()
    if lastMap then renderMap(lastMap) end
  end)
  f.profBtn = button(f, "", 170)
  f.profBtn:SetPoint("TOPRIGHT", -14, -55)
  f.profBtn:SetScript("OnClick", function()
    local order = { [false] = "Herb Gathering", ["Herb Gathering"] = "Mining", ["Mining"] = "Fishing", ["Fishing"] = false }
    ns.db.profession = order[ns.db.profession or false] or nil
    W.UpdateControls()
    W.Refresh()
  end)

  -- bags and here tabs: plain lines, left text and right text
  lines = {}
  for i = 1, LINES do
    local l = { left = text(f, "GameFontHighlightSmall"), right = text(f, "GameFontHighlightSmall", nil, "RIGHT") }
    l.left:SetPoint("TOPLEFT", 14, -58 - (i - 1) * LINE_H)
    l.left:SetWidth(300)
    l.right:SetPoint("TOPRIGHT", -14, -58 - (i - 1) * LINE_H)
    l.right:SetWidth(150)
    lines[i] = l
  end

  -- loading / empty / error panel
  panel = CreateFrame("Frame", nil, f)
  panel:SetPoint("TOPLEFT", 14, -80)
  panel:SetPoint("TOPRIGHT", -14, -80)
  panel:SetHeight(220)
  panel.title = text(panel, "GameFontNormal", GOLD, "CENTER")
  panel.title:SetPoint("TOP", 0, -30)
  panel.title:SetWidth(400)
  panel.body = text(panel, "GameFontHighlightSmall", { 0.85, 0.8, 0.64 }, "CENTER")
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

  f.banner = text(f, "GameFontNormalSmall", GOLD)
  f.banner:SetPoint("BOTTOMLEFT", 14, 88)
  f.banner:SetWidth(452)
  f.footer = text(f, "GameFontHighlightSmall", MUTED)
  f.footer:SetPoint("BOTTOMLEFT", 14, 52)
  f.footer:SetWidth(452)

  f.toMap = button(f, S.to_map, 130)
  f.toMap:SetPoint("BOTTOMLEFT", 14, 26)
  f.toMap:SetScript("OnClick", function()
    local row = selected and rows[selected]
    if row and row.zoneID then openMap(row.zoneID) end
  end)
  f.note = text(f, "GameFontHighlightSmall", MUTED)
  f.note:SetPoint("LEFT", f.toMap, "RIGHT", 10, 0)
  f.note:SetText(S.map_note)
  f.refresh = button(f, S.refresh, 100)
  f.refresh:SetPoint("BOTTOMRIGHT", -14, 26)
  f.refresh:SetScript("OnClick", function() W.Refresh() end)

  -- bottom tabs
  f.tabs = {}
  for i, def in ipairs(TABS) do
    local tab = CreateFrame("Button", nil, f)
    tab:SetSize(70, 20)
    tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 10 + (i - 1) * 72, 1)
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
  for _, l in ipairs(lines) do l.left:SetText(""); l.right:SetText("") end
  f.subtitle:SetText("")
  f.banner:SetText("")
  panel:Show()
  panel.title:SetText(title)
  panel.body:SetText(body)
  panel.retry:SetShown(canRetry)
  if loading then panel.pulse:Play() else panel.pulse:Stop() panel.title:SetAlpha(1) end
end

-- Fills the plain lines. entries = { { left, right, head = bool }, ... }; extra entries beyond the pool are summarised.
local function setLines(entries, tail)
  for _, r in ipairs(rows) do r:Hide() end
  panel:Hide()
  panel.pulse:Stop()
  local room = LINES - #tail
  local shown = #entries
  if shown > room then shown = room - 1 end
  for i = 1, LINES do
    local l, e = lines[i], nil
    if i <= shown then e = entries[i]
    elseif i == shown + 1 and shown < #entries then e = { left = S.bags_more:format(#entries - shown) }
    elseif i > LINES - #tail then e = tail[i - (LINES - #tail)] end
    l.left:SetFontObject(e and e.head and GameFontNormal or GameFontHighlightSmall)
    l.left:SetText(e and e.left or "")
    l.right:SetText(e and e.right or "")
  end
end

local function render(res, kind)
  f.refresh:SetBusy(false)
  f.toMap:SetBusy(kind ~= "map" or res.state ~= "ok")
end

function renderMap(res)
  lastMap = res
  render(res, "map")
  if res.state ~= "ok" then
    local title, body = ns.StateText(res)
    return showPanel(title, body, true)
  end
  for _, l in ipairs(lines) do l.left:SetText(""); l.right:SetText("") end
  panel:Hide()
  panel.pulse:Stop()
  f.subtitle:SetText(res.supposed and S.hypothetical:format(res.supposed) or S.mine)
  local shown, hidden = ns.VisibleZones(res.all, ns.db.onlyLevel)
  local banner = {}
  local partial = ns.PartialText(shown)
  if partial ~= "" then banner[#banner + 1] = partial end
  if hidden > 0 then banner[#banner + 1] = S.unknown_level_hidden:format(hidden) end
  if res.fishing then banner[#banner + 1] = S.fish_note end
  if res.ageUnknown then banner[#banner + 1] = S.age_unknown end
  f.banner:SetText(table.concat(banner, " "))
  if #shown == 0 then return showPanel(S.nolevel_t, S.nolevel_p, true) end
  local best = shown[1].copperPerHour
  for i, r in ipairs(rows) do
    local row = shown[i]
    if row then
      r.zoneID = row.zone
      r.rank:SetText(i)
      r.zone:SetText(row.name)
      local info = ns.Zones[row.zone]
      local lo = info and info[2]
      local tags = (row.old and (" · " .. S.tag_old) or "") .. (row.partial and (" · " .. S.tag_partial) or "")
        .. (info and not lo and (" · " .. S.unknown_level_tag) or "")
        .. (lo and lo > UnitLevel("player") and (" · " .. S.far_tag:format(lo, info[3])) or "")
      r:SetAlpha(lo and lo - UnitLevel("player") > 3 and 0.45 or 1)
      r.sub:SetText(table.concat(row.itemNames, ", ") .. tags)
      r.gph:SetText(S.per_hour:format(ns.Money(row.copperPerHour)))
      r.age:SetText(S.price_age:format(ns.AgeText(row.maxAge)))
      r.bar:SetWidth(math.max(2, 90 * row.copperPerHour / best))
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
  f.subtitle:SetText(res.supposed and S.hypothetical:format(res.supposed) or "")
  f.banner:SetText(ns.PartialText({ cmp.row }))
  local entries = {
    { head = true, left = cmp.row.name, right = S.here_level:format(res.level) },
    { left = "|cff1eff00" .. S.here_you:format(ns.Money(cmp.row.copperPerHour)) .. "|r", right = "|cff9d9d9d" .. S.estimate .. "|r" },
  }
  if cmp.ratio and cmp.other then
    local other = cmp.other.name
    entries[#entries + 1] = { left = "|cff9d9d9d" .. (cmp.best and S.here_best:format(fmtRatio(cmp.ratio), other)
      or S.here_behind:format(other, fmtRatio(cmp.ratio), ns.Money(cmp.other.copperPerHour))) .. "|r" }
  end
  entries[#entries + 1] = { head = true, left = S.here_nodes }
  for _, n in ipairs(res.nodes) do entries[#entries + 1] = { left = n.name, right = ns.Money(n.unit) } end
  if #res.pickups > 0 then
    entries[#entries + 1] = { head = true, left = S.here_pickups }
    for _, p in ipairs(res.pickups) do
      entries[#entries + 1] = { left = ("%s ×%d |cff9d9d9d(%s)|r"):format(p.name, p.count, p.quest), right = ns.Money(p.unit) }
    end
  end
  setLines(entries, res.hint and { { left = "|cff9d9d9d" .. S.here_hint:format(S.prof_names[res.hint.prof], ns.Money(res.hint.gain)) .. "|r" } } or {})
end

function W.UpdateControls()
  f.levelBox.mark:SetShown(ns.db.onlyLevel and true or false)
  f.profBtn.label:SetText(S.prof_label:format(ns.db.profession and S.prof_names[ns.db.profession] or S.prof_all))
end

function W.Refresh()
  if not f then return end
  token = token + 1
  local mine = token
  f.refresh:SetBusy(true)
  f.toMap:SetBusy(true)
  local function guard(fn) return function(res) if mine == token then fn(res) end end end
  if current == "map" then
    showPanel(S.loading_t, S.loading_p, false, true)
    ns.Run(guard(renderMap), { profession = ns.db.profession })
  elseif current == "bags" then
    showPanel(S.loading_t, S.bags_loading, false, true)
    ns.RunBags(guard(renderBags))
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
  W.UpdateControls()
  W.Refresh()
end

function W.Toggle()
  if not f then build() end
  if f:IsShown() then return f:Hide() end
  f:Show()
  W.SetTab(current)
end

-- The bags tab follows the bags and the here tab follows the zone, while the window is open.
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("BAG_UPDATE_DELAYED")
watcher:RegisterEvent("ZONE_CHANGED_NEW_AREA")
watcher:SetScript("OnEvent", function(_, event)
  if not (f and f:IsShown()) then return end
  if (event == "BAG_UPDATE_DELAYED" and current == "bags") or (event == "ZONE_CHANGED_NEW_AREA" and current == "here") then W.Refresh() end
end)
