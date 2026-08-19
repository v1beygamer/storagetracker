--------------------------------------------------------------------------
-- STORAGE NETWORK MONITOR
-- Reads Create (6.0+) Logistics Networks via one or more Stock Tickers
-- (bound to Vaults through Stock Links) and displays a live dashboard
-- with statistics on an attached monitor. Supports multiple independent
-- vault networks at once (one Stock Ticker per network).
--
-- Optional: raw "inventory" peripherals (chests/barrels/etc) can also be
-- folded into the totals if CONFIG.includeRawInventories is enabled.
--
-- Controls:
--   Monitor (touch)   - page through items, switch source tabs, sort
--   Computer terminal  - type commands: search <text> | sort name|qty|pct
--                        | clear | sources | refresh | help
--------------------------------------------------------------------------

--============================== CONFIG ==================================
local CONFIG = {
  monitorSide          = nil,   -- e.g. "top", "right", or nil = auto-detect
  refreshInterval       = 5,     -- seconds between automatic rescans
  historyLength         = 120,   -- samples kept for the trend graph / rate calc
  lowStockThreshold      = 64,    -- items below this count are flagged low
  includeRawInventories  = false, -- also scan plain chest/barrel peripherals
  itemsPerPage           = nil,   -- nil = auto-fit to monitor height
  monitorScale           = 0.5,   -- smaller = more text fits
  -- Give friendly names to specific Stock Ticker peripherals, e.g.
  --   ["stockTicker_3"] = "Main Base Vaults",
  --   ["stockTicker_7"] = "Iron Farm Vaults",
  sourceLabels           = {},
}
--==========================================================================

local COLOR = {
  bg        = colors.black,
  header    = colors.gray,
  title     = colors.white,
  accent    = colors.cyan,
  good      = colors.lime,
  bad       = colors.red,
  warn      = colors.yellow,
  text      = colors.white,
  dim       = colors.lightGray,
  button    = colors.blue,
  buttonOn  = colors.cyan,
}

--------------------------------------------------------------------------
-- Peripheral discovery
--------------------------------------------------------------------------

