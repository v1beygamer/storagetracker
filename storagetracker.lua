--------------------------------------------------------------------------
-- STORAGE NETWORK MONITOR
-- Reads Create (6.0+) Logistics Networks via one or more Stock Tickers
-- (bound to Vaults through Stock Links) and displays a tabbed dashboard
-- on an attached monitor. Supports multiple independent vault networks
-- at once (one Stock Ticker per network).
--
-- Controls:
--   Monitor (touch)   - switch tabs, page through items, sort, filter by
--                        network
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
  includeRawInventories   = false, -- also scan plain chest/barrel peripherals
  monitorScale            = 1,     -- 1 = normal readable size
  -- Give friendly names to specific Stock Ticker peripherals, e.g.
  --   ["stockTicker_3"] = "Main Base Vaults",
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
  barUp      = colors.lime,
  barDown    = colors.red,
  barFlat    = colors.cyan,
}

-- CP437 box-drawing characters (CC's font is CP437-based)
local BOX = {
  h = string.char(196), v = string.char(179),
  tl = string.char(218), tr = string.char(191),
  bl = string.char(192), br = string.char(217),
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
  if kind == "stockTicker" then return ("Vault Network #%d"):format(index) end
  return ("Inventory: %s"):format(name)
end

local function discoverSources()
  sources = {}
  local stockTickerCount, invCount = 0, 0
  for _, name in ipairs(peripheral.getNames()) do
    local ok, ptype = pcall(peripheral.getType, name)
    if ok then
      if ptype == "Create_StockTicker" then
        stockTickerCount = stockTickerCount + 1
        table.insert(sources, {
          name = name, kind = "stockTicker", p = peripheral.wrap(name),
          label = friendlyLabel(name, "stockTicker", stockTickerCount),
          lastGood = nil, stale = false,
        })
      elseif CONFIG.includeRawInventories and ptype == "inventory" then
        invCount = invCount + 1
        table.insert(sources, {
          name = name, kind = "inventory", p = peripheral.wrap(name),
          label = friendlyLabel(name, "inventory", invCount),
          lastGood = nil, stale = false,
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

local items = {}          -- name -> {name, displayName, count, perSource={label=count}}
local previousItems = {}
local history = {}        -- {t=epochMs, total=n}
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
      local snapshot = {}
      for _, entry in pairs(list) do
        local name, display, count = extractEntry(entry)
        if count and count > 0 then
          snapshot[name] = { displayName = display, count = (snapshot[name] and snapshot[name].count or 0) + count }
        end
      end
      src.lastGood = snapshot
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
  if dtMin < (CONFIG.rateWindowSeconds / 60) * 0.5 then return nil end -- not enough data yet
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
  { id = "items",    label = "All Items" },
  { id = "top",      label = "Top Items" },
  { id = "low",      label = "Low Stock" },
  { id = "movers",   label = "Movers" },
  { id = "sources",  label = "Sources" },
}

local ui = {
  view = "overview",
  page = 1,
  sortMode = "qty",       -- "qty" | "name"
  searchTerm = nil,
  networkFilter = 0,      -- 0 = all, else index into sources
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
  table.insert(ui.touchZones, { x1 = x1, y1 = y, x2 = x2, y2 = y, action = action })
end

local function writeAt(x, y, text, fg, bg)
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
  writeAt(x, y, string.rep(BOX.h, w), color or COLOR.border)
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

-- A stat "tile": label on top, big value below, optional colored value.
local function statTile(x, y, w, label, value, valueColor)
  writeAt(x, y, label, COLOR.dim)
  writeAt(x, y + 1, value, valueColor or COLOR.title)
end

--------------------------------------------------------------------------
-- Trend graph: scaled to the *visible range* (not 0), so real movement
-- is actually visible instead of a solid-looking block, and each column
-- is colored by whether it went up/down/flat vs the previous sample.
--------------------------------------------------------------------------

local function drawTrendGraph(x, y, w, h)
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

  for col, s in ipairs(visible) do
    local frac = (s.total - minV) / range
    local filledRows = math.max(1, math.floor(frac * h + 0.5))
    local prev = visible[col - 1]
    local barColor = COLOR.barFlat
    if prev then
      if s.total > prev.total then barColor = COLOR.barUp
      elseif s.total < prev.total then barColor = COLOR.barDown end
    end
    for row = 1, h do
      local screenY = y + (h - row)
      mon.setCursorPos(x + col - 1, screenY)
      mon.setBackgroundColor(row <= filledRows and barColor or colors.gray)
      mon.write(" ")
    end
  end
  mon.setBackgroundColor(COLOR.bg)

  writeAt(x, y + h, "min " .. fmt(minV), COLOR.dim)
  local maxLabel = "max " .. fmt(maxV)
  writeAt(x + w - #maxLabel, y + h, maxLabel, COLOR.dim)
end

--------------------------------------------------------------------------
-- Header / tab bar (shared across all views)
--------------------------------------------------------------------------

local function drawHeader(w)
  fillRow(1, COLOR.panel)
  centerText(1, "STORAGE NETWORK MONITOR", COLOR.title, COLOR.panel)

  fillRow(2, COLOR.bg)
  local tx = 2
  for _, tab in ipairs(TABS) do
    local active = ui.view == tab.id
    local label = " " .. tab.label .. " "
    writeAt(tx, 2, label, active and COLOR.tabOnText or COLOR.tabOffText, active and COLOR.tabOn or COLOR.tabOff)
    registerZone(tx, 2, tx + #label - 1, { type = "view", value = tab.id })
    tx = tx + #label + 1
  end
  hline(1, 3, w, COLOR.border)
end

local function drawNetworkChips(y)
  local tx = 2
  local function chip(label, active, action)
    local text = " " .. label .. " "
    writeAt(tx, y, text, active and COLOR.tabOnText or COLOR.dim, active and COLOR.tabOn or COLOR.bg)
    registerZone(tx, y, tx + #text - 1, action)
    tx = tx + #text + 1
  end
  chip("All Networks", ui.networkFilter == 0, { type = "network", value = 0 })
  for i, src in ipairs(sources) do
    local label = src.label .. (src.stale and " (stale)" or "")
    chip(label, ui.networkFilter == i, { type = "network", value = i })
  end
end

local function drawFooter(h, w, extra)
  hline(1, h - 1, w, COLOR.border)
  local scanAgeSec = math.floor((os.epoch("utc") - lastScanTime) / 1000)
  local status = ("Last scan: %ds ago | every %ds | uptime %s"):format(
    scanAgeSec, CONFIG.refreshInterval, fmtDuration(os.epoch("utc") - startTime))
  writeAt(2, h, status, COLOR.dim)
  if not lastScanOk then
    writeAt(w - 14, h, "SCAN ERROR", COLOR.bad)
  end
  if extra then extra() end
end

--------------------------------------------------------------------------
-- View: Overview
--------------------------------------------------------------------------

local function drawOverview(w, h)
  local rate = itemsPerMinute()
  local rateStr, rateColor
  if rate == nil then
    rateStr, rateColor = "collecting...", COLOR.dim
  else
    rateStr = (rate >= 0 and "+" or "") .. fmt(rate) .. "/min"
    rateColor = rate > 0 and COLOR.good or (rate < 0 and COLOR.bad or COLOR.dim)
  end

  local _, lowN = lowStockItems(nil)

  local row1 = 5
  statTile(2, row1, 20, "TOTAL ITEMS", fmt(totalItems), COLOR.accent)
  statTile(22, row1, 20, "UNIQUE ITEMS", fmt(uniqueItems), COLOR.accent)
  statTile(42, row1, 20, "NETWORKS", tostring(#sources), COLOR.accent)
  statTile(58, row1, 20, ("THROUGHPUT (%ds)"):format(CONFIG.rateWindowSeconds), rateStr, rateColor)

  local row2 = row1 + 3
  statTile(2, row2, 20, "LOW STOCK ITEMS", tostring(lowN), lowN > 0 and COLOR.warn or COLOR.good)
  local avg = uniqueItems > 0 and (totalItems / uniqueItems) or 0
  statTile(22, row2, 20, "AVG STACK/ITEM", fmt(avg), COLOR.text)
  local staleCount = 0
  for _, s in ipairs(sources) do if s.stale then staleCount = staleCount + 1 end end
  statTile(42, row2, 20, "NETWORKS STALE", tostring(staleCount), staleCount > 0 and COLOR.warn or COLOR.good)

  local graphY = row2 + 4
  writeAt(2, graphY - 1, "TOTAL ITEM TREND", COLOR.dim)
  drawTrendGraph(2, graphY, math.min(w - 3, 70), math.max(3, h - graphY - 8))

  local bottomY = h - 8
  hline(1, bottomY - 1, w, COLOR.border)
  writeAt(2, bottomY, "TOP 3 ITEMS", COLOR.dim)
  local top3 = topItems(3)
  for i, rec in ipairs(top3) do
    writeAt(2, bottomY + i, ("%d. %s"):format(i, rec.displayName), COLOR.text)
    writeAt(30, bottomY + i, fmt(rec.count), COLOR.accent)
  end

  writeAt(45, bottomY, "TOP MOVERS (since last scan)", COLOR.dim)
  local movers = topMovers(3)
  if #movers == 0 then
    writeAt(45, bottomY + 1, "No change", COLOR.dim)
  end
  for i, m in ipairs(movers) do
    local sign = m.delta > 0 and "+" or ""
    local c = m.delta > 0 and COLOR.good or COLOR.bad
    writeAt(45, bottomY + i, m.name, COLOR.text)
    writeAt(70, bottomY + i, sign .. fmt(m.delta), c)
  end
end

--------------------------------------------------------------------------
-- View: All Items (paginated, sortable, filterable by network)
--------------------------------------------------------------------------

local function drawItemsList(w, h, list, topY, opts)
  opts = opts or {}
  local rowsAvailable = h - topY - 2
  local perPage = math.max(1, rowsAvailable)
  local totalPages = math.max(1, math.ceil(#list / perPage))
  if ui.page > totalPages then ui.page = totalPages end
  local startIdx = (ui.page - 1) * perPage + 1

  for i = 0, perPage - 1 do
    local idx = startIdx + i
    local rec = list[idx]
    local y = topY + 1 + i
    if rec then
      local nameStr = rec.displayName
      if #nameStr > 34 then nameStr = nameStr:sub(1, 33) .. "…" end
      local color = COLOR.text
      if opts.lowColor and rec.count < CONFIG.lowStockThreshold then color = COLOR.warn end
      writeAt(2, y, nameStr, color)
      writeAt(38, y, fmt(rec.count), color)
      if totalItems > 0 then
        writeAt(50, y, string.format("%5.1f%%", rec.count / totalItems * 100), COLOR.dim)
      end
      if opts.showBar then
        local barW = math.min(20, w - 62)
        if barW > 0 and opts.maxForBar and opts.maxForBar > 0 then
          local filled = math.floor((rec.count / opts.maxForBar) * barW + 0.5)
          writeAt(60, y, string.rep(string.char(219), filled), COLOR.accent)
        end
      end
    end
  end
  return totalPages
end

local function drawPagination(y, totalPages)
  writeAt(2, y, "[ < Prev ]", COLOR.tabOnText, COLOR.button or colors.blue)
  registerZone(2, y, 11, { type = "page", value = -1 })
  local label = ("Page %d/%d"):format(ui.page, totalPages)
  writeAt(13, y, label, COLOR.dim)
  local nextX = 13 + #label + 2
  writeAt(nextX, y, "[ Next > ]", COLOR.tabOnText, colors.blue)
  registerZone(nextX, y, nextX + 9, { type = "page", value = 1 })
end

local function drawItemsView(w, h)
  drawNetworkChips(4)
  local listTop = 6
  local function sortBtn(label, x, mode)
    local active = ui.sortMode == mode
    local text = "[" .. label .. "]"
    writeAt(x, listTop, text, active and COLOR.accent or COLOR.dim)
    registerZone(x, listTop, x + #text - 1, { type = "sort", value = mode })
  end
  writeAt(2, listTop, "ITEM", COLOR.dim)
  writeAt(38, listTop, "QTY", COLOR.dim)
  writeAt(50, listTop, "  % ", COLOR.dim)
  sortBtn("Sort: Name", 60, "name")
  sortBtn("Sort: Qty", 74, "qty")
  hline(1, listTop + 1, w, COLOR.border)

  if ui.searchTerm then
    writeAt(2, listTop - 1, "Filter (terminal): \"" .. ui.searchTerm .. "\"  (type 'clear' to reset)", COLOR.accent)
  end

  local list = sortedFilteredItems()
  local totalPages = drawItemsList(w, h, list, listTop + 1)
  drawPagination(h - 3, totalPages)
end

--------------------------------------------------------------------------
-- View: Top Items (bar chart style)
--------------------------------------------------------------------------

local function drawTopView(w, h)
  writeAt(2, 5, ("TOP %d ITEMS BY QUANTITY"):format(CONFIG.topCount), COLOR.dim)
  hline(1, 6, w, COLOR.border)
  local list = topItems(CONFIG.topCount)
  local maxV = list[1] and list[1].count or 1
  drawItemsList(w, h, list, 6, { showBar = true, maxForBar = maxV })
end

--------------------------------------------------------------------------
-- View: Low Stock
--------------------------------------------------------------------------

local function drawLowView(w, h)
  local list, totalLow = lowStockItems(nil)
  writeAt(2, 5, ("LOW STOCK (below %d) - %d item(s)"):format(CONFIG.lowStockThreshold, totalLow), COLOR.warn)
  hline(1, 6, w, COLOR.border)
  if totalLow == 0 then
    writeAt(2, 8, "Nothing is low on stock right now.", COLOR.good)
    return
  end
  local totalPages = drawItemsList(w, h, list, 6, { lowColor = true })
  drawPagination(h - 3, totalPages)
end

--------------------------------------------------------------------------
-- View: Movers
--------------------------------------------------------------------------

local function drawMoversView(w, h)
  writeAt(2, 5, "BIGGEST CHANGES SINCE LAST SCAN", COLOR.dim)
  hline(1, 6, w, COLOR.border)
  local movers = topMovers(CONFIG.moversCount)
  if #movers == 0 then
    writeAt(2, 8, "No changes detected on the last scan.", COLOR.dim)
    return
  end
  for i, m in ipairs(movers) do
    local y = 7 + i
    local sign = m.delta > 0 and "+" or ""
    local c = m.delta > 0 and COLOR.good or COLOR.bad
    local nameStr = m.name
    if #nameStr > 34 then nameStr = nameStr:sub(1, 33) .. "…" end
    writeAt(2, y, nameStr, COLOR.text)
    writeAt(38, y, sign .. fmt(m.delta), c)
    writeAt(52, y, "now " .. fmt(m.count), COLOR.dim)
  end
end

--------------------------------------------------------------------------
-- View: Sources
--------------------------------------------------------------------------

local function drawSourcesView(w, h)
  writeAt(2, 5, ("%d CONNECTED NETWORK(S)"):format(#sources), COLOR.dim)
  hline(1, 6, w, COLOR.border)
  if #sources == 0 then
    writeAt(2, 8, "No Create_StockTicker peripherals detected.", COLOR.bad)
    writeAt(2, 9, "Attach one via wired modem and bind it to a Stock Link.", COLOR.dim)
    return
  end
  for i, src in ipairs(sources) do
    local y = 6 + (i - 1) * 3 + 1
    local uniqueForSrc, totalForSrc = 0, 0
    for _, rec in pairs(items) do
      local c = rec.perSource[src.label]
      if c then uniqueForSrc = uniqueForSrc + 1; totalForSrc = totalForSrc + c end
    end
    local statusColor = src.stale and COLOR.bad or COLOR.good
    local statusText = src.stale and "STALE (last good data shown)" or "ONLINE"
    writeAt(2, y, ("[%d] %s"):format(i, src.label), COLOR.title)
    writeAt(45, y, statusText, statusColor)
    writeAt(2, y + 1, ("  peripheral: %s   items: %s   unique: %s"):format(
      src.name, fmt(totalForSrc), fmt(uniqueForSrc)), COLOR.dim)
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

  drawHeader(w)

  if ui.view == "overview" then drawOverview(w, h)
  elseif ui.view == "items" then drawItemsView(w, h)
  elseif ui.view == "top" then drawTopView(w, h)
  elseif ui.view == "low" then drawLowView(w, h)
  elseif ui.view == "movers" then drawMoversView(w, h)
  elseif ui.view == "sources" then drawSourcesView(w, h)
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
  print("  sources         - list connected vault networks")
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
    print("WARNING: no Create_StockTicker peripherals found.")
    print("Attach a Stock Ticker via wired modem, bind it to a Stock Link,")
    print("and this program will pick it up automatically (or press refresh).")
  end
  scanAll()
  render()
  parallel.waitForAny(refreshLoop, touchLoop, terminalLoop, peripheralWatchLoop)
end

main()
