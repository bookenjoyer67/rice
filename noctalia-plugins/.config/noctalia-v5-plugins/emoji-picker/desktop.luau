--!nonstrict
local picker = require("./picker.luau")

function onOpen(_context)
  picker.onOpen(640)
end

function onKey(chord, pressed)
  picker.onKey(chord, pressed)
end