local sources = {}      -- { {name=periphName, kind="stockTicker"/"inventory", p=wrapped, label=str} }
local monitor, mon      -- mon = window buffer drawn onto monitor

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
        local p = peripheral.wrap(name)
        table.insert(sources, {
          name = name, kind = "stockTicker", p = p,
          label = friendlyLabel(name, "stockTicker", stockTickerCount),
        })
      elseif CONFIG.includeRawInventories and ptype == "inventory" then
        invCount = invCount + 1
        local p = peripheral.wrap(name)
        table.insert(sources, {
          name = name, kind = "inventory", p = p,
          label = friendlyLabel(name, "inventory", invCount),
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

local items = {}          -- itemKey -> { name, displayName, count, perSource = {srcLabel=count}, maxCount }
local previousItems = {}  -- snapshot from the prior scan, for "movers" calc
local history = {}        -- { {t=epochMs, total=n}, ... }
local totalItems, uniqueItems = 0, 0
local lastScanTime = 0
local lastScanOk, lastScanErr = true, nil

local function safeCall(fn, ...)
  local ok, a, b = pcall(fn, ...)
  if ok then return a, b end
  return nil, a
end

local function extractEntry(entry)
  -- Defensive extraction: Create's stock()/list() results, field names
  -- can vary slightly (name vs displayName), so cover both.
  local name = entry.name or entry.id or "unknown"
  local display = entry.displayName or entry.name or name
  local count = entry.count or entry.amount or 0
  return name, display, count, entry.maxCount
end

local function scanAll()
  previousItems = items
  items = {}
  totalItems, uniqueItems = 0, 0
  lastScanOk, lastScanErr = true, nil

  for _, src in ipairs(sources) do
    local list, err

    if src.kind == "stockTicker" then
      list, err = safeCall(src.p.stock, false)
      if not list then
        -- fall back to list() if stock() isn't available on this build
        list, err = safeCall(src.p.list)
      end
    elseif src.kind == "inventory" then
      list, err = safeCall(src.p.list)
    end

    if not list then
      lastScanOk = false
      lastScanErr = ("%s: %s"):format(src.label, tostring(err))
    else
      for _, entry in pairs(list) do
        local name, display, count, maxCount = extractEntry(entry)
        if count and count > 0 then
          local rec = items[name]
          if not rec then
            rec = { name = name, displayName = display, count = 0, perSource = {}, maxCount = maxCount }
            items[name] = rec
          end
          rec.count = rec.count + count
          rec.perSource[src.label] = (rec.perSource[src.label] or 0) + count
          totalItems = totalItems + count
        end
      end
    end
  end

  for _ in pairs(items) do uniqueItems = uniqueItems + 1 end

  lastScanTime = os.epoch("utc")
  table.insert(history, { t = lastScanTime, total = totalItems })
  while #history > CONFIG.historyLength do table.remove(history, 1) end
end

local function itemsPerMinute()
  if #history < 2 then return 0 end
  local first, last = history[1], history[#history]
  local dtMin = (last.t - first.t) / 60000
  if dtMin <= 0 then return 0 end
  return (last.total - first.total) / dtMin
end

local function topMovers(n)
  local deltas = {}
  for name, rec in pairs(items) do
    local prevCount = previousItems[name] and previousItems[name].count or 0
    local delta = rec.count - prevCount
    if delta ~= 0 then
      table.insert(deltas, { name = rec.displayName, delta = delta })
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

local ui = {
  page = 1,
  sortMode = "qty",     -- "qty" | "name" | "pct"
  searchTerm = nil,
  activeTab = 0,          -- 0 = "All sources", 1..n = sources[n]
  touchZones = {},        -- {x1,y1,x2,y2, action}
}

local function sortedFilteredItems()
  local list = {}
  for _, rec in pairs(items) do
    local include = true
    if ui.searchTerm and ui.searchTerm ~= "" then
      include = rec.displayName:lower():find(ui.searchTerm:lower(), 1, true) ~= nil
    end
    if include and ui.activeTab > 0 then
      local src = sources[ui.activeTab]
      include = src and rec.perSource[src.label] ~= nil
    end
    if include then table.insert(list, rec) end
  end

  if ui.sortMode == "name" then
    table.sort(list, function(a, b) return a.displayName:lower() < b.displayName:lower() end)
  else -- "qty" and "pct" both sort by count, high to low
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
  if fg then mon.setTextColor(fg) end
  if bg then mon.setBackgroundColor(bg) end
  mon.write(text)
  mon.setBackgroundColor(COLOR.bg)
  mon.setTextColor(COLOR.text)
end

local function centerText(y, text, fg)
  local w = select(1, mon.getSize())
  local x = math.max(1, math.floor((w - #text) / 2) + 1)
  writeAt(x, y, text, fg)
end

local function drawBarGraph(x, y, w, h, series)
  -- Mini bar chart, `h` rows tall, using background-colored cells.
  local n = #series
  if n == 0 then return end
  local maxVal = 0
  for _, s in ipairs(series) do if s.total > maxVal then maxVal = s.total end end
  if maxVal == 0 then maxVal = 1 end

  local startIdx = math.max(1, n - w + 1)
  local col = 0
  for i = startIdx, n do
    col = col + 1
    local frac = series[i].total / maxVal
    local filledRows = math.floor(frac * h + 0.5)
    for row = 1, h do
      local screenY = y + (h - row)
      local on = row <= filledRows
      mon.setCursorPos(x + col - 1, screenY)
      mon.setBackgroundColor(on and COLOR.accent or colors.gray)
      mon.write(" ")
    end
  end
  mon.setBackgroundColor(COLOR.bg)
end

local function fmt(n)
  n = math.floor(n + 0.5)
  local s = tostring(n)
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return out:gsub("^,", "")
end

--------------------------------------------------------------------------
-- Main render
--------------------------------------------------------------------------

local function render()
  clearZones()
  local w, h = mon.getSize()
  mon.setBackgroundColor(COLOR.bg)
  mon.clear()

  -- Title bar
  mon.setBackgroundColor(COLOR.header)
  for row = 1, 1 do
    mon.setCursorPos(1, row); mon.write(string.rep(" ", w))
  end
  centerText(1, "STORAGE NETWORK MONITOR", COLOR.title)
  mon.setBackgroundColor(COLOR.bg)

  -- Stats line
  local rate = itemsPerMinute()
  local rateStr = (rate >= 0 and "+" or "") .. fmt(rate) .. "/min"
  local rateColor = rate >= 0 and COLOR.good or COLOR.bad
  local statLine1 = ("Vaults/Networks: %d   Unique Items: %s   Total Items: %s")
      :format(#sources, fmt(uniqueItems), fmt(totalItems))
  writeAt(2, 3, statLine1, COLOR.text)
  writeAt(2, 4, "Throughput: ", COLOR.text)
  writeAt(14, 4, rateStr, rateColor)

  local lowCount = 0
  for _, rec in pairs(items) do
    if rec.count < CONFIG.lowStockThreshold then lowCount = lowCount + 1 end
  end
  writeAt(28, 4, ("Low stock (<%d): %d"):format(CONFIG.lowStockThreshold, lowCount),
    lowCount > 0 and COLOR.warn or COLOR.dim)

  if not lastScanOk then
    writeAt(2, 5, "! Scan error: " .. tostring(lastScanErr), COLOR.bad)
  end

  -- Trend graph
  local graphY, graphH = 6, 4
  writeAt(2, graphY - 1, "Total item trend:", COLOR.dim)
  drawBarGraph(2, graphY, math.min(w - 3, 60), graphH, history)

  -- Source tabs
  local tabY = graphY + graphH + 1
  local tx = 2
  local function drawTab(label, active, action)
    local bg = active and COLOR.buttonOn or COLOR.button
    writeAt(tx, tabY, " " .. label .. " ", COLOR.title, bg)
    registerZone(tx, tabY, tx + #label + 1, action)
    tx = tx + #label + 3
  end
  drawTab("All", ui.activeTab == 0, { type = "tab", value = 0 })
  for i, src in ipairs(sources) do
    drawTab(src.label, ui.activeTab == i, { type = "tab", value = i })
  end

  -- Column header / sort buttons
  local listTop = tabY + 2
  local function sortBtn(label, x, mode)
    local active = ui.sortMode == mode
    writeAt(x, listTop, label, active and COLOR.accent or COLOR.dim)
    registerZone(x, listTop, x + #label - 1, { type = "sort", value = mode })
  end
  sortBtn("Item", 2, "name")
  sortBtn("Qty", 30, "qty")
  sortBtn("% of total", 40, "pct")
  writeAt(52, listTop, "Sources", COLOR.dim)

  -- Item rows
  local rowsAvailable = h - listTop - 2 -- leave room for footer
  local perPage = CONFIG.itemsPerPage or rowsAvailable
  local list = sortedFilteredItems()
  local totalPages = math.max(1, math.ceil(#list / perPage))
  if ui.page > totalPages then ui.page = totalPages end
  local startIdx = (ui.page - 1) * perPage + 1

  for i = 0, perPage - 1 do
    local idx = startIdx + i
    local rec = list[idx]
    local y = listTop + 1 + i
    if rec then
      local pct = totalItems > 0 and (rec.count / totalItems * 100) or 0
      local nameStr = rec.displayName
      if #nameStr > 26 then nameStr = nameStr:sub(1, 25) .. "…" end
      local color = rec.count < CONFIG.lowStockThreshold and COLOR.warn or COLOR.text
      writeAt(2, y, nameStr, color)
      writeAt(30, y, fmt(rec.count), color)
      writeAt(40, y, string.format("%.1f%%", pct), COLOR.dim)
      local srcCount = 0
      for _ in pairs(rec.perSource) do srcCount = srcCount + 1 end
      writeAt(52, y, tostring(srcCount), COLOR.dim)
    end
  end

  -- Footer: pagination + movers + search state
  local footY = h - 1
  local pageLabel = ("Page %d/%d"):format(ui.page, totalPages)
  writeAt(2, footY, "[ < Prev ]", COLOR.title, COLOR.button)
  registerZone(2, footY, 11, { type = "page", value = -1 })
  writeAt(13, footY, pageLabel, COLOR.dim)
  writeAt(13 + #pageLabel + 2, footY, "[ Next > ]", COLOR.title, COLOR.button)
  registerZone(13 + #pageLabel + 2, footY, 13 + #pageLabel + 11, { type = "page", value = 1 })

  if ui.searchTerm then
    writeAt(35, footY, "Filter: " .. ui.searchTerm, COLOR.accent)
  end

  local scanAgeSec = math.floor((os.epoch("utc") - lastScanTime) / 1000)
  writeAt(2, h, ("Last scan: %ds ago | refresh every %ds"):format(scanAgeSec, CONFIG.refreshInterval), COLOR.dim)

  mon.setVisible(true)
end

--------------------------------------------------------------------------
-- Terminal command interface
--------------------------------------------------------------------------

local function printHelp()
  print("Commands:")
  print("  search <text>   - filter items by name")
  print("  clear           - clear filter")
  print("  sort name|qty|pct")
  print("  sources         - list connected vault networks")
  print("  refresh         - force an immediate rescan")
  print("  help            - show this message")
end

local function printSources()
  print(("%d source(s) connected:"):format(#sources))
  for i, s in ipairs(sources) do
    print(("  [%d] %s  (%s, peripheral: %s)"):format(i, s.label, s.kind, s.name))
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
        ui.searchTerm = rest
        ui.page = 1
        print("Filtering: " .. rest)
      elseif cmd == "clear" then
        ui.searchTerm = nil
        ui.page = 1
        print("Filter cleared.")
      elseif cmd == "sort" then
        if rest == "name" or rest == "qty" or rest == "pct" then
          ui.sortMode = rest
          print("Sort mode: " .. rest)
        else
          print("Usage: sort name|qty|pct")
        end
      elseif cmd == "sources" then
        printSources()
      elseif cmd == "refresh" then
        scanAll()
        print("Rescanned.")
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
      if a.type == "tab" then
        ui.activeTab = a.value
        ui.page = 1
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