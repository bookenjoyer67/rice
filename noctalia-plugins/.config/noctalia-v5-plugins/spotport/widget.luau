
local pluginDir = noctalia.pluginDir()

local function statusPath()
  local ok, p = pcall(noctalia.expandPath, "~/.cache/spotport/status.json")
  if ok and type(p) == "string" and p ~= "" then
    return p
  end
  return (noctalia.getenv("HOME") or "") .. "/.cache/spotport/status.json"
end

local function readStatus()
  local ok, raw = pcall(noctalia.readFile, statusPath())
  if not ok or type(raw) ~= "string" or raw == "" then
    return nil
  end
  local decoded, data = pcall(noctalia.json.decode, raw)
  if not decoded or type(data) ~= "table" then
    return nil
  end
  return data
end

local function setWidget(glyph, text, tooltip)
  if not barWidget then
    return
  end
  if barWidget.setGlyph then barWidget.setGlyph(glyph) end
  if barWidget.setText then barWidget.setText(text) end
  if barWidget.setTooltip then barWidget.setTooltip(tooltip) end
end

local function nowSeconds()
  local ok, ms = pcall(noctalia.nowMs)
  if ok and type(ms) == "number" then
    return math.floor(ms / 1000)
  end
  return 0
end

local function humanAge(ts)
  ts = tonumber(ts)
  if not ts or ts <= 0 then
    return "never"
  end
  local d = nowSeconds() - ts
  if d < 0 then d = 0 end
  if d < 90 then return tostring(d) .. "s ago" end
  if d < 5400 then return tostring(math.floor(d / 60)) .. "m ago" end
  if d < 172800 then return tostring(math.floor(d / 3600)) .. "h ago" end
  return tostring(math.floor(d / 86400)) .. "d ago"
end

local lastState = nil

function update()
  local st = readStatus()
  if not st then
    setWidget(
      "brand-spotify",
      "",
      "spotport: no sync recorded yet\nleft click = sync   right click = dry run"
    )
    noctalia.setUpdateInterval(30000)
    return
  end

  local state = tostring(st.state or "unknown")

  if state == "running" then
    local msg = tostring(st.message or "syncing")
    if st.dry_run then msg = msg .. " (dry run)" end
    setWidget("refresh", "…", "spotport: " .. msg)
    noctalia.setUpdateInterval(3000)
    return
  end

  local matched, total = 0, 0
  if type(st.sources) == "table" then
    for _, src in ipairs(st.sources) do
      matched = matched + (tonumber(src.matched) or 0)
      total = total + (tonumber(src.tracks) or 0)
    end
  end

  local ok = (state == "ok")
  local text = ok and tostring(matched) or "!"
  local tip = string.format(
    "spotport: %s\n%s\n%d of %d tracks matched\n%d low-confidence in review\nlast run %s\nleft click = sync   right click = dry run",
    state,
    tostring(st.message or ""),
    matched,
    total,
    tonumber(st.review_entries) or 0,
    humanAge(st.updated_at)
  )
  setWidget(ok and "brand-spotify" or "alert-triangle", text, tip)

  if lastState ~= nil and lastState ~= state and not ok then
    noctalia.notify("spotport", tostring(st.message or state))
  end
  lastState = state

  noctalia.setUpdateInterval(30000)
end

local function trigger(mode, label)
  local cmd = "bash '" .. pluginDir .. "/trigger.sh' " .. mode
  local accepted = false
  local ok = pcall(function()
    accepted = noctalia.runAsync(cmd, function() end, 8000)
  end)
  if ok and accepted ~= false then
    noctalia.notify("spotport", label .. " started - view: status.json / sync.log")
    noctalia.setUpdateInterval(2000)
  else
    noctalia.notify("spotport", "could not start " .. label)
  end
end

function sync()
  trigger("sync", "sync")
end

function sync_dry()
  trigger("dry", "dry run")
end

function open_review()
  noctalia.runAsync("bash '" .. pluginDir .. "/trigger.sh' review", function(res)
    local out = (res and res.stdout) or ""
    if out == "" then out = "no review entries" end
    noctalia.notify("spotport: low-confidence matches", out)
  end, 8000)
end

function onIpc(a, b)
  local event = a
  if type(a) == "table" then
    event = a.event or a.name or a.command
  end
  if event == nil then
    event = b
  end
  event = tostring(event or "")
  if event == "sync" then
    sync()
  elseif event == "sync_dry" then
    sync_dry()
  elseif event == "open_review" then
    open_review()
  end
end

update()
