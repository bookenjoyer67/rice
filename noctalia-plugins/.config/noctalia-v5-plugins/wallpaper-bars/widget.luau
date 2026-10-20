--!nonstrict
-- wallpaper-bars desktop widget.
--
-- One ui.box per spectrum band, bottom-aligned, tinted with the wallpaper
-- colour the service sampled behind that bar. Bars are frame-ticked and
-- smoothed, and the tick loop shuts itself off when the music stops (the
-- service's level feed wakes it again), so an idle desktop costs nothing.

local function num(v, d)
  local n = tonumber(v)
  if n == nil then
    return d
  end
  return n
end

local N = math.clamp(math.floor(num(noctalia.getConfig("bands"), 64)), 8, 128)
local W = math.max(40, num(noctalia.getConfig("width"), 1360))
local H = math.max(20, num(noctalia.getConfig("height"), 768))
local GAP = math.max(0, num(noctalia.getConfig("gap"), 3))
local RADIUS = math.max(0, num(noctalia.getConfig("radius"), 4))
local MODE = noctalia.getConfig("color_mode") or "tip"
-- which output this widget sits on; empty falls back to a canvas-size match
local MONITOR = noctalia.getConfig("monitor") or ""
local BRIGHT = math.clamp(num(noctalia.getConfig("brightness"), 0.22), 0, 1)
local SAT = math.clamp(num(noctalia.getConfig("saturation"), 1.35), 0, 3)
local MIN_LIGHT = math.clamp(num(noctalia.getConfig("min_light"), 0.40), 0, 1)
local ALPHA = math.clamp(num(noctalia.getConfig("bar_opacity"), 0.92), 0.05, 1)
local SMOOTH_MS = math.max(0, num(noctalia.getConfig("smoothing"), 45))
local FADE = noctalia.getConfig("fade_when_idle") ~= false
local IDLE_MS = math.max(1, num(noctalia.getConfig("idle_seconds"), 6)) * 1000

local MIN_BAR = math.max(2, H * 0.004)
local BAR_W = math.max(1, (W - GAP * (N - 1)) / N)
local BAR_R = math.min(RADIUS, BAR_W / 2)
local ALPHA_HEX = string.format("%02x", math.floor(ALPHA * 255 + 0.5))

local levels = {}
local targets = {}
local grid = nil
local opacity = 1
local idleMs = 0
local ticking = false

for i = 1, N do
  levels[i] = 0
  targets[i] = 0
end

-- ---------------------------------------------------------------- colour

local function rgbToHsv(r, g, b)
  local maxc = math.max(r, g, b)
  local minc = math.min(r, g, b)
  local d = maxc - minc
  local h = 0
  if d > 1e-6 then
    if maxc == r then
      h = ((g - b) / d) % 6
    elseif maxc == g then
      h = (b - r) / d + 2
    else
      h = (r - g) / d + 4
    end
    h = h / 6
  end
  local s = 0
  if maxc > 1e-6 then
    s = d / maxc
  end
  return h, s, maxc
end

local function hsvToRgb(h, s, v)
  local i = math.floor(h * 6)
  local f = h * 6 - i
  local p = v * (1 - s)
  local q = v * (1 - f * s)
  local t = v * (1 - (1 - f) * s)
  i = i % 6
  if i == 0 then
    return v, t, p
  elseif i == 1 then
    return q, v, p
  elseif i == 2 then
    return p, v, t
  elseif i == 3 then
    return p, q, v
  elseif i == 4 then
    return t, p, v
  end
  return v, p, q
end

-- Lift/saturate a wallpaper colour just enough that the bar reads against the
-- very pixels it was sampled from.
local function tint(rgb)
  local r = (rgb // 65536) % 256 / 255
  local g = (rgb // 256) % 256 / 255
  local b = (rgb % 256) / 255
  local h, s, v = rgbToHsv(r, g, b)
  s = math.clamp(s * SAT, 0, 1)
  v = math.clamp(v + (1 - v) * BRIGHT, 0, 1)
  if v < MIN_LIGHT then
    v = MIN_LIGHT
  end
  r, g, b = hsvToRgb(h, s, v)
  return string.format("#%02x%02x%02x%s", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
    math.floor(b * 255 + 0.5), ALPHA_HEX)
end

local FALLBACK = { "#8fd6ff", "#a9b8ff", "#d0b3ff", "#ffc6e0" }
local fallbackI = 0
-- Colour strings are the expensive part of a frame (HSV math + formatting), and
-- a bar keeps the same sampled pixel for many frames: cache per bar until the
-- row it points at changes.
local colorCache = {}

local function barColor(i, level)
  if grid == nil or type(grid.data) ~= "table" then
    fallbackI = fallbackI % #FALLBACK + 1
    return FALLBACK[fallbackI] .. ALPHA_HEX
  end
  local rows = tonumber(grid.rows) or 1
  local cols = tonumber(grid.cols) or N
  -- map this bar onto the sampled columns proportionally, so a widget whose
  -- band count was changed on its own still lines up with the wallpaper
  local col = math.floor((i - 0.5) / N * cols) + 1
  col = math.clamp(col, 1, cols)

  local row
  if MODE == "floor" then
    row = rows
  elseif MODE == "body" then
    -- middle of the drawn bar
    row = 1 + math.floor((1 - level * 0.5) * (rows - 1) + 0.5)
  else
    -- tip of the bar: the colour climbs the image with the music
    row = 1 + math.floor((1 - level) * (rows - 1) + 0.5)
  end
  row = math.clamp(row, 1, rows)

  local key = row * 1024 + col
  local cached = colorCache[i]
  if cached ~= nil and cached.key == key then
    return cached.hex
  end

  local rgb = tonumber(grid.data[(row - 1) * cols + col])
  local hex = rgb ~= nil and tint(rgb) or (FALLBACK[1] .. ALPHA_HEX)
  colorCache[i] = { key = key, hex = hex }
  return hex
end

-- ---------------------------------------------------------------- render

local lastHeights = {}
local lastOpacity = -1

local function render(force)
  local changed = force == true or math.abs(opacity - lastOpacity) > 0.002
  for i = 1, N do
    local h = MIN_BAR + (levels[i] or 0) * (H - MIN_BAR)
    if math.abs(h - (lastHeights[i] or -1)) > 0.5 then
      changed = true
    end
    lastHeights[i] = h
  end
  if not changed then
    return
  end
  lastOpacity = opacity

  local kids = {}
  for i = 1, N do
    local h = lastHeights[i]
    kids[i] = ui.box({
      key = "b" .. i,
      width = BAR_W,
      height = h,
      radius = BAR_R,
      fill = barColor(i, (h - MIN_BAR) / (H - MIN_BAR)),
    })
  end
  desktopWidget.render(ui.row({
    width = W,
    height = H,
    gap = GAP,
    align = "end",
    opacity = opacity,
  }, kids))
end

local function setTicking(on)
  if on ~= ticking then
    ticking = on
    desktopWidget.setNeedsFrameTick(on)
  end
end

-- ---------------------------------------------------------------- state

local function maxOf(t)
  local m = 0
  for i = 1, N do
    local v = t[i]
    if v ~= nil and v > m then
      m = v
    end
  end
  return m
end

noctalia.state.watch("levels", function(value)
  if type(value) ~= "table" then
    return
  end
  for i = 1, N do
    local v = tonumber(value[i])
    targets[i] = v and math.clamp(v, 0, 1) or 0
  end
  if maxOf(targets) > 0.002 then
    idleMs = 0
    setTicking(true)
  end
end)

-- the service publishes one grid per output; take ours by monitor name, else
-- the one whose output geometry matches this canvas
local function pickGrid(all)
  if type(all) ~= "table" then
    return nil
  end
  if MONITOR ~= "" and type(all[MONITOR]) == "table" then
    return all[MONITOR]
  end
  for _, g in pairs(all) do
    if type(g) == "table" and tonumber(g.w) == W and tonumber(g.h) == H then
      return g
    end
  end
  for _, g in pairs(all) do
    if type(g) == "table" and g.data ~= nil then
      return g
    end
  end
  return nil
end

noctalia.state.watch("grids", function(value)
  local picked = pickGrid(value)
  if picked ~= nil then
    grid = picked
    colorCache = {}
    render(true)
  end
end)

function onFrameTick(deltaMs)
  local dt = tonumber(deltaMs) or 16
  local k = 1
  if SMOOTH_MS > 0 then
    k = 1 - math.exp(-dt / SMOOTH_MS)
  end
  local peak = 0
  for i = 1, N do
    local t = targets[i] or 0
    local nextv = levels[i] + (t - levels[i]) * k
    levels[i] = nextv
    if nextv > peak then
      peak = nextv
    end
  end

  local want = 1
  if FADE then
    if peak < 0.003 then
      idleMs += dt
    else
      idleMs = 0
    end
    if idleMs > IDLE_MS then
      want = 0
    end
  end
  opacity = opacity + (want - opacity) * math.min(1, dt / 220)

  if FADE and want == 0 and opacity < 0.02 then
    opacity = 0
    render()
    setTicking(false)
    return
  end
  render()
end

-- seed the first frame (grids may still be empty for a moment)
grid = pickGrid(noctalia.state.get("grids"))
noctalia.log(string.format("wallpaper-bars: canvas %dx%d monitor='%s' grid=%s", W, H, MONITOR,
  grid and (tostring(grid.cols) .. "x" .. tostring(grid.rows)) or "none"))
render(true)
setTicking(true)
