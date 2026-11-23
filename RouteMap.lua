-- "Où monter" and "Itinéraire" for the gathering professions: reads the game (GatherMate2 spots, the player's place, the map) and draws
-- the loop of Route.lua on the world map. Every call that may not exist on this client (map canvas, lines, waypoint, world
-- position) is in a pcall and degrades: markers without the dashed line, a waypoint without the auto advance, nothing without the map.
local _, ns = ...
local S = ns.S

local RM = {}
ns.RouteMap = RM

local ARRIVE = 40        -- yards from a point where the next one takes over
local TICK = 0.5         -- seconds between two checks of the player's position
-- the professions that have an "Où monter": skill line ID -> English name (the node type of GatherMate2 for the first two)
RM.LINES = { [182] = "Herb Gathering", [186] = "Mining", [393] = "Skinning" }

local function french() return GetLocale and GetLocale() == "frFR" end

-- Known spots per zone and node ({ [zoneID] = { [nodeID] = n } }): the player's GatherMate2 data, else the ForeverDB counts. Cached a minute
-- (asking GatherMate2 about every map is not free).
local cache
local function counts()
  if cache and time() - cache.at < 60 then return cache.zones end
  local zones, total = {}, 0
  if ns.Nodes.Installed() then
    local ok, z, n = pcall(ns.Nodes.Counts)
    if ok then zones, total = z, n end
  end
  if total == 0 then   -- no GatherMate2 data: the ForeverDB points of the item of each node
    for id, node in pairs(ns.GatherNodes) do
      for _, src in ipairs(node.item and ns.GatherSources and ns.GatherSources[node.item] and ns.GatherSources[node.item].zones or {}) do
        local n = math.max(src[2] or 0, src[3] or 0)
        if n > 0 then
          zones[src[1]] = zones[src[1]] or {}
          zones[src[1]][id] = n
        end
      end
    end
  end
  cache = { at = time(), zones = zones }
  return zones
end

-- GatherMate2's coordinate of a spot -> x, y in percent of the map. Its own decoder when it has one, else its packed format.
local function decode(coord)
  if GatherMate2.DecodeLoc then
    local ok, x, y = pcall(GatherMate2.DecodeLoc, GatherMate2, coord)
    if ok and x then return x * 100, y * 100 end
  end
  return math.floor(coord / 1000000) / 100, math.floor(coord % 1000000 / 100) / 100
end

-- Points { x, y } (percent of the map) of the herbs or ore of a zone: the player's GatherMate2 spots for these nodes, else the best point
-- ForeverDB gives for their items.
local function gatherPoints(prof, zone, ids)
  local want, pts = {}, {}
  for _, id in ipairs(ids) do want[id] = true end
  if ns.Nodes.Installed() then
    local ok = pcall(function()
      for coord, id in GatherMate2:GetNodesForZone(zone, prof, true) do
        if want[id] then
          local x, y = decode(coord)
          pts[#pts + 1] = { x = x, y = y }
        end
      end
    end)
    if not ok then ns.Log("frame", "route: GatherMate2 spots of zone " .. zone .. " unreadable") end
  end
  if #pts == 0 then
    for _, id in ipairs(ids) do
      local item = ns.GatherNodes[id].item
      for _, src in ipairs(item and ns.GatherSources and ns.GatherSources[item] and ns.GatherSources[item].zones or {}) do
        if src[1] == zone and src.best then pts[#pts + 1] = { x = src.best[1], y = src.best[2] } end
      end
    end
  end
  return pts
end

-- Points of the beasts of a skinning step: the spawn points of ns.SkinSpots on this zone's map.
local function skinPoints(zone, beasts)
  local pts = {}
  for _, b in ipairs(beasts) do
    for _, s in ipairs(ns.SkinSpots and ns.SkinSpots[b.id] or {}) do
      if s[1] == zone then pts[#pts + 1] = { x = s[2], y = s[3] } end
    end
  end
  return pts
end

local function itemName(item, english)
  local name = ((C_Item and C_Item.GetItemInfo) or GetItemInfo)(item)
  if not name and Item and Item.CreateFromItemID then pcall(function() Item:CreateFromItemID(item):ContinueOnItemLoad(function() end) end) end
  return name or english
end

-- Where the player stands: the continent letter of ns.MapIDs ("K" | "E" | nil), for "your continent first".
local function continent()
  local C = C_Map
  local here = C and C.GetBestMapForUnit and C.GetBestMapForUnit("player")
  for _, m in pairs(ns.MapIDs) do if m[1] == here then return m[2] end end
end

-- The steps of "Où monter" for a gathering profession p (ns.ProfessionList entry), with the roadmap `road` (Leveling.Roadmap) and the
-- English profession name; nil for the other professions. A zone step carries { from, to, zone = mapID, spots, names, lo, hi, points }.
function RM.Plan(p, road, english)
  if not p.skill or RM.LINES[p.line] ~= english then return end
  local ctx = { level = UnitLevel("player"), continent = continent(),
    contOf = function(zone) for _, m in pairs(ns.MapIDs) do if m[1] == zone then return m[2] end end end,
    lowest = function(zone) return ns.Zones[zone] and ns.Zones[zone][2] end }
  local function lookup(skill)
    local list
    if english == "Skinning" then   -- the one place that says which zones and beasts to skin: ns.SkinZones (Data/ForeverSkinZones.lua)
      list = ns.Route.SkinZones(skill, ns.SkinZones or {})
    else
      list = ns.Route.GatherZones(english, skill, ns.GatherNodes, counts())
    end
    -- a zone with no known point to walk through goes after the ones that have some (the loop needs points)
    local has = {}
    for _, z in ipairs(list) do
      if z.all then has[z] = #skinPoints(z.zone, z.all) > 0 end
    end
    ns.Route.Order(list, ctx)
    -- the zone the character was sent to stays first while it still gives points (and is not far above the level): the best zone by
    -- spots changes as nodes turn gray, and a plan that moved on before the zone was spent contradicted the one announced earlier
    local stay = ns.char and ns.char.routeZone and ns.char.routeZone[english]
    for i, z in ipairs(stay and list or {}) do
      if z.zone == stay then
        local lo = ctx.lowest(z.zone)
        if not (lo and ctx.level and lo - ctx.level > ns.Route.FAR) then table.remove(list, i); table.insert(list, 1, z) end
        break
      end
    end
    local kept, rest = {}, {}
    for _, z in ipairs(list) do table.insert(has[z] == false and rest or kept, z) end
    for _, z in ipairs(rest) do kept[#kept + 1] = z end
    return kept
  end
  local plan = ns.Route.Plan({ skill = p.skill, max = p.max, nextRank = road.nextRank, capped = road.capped, rankNow = road.rankNow,
    rankAt = road.rankAt, lookup = lookup })
  local steps = {}
  for _, s in ipairs(plan) do
    local step = { kind = s.kind, from = s.from, at = s.at, to = s.to }
    local z = s.zone
    if z then
      step.zone, step.spots, step.names = z.zone, z.spots, {}
      if z.beasts then   -- skinning: the beasts, levels of those beasts
        local fr = french()
        for _, b in ipairs(z.beasts) do
          local npc = ns.Npcs and ns.Npcs[b.id]
          if #step.names < ns.Route.NAMES then step.names[#step.names + 1] = fr and npc and npc[4] or b.name end
        end
        step.lo, step.hi = z.lo, z.hi
        step.points = skinPoints(z.zone, z.all)
      else               -- herbs, ore: the items of the nodes, the level range of the zone
        local ids, seen = {}, {}
        for _, n in ipairs(z.nodes) do
          ids[#ids + 1] = n.id
          local item = ns.GatherNodes[n.id].item
          if item and not seen[item] and #step.names < ns.Route.NAMES then
            seen[item] = true
            local src = ns.GatherSources and ns.GatherSources[item]
            step.names[#step.names + 1] = itemName(item, src and src.nodes[1] and src.nodes[1][1] or ("#" .. item))
          end
        end
        local info = ns.Zones[z.zone]
        step.lo, step.hi = info and info[2], info and info[3]
        step.points = gatherPoints(english, z.zone, ids)
      end
    end
    steps[#steps + 1] = step
  end
  for _, step in ipairs(steps) do                 -- the first zone of the plan is the one the character is sent to
    if step.kind == "zone" then
      if ns.char then
        ns.char.routeZone = ns.char.routeZone or {}
        ns.char.routeZone[english] = step.zone
      end
      break
    end
  end
  return { steps = steps, skin = english == "Skinning" }
end

-- ---- the route on the map ------------------------------------------------------------------------------------------------------

local route                  -- { zone, points = { {x, y} in walking order }, next = index of the point to go to }
local pins, dashes = {}, {}
local bar, driver, hooked
local acc = 0

local function canvas()
  if not WorldMapFrame then return end
  local ok, c = pcall(function() return WorldMapFrame.GetCanvas and WorldMapFrame:GetCanvas() or WorldMapFrame.ScrollContainer.Child end)
  return ok and c or nil
end

-- User waypoint and super tracking on a point (as Window.GoTo does for an NPC): arrow on the screen, out of combat only.
local function setWaypoint(pt)
  if InCombatLockdown() then return end
  local C = C_Map
  if C and C.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates
    and (not C.CanSetUserWaypointOnMap or C.CanSetUserWaypointOnMap(route.zone)) then
    local ok = pcall(function()
      C.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(route.zone, pt.x / 100, pt.y / 100))
      if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
    end)
    ns.Log("frame", ("route: waypoint %.1f,%.1f pinned=%s"):format(pt.x, pt.y, tostring(ok)))
  end
end

local function clearWaypoint()
  pcall(function()
    if C_Map and C_Map.ClearUserWaypoint then C_Map.ClearUserWaypoint() end
  end)
end

local function pin(i, c)
  local p = pins[i]
  if not p then
    p = CreateFrame("Frame", nil, c)
    p:SetSize(24, 24)
    p.ring = p:CreateTexture(nil, "ARTWORK")
    p.ring:SetAllPoints()
    p.ring:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    p.fill = p:CreateTexture(nil, "OVERLAY")
    p.fill:SetPoint("CENTER")
    p.fill:SetSize(18, 18)
    p.fill:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    p.num = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    p.num:SetPoint("CENTER")
    pins[i] = p
  end
  return p
end

local function hideAll()
  for _, p in ipairs(pins) do p:Hide() end
  for _, d in ipairs(dashes) do d:Hide() end
end

local function drawBar()
  if not (WorldMapFrame and route) then if bar then bar:Hide() end return end
  if not bar then
    bar = CreateFrame("Frame", nil, WorldMapFrame)
    bar:SetSize(400, 26)
    bar:SetPoint("BOTTOMLEFT", WorldMapFrame, "BOTTOMLEFT", 12, 10)
    bar:SetFrameStrata("HIGH")
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetColorTexture(0.08, 0.06, 0.04, 0.85)
    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("LEFT", 8, 0)
    bar.clear = CreateFrame("Button", nil, bar)
    bar.clear:SetSize(140, 26)
    bar.clear:SetPoint("RIGHT", -4, 0)
    bar.clear.label = bar.clear:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bar.clear.label:SetPoint("CENTER")
    bar.clear.label:SetText(S.route_clear)
    bar.clear:SetScript("OnClick", function() RM.Clear(true) end)
  end
  bar.text:SetText(S.route_bar:format(#route.points) .. (route.next and (" · " .. S.route_next:format(route.next, #route.points)) or ""))
  bar:Show()
end

-- Draws the numbered markers and the dashed line when the map shows the route's zone.
function RM.Draw()
  hideAll()
  if not route then return drawBar() end
  drawBar()
  local c = canvas()
  local ok, mapID = pcall(function() return WorldMapFrame:GetMapID() end)
  if not c or not ok or mapID ~= route.zone then return end
  local w, h = c:GetWidth(), c:GetHeight()
  if type(w) ~= "number" or type(h) ~= "number" then return end
  local n = #route.points
  -- dashed line first (under the markers): a short Line object per dash, none when the client has no CreateLine
  if c.CreateLine and n > 1 then
    local used = 0
    for i = 1, n do
      local a, b = route.points[i], route.points[i % n + 1]
      local x1, y1, x2, y2 = a.x / 100 * w, a.y / 100 * h, b.x / 100 * w, b.y / 100 * h
      local len = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
      for k = 0, math.floor(len / 17) - 1 do
        used = used + 1
        if used > 300 then break end
        local d = dashes[used]
        if not d then
          local made, line = pcall(c.CreateLine, c, nil, "ARTWORK")
          if not made then break end
          d = line
          d:SetThickness(2.5)
          d:SetColorTexture(1, 0.82, 0, 0.9)
          dashes[used] = d
        end
        local t0, t1 = k * 17 / len, (k * 17 + 10) / len
        d:SetStartPoint("TOPLEFT", c, x1 + (x2 - x1) * t0, -(y1 + (y2 - y1) * t0))
        d:SetEndPoint("TOPLEFT", c, x1 + (x2 - x1) * t1, -(y1 + (y2 - y1) * t1))
        d:Show()
      end
    end
  end
  for i, pt in ipairs(route.points) do
    local p = pin(i, c)
    p:ClearAllPoints()
    p:SetPoint("CENTER", c, "TOPLEFT", pt.x / 100 * w, -pt.y / 100 * h)
    p:SetFrameLevel((c:GetFrameLevel() or 1) + 20)
    local now = i == route.next
    p.ring:SetVertexColor(1, 0.82, 0)
    p.fill:SetVertexColor(now and 1 or 0.1, now and 0.82 or 0.08, now and 0 or 0.04)
    p.num:SetTextColor(now and 0.1 or 1, now and 0.08 or 0.82, now and 0.04 or 0)
    p.num:SetText(i)
    p:Show()
  end
end

-- Player place on the route's map in percent, nil when elsewhere or when the API is missing.
local function playerPos(zone)
  local C = C_Map
  if not (C and C.GetPlayerMapPosition) then return end
  local ok, p = pcall(C.GetPlayerMapPosition, zone, "player")
  if ok and p then
    local x, y = p:GetXY()
    if x and (x > 0 or y > 0) then return x * 100, y * 100 end
  end
end

-- Distance in yards between two points of the route's map (world positions), nil when the game cannot tell.
local function yards(zone, ax, ay, bx, by)
  local C = C_Map
  if not (C and C.GetWorldPosFromMapPos and CreateVector2D) then return end
  local ok1, i1, p1 = pcall(C.GetWorldPosFromMapPos, zone, CreateVector2D(ax / 100, ay / 100))
  local ok2, i2, p2 = pcall(C.GetWorldPosFromMapPos, zone, CreateVector2D(bx / 100, by / 100))
  if ok1 and ok2 and i1 and i1 == i2 and p1 and p2 then
    local x1, y1 = p1:GetXY()
    local x2, y2 = p2:GetXY()
    return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
  end
end

-- Every half second: the next point is reached within ARRIVE yards, the one after takes over (waypoint and marker).
function RM.Tick()
  if not route then return end
  local px, py = playerPos(route.zone)
  if not px then return end
  local pt = route.points[route.next]
  local d = yards(route.zone, px, py, pt.x, pt.y)
  if d and d <= ARRIVE then
    route.next = route.next % #route.points + 1
    ns.Log("frame", ("route: reached, next point %d"):format(route.next))
    setWaypoint(route.points[route.next])
    RM.Draw()
  end
end

function RM.Active() return route end

function RM.Clear(say)
  if not route then return end
  route = nil
  if driver then driver:SetScript("OnUpdate", nil) end
  hideAll()
  drawBar()
  clearWaypoint()
  if say then ns.Print(S.route_cleared) end
end

-- Click on "Itinéraire": the loop through the points of the step, the map opened on its zone, the first point as waypoint.
function RM.Start(step)
  if InCombatLockdown() then return ns.Print(S.map_combat) end
  if not step.points or #step.points == 0 then return ns.Print(S.route_nospot) end
  local px, py = playerPos(step.zone)
  local aspect
  local c = canvas()
  if c and type(c:GetWidth()) == "number" and c:GetHeight() > 0 then aspect = c:GetWidth() / c:GetHeight() end
  local loop = ns.Route.Loop(step.points, px and { x = px, y = py } or nil, { aspect = aspect })
  route = { zone = step.zone, points = loop.points, next = 1 }
  ns.Log("frame", ("route: zone %d, %d spots -> %d points, player at %s"):format(step.zone, #step.points, #loop.points, px and ("%.1f,%.1f"):format(px, py) or "?"))
  setWaypoint(route.points[1])
  if not hooked and WorldMapFrame then
    hooked = true
    pcall(function()
      if hooksecurefunc and WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", RM.Draw) end
      if WorldMapFrame.HookScript then WorldMapFrame:HookScript("OnShow", RM.Draw) end
    end)
  end
  driver = driver or CreateFrame("Frame")
  acc = 0
  driver:SetScript("OnUpdate", function(_, dt)
    acc = acc + dt
    if acc >= TICK then acc = 0; RM.Tick() end
  end)
  ns.Window.OpenMap(step.zone)
  RM.Draw()
  if C_Timer and C_Timer.After then C_Timer.After(0.2, RM.Draw) end   -- the map is laid out a moment after it opens
end
