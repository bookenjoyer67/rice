--!nonstrict

local isVertical = barWidget.isVertical()

local function cfg(key)
	return noctalia.getConfig(key)
end

local function st(key)
	return noctalia.state.get(key)
end

local function tr(key, subst)
	return noctalia.tr(key, subst)
end

local function trunc(s, n)
	if #s <= n then
		return s
	end
	return s:sub(1, n - 1) .. "…"
end

function update()
	local stats = st("stats")
	local cpu = stats and stats.cpu and stats.cpu.usagePercent
	local ram = stats and stats.ram and stats.ram.usagePercent
	local count = #(st("procs") or {})
	local cpuInt = math.floor(cpu or 0)
	local tooltip = tr("widget.tooltip", { cpu = cpuInt, ram = math.floor(ram or 0), n = count })

	local color = "on_surface"
	if cpuInt >= 80 then
		color = "error"
	elseif cpuInt >= 50 then
		color = "secondary"
	end

	local children = { ui.glyph({ name = cfg("glyph") or "cpu", size = 14, color = color }) }

	if not isVertical and not cfg("icon_only") then
		local text = string.format("CPU %d%% RAM %d%%", cpuInt, math.floor(ram or 0))
		if cfg("show_count") then
			text = text .. " · " .. count
		end
		table.insert(children, ui.label({ text = text, fontSize = 11 }))
	end

	local container = isVertical and ui.column or ui.row
	barWidget.render(container({ gap = 6, align = "center" }, children))
	barWidget.setTooltip(tooltip)
end

noctalia.state.watch("stats", update)
noctalia.state.watch("procs", update)
noctalia.setUpdateInterval(1000)

function onClick()
	noctalia.togglePanel("weinguyen/procmon:panel")
end
