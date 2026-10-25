--!nonstrict

local CATEGORIES = {
  { id = "smileys",  label = "Smileys & People", glyph = "mood-smile" },
  { id = "animals",  label = "Animals & Nature", glyph = "paw" },
  { id = "food",     label = "Food & Drink",     glyph = "apple" },
  { id = "activity", label = "Activities",       glyph = "ball-football" },
  { id = "travel",   label = "Travel & Places",  glyph = "map" },
  { id = "objects",  label = "Objects",          glyph = "device-floppy" },
  { id = "symbols",  label = "Symbols",          glyph = "at" },
  { id = "chars",    label = "Characters",       glyph = "math-symbols" },
  { id = "flags",    label = "Flags",            glyph = "flag" },
}

local M = {}

local TIERS = {
  { cols = 9, cell = 72, glyph = 34, panel = 780 }, -- wide
  { cols = 8, cell = 66, glyph = 30, panel = 640 }, -- desktop
  { cols = 6, cell = 58, glyph = 26, panel = 480 }, -- compact
}

local GAP = 6

local TILE_CHROME = 0
local SCROLLBAR_GUTTER = 24
local ROOT_PADDING = 8
local HOST_PADDING = 16

local function fitGrid(availableWidth, gap, wantCols, wantCell)
  local budget = availableWidth - SCROLLBAR_GUTTER
  local cell = wantCell + TILE_CHROME
  local cols = math.min(wantCols, math.floor((budget + gap) / (cell + gap)))
  if cols < 1 then
    cols = 1
  end
  cell = math.floor((budget - (cols - 1) * gap) / cols)
  return cols, cell
end

local PANEL_WIDTH_BY_ID = { wide = 780, desktop = 640, compact = 480 }
local fitWidth = PANEL_WIDTH_BY_ID.compact -- replaced by the shim's width at onOpen
local MAX_SEARCH_RESULTS = 300
local RECENCY_HALF_LIFE_DAYS = 14.0

local data = nil -- dataset array; published only by a fully successful load
local byCat = nil -- { [catId] = {entry, …} } browse list (no skin-tone variants)
local emojiIndex = nil -- { [emoji] = entry }
local loadError = nil -- why the last load attempt failed; nil once loaded
local usage = nil -- { [emoji] = { c = count, t = last_used_epoch_s } }
local usagePath = nil

local tier = TIERS[1]

local gridCols, gridCell, gridRowWidth
local function applyGridFit()
  local avail = fitWidth - 2 * (HOST_PADDING + ROOT_PADDING)
  gridCols, gridCell = fitGrid(avail, GAP, tier.cols, tier.cell)
  gridRowWidth = avail - SCROLLBAR_GUTTER
end
applyGridFit()

local cat = "smileys" -- browse category; "all" renders every section (slower)
local query = ""
local inputKey = 0 -- bump to recreate the input (clears its host-owned buffer)
local items = {} -- flat item list for the current view (entry tables)
local rows = {} -- { { base = first item index, len = n }, … }
local rowOfItem = {} -- item index -> row index
local sel = 0 -- focused item index into `items` (0 = none)

local INITIAL_RENDER_ROWS = 8
local RENDER_ROWS_STEP = 10
local renderLimit = INITIAL_RENDER_ROWS

local function nowSec()
  return noctalia.nowMs() / 1000.0
end

local function loadUsage()
  usage = {}
  if usagePath == nil then
    local dir = noctalia.pluginDataDir()
    if dir == "" then
      return
    end
    usagePath = dir .. "/usage.json"
  end
  local content = noctalia.readFile(usagePath)
  if type(content) == "string" then
    local ok, parsed = pcall(noctalia.json.decode, content)
    if ok and type(parsed) == "table" then
      for emoji, u in pairs(parsed) do
        if type(u) == "table" and type(u.c) == "number" and type(u.t) == "number" then
          usage[emoji] = { c = u.c, t = u.t }
        end
      end
    end
  end
end

