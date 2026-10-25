local Playlist = {}

local store = require("./store.luau")
local api = require("../api.luau")
local logger = require("../utils/log.luau")
local library = require("./library.luau")
local network = require("../utils/network.luau")
local player = require("./player.luau")

local state = store.state
local log = logger.module("ytm", "playlist")

local open_seq = 0

local queue_is_filtered = false

local do_fetch

local staging = nil
local staging_pid = nil

local function walk_target()
	return staging or state.playlist.tracks
end

local function commit_staging(pid)
	if not staging or staging_pid ~= pid then
		return
	end
	local fresh = #staging
	local replaced = #state.playlist.tracks
	state.playlist.tracks = staging
	staging = nil
	staging_pid = nil
	log("staged walk done: swapped in " .. fresh .. " fresh rows, replacing " .. replaced .. " cached")
end

local WALK_TTL_SECONDS = 30 * 60
local walk_stamps = {}

local function walk_is_fresh(pid, cached_rows)
	local stamp = walk_stamps[pid]
	if not stamp or stamp.rows ~= cached_rows then
		return false
	end
	return (os.time() - stamp.at) < WALK_TTL_SECONDS
end

local function stamp_walk(pid, rows)
	walk_stamps[pid] = { at = os.time(), rows = rows }
end

local function load_cached(pid)
	if api and api.load_cached_playlist then
		return api.load_cached_playlist(pid)
	end
	return nil
end

