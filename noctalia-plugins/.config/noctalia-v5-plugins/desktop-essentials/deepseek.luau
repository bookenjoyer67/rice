--!nonstrict
-- Desktop DeepSeek rate widget: peak/off-peak period, USD/M price and the
-- countdown to the next switch, from ~/.config/eww/scripts/deepseek_price.sh
-- (the exact script the eww deepseek widget polled every 60s). Re-polled once a
-- minute so the countdown matches what eww showed.

local HOME = noctalia.getenv("HOME") or ""
local SCRIPT = HOME .. "/.local/bin/deepseek_price.sh"
local REFRESH_SECONDS = 60

local period, price, timeLeft = "Waiting...", "...", "..."
local ticks = 0

local function render()
  desktopWidget.render(ui.column({
    width = 300,
    height = 60,
    gap = 2,
    justify = "center",
    align = "start",
  }, {
    ui.row({ gap = 6, align = "center" }, {
      ui.label({ text = "DeepSeek:", fontSize = 13, fontWeight = "bold", color = "on_surface_variant" }),
      ui.label({ text = period, fontSize = 13, fontWeight = "bold" }),
      ui.label({ text = price, fontSize = 13, fontWeight = "bold", color = "tertiary" }),
    }),
    ui.label({ text = timeLeft .. " until switch", fontSize = 12, color = "secondary" }),
  }))
end

local function refresh()
  noctalia.runAsync({ SCRIPT }, function(result)
    if result.exitCode ~= 0 then return end
    local data = noctalia.json.decode(result.stdout or "")
    if type(data) ~= "table" then return end

    local newPeriod = data.period or period
    local newPrice = data.price or price
    local newLeft = data.time_left or timeLeft

    if newPeriod ~= period or newPrice ~= price or newLeft ~= timeLeft then
      period, price, timeLeft = newPeriod, newPrice, newLeft
      render()
    end
  end)
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