local function saveUsage()
  if usagePath ~= nil then
    local dir = usagePath:match("^(.*)/")
    if dir ~= nil then
      noctalia.mkdirAll(dir)
    end
    pcall(function()
      noctalia.writeFile(usagePath, noctalia.json.encode(usage))
    end)
  end
end

local function frecencyScore(count, lastUsed, now)
  if count <= 0 then
    return 0.0
  end
  local ageDays = math.max(0.0, now - lastUsed) / 86400.0
  return count * (0.5 ^ (ageDays / RECENCY_HALF_LIFE_DAYS))
end

local function frecency(emoji, now)
  local u = usage[emoji]
  if u == nil then
    return 0.0
  end
  return frecencyScore(u.c, u.t, now)
end

local function ensureData()
  if data ~= nil then
    return
  end
  local ok, err = pcall(function()
    local content, readErr = noctalia.readFile("assets/emoji.json")
    if type(content) ~= "string" then
      error(readErr or "cannot read assets/emoji.json", 0)
    end
    local decoded, decodeErr = noctalia.json.decode(content)
    if type(decoded) ~= "table" then
      error(decodeErr or "dataset is not a JSON array", 0)
    end
    if #decoded == 0 then
      error("dataset is empty", 0)
    end
    local nextByCat = {}
    local nextEmojiIndex = {}
    for _, e in ipairs(decoded) do
      local z = e.l
      for _, k in ipairs(e.k) do
        z ..= " " .. k
      end
      if e.a ~= nil then
        for _, x in ipairs(e.a) do
          z ..= " " .. x
        end
      end
      e.z = z
      nextEmojiIndex[e.e] = e
      if string.find(e.n, "skin tone", 1, true) == nil then
        local list = nextByCat[e.c]
        if list == nil then
          list = {}
          nextByCat[e.c] = list
        end
        table.insert(list, e)
      end
    end
    data = decoded
    byCat = nextByCat
    emojiIndex = nextEmojiIndex
  end)
  if ok then
    loadError = nil
  else
    loadError = tostring(err)
    noctalia.log("emoji-picker: dataset failed to load: " .. loadError)
  end
end

ensureData()

