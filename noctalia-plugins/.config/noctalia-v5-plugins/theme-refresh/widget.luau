--!nonstrict

-- Bar button: re-sync the rice palette with the current wallpaper.
-- Noctalia extracts the shell palette asynchronously; when that extraction
-- lands late the bar/panels/widgets keep the old wallpaper's colours. One
-- click re-runs the palette pipeline (see scripts/theme-refresh.sh).
--
-- Chromium only reads a theme extension at startup, so a running Brave stays
-- one palette behind. Left-click restarts Brave gracefully (session restored)
-- after the refresh; right-click only refreshes files/prefs.
local SCRIPT = "bash \"$HOME/.config/noctalia/scripts/theme-refresh.sh\""
local GLYPH = "refresh"

local running = false

local function render()
  barWidget.setGlyph(GLYPH)
  if running then
    barWidget.setGlyphColor("primary")
    barWidget.setTooltip("Re-syncing palette from wallpaper…")
  else
    barWidget.setGlyphColor("on_surface_variant")
    barWidget.setTooltip("Refresh theme colours — restarts Brave so it picks them up")
  end
end

render()

local function run(restart_brave)
  if running then return end
  running = true
  render()

  local cmd = SCRIPT
  if restart_brave then
    cmd = cmd .. " --restart-brave"
  end

  local started = noctalia.runAsync(cmd, function(result)
    running = false
    render()
    if not result or (result.exitCode ~= 0) then
      local err = result and tostring(result.stderr or "") or ""
      noctalia.notifyError("Theme refresh failed", err ~= "" and err or "Palette could not be re-synced.")
    else
      -- The script's last stdout line is the human summary (Brave state
      -- included); fall back to a generic message if it printed nothing.
      local summary = tostring(result.stdout or ""):match("([^\n]+)%s*$")
      if summary == nil or summary == "" then
        summary = "Palette re-synced from the current wallpaper."
      end
      noctalia.notify("Theme refreshed", summary)
    end
  end, 120000)

  if not started then
    running = false
    render()
    noctalia.notifyError("Theme refresh failed", "Could not start theme-refresh.sh.")
  end
end

function onClick()
  -- Chromium only reads a theme extension at startup, so a click restarts
  -- Brave (with session restore) to actually apply the new palette.
  run(true)
end

function onRightClick()
  -- Files/prefs only; Brave picks it up on its next manual start.
  run(false)
end