local function save_cache(pid)
	if api and api.save_playlist_cache then
		noctalia.runAsync("true", function()
			local total = tonumber(state.playlist.count) or 0
			if total > 0 and #state.playlist.tracks > total then
				log("save_cache: skipped, " .. #state.playlist.tracks .. " rows > declared " .. total)
				return
			end
			api.save_playlist_cache(pid, state.playlist.tracks)
		end)
	end
end

local function ensure_thumbs(kind)
	if api and api.ensure_thumbnails then
		noctalia.runAsync("true", function()
			api.ensure_thumbnails(state.playlist.tracks, store.publish, kind)
		end)
	end
end

local function sync_queue(pid)
	if queue_is_filtered then
		return
	end
	if state.player.source_playlist ~= pid then
		return
	end
	local queued = {}
	for _, t in ipairs(state.player.queue) do
		if t.id then
			queued[t.id] = true
		end
	end
	for _, t in ipairs(state.playlist.tracks) do
		if t.id and not queued[t.id] then
			queued[t.id] = true
			player.append_to_queue(t)
		end
	end
end

local function settle(pid)
	if staging and staging_pid == pid then
		return
	end
	sync_queue(pid)
	store.publish()
	save_cache(pid)
	ensure_thumbs("playlist")
end

local PREFETCH_MAX_PAGES = 20
local prefetch_pages = 0

local function prefetch_more(pid)
	if not pid or state.playlist.id ~= pid then
		return
	end
	if not network.isOnline() then
		return
	end
	local total = tonumber(state.playlist.count) or 0
	local tok = state.playlist.next_token
	if not tok or tok == "" then
		return
	end
	if total > 0 and #walk_target() >= total then
		return
	end
	if prefetch_pages >= PREFETCH_MAX_PAGES then
		log("prefetch: page cap " .. PREFETCH_MAX_PAGES .. " reached, stopping and committing the partial list")
		state.playlist.fetching = false
		commit_staging(pid)
		settle(pid)
		return
	end
	prefetch_pages = prefetch_pages + 1
	state.playlist.fetching = true
	do_fetch(pid, tok)
end

function Playlist.open(pid, title)
	if not pid or pid == "" then
		return
	end
	open_seq = open_seq + 1
	local seq = open_seq
	prefetch_pages = 0
	staging = nil
	staging_pid = nil
	state.playlist.id = pid
	state.playlist.title = tostring(title or "Playlist")

	state.playlist.next_token = nil
	state.playlist.suggestions = {}

	local cached = load_cached(pid)
	local had_cache = (cached ~= nil and #cached > 0)
	if had_cache then
		if pid == "VLLM" then
			library.sync_liked_tracks(cached)
		end
		state.playlist.tracks = cached
		state.playlist.fetching = false
		if not state.playlist.count or state.playlist.count == 0 or state.playlist.count == "0" then
			state.playlist.count = #cached
		end
		store.publish()
		ensure_thumbs("playlist")
	else
		state.playlist.tracks = {}
		state.playlist.fetching = true
		store.publish()
	end

	if had_cache and walk_is_fresh(pid, #cached) then
		log(
			"open: cache for '"
				.. pid
				.. "' is "
				.. (os.time() - walk_stamps[pid].at)
				.. "s old, inside the "
				.. math.floor(WALK_TTL_SECONDS / 60)
				.. "min TTL, skipping fetch"
		)
		return
	end

	if not network.isOnline() then
		return
	end

	if api and api.playlist_page then
		api.playlist_page(pid, nil, function(res)
			if seq ~= open_seq or state.playlist.id ~= pid then
				log("playlist_page: dropped stale response for '" .. tostring(pid) .. "'")
				return
			end
			state.playlist.fetching = false
			state.playlist.next_token = res.next_token
			if res.total_count and res.total_count > 0 then
				state.playlist.count = res.total_count
			end
			if res.tracks and #res.tracks > 0 then
				if pid == "VLLM" then
					library.sync_liked_tracks(res.tracks)
				end
				if had_cache then
					local on_screen = #state.playlist.tracks
					staging = res.tracks
					staging_pid = pid
					log(
						"warm path for '"
							.. pid
							.. "': "
							.. on_screen
							.. " cached rows on screen, staging a fresh walk beside them (page 1 = "
							.. #res.tracks
							.. ")"
					)
				else
					state.playlist.tracks = res.tracks
					log("cold path for '" .. pid .. "': no cache, visible list fills as pages land")
				end
				if not state.playlist.count or state.playlist.count == 0 or state.playlist.count == "0" then
					state.playlist.count = #res.tracks
				end
			end
			local total = tonumber(state.playlist.count) or 0
			if total > 0 and #walk_target() >= total then
				state.playlist.next_token = nil
				commit_staging(pid)
				stamp_walk(pid, #state.playlist.tracks)
				if res.next_token and res.next_token ~= "" then
					noctalia.runAsync("true", function()
						do_fetch(pid, res.next_token)
					end)
				end
			end
			settle(pid)
			prefetch_more(pid)
		end)
	end

end

function Playlist.play(pid, title)
	if not pid or pid == "" then
		return
	end
	staging = nil
	staging_pid = nil
	queue_is_filtered = false
	state.playlist.id = pid
	state.playlist.title = tostring(title or "Playlist")
	local cached = load_cached(pid)
	if cached and #cached > 0 then
		state.playlist.tracks = cached
		state.player.source_playlist = pid
		player.play_index(1, cached)
	else
		state.playlist.tracks = {}
	end
	store.publish()
end

function Playlist.refresh(pid)
	pid = pid or state.playlist.id
	if not pid or pid == "" then
		return
	end
	open_seq = open_seq + 1
	local seq = open_seq
	prefetch_pages = 0
	staging = nil
	staging_pid = nil
	walk_stamps[pid] = nil
	state.playlist.id = pid
	state.playlist.suggestions = {}
	state.playlist.next_token = nil
	store.publish()

	if not network.isOnline() then
		local cached = load_cached(pid)
		state.playlist.tracks = (cached and #cached > 0) and cached or {}
		state.playlist.fetching = false
		store.publish()
		return
	end

	state.playlist.tracks = {}
	state.playlist.fetching = true
	store.publish()
	if api and api.playlist_page then
		api.playlist_page(pid, nil, function(res)
			if seq ~= open_seq or state.playlist.id ~= pid then
				log("playlist_page: dropped stale refresh for '" .. tostring(pid) .. "'")
				return
			end
			state.playlist.fetching = false
			if res.total_count and res.total_count > 0 then
				state.playlist.count = res.total_count
			end
			state.playlist.next_token = res.next_token
			if res.tracks and #res.tracks > 0 then
				state.playlist.tracks = res.tracks
			end
			local total = tonumber(state.playlist.count) or 0
			if total > 0 and #state.playlist.tracks >= total then
				state.playlist.next_token = nil
			end
			save_cache(pid)
			store.publish()
			ensure_thumbs("playlist")
			prefetch_more(pid)
		end)
	end
end

do_fetch = function(pid, fetch_token)
	api.playlist_page(pid, fetch_token, function(res)
		if state.playlist.id ~= pid then
			return
		end
		pcall(function()
			local total = tonumber(state.playlist.count) or 0
			local dest = walk_target()
			local mode = (staging ~= nil and staging_pid == pid) and "staged" or "live"
			local incoming = res.tracks or {}
			local real, suggested = {}, {}
			if total > 0 then
				local room = math.max(0, total - #dest)
				for i, t in ipairs(incoming) do
					if i <= room then
						table.insert(real, t)
					else
						table.insert(suggested, t)
					end
				end
			else
				real = incoming
			end

			local existing = {}
			for _, t in ipairs(dest) do
				if t.id then
					existing[t.id] = true
				end
			end

			local added_count = 0
			for _, tr in ipairs(real) do
				if tr.id and not existing[tr.id] then
					table.insert(dest, tr)
					existing[tr.id] = true
					added_count = added_count + 1
				end
			end

			if #suggested > 0 then
				local seen = {}
				for _, t in ipairs(dest) do
					if t.id then
						seen[t.id] = true
					end
				end
				local uniq = {}
				for _, t in ipairs(suggested) do
					if t.id and not seen[t.id] then
						seen[t.id] = true
						table.insert(uniq, t)
					end
				end
				state.playlist.suggestions = uniq
			end

			local new_token = res.next_token
			local token_valid = (new_token and new_token ~= "" and new_token ~= fetch_token)

			if total > 0 and #dest >= total then
				log("[" .. mode .. "] declared count " .. total .. " reached, dropping continuation")
				state.playlist.next_token = nil
				state.playlist.fetching = false
				commit_staging(pid)
				stamp_walk(pid, #state.playlist.tracks)
				settle(pid)
				return
			end

			if added_count == 0 and token_valid then
				if prefetch_pages >= PREFETCH_MAX_PAGES then
					log("[" .. mode .. "] duplicate-page cap " .. PREFETCH_MAX_PAGES .. " reached, stopping")
					state.playlist.fetching = false
					commit_staging(pid)
					settle(pid)
					return
				end
				prefetch_pages = prefetch_pages + 1
				log("[" .. mode .. "] page was all duplicates, skipping to next")
				noctalia.runAsync("true", function()
					do_fetch(pid, new_token)
				end)
				return
			end

			local finished = not token_valid
			if finished then
				state.playlist.next_token = nil
			else
				state.playlist.next_token = new_token
			end

			state.playlist.fetching = false
			log(
				"["
					.. mode
					.. "] added "
					.. added_count
					.. " rows ("
					.. #dest
					.. " of "
					.. (total > 0 and tostring(total) or "?")
					.. "), next_token="
					.. tostring(state.playlist.next_token ~= nil)
			)
			if finished then
				commit_staging(pid)
				stamp_walk(pid, #state.playlist.tracks)
				state.playlist.count = #state.playlist.tracks
			end
			settle(pid)
			noctalia.runAsync("true", function()
				prefetch_more(pid)
			end)
		end)
	end)
end

function Playlist.fetch_next_page(pid, token)
	pid = pid or state.playlist.id
	token = token or state.playlist.next_token
	if not pid or not token or token == "" or state.playlist.fetching then
		return
	end
	if not network.isOnline() then
		return
	end
	local total = tonumber(state.playlist.count) or 0
	if total > 0 and #state.playlist.tracks >= total then
		return
	end
	if not (api and api.playlist_page) then
		return
	end
	state.playlist.fetching = true
	log("fetch_next_page for pid='" .. pid .. "'")
	do_fetch(pid, token)
end

function Playlist.play_queue(queue, index, source_playlist, filtered)
	if queue and #queue > 0 then
		if source_playlist and source_playlist ~= "" then
			local spid = tostring(source_playlist)
			local is_library = false
			for _, pl in ipairs(state.library) do
				if tostring(pl.id or "") == spid then
					is_library = true
					break
				end
			end
			if not is_library then
				library.remember_playlist(spid, state.playlist.title or "Playlist")
			end
		end
		state.player.source_playlist = source_playlist
		queue_is_filtered = (filtered == true)
		player.play_index(index or 1, queue)
	else
		log("replace_queue_and_play: empty or missing queue")
	end
end

return Playlist
