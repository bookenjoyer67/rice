--!nonstrict
-- Desktop clock: 12-hour time, weekday and date, rendered as an SVG image so
-- the glyphs can carry a real outline. Noctalia's ui.label has no
-- text-shadow/stroke, so paint-order="stroke fill" in SVG replaces the
-- eight-offset text-shadow halo the eww clock used.
--
-- Colours come from the live palette via noctalia.getColor(), so the fill and
-- the outline follow the wallpaper like the rest of the shell.
--
-- Click runs the same calcurse script the old yambar bar clock (and the eww
-- clock button) opened.

local HOME = os.getenv("HOME") or ""
local CALENDAR = HOME .. "/.local/bin/calendar.sh"

local W, H = 460, 170
local TIME_SIZE, SUB_SIZE = 72, 24
local OUTLINE_W = 4   -- ~the eww 2px text-shadow halo, doubled for a stroke
local SUB_OUTLINE_W = 2
local VERSION = "v4"  -- bump when the drawn layout changes (frame cache key)

-- one file per distinct frame; only the newest few are kept on disk
local CACHE_DIR = (noctalia.pluginDataDir() or "/tmp/noctalia-clock") .. "/frames"
local KEEP = 5

local lastKey
-- Palette signature, tracked separately from the time key: a wallpaper/theme
-- change mid-minute leaves the cached frame painted in the old colours until
-- the next minute tick, so the clock visibly lags the rest of the shell.
local lastPaletteKey

local function esc(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function colorKey(hex)
  return (tostring(hex):gsub("#", ""))
end

-- Live palette signature; empty string when the shell has no colour yet, so a
-- palette that arrives later still counts as a change.
local function paletteKey()
  return table.concat({
    colorKey(noctalia.getColor("tertiary") or ""),
    colorKey(noctalia.getColor("primary") or ""),
    colorKey(noctalia.getColor("secondary") or ""),
    colorKey(noctalia.getColor("surface") or ""),
  }, "-")
end

local function frameKey(time, day, date)
  return (time .. day .. date):gsub("%W", "")
end

local function buildFrame()
  local time = os.date("%I:%M %p")
  local day = os.date("%A")
  local date = os.date("%d %B %Y")

  local fillTime = noctalia.getColor("tertiary") or "#c8c8ff"
  local fillDay = noctalia.getColor("primary") or "#aad290"
  local fillDate = noctalia.getColor("secondary") or "#bdcbaf"
  local outline = noctalia.getColor("surface") or "#101010"

  local key = VERSION .. "-" .. frameKey(time, day, date)
    .. "-" .. colorKey(fillTime) .. colorKey(fillDay) .. colorKey(fillDate) .. colorKey(outline)

  local path = CACHE_DIR .. "/clock-" .. key .. ".svg"
  if noctalia.fileExists(path) then
    return path
  end

  noctalia.mkdirAll(CACHE_DIR)

  local svg = table.concat({
    `<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">`,
    `<text x="{W / 2}" y="86" text-anchor="middle" font-family="Sans" font-size="{TIME_SIZE}"`,
    ` font-weight="bold" fill="{fillTime}" stroke="{outline}" stroke-width="{OUTLINE_W}"`,
    ` paint-order="stroke fill" stroke-linejoin="round">` .. esc(time) .. `</text>`,
    `<text x="{W / 2}" y="136" text-anchor="middle" font-family="Sans" font-size="{SUB_SIZE}"`,
    ` stroke="{outline}" stroke-width="{SUB_OUTLINE_W}" paint-order="stroke fill"`,
    ` stroke-linejoin="round">`,
    `<tspan fill="{fillDay}" font-weight="bold">` .. esc(day) .. `</tspan>`,
    `<tspan dx="10" fill="{fillDate}">` .. esc(date) .. `</tspan>`,
    `</text></svg>`,
  }, "")

  noctalia.writeFile(path, svg)
  return path
end

local function prune()
  noctalia.runAsync({ "sh", "-c",
    `ls -t '{CACHE_DIR}'/clock-*.svg 2>/dev/null | tail -n +{KEEP + 1} | xargs -r rm -f` })
end

local function render()
  desktopWidget.render(ui.column({
    width = W,
    height = H,
    align = "center",
    justify = "center",
    onClick = "onClockClick",
  }, {
    ui.image({ path = buildFrame(), width = W, height = H, fit = "contain", onClick = "onClockClick" }),
  }))
end

function onClockClick()
  -- calcurse is where events are edited (the shell's calendar is read-only);
  -- the script focuses an already-open instance or spawns one in kitty.
  -- The control-center calendar tab stays reachable from the bar clock's
  -- left click, which is hardcoded to `panel-toggle control-center calendar`.
  noctalia.runAsync({ HOME .. "/.local/bin/calcurse-launch.sh" })
end

-- programmatic trigger (same code path as the click, for testing):
--   noctalia msg plugin computing/desktop-essentials:clock all calcurse
function onIpc(event, _payload)
  if event == "calcurse" then
    onClockClick()
  end
end

local frames = 0
function update()
  local key = frameKey(os.date("%I:%M %p"), os.date("%A"), os.date("%d %B %Y"))
  local palette = paletteKey()
  local repaint = key ~= lastKey or palette ~= lastPaletteKey
  if repaint then
    local paletteOnly = key == lastKey
    lastKey = key
    lastPaletteKey = palette
    render()
    frames += 1
    -- a wallpaper flip can churn several frames within one minute, so collect
    -- on those too instead of waiting for the next 60-render sweep
    if paletteOnly or frames % 60 == 0 then prune() end
  end
end

lastKey = frameKey(os.date("%I:%M %p"), os.date("%A"), os.date("%d %B %Y"))
lastPaletteKey = paletteKey()
render()
desktopWidget.setWantsSecondTicks(true)
