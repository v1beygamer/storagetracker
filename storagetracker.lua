--------------------------------------------------------------------------
-- STORAGE NETWORK MONITOR
-- Per-vault mode: wire a Wired Modem directly to each Create Item Vault
-- (and/or chest/barrel) you want tracked -- CC:Tweaked sees each as a
-- generic "inventory" peripheral, giving a true per-vault breakdown
-- instead of a network-wide aggregate. Create_StockTicker peripherals
-- (whole Logistics Network totals) are still supported and can be mixed
-- in alongside individual vaults.
--
-- Controls:
--   Monitor (touch)   - switch tabs, page through items, sort, filter by
--                        source
--   Computer terminal - type commands: search <text> | sort name|qty
--                        | clear | sources | refresh | help
--------------------------------------------------------------------------

--============================== CONFIG ==================================
local CONFIG = {
  monitorSide           = nil,   -- e.g. "top", "right", or nil = auto-detect
  refreshInterval        = 5,     -- seconds between automatic rescans
  historyLength          = 240,   -- samples kept for the trend graph / rate calc
  rateWindowSeconds       = 60,    -- lookback window for the items/min stat
  lowStockThreshold       = 64,    -- items below this count are flagged low
  topCount                = 15,    -- how many items to show on the Top tab
  moversCount             = 15,    -- how many items to show on the Movers tab
  includeInventories      = true,  -- scan generic "inventory" peripherals (Vaults, chests, barrels...)
  includeStockTickers     = true,  -- also scan Create_StockTicker peripherals (whole-network totals)
  monitorScale            = 1,     -- 1 = normal readable size
  -- Give friendly names to specific peripherals, e.g.
  --   ["inventory_3"] = "Iron Farm Vault",
  --   ["stockTicker_7"] = "Main Base Network",
  sourceLabels            = {},
}
--==========================================================================

local COLOR = {
  bg         = colors.black,
  panel      = colors.gray,
  panelText  = colors.white,
  title      = colors.white,
  accent     = colors.cyan,
  good       = colors.lime,
  bad        = colors.red,
  warn       = colors.yellow,
  text       = colors.white,
  dim        = colors.lightGray,
  border     = colors.gray,
  tabOff     = colors.gray,
  tabOn      = colors.cyan,
  tabOffText = colors.white,
  tabOnText  = colors.black,
  button     = colors.blue,
}

-- CP437 shading/box characters (CC's font is CP437-based)
local CH = {
  hline  = string.char(196),
  shade1 = string.char(176), -- light
  shade2 = string.char(177), -- medium
  shade3 = string.char(178), -- dark
  block  = string.char(219), -- full
}

--------------------------------------------------------------------------
-- Name prettifying: strip "minecraft:" / "modid:" and underscores
--------------------------------------------------------------------------

local function titleCase(s)
  return s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b:lower() end)
end

local function prettifyName(raw)
  if not raw then return "Unknown" end
  local s = raw
  local colonPos = s:find(":")
  if colonPos then s = s:sub(colonPos + 1) end
  s = s:gsub("_", " ")
  s = titleCase(s)
  return s
end

--------------------------------------------------------------------------
-- Peripheral discovery
--------------------------------------------------------------------------

local sources = {}
local monitor, mon

local function friendlyLabel(name, kind, index)
  if CONFIG.sourceLabels[name] then return CONFIG.sourceLabels[name] end
  if kind == "stockTicker" then return ("Network #%d"):format(index) end
  return ("Vault #%d"):format(index)
end

local function discoverSources()
  sources = {}
  local stockTickerCount, invCount = 0, 0
  for _, name in ipairs(peripheral.getNames()) do
    local ok, ptype = pcall(peripheral.getType, name)
    if ok then
      if CONFIG.includeStockTickers and ptype == "Create_StockTicker" then
        stockTickerCount = stockTickerCount + 1
        table.insert(sources, {
          name = name, kind = "stockTicker", p = peripheral.wrap(name),
          label = friendlyLabel(name, "stockTicker", stockTickerCount),
          lastGood = nil, stale = false, slots = nil,
        })
      elseif CONFIG.includeInventories and ptype == "inventory" then
        invCount = invCount + 1
        table.insert(sources, {
          name = name, kind = "inventory", p = peripheral.wrap(name),
          label = friendlyLabel(name, "inventory", invCount),
          lastGood = nil, stale = false, slots = nil,
        })
      end
    end
  end
  return sources
