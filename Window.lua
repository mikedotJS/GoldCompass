-- The map window (PLAN.md step 2), styled after docs/mockup.html: gold frame, bottom tab, red buttons.
-- Only the map tab exists; the Bags and Here tabs are later steps.
local _, ns = ...
local S = ns.S

local W = {}
ns.Window = W

local ROWS, ROW_H = 10, 34
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

-- Red game-style button; disabled = greyed out and not clickable.
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

local f, rows, panel, selected

local function openMap(zone)
  local ok = OpenWorldMap and pcall(OpenWorldMap, zone)
  if not ok then ns.Print(S.map_fail) end
end

local function selectRow(i)
  selected = i
  for n, row in ipairs(rows) do row.sel:SetShown(n == i) end
end

local function build()
  f = CreateFrame("Frame", "GoldCompassFrame", UIParent)
  f:SetSize(480, 440)
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
  tinsert(UISpecialFrames, "GoldCompassFrame") -- Escape closes it

  local edge = solid(f, "BACKGROUND", 0.416, 0.333, 0.149)
  edge:SetAllPoints()
  local bg = solid(f, "BORDER", 0.075, 0.063, 0.035, 0.97)
  bg:SetPoint("TOPLEFT", 1, -1)
  bg:SetPoint("BOTTOMRIGHT", -1, 1)

  local title = text(f, "GameFontNormal", GOLD, "CENTER")
  title:SetPoint("TOP", 0, -9)
  title:SetText(S.title)
  local line = solid(f, "ARTWORK", 0.227, 0.184, 0.078)
  line:SetPoint("TOPLEFT", 1, -30)
  line:SetPoint("TOPRIGHT", -1, -30)
  line:SetHeight(1)
  local close = button(f, "X", 20)
  close:SetPoint("TOPRIGHT", -5, -5)
  close:SetScript("OnClick", function() f:Hide() end)

  f.subtitle = text(f, "GameFontNormalSmall", { 0.79, 0.73, 0.54 })
  f.subtitle:SetPoint("TOPLEFT", 14, -38)

  rows = {}
  for i = 1, ROWS do
    local r = CreateFrame("Button", nil, f)
    r:SetSize(452, ROW_H)
    r:SetPoint("TOPLEFT", 14, -58 - (i - 1) * ROW_H)
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
  f.footer:SetText(S.footer)

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

  local tab = CreateFrame("Frame", nil, f)
  tab:SetSize(70, 20)
  tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 10, 1)
  local tabEdge = solid(tab, "BACKGROUND", 0.416, 0.333, 0.149)
  tabEdge:SetAllPoints()
  local tabFill = solid(tab, "BORDER", 0.114, 0.09, 0.047)
  tabFill:SetPoint("TOPLEFT", 1, 0)
  tabFill:SetPoint("BOTTOMRIGHT", -1, 1)
  local tabLabel = text(tab, "GameFontNormalSmall", GOLD, "CENTER")
  tabLabel:SetPoint("CENTER")
  tabLabel:SetText(S.tab_map)
end

local function showPanel(title, body, canRetry, loading)
  for _, r in ipairs(rows) do r:Hide() end
  f.subtitle:SetText("")
  f.banner:SetText("")
  panel:Show()
  panel.title:SetText(title)
  panel.body:SetText(body)
  panel.retry:SetShown(canRetry)
  if loading then panel.pulse:Play() else panel.pulse:Stop() panel.title:SetAlpha(1) end
end

local function render(res)
  f.refresh:SetBusy(false)
  f.toMap:SetBusy(res.state ~= "ok")
  if res.state ~= "ok" then
    local title, body = ns.StateText(res)
    return showPanel(title, body, true)
  end
  panel:Hide()
  panel.pulse:Stop()
  f.subtitle:SetText(res.supposed and S.hypothetical:format(res.supposed) or S.mine)
  local banner = {}
  if res.anyPartial then banner[#banner + 1] = S.stale_banner end
  if res.ageUnknown then banner[#banner + 1] = S.age_unknown end
  f.banner:SetText(table.concat(banner, " "))
  local best = res.rows[1].copperPerHour
  for i, r in ipairs(rows) do
    local row = res.rows[i]
    if row then
      r.zoneID = row.zone
      r.rank:SetText(i)
      r.zone:SetText(row.name)
      local tags = (row.old and (" · " .. S.tag_old) or "") .. (row.partial and (" · " .. S.tag_partial) or "")
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

function W.Refresh()
  if not f then return end
  f.refresh:SetBusy(true)
  f.toMap:SetBusy(true)
  showPanel(S.loading_t, S.loading_p, false, true)
  ns.Run(render)
end

function W.Toggle()
  if not f then build() end
  if f:IsShown() then return f:Hide() end
  f:Show()
  W.Refresh()
end
