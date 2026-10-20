--!nonstrict
-- Desktop weather: one line, e.g. "  +61 F", exactly what the eww weather
-- widget showed. The text comes from the existing wttr.in script (which caches
-- for 30 min); we re-run it every 15 min anyway so the cache never goes stale
-- silently. Click opens the Noctalia control-center weather tab (same action
-- the eww weather button used).

local HOME = noctalia.getenv("HOME") or ""
local SCRIPT = HOME .. "/.local/bin/weather.sh"
local FONT   = "MesloLGL Nerd Font Mono" -- the script emits a Nerd Font glyph
local REFRESH_SECONDS = 900

local text = "..."
local ticks = 0
local label

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function render()
  label = ui.label({
    text = text,
    fontSize = 18,
    fontWeight = "bold",
    color = "primary",
    fontFamily = FONT,
  })
  desktopWidget.render(ui.row({
    width = 280,
    height = 60,
    align = "center",
    justify = "center",
    onClick = "onWeatherClick",
  }, { label }))
end

local function refresh()
  noctalia.runAsync({ SCRIPT }, function(result)
    if result.exitCode == 0 then
      local out = trim(result.stdout)
      if out ~= "" and out ~= text then
        text = out
        render()
      end
    end
  end)
end

function onWeatherClick()
  noctalia.runAsync({ "noctalia", "msg", "panel-toggle", "control-center", "weather" })
end

function update()
  ticks += 1
  if ticks >= REFRESH_SECONDS then
    ticks = 0
    refresh()
  end
end

refresh()
desktopWidget.setWantsSecondTicks(true)
render()
