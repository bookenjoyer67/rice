local Mpv = {}
local Bash = require("../utils/bash.luau")
local scratch = require("../utils/scratch.luau")
local logger = require("../utils/log.luau")
local log = logger.module("ytm", "mpv")

function Mpv.play(url, title, volume, on_ready, cover_path)
	local url_file = scratch.path("mpv-url")
	local title_file = scratch.path("mpv-title")
	noctalia.writeFile(url_file, url)
	noctalia.writeFile(title_file, title or "")
	Bash.run_script("mpv.sh", "mpv_play", function(res)
		local out = (type(res) == "table" and res.stdout) or ""
		local ready = out:find("READY=1", 1, true) ~= nil
		local ms = out:match("MS=(%d+)")
		log("mpv_play ready=" .. tostring(ready) .. (ms and (" in " .. ms .. "ms") or ""))
		if type(on_ready) == "function" then
			on_ready(ready)
		end
	end, 10000, tostring(volume or 100), url_file, title_file, cover_path or "")
end

function Mpv.send(payload_json)
	Bash.run_script("mpv.sh", "mpv_send", function() end, 5000, payload_json)
end

function Mpv.kill()
	Bash.run_script("mpv.sh", "mpv_kill", function() end, 2000)
end

function Mpv.stream(on_line)
	return Bash.run_stream("mpv.sh", "mpv_stream", on_line)
end

return Mpv
