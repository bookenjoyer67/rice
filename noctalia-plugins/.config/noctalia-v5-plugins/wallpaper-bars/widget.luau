--!nonstrict
-- wallpaper-bars desktop widget.
--
-- One ui.box per spectrum band, bottom-aligned, tinted with the wallpaper
-- colour the service sampled behind that bar. With `blur` on, each bar is a
-- nested stack of translucent capsules so it melts into coloured mist. Bars
-- are frame-ticked and smoothed, and the tick loop shuts itself off when the
-- music stops (the service's level feed wakes it again), so an idle desktop
-- costs nothing.

local function num(v, d)
  local n = tonumber(v)
  if n == nil then
    return d
  end
  return n
end

local N = math.clamp(math.floor(num(noctalia.getConfig("bands"), 128)), 8, 512)
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
local ALPHA = math.clamp(num(noctalia.getConfig("bar_opacity"), 0.75), 0.05, 1)
local BLUR = math.clamp(num(noctalia.getConfig("blur"), 1.0), 0, 1)
local SMOOTH_MS = math.max(0, num(noctalia.getConfig("smoothing"), 45))
local FADE = noctalia.getConfig("fade_when_idle") ~= false
local IDLE_MS = math.max(1, num(noctalia.getConfig("idle_seconds"), 6)) * 1000

local MIN_BAR = math.max(2, H * 0.004)
local BAR_W = math.max(1, (W - GAP * (N - 1)) / N)
local BAR_R = math.min(RADIUS, BAR_W / 2)
local ALPHA_HEX = string.format("%02x", math.floor(ALPHA * 255 + 0.5))

-- "Blur" is a simulated glow: ui.box has no gaussian blur, so each bar is a
-- nested stack of translucent capsules, faintest and widest on the outside.
-- One slider controls how narrow the solid core gets and how far the mist
-- reaches past the tip.
local BLUR_ON = BLUR > 0.01
local LAYERS = BLUR_ON and math.floor(4 + BLUR * 6) or 0
local CORE_FRAC = 0.45 - 0.32 * BLUR
local CORE_W = math.max(1, BAR_W * CORE_FRAC)
local CORE_R = math.min(RADIUS, CORE_W / 2)
local HALO_EXTRA = BLUR_ON and BAR_W * 1.5 * BLUR or 0
local HALO_W = BAR_W + 2 * HALO_EXTRA
local VSPREAD = BLUR_ON and H * 0.09 * BLUR or 0
local BAR_MAX = math.max(MIN_BAR, H - VSPREAD)
local CORE_ALPHA = ALPHA * (1 - 0.45 * BLUR)
local CORE_ALPHA_HEX = string.format("%02x", math.floor(CORE_ALPHA * 255 + 0.5))

local LAYER_W = {}
local LAYER_DH = {}
local LAYER_R = {}
local LAYER_ALPHA_HEX = {}
if BLUR_ON then
  -- Target visible alpha at each ring, core outward. Solving each layer's own
  -- alpha from it keeps the falloff smooth instead of banded at the edge.
  local profile = {}
  for j = 0, LAYERS do
    local t = j / LAYERS
    profile[j] = CORE_ALPHA * math.exp(-4.0 * t * t)
  end
  for j = 1, LAYERS do
    local t = j / LAYERS
    local w = CORE_W + (HALO_W - CORE_W) * t
    LAYER_W[j] = w
    LAYER_DH[j] = VSPREAD * t ^ 1.3
    LAYER_R[j] = math.min(CORE_R + (HALO_W / 2 - CORE_R) * t, w / 2)
    local pnext = profile[j + 1] or 0
    local a = (profile[j] - pnext) / (1 - pnext)
    LAYER_ALPHA_HEX[j] = string.format("%02x", math.floor(a * 255 + 0.5))
  end
end

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
  return string.format("#%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
    math.floor(b * 255 + 0.5))
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
    return FALLBACK[fallbackI]
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
  local hex = rgb ~= nil and tint(rgb) or FALLBACK[1]
  colorCache[i] = { key = key, hex = hex }
  return hex
end

-- ---------------------------------------------------------------- render

local BAR_SPAN = math.max(0, BAR_MAX - MIN_BAR)
local lastHeights = {}
local lastOpacity = -1

local function barNode(i, h, level)
  local color = barColor(i, level)
  if not BLUR_ON then
    return ui.box({
      key = "b" .. i,
      width = BAR_W,
      height = h,
      radius = BAR_R,
      fill = color .. ALPHA_HEX,
    })
  end

  local node = ui.box({
    key = "b" .. i .. "l0",
    width = CORE_W,
    height = h,
    radius = CORE_R,
    fill = color .. CORE_ALPHA_HEX,
  })
  -- A quiet band gets a small halo, a loud one the full spread.
  local reach = 0.2 + 0.8 * level
  for j = 1, LAYERS do
    node = ui.column({
      key = "b" .. i .. "l" .. j,
      width = LAYER_W[j],
      height = h + LAYER_DH[j] * reach,
      radius = LAYER_R[j],
      fill = color .. LAYER_ALPHA_HEX[j],
      align = "center",
      justify = "end",
    }, { node })
  end
  -- The wrapper reserves exactly one band slot; the halo is allowed to spill
  -- over the gaps and into neighbouring slots, which is what turns separate
  -- bars into a continuous mist.
  return ui.column({
    key = "b" .. i .. "w",
    width = BAR_W,
    height = H,
    align = "center",
    justify = "end",
  }, { node })
end

local function render(force)
  local changed = force == true or math.abs(opacity - lastOpacity) > 0.002
  for i = 1, N do
    local h = MIN_BAR + (levels[i] or 0) * BAR_SPAN
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
    kids[i] = barNode(i, lastHeights[i], levels[i] or 0)
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
  -- One cava feeds every widget, so a widget whose own band count differs from
  -- the feed (a per-instance override, a stale pin) must spread itself over the
  -- whole spectrum instead of reading the first feed bands and going dead past
  -- them. Feed == N is the normal case and maps 1:1.
  local feed = #value
  local spread = feed > 0 and feed ~= N
  for i = 1, N do
    local src = i
    if spread then
      src = math.clamp(math.floor((i - 0.5) / N * feed) + 1, 1, feed)
    end
    local v = tonumber(value[src])
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
noctalia.log(string.format("wallpaper-bars: canvas %dx%d bands=%d gap=%.1f monitor='%s' grid=%s", W, H, N, GAP, MONITOR,
  grid and (tostring(grid.cols) .. "x" .. tostring(grid.rows)) or "none"))
render(true)
setTicking(true)
