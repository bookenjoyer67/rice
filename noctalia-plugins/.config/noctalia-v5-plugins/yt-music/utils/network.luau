
local Net = {}

local online = true

function Net.isOnline()
	return online
end

function Net.setOnline(v)
	online = v and true or false
end

local function synthetic_result()
	return {
		exitCode = 1,
		stdout = "NETGATE=OFFLINE\n",
		stderr = "",
		timedOut = false,
		stdoutTruncated = false,
		stderrTruncated = false,
	}
end

function Net.runAsync(cmd, cb, timeout, tag)
	if not online then
		if cb then
			noctalia.runAsync("true", function()
				cb(synthetic_result())
			end)
		end
		return false
	end
	return noctalia.runAsync(cmd, cb, timeout)
end

function Net.http(req, cb)
	if not online then
		cb({ ok = false, status = 0, body = "" })
		return false
	end
	return noctalia.http(req, cb)
end

return Net
