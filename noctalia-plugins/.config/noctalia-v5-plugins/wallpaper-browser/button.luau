--!nonstrict
-- Bar button: open the custom Wallpaper Browser panel.
--
-- Left click  : toggle the wallhaven browser panel
--               (computing/wallpaper-browser:browser)
-- Right click : one random switch, through the canonical funnel
--               (~/.config/hypr/scripts/random-wallpaper.sh -> apply-wallpaper.sh),
--               launched via niri so it gets the session env.
--
-- This replaces Noctalia's built-in "wallpaper" bar widget on this box.

local PANEL_ID = "computing/wallpaper-browser:browser"
local GLYPH = "photo"

local function render()
    if barWidget == nil then
        return
    end
    if barWidget.setGlyph then barWidget.setGlyph(GLYPH) end
    if barWidget.setGlyphColor then barWidget.setGlyphColor("primary") end
    if barWidget.setTooltip then
        barWidget.setTooltip(noctalia.tr("widget.tooltip"))
    end
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
    noctalia.runAsync(
        "niri msg action spawn -- bash " .. "$HOME/.config/hypr/scripts/random-wallpaper.sh",
        function(result)
            if result and result.exitCode ~= 0 then
                noctalia.notifyError(
                    noctalia.tr("notify.failed_title"),
                    tostring(result.stderr or "random-wallpaper.sh failed")
                )
            end
        end,
        60000
    )
end

render()
