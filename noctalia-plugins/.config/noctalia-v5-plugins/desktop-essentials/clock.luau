--!nonstrict

local HOME = noctalia.getenv("HOME") or ""
local CALENDAR = HOME .. "/.local/bin/calendar.sh"

local W, H = 460, 170
local TIME_SIZE, SUB_SIZE = 72, 24
local OUTLINE_W = 4   -- ~the eww 2px text-shadow halo, doubled for a stroke
local SUB_OUTLINE_W = 2
local VERSION = "v4"  -- bump when the drawn layout changes (frame cache key)

local CACHE_DIR = (noctalia.pluginDataDir() or "/tmp/noctalia-clock") .. "/frames"
local KEEP = 5

local lastKey
local lastPaletteKey

local function esc(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function colorKey(hex)
  return (tostring(hex):gsub("#", ""))
end

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
  noctalia.runAsync({ HOME .. "/.local/bin/calcurse-launch.sh" })
end

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
    if paletteOnly or frames % 60 == 0 then prune() end
  end
end

lastKey = frameKey(os.date("%I:%M %p"), os.date("%A"), os.date("%d %B %Y"))
lastPaletteKey = paletteKey()
render()
desktopWidget.setWantsSecondTicks(true)