end

local function findMonitor()
  if CONFIG.monitorSide then
    monitor = peripheral.wrap(CONFIG.monitorSide)
  else
    monitor = peripheral.find("monitor")
  end
  if not monitor then
    error("No monitor found. Attach an (Advanced) Monitor via wired modem or set CONFIG.monitorSide.")
  end
  monitor.setTextScale(CONFIG.monitorScale)
  local w, h = monitor.getSize()
  mon = window.create(monitor, 1, 1, w, h, false)
end

--------------------------------------------------------------------------
-- Scanning / aggregation
--------------------------------------------------------------------------

local items = {}
local previousItems = {}
local history = {}
local totalItems, uniqueItems = 0, 0
local lastScanTime = 0
local lastScanOk, lastScanErr = true, nil
local startTime = os.epoch("utc")

local function safeCall(fn, ...)
  local ok, a, b = pcall(fn, ...)
  if ok then return a, b end
  return nil, a
end

local function extractEntry(entry)
  local name = entry.name or entry.id or "unknown"
  local display = prettifyName(entry.displayName or entry.name or name)
  local count = entry.count or entry.amount or 0
  return name, display, count
end

local function readSource(src)
  local list, err
  if src.kind == "stockTicker" then
    list, err = safeCall(src.p.stock, false)
    if not list then list, err = safeCall(src.p.list) end
  else
    list, err = safeCall(src.p.list)
    if list then
      src.slots = select(1, safeCall(src.p.size))
    end
  end
  return list, err
end

local function scanAll()
  previousItems = items
  items = {}
  totalItems, uniqueItems = 0, 0
  lastScanOk, lastScanErr = true, nil

  for _, src in ipairs(sources) do
    local list, err = readSource(src)

    if list then
      -- Cache a good read so a transient failure next tick doesn't
      -- create a fake dip in the totals / throughput graph.
      local snapshot, usedSlots = {}, 0
      for _, entry in pairs(list) do
        usedSlots = usedSlots + 1
        local name, display, count = extractEntry(entry)
        if count and count > 0 then
          snapshot[name] = { displayName = display, count = (snapshot[name] and snapshot[name].count or 0) + count }
        end
      end
      src.lastGood = snapshot
      src.usedSlots = usedSlots
      src.stale = false
    else
      src.stale = true
      lastScanOk = false
      lastScanErr = ("%s: %s"):format(src.label, tostring(err))
    end

    local useSnapshot = src.lastGood
    if useSnapshot then
      for name, rec0 in pairs(useSnapshot) do
        local rec = items[name]
        if not rec then
          rec = { name = name, displayName = rec0.displayName, count = 0, perSource = {} }
          items[name] = rec
        end
        rec.count = rec.count + rec0.count
        rec.perSource[src.label] = (rec.perSource[src.label] or 0) + rec0.count
        totalItems = totalItems + rec0.count
      end
    end
  end

  for _ in pairs(items) do uniqueItems = uniqueItems + 1 end

  lastScanTime = os.epoch("utc")
  table.insert(history, { t = lastScanTime, total = totalItems })
  while #history > CONFIG.historyLength do table.remove(history, 1) end
end

