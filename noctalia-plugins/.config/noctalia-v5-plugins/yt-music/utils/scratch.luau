
local Scratch = {}
Scratch.DIR = "/tmp/yt-music"

noctalia.mkdirAll(Scratch.DIR)

local counter = 0
local SLOTS = 128

function Scratch.path(prefix)
	counter = counter + 1
	return Scratch.DIR .. "/" .. prefix .. "-" .. ((counter % SLOTS) + 1)
end

return Scratch
