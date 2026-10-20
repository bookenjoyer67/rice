-- Native Noctalia v5 port of Catwalk's original animated SVG bar widget.
local frame = 0
local iconSize = 22
local pluginDir = noctalia.pluginDir()
local cpuUsage = nil
local previousTotal = nil
local previousIdle = nil
local themeMode = "dark"
local themeCheckPending = false
local themeCheckElapsed = 2000

-- Ask Noctalia for its resolved mode so wallpaper-driven "auto" mode works too.
-- Two physical SVG sets avoid relying on image tinting, which setImage lacks.
local function refreshThemeMode()
  if themeCheckPending or themeCheckElapsed < 2000 then return end
  themeCheckPending = true
  themeCheckElapsed = 0
  noctalia.runAsync("noctalia msg theme-mode-get", function(result)
    themeCheckPending = false
    local resolved = result.stdout and string.match(result.stdout, "(dark)") or nil
    if resolved == nil and result.stdout ~= nil then
      resolved = string.match(result.stdout, "(light)")
    end
    if resolved ~= nil then themeMode = resolved end
  end, 2000)
end

-- Translate total CPU utilization into animation delay: more work, faster cat.
local function animationDelay(usage)
  if usage == nil or usage <= 10 then return 550 end
  if usage <= 35 then return math.floor(400 - ((usage - 10) / 25) * 150) end
  if usage <= 70 then return math.floor(250 - ((usage - 35) / 35) * 130) end
  return 70
end

local function mood(usage)
  if usage == nil or usage <= 10 then return "chilling" end
  if usage <= 35 then return "trotting" end
  if usage <= 70 then return "running" end
  return "zooming"
end

-- Calculate aggregate utilization from the change in Linux CPU accounting counters.
local function readCpuUsage()
  local raw = noctalia.readFile("/proc/stat")
  local firstLine = raw and string.match(raw, "([^\n]+)")
  if firstLine == nil then return end

  local values = {}
  for value in string.gmatch(firstLine, "%d+") do
    values[#values + 1] = tonumber(value)
  end
  if #values < 4 then return end

  local total = 0
  for _, value in ipairs(values) do total = total + value end
  local idle = values[4] + (values[5] or 0)

  if previousTotal ~= nil then
    local totalDelta = total - previousTotal
    local idleDelta = idle - previousIdle
    if totalDelta > 0 then
      cpuUsage = math.max(0, math.min(100, ((totalDelta - idleDelta) / totalDelta) * 100))
    end
  end
  previousTotal = total
  previousIdle = idle
end

local function drawCat()
  readCpuUsage()
  refreshThemeMode()
  -- A genuinely idle CPU uses the original sleeping frames; active states run.
  local sleeping = cpuUsage == nil or cpuUsage <= 10
  local animation = sleeping and "idle" or "active"
  local frameCount = sleeping and 4 or 5
  frame = frame % frameCount
  local image = pluginDir .. "/icons/" .. themeMode .. "/my-" .. animation .. "-" .. tostring(frame) .. "-symbolic.svg"
  -- Dark-mode frames are white; light-mode frames are black for clear contrast.
  barWidget.setImage(image, true, iconSize, iconSize)
  local detail = cpuUsage and string.format("%.0f%% CPU · %s", cpuUsage, mood(cpuUsage)) or "measuring CPU"
  barWidget.setTooltip("Catwalk · " .. detail)
  frame = (frame + 1) % frameCount
  local delay = animationDelay(cpuUsage)
  themeCheckElapsed = themeCheckElapsed + delay
  noctalia.setUpdateInterval(delay)
end

function update()
  drawCat()
end

-- Start slowly; the first two samples establish the utilization baseline.
noctalia.setUpdateInterval(550)
