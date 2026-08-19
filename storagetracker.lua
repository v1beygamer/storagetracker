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