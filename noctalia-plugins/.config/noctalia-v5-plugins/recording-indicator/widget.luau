--!nonstrict
-- Recording indicator — bar widget.
--
-- Shows a pulsing red REC dot (plus elapsed time) ONLY while a screen
-- recording is running, so the bar stays clean otherwise. The state comes from
-- ~/.config/noctalia/scripts/record-status.sh, which reads wf-recorder's
-- pidfile / process table and OBS's open output file.
--
-- Left click stops the current recording by running the same toggle script the
-- Mod+Shift+R bind uses (~/.config/hypr/scripts/record-screen.sh).

local STATUS = "bash \"$HOME/.config/noctalia/scripts/record-status.sh\""
local TOGGLE = "bash \"$HOME/.config/hypr/scripts/record-screen.sh\""

local recording = false
local elapsed = 0
local file = ""
local checking = false
local tick = 0
local lastGlyphColor = nil
local lastText = nil

local function fmt(sec)
  sec = math.floor(tonumber(sec) or 0)
  local h = sec // 3600
  local m = (sec % 3600) // 60
  local s = sec % 60
  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%02d:%02d", m, s)
end

local function base(path)
  if not path or path == "" then return nil end
  return tostring(path):match("([^/]+)$") or path
end

local function render()
  local hideIdle = noctalia.getConfig("hide_when_idle")
  if hideIdle == nil then hideIdle = true end

  if not recording then
    if hideIdle then
      barWidget.setVisible(false)
      barWidget.setTooltip("Not recording")
      return
    end
    -- Idle but configured to stay on the bar: draw a dim idle icon, since
    -- setGlyph has no effect once a render() tree is active.
    barWidget.render(ui.row({ gap = 4, align = "center" }, {
      ui.glyph({ name = "player-record", size = 11, color = "on_surface_variant" }),
    }))
    barWidget.setVisible(true)
    barWidget.setTooltip("Not recording")
    lastGlyphColor = nil
    lastText = nil
    return
  end

  local blink = noctalia.getConfig("blink")
  if blink == nil then blink = true end
  local showElapsed = noctalia.getConfig("show_elapsed")
  if showElapsed == nil then showElapsed = true end

  -- Pulse between full and faded red once per second.
  local color = "error"
  if blink and (tick % 2 == 1) then
    color = "error/0.35"
  end

  local text = ""
  if showElapsed then
    text = fmt(elapsed)
  end

  local children = {
    ui.glyph({ name = "circle-filled", size = 9, color = color }),
  }
  if text ~= "" then
    table.insert(children, ui.label({ text = text, fontSize = 11, color = color }))
  end

  barWidget.render(ui.row({ gap = 4, align = "center" }, children))
  if type(barWidget.setActive) == "function" then
    barWidget.setActive(true)
  end
  barWidget.setVisible(true)

  local name = base(file)
  local tip = "Recording"
  if name then
    tip = tip .. " · " .. name
  end
  tip = tip .. " · " .. fmt(elapsed)
  local stopOnClick = noctalia.getConfig("stop_on_click")
  if stopOnClick == nil or stopOnClick then
    tip = tip .. "\nClick to stop"
  end
  barWidget.setTooltip(tip)
  lastGlyphColor = color
  lastText = text
end

local function applyStatus(out)
  local newRec, newElapsed, newFile = false, 0, ""
  local line = tostring(out or ""):match("[^\n]+")
  if line and line:sub(1, 3) == "rec" then
    local e, f = line:match("^rec\t(%d+)\t?(.*)$")
    newRec = true
    newElapsed = tonumber(e) or 0
    newFile = f or ""
  end
  local changed = (newRec ~= recording) or (newFile ~= file)
  recording, elapsed, file = newRec, newElapsed, newFile
  if changed then
    noctalia.log("recording-indicator: " .. (recording and ("recording " .. base(file)) or "idle"))
  end
  render()
end

function update()
  tick = tick + 1
  -- Blink and the clock must advance even without a fresh probe.
  render()
  if checking then return end
  checking = true
  local started = noctalia.runAsync(STATUS, function(res)
    checking = false
    if res and res.exitCode == 0 then
      applyStatus(res.stdout)
    end
  end, 4000)
  if not started then
    checking = false
  end
end

function onClick()
  local stopOnClick = noctalia.getConfig("stop_on_click")
  if stopOnClick == false then return end
  if not recording then return end
  noctalia.runAsync(TOGGLE, function(res)
    if res and res.exitCode ~= 0 then
      noctalia.notifyError("Stop recording failed", tostring(res.stderr or ""))
    end
    -- Re-probe immediately so the dot disappears without waiting a tick.
    checking = false
    update()
  end, 60000)
end

function onConfigChanged()
  render()
end

noctalia.setUpdateInterval(1000)
applyStatus("idle")
