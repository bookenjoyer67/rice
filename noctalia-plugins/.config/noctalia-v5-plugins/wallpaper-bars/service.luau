--!nonstrict
-- wallpaper-bars service.
--
-- Two feeds, both published through noctalia.state:
--   "levels"  cava spectrum, 0..1 per band, ~fps times a second
--   "grids"   one wallpaper colour grid per output that has one of our widgets
--
-- A grid is produced by ImageMagick: find every desktop widget of this plugin
-- in the layout, take its real rect on its own output, map that rect onto that
-- output's wallpaper with a "cover" fit (what the compositor draws), crop it,
-- then average it down to one colour per band column and grid row. It is
-- re-derived whenever a wallpaper or a box changes - that is what makes the
-- bars adapt to the environment instead of a fixed palette.
--
-- One cava feeds every output; each widget draws the newest frame its own
-- refresh rate allows.

local ROWS = 24
local POLL_MS = 5000
local SAMPLE_TIMEOUT_MS = 15000

local function num(v, d)
  local n = tonumber(v)
  if n == nil then
    return d
  end
  return n
end

local bands = math.clamp(math.floor(num(noctalia.getConfig("bands"), 64)), 8, 128)
local fps = math.clamp(math.floor(num(noctalia.getConfig("fps"), 60)), 10, 240)

local dataDir = noctalia.pluginDataDir() or "/tmp/noctalia-wallpaper-bars"
noctalia.mkdirAll(dataDir)
local cavaConf = dataDir .. "/cava.conf"

local settingsPath = noctalia.expandPath("~/.local/state/noctalia/settings.toml") or ""
local fallbackWallpaper = noctalia.expandPath("~/.cache/wallpaper/wallpaper.jpg") or ""

local lastLineMs = 0
local signatures = {} -- per output: wallpaper path + mtime + rect + grid size
local sampling = {}   -- per output: in-flight guard
local grids = {}      -- per output: last published colour grid

-- ---------------------------------------------------------------- settings.toml

local function stripValue(raw)
  raw = raw:gsub("%s+#.*$", "")
  local q = raw:match('^"(.*)"$')
  if q then
    return q
  end
  q = raw:match("^'(.*)'$")
  if q then
    return q
  end
  local n = tonumber(raw)
  if n ~= nil then
    return n
  end
  if raw == "true" then
    return true
  end
  if raw == "false" then
    return false
  end
  return raw
end

