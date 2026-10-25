--!nonstrict

local SIZE = 420 -- auto-fit size; keep in sync with DEFAULT_SIZE in service.luau

local status = noctalia.state.get("status")

local function message(glyph, title, hint)
    return ui.column({
        width = SIZE,
        height = SIZE,
        padding = 24,
        gap = 10,
        fill = "surface",
        radius = SIZE / 2,
        align = "center",
        justify = "center",
    }, {
        ui.glyph({ name = glyph, size = 36, color = "primary" }),
        ui.label({ text = title, fontSize = 16, fontWeight = "bold", color = "on_surface", textAlign = "center" }),
        ui.label({ text = hint, fontSize = 12, color = "on_surface_variant", maxWidth = SIZE - 96, maxLines = 4, textAlign = "center" }),
    })
end

local function render()
    local problem = if type(status) == "table" then status.problem else nil
    if problem == "missing_renderer" then
        desktopWidget.render(message("alert-triangle", noctalia.tr("widget.missing_renderer"), noctalia.tr("widget.missing_renderer_hint")))
    elseif problem == "missing_cava" then
        desktopWidget.render(message("alert-triangle", noctalia.tr("widget.missing_cava"), noctalia.tr("widget.missing_cava_hint")))
    elseif problem == "crashed" then
        desktopWidget.render(message("alert-triangle", noctalia.tr("widget.crashed"),
            noctalia.tr("widget.crashed_hint", { path = status.config or "" })))
    else
        desktopWidget.render(ui.box({ width = SIZE, height = SIZE, fill = "#00000000" }, {}))
    end
end

noctalia.state.set("surface", noctalia.nowMs())

noctalia.state.watch("status", function(value)
    status = value
    render()
end)

render()
