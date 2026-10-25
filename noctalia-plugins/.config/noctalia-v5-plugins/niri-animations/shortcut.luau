--!nonstrict

local TARGET = noctalia.getConfig("target_file") or "~/.config/niri/animations.kdl"

local function animationsOn(): boolean
  local text = noctalia.readFile(TARGET)
  if text == nil then return true end
  return string.match(text, "\n%s*off%s*[\n\r]") == nil
end

local function render()
  local on = animationsOn()
  shortcut.setLabel(noctalia.tr("shortcut_label"))
  shortcut.setIcon("movie")
  shortcut.setActive(on)
  shortcut.setEnabled(true)
end

render()

function onClick()
  noctalia.runAsync("noctalia msg panel-toggle imjustdoingmypart/niri-animations:docked")
  render()
end