-- Minimal, line-oriented reader: we only need [wallpaper.*] and the
-- [desktop_widgets.widget.<id>] blocks, not a general TOML parser.
local function parseSettings(text)
  local res = { wallpapers = {}, widgets = {} }
  local cur = nil
  for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
    local sec = line:match("^%s*%[([^%]]+)%]%s*$")
    if sec then
      cur = nil
      local mon = sec:match("^wallpaper%.monitors%.(.+)$")
      if mon then
        cur = {}
        res.wallpapers[mon] = cur
      elseif sec == "wallpaper.default" or sec == "wallpaper.last" then
        cur = {}
        res.wallpapers[sec:gsub("^wallpaper%.", "")] = cur
      elseif sec:match("^desktop_widgets%.widget%.") then
        cur = {}
        res.widgets[#res.widgets + 1] = cur
      end
    elseif cur then
      local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if k and v and v ~= "" then
        cur[k] = stripValue(v)
      end
    end
  end
  return res
end

local function readSettings()
  local ok, text = pcall(noctalia.readFile, settingsPath)
  if not ok or type(text) ~= "string" then
    return { wallpapers = {}, widgets = {} }
  end
  return parseSettings(text)
end

-- ---------------------------------------------------------------- geometry

local function outputFor(name)
  local list = noctalia.outputs() or {}
  for _, o in ipairs(list) do
    if o.name == name then
      return o
    end
  end
  for _, o in ipairs(list) do
    if o.focused then
      return o
    end
  end
  return list[1]
end

-- Rect of the widget on its output, clamped to it. Falls back to the whole
-- output when the layout entry has no box yet (freshly dropped widget).
local function widgetRect(w, out)
  local ow = num(out.width, 1920)
  local oh = num(out.height, 1080)
  if w == nil then
    return 0, 0, ow, oh
  end
  local bw = num(w.box_width, 0)
  local bh = num(w.box_height, 0)
  if bw <= 0 then
    bw = ow
  end
  if bh <= 0 then
    bh = oh
  end
  local cx = num(w.cx, ow / 2)
  local cy = num(w.cy, oh / 2)
  local x0 = math.max(0, cx - bw / 2)
  local y0 = math.max(0, cy - bh / 2)
  local x1 = math.min(ow, cx + bw / 2)
  local y1 = math.min(oh, cy + bh / 2)
  if x1 - x0 < 4 or y1 - y0 < 4 then
    return 0, 0, ow, oh
  end
  return x0, y0, x1, y1
end

local function wallpaperPath(parsed, outName)
  local override = noctalia.getConfig("wallpaper")
  if type(override) == "string" and override ~= "" then
    return noctalia.expandPath(override)
  end
  local wps = parsed.wallpapers
  local pick = wps[outName] or wps["default"] or wps["last"]
  if pick and type(pick.path) == "string" and pick.path ~= "" then
    return noctalia.expandPath(pick.path)
  end
  return fallbackWallpaper
end

-- One entry per output: the first widget of ours placed there.
local function collectTargets(parsed)
  local targets = {}
  local focus = noctalia.focusedOutputName() or ""
  for _, w in ipairs(parsed.widgets) do
    if tostring(w.type or ""):find("wallpaper%-bars") then
      local name = (type(w.output) == "string" and w.output ~= "") and w.output or focus
      local out = outputFor(name)
      if out ~= nil and out.name ~= nil and targets[out.name] == nil then
        targets[out.name] = { entry = w, out = out }
      end
    end
  end
  return targets
end

-- ---------------------------------------------------------------- sampling

local function publish(name, grid)
  grids[name] = grid
  noctalia.state.set("grids", grids)
end

-- shell-quote a path for the one composed magick pipeline
local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function sample(name, path, x0, y0, x1, y1, out, signature)
  -- The in-flight flag used to be cleared only inside the async callbacks, so a
  -- callback that died (Luau CPU budget, parse error) left it true forever and
  -- every later resample returned early with no log line: the bars then kept
  -- the colour grid of a wallpaper that was no longer on screen. Treat an
  -- attempt older than SAMPLE_TIMEOUT_MS as dead.
  local started = sampling[name]
  if started ~= nil and (noctalia.nowMs() - started) < SAMPLE_TIMEOUT_MS then
    return
  end
  sampling[name] = noctalia.nowMs()

  local function fail(msg)
    sampling[name] = nil
    noctalia.log("wallpaper-bars: " .. tostring(msg))
  end

  noctalia.runAsync({ "magick", "identify", "-format", "%w %h", path }, function(res)
    sampling[name] = nil
    local ok, err = pcall(function()
      if res.exitCode ~= 0 then
        fail("identify failed for " .. tostring(path) .. ": " .. tostring(res.stderr))
        return
      end
      local iw, ih = tostring(res.stdout):match("(%d+)%s+(%d+)")
      iw, ih = tonumber(iw), tonumber(ih)
      if iw == nil or ih == nil or iw < 2 or ih < 2 then
        fail("bad image dimensions for " .. tostring(path))
        return
      end

      -- cover fit: the wallpaper is scaled to fill the output, then centred
      local ow, oh = num(out.width, 1920), num(out.height, 1080)
      local scale = math.max(ow / iw, oh / ih)
      local dispW, dispH = iw * scale, ih * scale
      local offX, offY = (dispW - ow) / 2, (dispH - oh) / 2

      local ix0 = (x0 + offX) / scale
      local ix1 = (x1 + offX) / scale
      local iy0 = (y0 + offY) / scale
      local iy1 = (y1 + offY) / scale

      local cx = math.clamp(math.floor(ix0), 0, iw - 1)
      local cy = math.clamp(math.floor(iy0), 0, ih - 1)
      local cw = math.clamp(math.ceil(ix1 - ix0), 1, iw - cx)
      local ch = math.clamp(math.ceil(iy1 - iy0), 1, ih - cy)
      local crop = tostring(cw) .. "x" .. tostring(ch) .. "+" .. tostring(cx) .. "+" .. tostring(cy)

      -- Reduce to bare hex INSIDE the pipeline: parsing a full `txt:-` dump
      -- (~40 bytes per pixel) in Luau is what blew the callback CPU budget.
      -- Output is one line, 6 hex digits per pixel, row-major.
      local pipeline = string.format(
        "magick %s -auto-orient -crop %s +repage -resize %dx%d! -depth 8 txt:- "
          .. "| sed -n 's/.*#\\([0-9A-Fa-f]\\{6\\}\\).*/\\1/p' | tr -d '\\n'",
        shq(path), crop, bands, ROWS)

      noctalia.runAsync({ "sh", "-c", pipeline }, function(res2)
        local ok2, err2 = pcall(function()
          if res2.exitCode ~= 0 then
            fail("sample failed for " .. tostring(name) .. ": " .. tostring(res2.stderr))
            return
          end
          local str = tostring(res2.stdout)
          local limit = bands * ROWS
          local pixels = {}
          local n = 0
          for hex in str:gmatch("%x%x%x%x%x%x") do
            n += 1
            pixels[n] = tonumber(hex, 16)
            if n >= limit then
              break
            end
          end
          if n < limit * 0.5 then
            fail("short colour grid for " .. tostring(name) .. " (" .. tostring(n) .. "/" .. tostring(limit) .. ")")
            return
          end
          signatures[name] = signature
          publish(name, { rows = ROWS, cols = bands, w = ow, h = oh, data = pixels })
          noctalia.log("wallpaper-bars: sampled " .. tostring(name) .. " from " .. tostring(path) .. " crop " .. crop)
        end)
        if not ok2 then
          fail("sample parse failed for " .. tostring(name) .. ": " .. tostring(err2))
        end
      end)
    end)
    if not ok then
      fail("sample failed for " .. tostring(name) .. ": " .. tostring(err))
    end
  end)
end

-- ---------------------------------------------------------------- cava

local function onLine(line)
  local vals = {}
  local n = 0
  for v in tostring(line):gmatch("(%d+)") do
    n += 1
    vals[n] = math.min(1, math.max(0, tonumber(v) / 1000))
    if n >= bands then
      break
    end
  end
  if n > 0 then
    lastLineMs = noctalia.nowMs()
    noctalia.state.set("levels", vals)
  end
end

local cavaStartedMs = 0

local function startCava()
  local source = noctalia.getConfig("audio_source") or ""
  if source == "" then
    source = "auto"
  end
  local conf = table.concat({
    "[general]",
    "bars = " .. tostring(bands),
    "framerate = " .. tostring(fps),
    "",
    "[output]",
    "method = raw",
    "raw_target = /dev/stdout",
    "data_format = ascii",
    "channels = mono",
    "",
    "[input]",
    "method = pipewire",
    "source = " .. tostring(source),
  }, "\n")
  noctalia.writeFile(cavaConf, conf)
  -- A cava from a previous instance survives a hot reload / plugin bounce; a
  -- second reader on the same monitor then keeps the widget silent. Replace it
  -- in the SAME shell as the spawn, so the kill can never land on the new one.
  local cmd = "exec sh -c \"pkill -f '^cava -p " .. cavaConf .. "' >/dev/null 2>&1; "
    .. "sleep 0.2; exec cava -p " .. cavaConf .. "\""
  local ok = noctalia.runStream(cmd, onLine)
  cavaStartedMs = noctalia.nowMs()
  if not ok then
    noctalia.log("wallpaper-bars: could not start cava")
  end
end

-- ---------------------------------------------------------------- poll loop

local function refresh()
  local parsed = readSettings()
  local targets = collectTargets(parsed)
  for name, target in pairs(targets) do
    local out = target.out
    local wp = wallpaperPath(parsed, name)
    local x0, y0, x1, y1 = widgetRect(target.entry, out)
    noctalia.runAsync({ "stat", "-c", "%Y:%s", wp }, function(res)
      local stamp = ""
      if res.exitCode == 0 then
        stamp = tostring(res.stdout):gsub("%s+$", "")
      end
      local sig = tostring(wp) .. "|" .. stamp .. "|" .. tostring(x0) .. "," .. tostring(y0) .. ","
        .. tostring(x1) .. "," .. tostring(y1) .. "|" .. tostring(bands) .. "x" .. tostring(ROWS)
      if sig ~= signatures[name] then
        sample(name, wp, x0, y0, x1, y1, out, sig)
      end
    end)
  end
end

function update()
  -- cava watchdog. A stream that never produced a single line counts as dead
  -- too: `lastLineMs == 0` used to disable the check entirely, so a cava that
  -- failed to start (or was killed by a previous instance's onExit) stayed
  -- dead until the shell restarted.
  local now = noctalia.nowMs()
  local silentFor
  if lastLineMs == 0 then
    silentFor = now - cavaStartedMs
  else
    silentFor = now - lastLineMs
  end
  if silentFor > 15000 then
    lastLineMs = now
    startCava()
  end
  refresh()
end

function onExit()
  -- anchored: an unanchored -f pattern also matches a sibling shell whose
  -- command line merely mentions the conf
  noctalia.runAsync("pkill -f '^cava -p " .. cavaConf .. "'")
end

startCava()
noctalia.setUpdateInterval(POLL_MS)
refresh()