-- Rate over a short rolling window, not the whole history buffer, so it
-- reflects what's actually happening right now instead of lagging by
-- however long the full buffer spans.
local function itemsPerMinute()
  if #history < 2 then return nil end
  local now = history[#history].t
  local cutoff = now - CONFIG.rateWindowSeconds * 1000
  local ref = history[1]
  for i = #history, 1, -1 do
    if history[i].t <= cutoff then ref = history[i]; break end
    ref = history[i]
  end
  local dtMin = (now - ref.t) / 60000
  if dtMin < (CONFIG.rateWindowSeconds / 60) * 0.5 then return nil end
  return (history[#history].total - ref.total) / dtMin
end

local function topItems(n)
  local list = {}
  for _, rec in pairs(items) do table.insert(list, rec) end
  table.sort(list, function(a, b) return a.count > b.count end)
  local out = {}
  for i = 1, math.min(n, #list) do out[i] = list[i] end
  return out
end

local function lowStockItems(n)
  local list = {}
  for _, rec in pairs(items) do
    if rec.count < CONFIG.lowStockThreshold then table.insert(list, rec) end
  end
  table.sort(list, function(a, b) return a.count < b.count end)
  if n then
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out, #list
  end
  return list, #list
end

local function topMovers(n)
  local deltas = {}
  for name, rec in pairs(items) do
    local prevCount = previousItems[name] and previousItems[name].count or 0
    local delta = rec.count - prevCount
    if delta ~= 0 then
      table.insert(deltas, { name = rec.displayName, delta = delta, count = rec.count })
    end
  end
  table.sort(deltas, function(a, b) return math.abs(a.delta) > math.abs(b.delta) end)
  local out = {}
  for i = 1, math.min(n, #deltas) do out[i] = deltas[i] end
  return out
end

--------------------------------------------------------------------------
-- UI state
--------------------------------------------------------------------------

local TABS = {
  { id = "overview", label = "Overview" },
  { id = "items",    label = "Items" },
  { id = "top",      label = "Top" },
  { id = "low",      label = "Low" },
  { id = "movers",   label = "Movers" },
  { id = "sources",  label = "Vaults" },
}

local ui = {
  view = "overview",
  page = 1,
  sortMode = "qty",
  searchTerm = nil,
  networkFilter = 0,
  touchZones = {},
}

local function sortedFilteredItems()
  local list = {}
  for _, rec in pairs(items) do
    local include = true
    if ui.searchTerm and ui.searchTerm ~= "" then
      include = rec.displayName:lower():find(ui.searchTerm:lower(), 1, true) ~= nil
    end
    if include and ui.networkFilter > 0 then
      local src = sources[ui.networkFilter]
      include = src and rec.perSource[src.label] ~= nil
    end
    if include then table.insert(list, rec) end
  end
  if ui.sortMode == "name" then
    table.sort(list, function(a, b) return a.displayName:lower() < b.displayName:lower() end)
  else
    table.sort(list, function(a, b) return a.count > b.count end)
  end
  return list
end

--------------------------------------------------------------------------
-- Drawing helpers
--------------------------------------------------------------------------

local function clearZones() ui.touchZones = {} end
local function registerZone(x1, y, x2, action)
  local w = select(1, mon.getSize())
  if x1 > w or x1 < 1 then return end
  if x2 > w then x2 = w end
  table.insert(ui.touchZones, { x1 = x1, y1 = y, x2 = x2, y2 = y, action = action })
end

local function writeAt(x, y, text, fg, bg)
  local w, h = mon.getSize()
  if x > w or x < 1 or y < 1 or y > h then return end
  if x + #text - 1 > w then text = text:sub(1, w - x + 1) end
  mon.setCursorPos(x, y)
  mon.setTextColor(fg or COLOR.text)
  mon.setBackgroundColor(bg or COLOR.bg)
  mon.write(text)
  mon.setBackgroundColor(COLOR.bg)
  mon.setTextColor(COLOR.text)
end

local function fillRow(y, bg)
  local w = select(1, mon.getSize())
  mon.setCursorPos(1, y)
  mon.setBackgroundColor(bg)
  mon.write(string.rep(" ", w))
  mon.setBackgroundColor(COLOR.bg)
end

local function hline(x, y, w, color)
  writeAt(x, y, string.rep(CH.hline, w), color or COLOR.border)
end

local function centerText(y, text, fg, bg)
  local w = select(1, mon.getSize())
  local x = math.max(1, math.floor((w - #text) / 2) + 1)
  writeAt(x, y, text, fg, bg)
end

local function fmt(n)
  local neg = n < 0
  n = math.floor(math.abs(n) + 0.5)
  local s = tostring(n)
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return (neg and "-" or "") .. out
end

local function fmtDuration(ms)
  local sec = math.floor(ms / 1000)
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  local s = sec % 60
  if h > 0 then return ("%dh %dm"):format(h, m) end
  if m > 0 then return ("%dm %ds"):format(m, s) end
  return ("%ds"):format(s)
end

local function statTile(x, y, label, value, valueColor)
  writeAt(x, y, label, COLOR.dim)
  writeAt(x, y + 1, value, valueColor or COLOR.title)
end

-- Column positions scale with monitor width instead of being fixed, so
-- layout holds together on both small and large monitors.
local function columns(w)
  local qty = math.max(26, math.floor(w * 0.42))
  local pct = qty + 9
  local extra = pct + 9
  return { name = 2, qty = qty, pct = pct, extra = extra }
end

--------------------------------------------------------------------------
-- Trend graph: a single-row shaded sparkline in ONE color (no more
-- multi-color block wall), plus plain numeric stats above it.
--------------------------------------------------------------------------

local SHADES = { CH.shade1, CH.shade2, CH.shade3, CH.block }

local function drawTrendGraph(x, y, w)
  local _, monH = mon.getSize()
  if y < 1 or y > monH then return end
  local n = #history
  if n < 2 then
    writeAt(x, y, "Collecting data...", COLOR.dim)
    return
  end
  local startIdx = math.max(1, n - w + 1)
  local visible = {}
  for i = startIdx, n do table.insert(visible, history[i]) end

  local minV, maxV = math.huge, -math.huge
  for _, s in ipairs(visible) do
    if s.total < minV then minV = s.total end
    if s.total > maxV then maxV = s.total end
  end
  local range = maxV - minV
  if range == 0 then range = math.max(1, maxV * 0.01) end

  mon.setCursorPos(x, y)
  mon.setBackgroundColor(COLOR.bg)
  mon.setTextColor(COLOR.accent)
  local line = {}
  for _, s in ipairs(visible) do
    local frac = (s.total - minV) / range
    local idx = math.max(1, math.min(#SHADES, math.floor(frac * #SHADES) + 1))
    table.insert(line, SHADES[idx])
  end
  mon.write(table.concat(line))
  mon.setTextColor(COLOR.text)

  writeAt(x, y + 1, "min " .. fmt(minV), COLOR.dim)
  local maxLabel = "max " .. fmt(maxV)
  writeAt(x + w - #maxLabel, y + 1, maxLabel, COLOR.dim)
end

--------------------------------------------------------------------------
-- Header / tab bar (shared across all views) -- wraps to multiple rows
-- instead of running off the edge of narrow monitors.
--------------------------------------------------------------------------

local function layoutTabs(w)
  local rows = { {} }
  local rowIndex = 1
  local x = 2
  for _, tab in ipairs(TABS) do
    local label = " " .. tab.label .. " "
    if x + #label - 1 > w - 1 and #rows[rowIndex] > 0 then
      rowIndex = rowIndex + 1
      rows[rowIndex] = {}
      x = 2
    end
    table.insert(rows[rowIndex], { tab = tab, x = x, w = #label })
    x = x + #label + 1
  end
  return rows
end

-- Returns the first free content row below the header.
local function drawHeader(w)
  fillRow(1, COLOR.panel)
  centerText(1, "STORAGE NETWORK MONITOR", COLOR.title, COLOR.panel)

  local rows = layoutTabs(w)
  for r, rowTabs in ipairs(rows) do
    local y = 1 + r
    fillRow(y, COLOR.bg)
    for _, item in ipairs(rowTabs) do
      local active = ui.view == item.tab.id
      writeAt(item.x, y, " " .. item.tab.label .. " ",
        active and COLOR.tabOnText or COLOR.tabOffText,
        active and COLOR.tabOn or COLOR.tabOff)
      registerZone(item.x, y, item.x + item.w - 1, { type = "view", value = item.tab.id })
    end
  end

  local hlineY = 1 + #rows + 1
  hline(1, hlineY, w, COLOR.border)
  return hlineY + 1
end

local function drawSourceChips(y, w)
  local tx = 2
  local function chip(label, active, action)
    local text = " " .. label .. " "
    if tx + #text - 1 > w then return end
    writeAt(tx, y, text, active and COLOR.tabOnText or COLOR.dim, active and COLOR.tabOn or COLOR.bg)
    registerZone(tx, y, tx + #text - 1, action)
    tx = tx + #text + 1
  end
  chip("All", ui.networkFilter == 0, { type = "network", value = 0 })
  for i, src in ipairs(sources) do
    chip(src.label .. (src.stale and "!" or ""), ui.networkFilter == i, { type = "network", value = i })
  end
  return y + 1
end

local function drawFooter(h, w)
  hline(1, h - 1, w, COLOR.border)
  local scanAgeSec = math.floor((os.epoch("utc") - lastScanTime) / 1000)
  local status = ("Scan: %ds ago | every %ds | up %s"):format(
    scanAgeSec, CONFIG.refreshInterval, fmtDuration(os.epoch("utc") - startTime))
  writeAt(2, h, status, COLOR.dim)
  if not lastScanOk then
    writeAt(math.max(2, w - 11), h, "SCAN ERROR", COLOR.bad)
  end
end

--------------------------------------------------------------------------
-- View: Overview
--------------------------------------------------------------------------

local function drawOverview(w, h, top)
  local rate = itemsPerMinute()
  local rateStr, rateColor
  if rate == nil then
    rateStr, rateColor = "collecting...", COLOR.dim
  else
    rateStr = (rate >= 0 and "+" or "") .. fmt(rate) .. "/min"
    rateColor = rate > 0 and COLOR.good or (rate < 0 and COLOR.bad or COLOR.dim)
  end
  local _, lowN = lowStockItems(nil)
  local cols = columns(w)
  local tileW = math.max(16, math.floor((w - 4) / 4))

  -- Reserve the footer's 2 rows (hline + status); nothing below this
  -- line, and every section below is skipped once it would cross it.
  local maxY = h - 2

  local row1 = top + 1
  if row1 + 1 <= maxY then
    statTile(2, row1, "TOTAL ITEMS", fmt(totalItems), COLOR.accent)
    statTile(2 + tileW, row1, "UNIQUE ITEMS", fmt(uniqueItems), COLOR.accent)
    statTile(2 + tileW * 2, row1, "SOURCES", tostring(#sources), COLOR.accent)
    statTile(2 + tileW * 3, row1, ("RATE (%ds)"):format(CONFIG.rateWindowSeconds), rateStr, rateColor)
  end

  local row2 = row1 + 3
  if row2 + 1 <= maxY then
    statTile(2, row2, "LOW STOCK", tostring(lowN), lowN > 0 and COLOR.warn or COLOR.good)
    local avg = uniqueItems > 0 and (totalItems / uniqueItems) or 0
    statTile(2 + tileW, row2, "AVG STACK/ITEM", fmt(avg), COLOR.text)
    local staleCount = 0
    for _, s in ipairs(sources) do if s.stale then staleCount = staleCount + 1 end end
    statTile(2 + tileW * 2, row2, "STALE SOURCES", tostring(staleCount), staleCount > 0 and COLOR.warn or COLOR.good)
  end

  local graphY = row2 + 3
  if graphY + 1 <= maxY then
    writeAt(2, graphY - 1, "TOTAL ITEM TREND", COLOR.dim)
    drawTrendGraph(2, graphY, math.min(w - 3, 70))
  end

  local bottomY = graphY + 4
  if bottomY + 1 <= maxY then
    hline(1, bottomY - 1, w, COLOR.border)
    writeAt(2, bottomY, "TOP 3 ITEMS", COLOR.dim)
    local top3 = topItems(3)
    for i, rec in ipairs(top3) do
      if bottomY + i <= maxY then
        writeAt(2, bottomY + i, ("%d. %s"):format(i, rec.displayName), COLOR.text)
        writeAt(cols.qty, bottomY + i, fmt(rec.count), COLOR.accent)
      end
    end

    local secondColX = math.floor(w / 2) + 2
    writeAt(secondColX, bottomY, "TOP MOVERS", COLOR.dim)
    local movers = topMovers(3)
    if #movers == 0 then
      writeAt(secondColX, bottomY + 1, "No change", COLOR.dim)
    end
    for i, m in ipairs(movers) do
      if bottomY + i <= maxY then
        local sign = m.delta > 0 and "+" or ""
        local c = m.delta > 0 and COLOR.good or COLOR.bad
        writeAt(secondColX, bottomY + i, m.name, COLOR.text)
        writeAt(math.min(w - 8, secondColX + 24), bottomY + i, sign .. fmt(m.delta), c)
      end
    end
  end
end

--------------------------------------------------------------------------
-- Item list (shared by Items / Top / Low tabs)
--------------------------------------------------------------------------

local function drawItemsList(w, h, list, topY, opts)
  opts = opts or {}
  local cols = columns(w)
  local reserve = opts.paginated and 4 or 2
  local rowsAvailable = math.max(1, h - topY - reserve)
  local perPage = rowsAvailable
  local totalPages = math.max(1, math.ceil(#list / perPage))
  if ui.page > totalPages then ui.page = totalPages end
  local startIdx = (ui.page - 1) * perPage + 1

  for i = 0, perPage - 1 do
    local idx = startIdx + i
    local rec = list[idx]
    local y = topY + 1 + i
    if rec then
      local maxNameLen = math.max(10, cols.qty - cols.name - 2)
      local nameStr = rec.displayName
      if #nameStr > maxNameLen then nameStr = nameStr:sub(1, maxNameLen - 1) .. "…" end
      local color = COLOR.text
      if opts.lowColor and rec.count < CONFIG.lowStockThreshold then color = COLOR.warn end
      writeAt(cols.name, y, nameStr, color)
      writeAt(cols.qty, y, fmt(rec.count), color)
      if totalItems > 0 then
        writeAt(cols.pct, y, string.format("%5.1f%%", rec.count / totalItems * 100), COLOR.dim)
      end
      if opts.showBar and opts.maxForBar and opts.maxForBar > 0 then
        local barW = math.max(0, w - cols.extra - 2)
        local filled = math.floor((rec.count / opts.maxForBar) * barW + 0.5)
        if filled > 0 then writeAt(cols.extra, y, string.rep(CH.block, filled), COLOR.accent) end
      end
    end
  end
  return totalPages
end

local function drawPagination(y, w, totalPages)
  writeAt(2, y, "[ < Prev ]", COLOR.tabOnText, COLOR.button)
  registerZone(2, y, 11, { type = "page", value = -1 })
  local label = ("Page %d/%d"):format(ui.page, totalPages)
  writeAt(13, y, label, COLOR.dim)
  local nextX = 13 + #label + 2
  if nextX + 9 <= w then
    writeAt(nextX, y, "[ Next > ]", COLOR.tabOnText, COLOR.button)
    registerZone(nextX, y, nextX + 9, { type = "page", value = 1 })
  end
end

--------------------------------------------------------------------------
-- View: Items
--------------------------------------------------------------------------

local function drawItemsView(w, h, top)
  local chipsY = top
  local listTop = drawSourceChips(chipsY, w) + 1
  local cols = columns(w)

  local function sortBtn(label, x, mode)
    if x > w then return end
    local active = ui.sortMode == mode
    local text = "[" .. label .. "]"
    writeAt(x, listTop, text, active and COLOR.accent or COLOR.dim)
    registerZone(x, listTop, math.min(w, x + #text - 1), { type = "sort", value = mode })
  end
  writeAt(cols.name, listTop, "ITEM", COLOR.dim)
  writeAt(cols.qty, listTop, "QTY", COLOR.dim)
  writeAt(cols.pct, listTop, "  %  ", COLOR.dim)
  sortBtn("Name", cols.extra, "name")
  sortBtn("Qty", cols.extra + 8, "qty")
  hline(1, listTop + 1, w, COLOR.border)

  if ui.searchTerm then
    writeAt(2, listTop - 1, "Filter: \"" .. ui.searchTerm .. "\" (terminal: 'clear' to reset)", COLOR.accent)
  end

  local list = sortedFilteredItems()
  local totalPages = drawItemsList(w, h, list, listTop + 1, { paginated = true })
  drawPagination(h - 3, w, totalPages)
end

--------------------------------------------------------------------------
-- View: Top Items
--------------------------------------------------------------------------

local function drawTopView(w, h, top)
  writeAt(2, top, ("TOP %d ITEMS BY QUANTITY"):format(CONFIG.topCount), COLOR.dim)
  hline(1, top + 1, w, COLOR.border)
  local list = topItems(CONFIG.topCount)
  local maxV = list[1] and list[1].count or 1
  drawItemsList(w, h, list, top + 1, { showBar = true, maxForBar = maxV })
end

--------------------------------------------------------------------------
-- View: Low Stock
--------------------------------------------------------------------------

local function drawLowView(w, h, top)
  local list, totalLow = lowStockItems(nil)
  writeAt(2, top, ("LOW STOCK (below %d) - %d item(s)"):format(CONFIG.lowStockThreshold, totalLow), COLOR.warn)
  hline(1, top + 1, w, COLOR.border)
  if totalLow == 0 then
    writeAt(2, top + 3, "Nothing is low on stock right now.", COLOR.good)
    return
  end
  local totalPages = drawItemsList(w, h, list, top + 1, { lowColor = true, paginated = true })
  drawPagination(h - 3, w, totalPages)
end

--------------------------------------------------------------------------
-- View: Movers
--------------------------------------------------------------------------

local function drawMoversView(w, h, top)
  writeAt(2, top, "BIGGEST CHANGES SINCE LAST SCAN", COLOR.dim)
  hline(1, top + 1, w, COLOR.border)
  local movers = topMovers(CONFIG.moversCount)
  if #movers == 0 then
    writeAt(2, top + 3, "No changes detected on the last scan.", COLOR.dim)
    return
  end
  local cols = columns(w)
  for i, m in ipairs(movers) do
    local y = top + 1 + i
    if y < h - 1 then
      local sign = m.delta > 0 and "+" or ""
      local c = m.delta > 0 and COLOR.good or COLOR.bad
      local maxNameLen = math.max(10, cols.qty - 2)
      local nameStr = m.name
      if #nameStr > maxNameLen then nameStr = nameStr:sub(1, maxNameLen - 1) .. "…" end
      writeAt(2, y, nameStr, COLOR.text)
      writeAt(cols.qty, y, sign .. fmt(m.delta), c)
      writeAt(cols.pct, y, "now " .. fmt(m.count), COLOR.dim)
    end
  end
end

--------------------------------------------------------------------------
-- View: Vaults / Sources
--------------------------------------------------------------------------

local function drawSourcesView(w, h, top)
  writeAt(2, top, ("%d CONNECTED SOURCE(S)"):format(#sources), COLOR.dim)
  hline(1, top + 1, w, COLOR.border)
  if #sources == 0 then
    writeAt(2, top + 3, "No inventories or Stock Tickers detected.", COLOR.bad)
    writeAt(2, top + 4, "Wire a modem to a Vault (or Stock Ticker) and it'll show up here.", COLOR.dim)
    return
  end
  local y = top + 2
  for i, src in ipairs(sources) do
    if y + 1 >= h - 1 then break end
    local uniqueForSrc, totalForSrc = 0, 0
    for _, rec in pairs(items) do
      local c = rec.perSource[src.label]
      if c then uniqueForSrc = uniqueForSrc + 1; totalForSrc = totalForSrc + c end
    end
    local statusColor = src.stale and COLOR.bad or COLOR.good
    local statusText = src.stale and "STALE" or "ONLINE"
    writeAt(2, y, ("[%d] %s"):format(i, src.label), COLOR.title)
    writeAt(math.max(30, w - 12), y, statusText, statusColor)
    local detail = ("  %s | items %s | unique %s"):format(
      src.kind == "stockTicker" and "network" or "vault", fmt(totalForSrc), fmt(uniqueForSrc))
    if src.kind == "inventory" and src.slots then
      detail = detail .. ("  | slots %d/%d"):format(src.usedSlots or 0, src.slots)
    end
    writeAt(2, y + 1, detail, COLOR.dim)
    y = y + 3
  end
end

--------------------------------------------------------------------------
-- Main render dispatch
--------------------------------------------------------------------------

local function render()
  clearZones()
  local w, h = mon.getSize()
  mon.setBackgroundColor(COLOR.bg)
  mon.clear()

  local top = drawHeader(w)

  if ui.view == "overview" then drawOverview(w, h, top)
  elseif ui.view == "items" then drawItemsView(w, h, top)
  elseif ui.view == "top" then drawTopView(w, h, top)
  elseif ui.view == "low" then drawLowView(w, h, top)
  elseif ui.view == "movers" then drawMoversView(w, h, top)
  elseif ui.view == "sources" then drawSourcesView(w, h, top)
  end

  drawFooter(h, w)
  mon.setVisible(true)
end

--------------------------------------------------------------------------
-- Terminal command interface
--------------------------------------------------------------------------

local function printHelp()
  print("Commands:")
  print("  search <text>   - filter items by name (Items view)")
  print("  clear           - clear filter")
  print("  sort name|qty")
  print("  sources         - list connected vaults/networks")
  print("  refresh         - force an immediate rescan")
  print("  help            - show this message")
end

local function printSources()
  print(("%d source(s) connected:"):format(#sources))
  for i, s in ipairs(sources) do
    print(("  [%d] %s  (%s, peripheral: %s)%s"):format(
      i, s.label, s.kind, s.name, s.stale and "  [STALE]" or ""))
  end
end

local function terminalLoop()
  print("Storage Network Monitor - terminal control")
  print("Type 'help' for commands.")
  while true do
    write("> ")
    local line = read()
    if line then
      local cmd, rest = line:match("^(%S*)%s*(.-)$")
      cmd = (cmd or ""):lower()
      if cmd == "search" and rest ~= "" then
        ui.searchTerm = rest; ui.page = 1; ui.view = "items"
        print("Filtering: " .. rest)
      elseif cmd == "clear" then
        ui.searchTerm = nil; ui.page = 1
        print("Filter cleared.")
      elseif cmd == "sort" then
        if rest == "name" or rest == "qty" then
          ui.sortMode = rest
          print("Sort mode: " .. rest)
        else
          print("Usage: sort name|qty")
        end
      elseif cmd == "sources" then
        printSources()
      elseif cmd == "refresh" then
        scanAll(); print("Rescanned.")
      elseif cmd == "help" then
        printHelp()
      elseif cmd ~= "" then
        print("Unknown command. Type 'help'.")
      end
      render()
    end
  end
end

--------------------------------------------------------------------------
-- Touch + refresh loops
--------------------------------------------------------------------------

local function handleTouch(x, y)
  for _, z in ipairs(ui.touchZones) do
    if y == z.y1 and x >= z.x1 and x <= z.x2 then
      local a = z.action
      if a.type == "view" then
        ui.view = a.value; ui.page = 1
      elseif a.type == "network" then
        ui.networkFilter = a.value; ui.page = 1
      elseif a.type == "sort" then
        ui.sortMode = a.value
      elseif a.type == "page" then
        ui.page = math.max(1, ui.page + a.value)
      end
      render()
      return
    end
  end
end

local function touchLoop()
  while true do
    local _, _, x, y = os.pullEvent("monitor_touch")
    handleTouch(x, y)
  end
end

local function refreshLoop()
  while true do
    scanAll()
    render()
    os.sleep(CONFIG.refreshInterval)
  end
end

local function peripheralWatchLoop()
  while true do
    local event = os.pullEvent()
    if event == "peripheral" or event == "peripheral_detach" then
      discoverSources()
      findMonitor()
    end
  end
end

--------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------

local function main()
  findMonitor()
  discoverSources()
  if #sources == 0 then
    print("WARNING: no inventories or Stock Tickers found.")
    print("Wire a modem to a Vault (or Stock Ticker) and this program will")
    print("pick it up automatically (or use the 'refresh' command).")
  end
  scanAll()
  render()
  parallel.waitForAny(refreshLoop, touchLoop, terminalLoop, peripheralWatchLoop)
end

main()
