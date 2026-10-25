--!nonstrict

local TICK_MS = 50 -- animation step (matches the bar cat's cadence)

local function num(v, fallback)
  local n = tonumber(v)
  return n or fallback
end

local SIZE       = num(noctalia.getConfig("size"), 128)
local GLYPH      = SIZE
local BOX        = math.floor(SIZE * 2)
local TAPPY      = noctalia.getConfig("tappy_mode") ~= false
local RAVE       = noctalia.getConfig("rave_mode") ~= false
local IDLE_SLEEP = noctalia.getConfig("idle_sleep") ~= false

local catFont = noctalia.loadFont("fonts/bongocat.otf")

local STATE_IDLE, STATE_LEFT, STATE_RIGHT, STATE_BOTH = 0, 1, 2, 3
local GLYPHS = { [STATE_IDLE] = "bc", [STATE_LEFT] = "dc", [STATE_RIGHT] = "ba", [STATE_BOTH] = "da" }
local SLEEP_GLYPH, BLINK_GLYPH = "ef", "gh"

local IDLE_TICKS    = 5    -- 250ms to return paws to rest
local WAITING_TICKS = 100  -- 5s of quiet -> sleeping
local BLINK_DURATION = 9   -- ~450ms blink
local BLINK_MIN, BLINK_MAX = 120, 280

local catState, leftWasLast = STATE_IDLE, false
local paused, waiting, blinking = false, false, false
local idleTicks, waitingTicks, blinkDuration = 0, 0, 0
local nextBlinkIn = BLINK_MIN + math.floor(math.random() * (BLINK_MAX - BLINK_MIN))

local rainbowColors = { "#aa0000", "#b65c02", "#bb9c14", "#00a100", "#01019b", "#37005c", "#6a0196" }
local rainbowIndex = 1
local smoothedIntensity, previousIntensity, bassIntensity = 0, 0, 0
local beatThreshold, bigBeatThreshold, beatDeltaThreshold = 0.07, 0.30, 0.02
local beatCooldownTicks, raveFlashTicks = 0, 0

local lastGlyph, lastColor = nil, nil

local function currentGlyph()
  if paused or waiting then return SLEEP_GLYPH end
  if blinking then return BLINK_GLYPH end
  return GLYPHS[catState] or "bc"
end

local function currentColor()
  if RAVE and raveFlashTicks > 0 then return rainbowColors[rainbowIndex] end
  return "on_surface"
end

local function render(force)
  local g, c = currentGlyph(), currentColor()
  if not force and g == lastGlyph and c == lastColor then return end
  lastGlyph, lastColor = g, c

  local labelProps = { text = g, baseline = "pictographic", fontSize = GLYPH, color = c }
  if catFont ~= nil then labelProps.fontFamily = catFont end

  desktopWidget.render(ui.column({
    width = BOX,
    height = BOX,
    align = "center",
    justify = "center",
    fill = "surface/0",
    onClick = "onCatClick",
  }, {
    ui.label(labelProps),
  }))
end

local function beatTap(isBigHit)
  if paused then return end
  waiting, waitingTicks, blinking = false, 0, false
  if isBigHit then
    catState = STATE_BOTH
  else
    leftWasLast = not leftWasLast
    catState = leftWasLast and STATE_LEFT or STATE_RIGHT
  end
  idleTicks = 0
  render()
end

local function tick()
  if beatCooldownTicks > 0 then beatCooldownTicks -= 1 end
  if raveFlashTicks > 0 then
    raveFlashTicks -= 1
    if raveFlashTicks == 0 then render() end
  end
  if paused then return end

  if catState ~= STATE_IDLE then
    idleTicks += 1
    if idleTicks >= IDLE_TICKS then
      catState = STATE_IDLE
      render()
    end
  end

  if not waiting then
    waitingTicks += 1
    if IDLE_SLEEP and waitingTicks >= WAITING_TICKS then
      waiting = true
      blinking = false
      render()
    end
  end

  if not waiting and catState == STATE_IDLE then
    if blinking then
      blinkDuration += 1
      if blinkDuration >= BLINK_DURATION then
        blinking = false
        blinkDuration = 0
        nextBlinkIn = BLINK_MIN + math.floor(math.random() * (BLINK_MAX - BLINK_MIN))
        render()
      end
    else
      nextBlinkIn -= 1
      if nextBlinkIn <= 0 then
        blinking = true
        blinkDuration = 0
        render()
      end
    end
  end
end

local CAVA_CONF = [==[
[general]
framerate = 60
bars = 8

[input]
method = pulse
source = auto

[output]
method = raw
raw_target = /dev/stdout
data_format = ascii
ascii_max_range = 100
bar_delimiter = 59
frame_delimiter = 10
]==]

local function parseValues(line)
  local values = {}
  for part in line:gmatch("[^;]+") do
    local n = tonumber(part)
    if n ~= nil then
      values[#values + 1] = n / 100
    end
  end
  return values
end

local function average(values, firstIndex, lastIndex)
  if lastIndex < firstIndex then return 0 end
  local sum, count = 0, 0
  for i = firstIndex, lastIndex do
    sum += (values[i] or 0)
    count += 1
  end
  return count > 0 and sum / count or 0
end

local function onCavaLine(line)
  if paused then return end
  if not RAVE and not TAPPY then return end

  local values = parseValues(line)
  if #values == 0 then return end

  local bassAvg = average(values, 1, math.clamp(#values, 1, 8))
  local midAvg = average(values, 9, math.clamp(#values, 9, 16))
  bassIntensity = average(values, 1, math.clamp(#values, 1, 4))

  local intensity = (bassAvg * 0.8) + (midAvg * 0.6)
  previousIntensity = smoothedIntensity
  smoothedIntensity = 0.75 * intensity + 0.25 * smoothedIntensity

  local delta = smoothedIntensity - previousIntensity
  local isBeat = (delta > beatDeltaThreshold and smoothedIntensity > beatThreshold * 0.5)
      or (smoothedIntensity > beatThreshold and delta > 0)

  if isBeat and beatCooldownTicks <= 0 then
    if RAVE then
      rainbowIndex = (rainbowIndex % #rainbowColors) + 1
      raveFlashTicks = 2
      render()
    end
    if TAPPY then
      beatTap(bassIntensity > bigBeatThreshold)
    end
    beatCooldownTicks = 2
  end
end

local function startAudio()
  if not RAVE and not TAPPY then return end
  if not noctalia.commandExists("cava") then
    noctalia.notifyError("Desktop Cat", "cava not found - audio reactivity disabled")
    return
  end
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    noctalia.notifyError("Desktop Cat", "no plugin data dir - audio reactivity disabled")
    return
  end
  local conf = dir .. "/cava.conf"
  if not noctalia.fileExists(conf) then
    noctalia.writeFile(conf, CAVA_CONF)
  end
  local quoted = "'" .. conf:gsub("'", "'\\''") .. "'"
  if not noctalia.runStream("cava -p " .. quoted, onCavaLine) then
    noctalia.notifyError("Desktop Cat", "could not start cava")
  end
end

function onCatClick()
  paused = not paused
  if not paused then
    waiting, waitingTicks, catState = false, 0, STATE_IDLE
  end
  render(true)
end

function onIpc(event, _payload)
  if event == "pause" then
    paused = true
  elseif event == "resume" then
    paused = false
    waiting, waitingTicks, catState = false, 0, STATE_IDLE
  elseif event == "toggle" then
    paused = not paused
    if not paused then
      waiting, waitingTicks, catState = false, 0, STATE_IDLE
    end
  else
    return
  end
  render(true)
end

local frameAccumulator = 0
function onFrameTick(deltaMs)
  frameAccumulator += deltaMs
  local steps = 0
  while frameAccumulator >= TICK_MS and steps < 8 do
    tick()
    frameAccumulator -= TICK_MS
    steps += 1
  end
end

desktopWidget.setNeedsFrameTick(true)
startAudio()
render(true)
