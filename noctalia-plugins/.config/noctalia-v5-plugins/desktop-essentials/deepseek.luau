--!nonstrict

local HOME = noctalia.getenv("HOME") or ""
local SCRIPT = HOME .. "/.local/bin/deepseek_price.sh"
local REFRESH_SECONDS = 60

local period, price, timeLeft, balance = "Waiting...", "...", "...", ""
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
    ui.row({ gap = 12, align = "center" }, {
      ui.label({ text = timeLeft .. " until switch", fontSize = 12, color = "secondary" }),
      ui.label({
        text = balance ~= "" and (balance .. " left") or "-- left",
        fontSize = 12,
        fontWeight = "bold",
        color = "primary",
        onClick = "onDeepseekClick",
      }),
    }),
  }))
end

local function refresh(force)
  local argv = { SCRIPT }
  if force then argv = { SCRIPT, "--force" } end

  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then return end
    local data = noctalia.json.decode(result.stdout or "")
    if type(data) ~= "table" then return end

    local newPeriod = data.period or period
    local newPrice = data.price or price
    local newLeft = data.time_left or timeLeft
    local newBalance = data.balance or balance

    if newPeriod ~= period or newPrice ~= price or newLeft ~= timeLeft or newBalance ~= balance then
      period, price, timeLeft, balance = newPeriod, newPrice, newLeft, newBalance
      render()
    end
  end)
end

function onDeepseekClick()
  refresh(true)
end

function update()
  ticks += 1
  if ticks >= REFRESH_SECONDS then
    ticks = 0
    refresh(false)
  end
end

refresh(false)
desktopWidget.setWantsSecondTicks(true)
render()