local function recents(now, n)
  if emojiIndex == nil then
    return {}
  end
  local scored = {}
  for emoji, u in pairs(usage) do
    if emojiIndex[emoji] ~= nil and u.c > 0 then
      table.insert(scored, { emoji = emoji, score = frecencyScore(u.c, u.t, now) })
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.emoji < b.emoji
  end)
  local out = {}
  for i = 1, math.min(n, #scored) do
    table.insert(out, emojiIndex[scored[i].emoji])
  end
  return out
end

local function isWordBoundaryMatch(n, w)
  local from = 1
  while true do
    local s = string.find(n, w, from, true)
    if s == nil then
      return false
    end
    if s == 1 or string.sub(n, s - 1, s - 1) == " " then
      return true
    end
    from = s + 1
  end
end

local function nameWordCount(n)
  local count = 0
  for _ in string.gmatch(n, "%S+") do
    count += 1
  end
  return count
end

local function wordTier(entry, w)
  if entry.e == w then
    return 1100
  end
  if string.find(entry.z, w, 1, true) == nil then
    return 0
  end
  local single = #w == 1
  local symbol = entry.s == 1
  local n = entry.l
  local best = 0
  if symbol and entry.a ~= nil then
    for _, x in ipairs(entry.a) do
      if x == w then
        best = 1000
        break
      end
    end
  end
  if best < 1000 and n == w then
    best = 1000
  end
  if best < 900 and isWordBoundaryMatch(n, w) then
    best = if symbol then 900 else 700
  end
  if best < 900 and symbol and entry.a ~= nil then
    for _, x in ipairs(entry.a) do
      if isWordBoundaryMatch(x, w) then
        best = 900
        break
      end
    end
  end
  if best < 450 then
    for _, k in ipairs(entry.k) do
      local t = 0
      if k == w then
        t = 450
      elseif single then
        t = 0
      elseif #k >= #w and string.sub(k, 1, #w) == w then
        t = 150
      elseif string.find(k, w, 1, true) then
        t = 80
      end
      if t > best then
        best = t
      end
    end
  end
  if string.find(n, w, 1, true) then
    best = math.max(best, if symbol then 500 else 250)
  end
  return best
end

local function search(now)
  if data == nil then
    return {}
  end
  local words = {}
  for w in string.gmatch(string.lower(query), "%S+") do
    table.insert(words, w)
  end
  local scored = {}
  local minKeptTier = 1200
  for idx, e in ipairs(data) do
    local tierScore = 1000
    for _, w in ipairs(words) do
      local t = wordTier(e, w)
      if t == 0 then
        tierScore = 0
        break
      end
      if t < tierScore then
        tierScore = t
      end
    end
    if tierScore > 0 and (#scored < MAX_SEARCH_RESULTS or tierScore > minKeptTier) then
      local f = frecency(e.e, now)
      if f > 25 then
        f = 25 -- cap the tie-breaker: usage never outranks relevance
      end
      table.insert(
        scored,
        { e = e, tier = tierScore, s = e.s == 1, nwords = nameWordCount(e.l), nlen = #e.l, f = f, i = idx }
      )
      if tierScore < minKeptTier then
        minKeptTier = tierScore
      end
    end
  end
  table.sort(scored, function(a, b)
    if a.tier ~= b.tier then
      return a.tier > b.tier
    end
    if a.s ~= b.s then
      return a.s
    end
    if a.nwords ~= b.nwords then
      return a.nwords < b.nwords
    end
    if a.nlen ~= b.nlen then
      return a.nlen < b.nlen
    end
    if a.f ~= b.f then
      return a.f > b.f
    end
    return a.i < b.i
  end)
  local out = {}
  for i = 1, math.min(MAX_SEARCH_RESULTS, #scored) do
    table.insert(out, scored[i].e)
  end
  return out
end

local function searchActive()
  return string.find(query, "%S") ~= nil
end

local function buildView()
  ensureData()
  items = {}
  rows = {}
  rowOfItem = {}

  local function addSection(entries)
    for base = 1, #entries, gridCols do
      local len = math.min(gridCols, #entries - base + 1)
      local rowIndex = #rows + 1
      rows[rowIndex] = { base = #items + 1, len = len }
      for i = base, base + len - 1 do
        rowOfItem[#items + 1] = rowIndex
        table.insert(items, entries[i])
      end
    end
  end

  if searchActive() then
    addSection(search(nowSec()))
  else
    local recent = recents(nowSec(), gridCols * 2)
    if #recent > 0 then
      addSection(recent)
    end
    local catData = byCat or {}
    if cat == "all" then
      for _, c in ipairs(CATEGORIES) do
        addSection(catData[c.id] or {})
      end
    else
      addSection(catData[cat] or {})
    end
  end

  if sel < 1 or sel > #items then
    sel = if #items > 0 then 1 else 0
  end
  renderLimit = math.min(#rows, INITIAL_RENDER_ROWS)
end

local function ensureRowRendered(rowIndex)
  if rowIndex > renderLimit then
    renderLimit = math.min(#rows, rowIndex)
  end
end

local function moveSelection(dr, dc)
  if #items == 0 then
    return
  end
  if dr == 0 then
    sel = math.min(#items, math.max(1, sel + dc))
  else
    local row = rowOfItem[sel] or 1
    local col = sel - rows[row].base + 1
    local target = math.min(#rows, math.max(1, row + dr))
    col = math.min(col, rows[target].len)
    sel = rows[target].base + col - 1
  end
  ensureRowRendered(rowOfItem[sel] or 1)
end

local function shellQuote(s)
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function pasteWithConfiguredCommand(emoji)
  local cmd = noctalia.getConfig("paste_command")
  if type(cmd) ~= "string" or cmd == "" then
    return
  end
  local quoted = shellQuote(emoji)
  noctalia.runAsync((string.gsub(cmd, "{emoji}", function()
    return quoted
  end)))
end

local function commit(entry)
  if entry == nil then
    return
  end
  local now = nowSec()
  local u = usage[entry.e]
  if u == nil then
    u = { c = 0, t = now }
    usage[entry.e] = u
  end
  u.c += 1
  u.t = now
  saveUsage()
  noctalia.copyToClipboard(entry.e, "text/plain;charset=utf-8")
  pasteWithConfiguredCommand(entry.e)
  panel.close()
end

local render -- forward declaration (closures below call it)

local function tile(entry, idx)
  return ui.button({
    key = "t" .. tostring(idx),
    text = entry.e,
    fontSize = math.floor(gridCell * tier.glyph / (tier.cell + TILE_CHROME)),
    width = gridCell - TILE_CHROME,
    height = gridCell - TILE_CHROME,
    contentAlign = "center",
    tooltip = entry.n,
    onClick = function()
      commit(entry)
    end,
    onHover = function()
      if sel ~= idx then
        sel = idx
        render()
      end
    end,
  })
end

local function sectionBlock(label, entries, startIndex, budget)
  local children = {}
  if label ~= nil then
    table.insert(children, ui.label({
      key = "h" .. label,
      text = label,
      width = gridRowWidth,
      textAlign = "left",
      fontSize = 11,
      fontWeight = "semibold",
      color = "on_surface_variant",
    }))
  end
  if #entries == 0 then
    return children
  end
  for base = 1, #entries, gridCols do
    if budget.remaining <= 0 then
      break
    end
    local rowChildren = {}
    for i = base, math.min(base + gridCols - 1, #entries) do
      table.insert(rowChildren, tile(entries[i], startIndex + i - 1))
    end
    table.insert(children, ui.row({
      key = "r" .. tostring(startIndex) .. "-" .. tostring(base),
      width = gridRowWidth,
      gap = GAP,
      align = "center",
      justify = "center",
    }, rowChildren))
    budget.remaining -= 1
  end
  return children
end

local function categoryStrip()
  local buttons = {}
  local function catButton(id, glyph, label)
    table.insert(buttons, ui.button({
      key = "cat-" .. id,
      glyph = glyph,
      glyphSize = 18,
      variant = if cat == id then "secondary" else "ghost",
      width = 34,
      height = 30,
      tooltip = label,
      onClick = function()
        cat = id
        query = ""
        inputKey += 1 -- recreate the input: clears its host-owned buffer
        sel = 1
        buildView()
        render()
      end,
    }))
  end
  catButton("all", "layout-grid", "All")
  for _, c in ipairs(CATEGORIES) do
    catButton(c.id, c.glyph, c.label)
  end
  return ui.row({ key = "cats", gap = 2, align = "center",
    justify = "center" }, buttons)
end

local function gridArea()
  if data == nil then
    return ui.column({
      key = "load-error",
      align = "center",
      justify = "center",
      flexGrow = 1,
      gap = 8,
    }, {
      ui.glyph({ name = "alert-triangle", size = 28, color = "on_surface_variant" }),
      ui.label({ text = "Emoji dataset failed to load", color = "on_surface_variant" }),
      ui.label({
        text = loadError or "",
        fontSize = 11,
        color = "on_surface_variant",
        maxLines = 2,
        textAlign = "center",
      }),
    })
  end
  if #items == 0 then
    local message = if searchActive() then "No results found" else "No results"
    return ui.column({
      key = "empty",
      align = "center",
      justify = "center",
      flexGrow = 1,
      gap = 8,
    }, {
      ui.glyph({ name = "search", size = 28, color = "on_surface_variant" }),
      ui.label({ text = message, color = "on_surface_variant" }),
    })
  end

  local children = {}
  local budget = { remaining = renderLimit }
  if searchActive() then
    local section = {}
    for i = 1, #items do
      table.insert(section, items[i])
    end
    for _, b in ipairs(sectionBlock(nil, section, 1, budget)) do
      table.insert(children, b)
    end
  else
    local startIndex = 1
    local recent = recents(nowSec(), gridCols * 2)
    if #recent > 0 then
      for _, b in ipairs(sectionBlock("Frequently Used", recent, startIndex, budget)) do
        table.insert(children, b)
      end
      startIndex += #recent
    end
    local sections = {}
    if cat == "all" then
      for _, c in ipairs(CATEGORIES) do
        table.insert(sections, { label = c.label, entries = byCat[c.id] or {} })
      end
    else
      for _, c in ipairs(CATEGORIES) do
        if c.id == cat then
          table.insert(sections, { label = c.label, entries = byCat[c.id] or {} })
        end
      end
    end
    for _, s in ipairs(sections) do
      for _, b in ipairs(sectionBlock(s.label, s.entries, startIndex, budget)) do
        table.insert(children, b)
      end
      startIndex += #s.entries
    end
  end

  return ui.scroll({
    key = "grid-" .. (if searchActive() then "search" else cat),
    flexGrow = 1,
    gap = GAP,
    align = "center",
    paddingH = SCROLLBAR_GUTTER / 2,
    onScroll = function(offset, maxOffset)
      local off = tonumber(offset) or 0
      local mx = tonumber(maxOffset) or 0
      if renderLimit < #rows and mx - off < 400 then
        renderLimit = math.min(#rows, renderLimit + RENDER_ROWS_STEP)
        render()
      end
    end,
  }, children)
end

local function footer()
  local entry = items[sel]
  local emoji = if entry ~= nil then entry.e else ""
  local name = if entry ~= nil
    then entry.n
    elseif data == nil then "Dataset failed to load"
    elseif searchActive() then "No results found" else "Type to search"
  return ui.column({ key = "footer", gap = 8 }, {
    ui.separator({ key = "foot-sep" }),
    ui.row({ key = "foot-row", align = "center", gap = 10 }, {
      ui.label({ key = "foot-emoji", text = emoji, fontSize = 16, width = 24 }),
      ui.label({
        key = "foot-name",
        text = name,
        fontSize = 12,
        color = "on_surface_variant",
        flexGrow = 1,
        maxLines = 1,
      }),
      ui.label({
        key = "foot-hint",
        text = "Enter  Select      Esc  Close",
        fontSize = 11,
        color = "on_surface_variant",
      }),
    }),
  })
end

render = function()
  local children = {}
  table.insert(children, ui.input({
    key = "q-" .. tostring(inputKey),
    value = query,
    placeholder = "Search Emoji & Symbols…",
    fontSize = 15,
    focus = true,
    controlSize = "lg",
    onChange = function(value)
      query = if type(value) == "string" then value else ""
      sel = 1
      buildView()
      render()
    end,
  }))
  if not searchActive() then
    table.insert(children, categoryStrip())
  end
  table.insert(children, gridArea())
  table.insert(children, footer())
  panel.render(ui.column({
    key = "root",
    flexGrow = 1,
    align = "stretch",
    gap = 10,
    padding = ROOT_PADDING,
  }, children))
end

local function tierForWidth(width)
  for _, t in ipairs(TIERS) do
    if t.panel == width then
      return t
    end
  end
  return TIERS[#TIERS]
end

function M.onOpen(entryWidth)
  ensureData()
  loadUsage()
  fitWidth = if type(entryWidth) == "number" then entryWidth
    else PANEL_WIDTH_BY_ID.compact
  tier = tierForWidth(fitWidth)
  applyGridFit()
  query = ""
  cat = "smileys"
  inputKey += 1 -- fresh input: empty buffer, immediate focus
  sel = 1
  buildView()
  render()
end

function M.onKey(chord, pressed)
  if not pressed then
    return
  end
  if chord == "left" then
    moveSelection(0, -1)
  elseif chord == "right" then
    moveSelection(0, 1)
  elseif chord == "up" then
    moveSelection(-1, 0)
  elseif chord == "down" then
    moveSelection(1, 0)
  elseif chord == "enter" then
    commit(items[sel])
    return
  end
  render()
end

return M
