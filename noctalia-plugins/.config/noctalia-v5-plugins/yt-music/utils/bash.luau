local Bash = {}

local PLUGIN_DIR = noctalia.pluginDir()

function Bash.sh_quote(value)
	if value == nil then
		return "''"
	end
	local s = tostring(value)
	if s == "" then
		return "''"
	end
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

function Bash.run_script(file, fn, cb, timeout, ...)
	local cmd = "bash " .. Bash.sh_quote(PLUGIN_DIR .. "/scripts/" .. file)
	cmd = cmd .. " " .. Bash.sh_quote(fn)
	for _, a in ipairs({ ... }) do
		cmd = cmd .. " " .. Bash.sh_quote(a)
	end
	if type(cb) == "function" then
		return noctalia.runAsync(cmd, cb, timeout)
	end
	return noctalia.runAsync(cmd)
end

function Bash.run_stream(file, fn, on_line, ...)
	local cmd = "bash " .. Bash.sh_quote(PLUGIN_DIR .. "/scripts/" .. file)
	cmd = cmd .. " " .. Bash.sh_quote(fn)
	for _, a in ipairs({ ... }) do
		cmd = cmd .. " " .. Bash.sh_quote(a)
	end
	return noctalia.runStream(cmd, on_line)
end

return Bash
