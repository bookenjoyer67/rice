--!nonstrict
-- Per-core CPU monitor for the TV tile: one index + percentage per core,
-- sampled once a second from /proc/stat.
--
-- The desktop-widget host lays the tree out in "natural" units and then fits it
-- to the tile's box (measured ~0.6 on this output), so the layout below is
-- written at 1/0.6 of the real 200x128 tile and fills it exactly.

local MONO = "MesloLGL Nerd Font Mono"

local COLS     = 3
local TILE_W   = 200          -- box_width  in settings.toml
local TILE_H   = 128          -- box_height in settings.toml
local SCALE    = 0.6          -- host fit factor
local W        = math.floor(TILE_W / SCALE)   -- 333 natural units
local H        = math.floor(TILE_H / SCALE)   -- 213 natural units
local COL_GAP  = 40
local ROW_GAP  = 2
local COL_W    = math.floor((W - COL_GAP) / COLS)
local F_IDX    = 16
local F_PCT    = 28

local corePct = {}
local nCores = 0

local prevCores = nil
local inFlight, inFlightAt = false, 0
local lastKey = ""

local function nowMs()
  return (desktopWidget.timeMs and desktopWidget.timeMs()) or os.clock() * 1000
end

local function pctOf(cur, prev)
  if cur == nil or prev == nil then return 0 end
  local dt = cur.total - prev.total
  local di = cur.idle - prev.idle
  if dt <= 0 then return 0 end
  local p = math.floor((dt - di) * 100 / dt + 0.5)
  if p < 0 then p = 0 end
  if p > 100 then p = 100 end
  return p
end

local function parseStat(txt)
  local cores = {}
  for line in tostring(txt or ""):gmatch("[^\n]+") do
    local name, rest = line:match("^(cpu%d+)%s+(.*)$")
    if name then
      local vals = {}
      for n in rest:gmatch("%d+") do vals[#vals + 1] = tonumber(n) end
      if #vals >= 4 then
        local idx = tonumber(name:match("cpu(%d+)"))
        if idx then
          cores[idx + 1] = {
            idle = (vals[4] or 0) + (vals[5] or 0),
            total = (function()
              local t = 0
              for i = 1, math.min(#vals, 8) do t = t + vals[i] end
              return t
            end)(),
          }
        end
      end
    end
  end
  return cores
end

local function colorFor(p)
  if p >= 85 then return "error" end
  if p >= 50 then return "tertiary" end
  return "primary"
end

local function cell(idx, p)
  return ui.row({ key = "c" .. idx, width = COL_W, gap = 6, align = "center", justify = "space_between" }, {
    ui.label({
      key = "c" .. idx .. "n",
      text = string.format("%d", idx),
      fontSize = F_IDX,
      fontFamily = MONO,
      color = "on_surface_variant",
    }),
    ui.label({
      key = "c" .. idx .. "p",
      text = string.format("%d%%", p),
      fontSize = F_PCT,
      fontWeight = "bold",
      color = colorFor(p),
    }),
  })
end

local function render()
  local cols = {}
  for c = 1, COLS do cols[c] = {} end
  for idx = 0, nCores - 1 do
    local c = (idx % COLS) + 1
    cols[c][#cols[c] + 1] = cell(idx, corePct[idx + 1] or 0)
  end

  local columnNodes = {}
  for c = 1, COLS do
    columnNodes[c] = ui.column({ key = "col" .. c, width = COL_W, gap = ROW_GAP, align = "start" }, cols[c])
  end

  desktopWidget.render(ui.column({
    width = W,
    height = H,
    justify = "center",
    align = "center",
  }, {
    ui.row({ key = "grid", width = W, gap = COL_GAP, align = "center", justify = "center" }, columnNodes),
  }))
end

local function stateKey()
  local parts = {}
  for i = 1, nCores do parts[#parts + 1] = tostring(corePct[i] or 0) end
  return table.concat(parts, ",")
end

local function refresh()
  local now = nowMs()
  if inFlight and (now - inFlightAt) < 5000 then return end
  inFlight, inFlightAt = true, now

  noctalia.runAsync({ "cat", "/proc/stat" }, function(result)
    inFlight = false
    if result == nil or result.exitCode ~= 0 then return end

    local cores = parseStat(result.stdout)
    local n = #cores
    if n <= 0 then return end

    if prevCores ~= nil then
      for i = 1, n do corePct[i] = pctOf(cores[i], prevCores[i]) end
    end
    nCores = n
    prevCores = cores

    local key = stateKey()
    if key ~= lastKey then
      lastKey = key
      render()
    end
  end)
end

function update()
  refresh()
end

render()
refresh()
desktopWidget.setWantsSecondTicks(true)
