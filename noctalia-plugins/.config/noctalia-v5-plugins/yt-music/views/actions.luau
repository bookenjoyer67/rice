local REQ_KEY = "yt_music.request"

local req_nonce = noctalia.nowMs() * 1000 + math.random(0, 999)

local function request(action, payload)
	req_nonce = math.max(req_nonce + 1, noctalia.nowMs() * 1000)
	local msg = { action = action, nonce = req_nonce }
	for k, v in pairs(payload or {}) do
		msg[k] = v
	end
	noctalia.state.set(REQ_KEY, msg)
end

return request
