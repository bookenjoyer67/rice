--!strict

-- Shared YT Music API constants.
-- Scope: api/* only. service.luau / panel.luau never touch these directly.

local XDG_CACHE = noctalia.getenv("XDG_CACHE_HOME")
local CACHE_ROOT = noctalia.expandPath(XDG_CACHE and XDG_CACHE ~= "" and XDG_CACHE or "~/.cache") .. "/yt-music"

local EXPO = {}

-- The InnerTube API key is a SECRET and must never live in this repo.
-- Resolution order:
--   1. environment variable  YT_MUSIC_KEY
--   2. key file              ~/.local/share/yt-music/key  (chmod 600, outside the repo)
-- Fails loudly (notification + error) when neither is present.
local KEY_ENV = "YT_MUSIC_KEY"
local KEY_FILE = noctalia.expandPath("~/.local/share/yt-music/key")

local function load_key(): string
	local k: string? = noctalia.getenv(KEY_ENV)
	if k ~= nil and k ~= "" then
		return k
	end
	if noctalia.fileExists(KEY_FILE) then
		local raw = noctalia.readFile(KEY_FILE)
		if raw then
			local trimmed = string.gsub(raw, "%s+$", "")
			if trimmed ~= "" then
				return trimmed
			end
		end
	end
	pcall(noctalia.notify, "YouTube Music", "Missing API key: set YT_MUSIC_KEY or ~/.local/share/yt-music/key")
	error("yt-music: no API key. Set " .. KEY_ENV .. " or write ~/.local/share/yt-music/key (chmod 600) - never commit it.", 0)
end

EXPO.KEY = load_key()
EXPO.CLIENT_VERSION = "1.20240813.01.00"
EXPO.BASE = "https://music.youtube.com/youtubei/v1/"
EXPO.ORIGIN = "https://music.youtube.com"

EXPO.CACHE_DIR = CACHE_ROOT
EXPO.COOKIE_PATH = CACHE_ROOT .. "/cookies.txt"
EXPO.LIBRARY_CACHE_PATH = CACHE_ROOT .. "/library.json"
EXPO.RECENT_PLAYLISTS_CACHE_PATH = CACHE_ROOT .. "/recent_playlists.json"
EXPO.PLAYLISTS_CACHE_DIR = CACHE_ROOT .. "/playlists"
EXPO.ARTISTS_CACHE_DIR = CACHE_ROOT .. "/artists"
EXPO.SESSION_CACHE_PATH = CACHE_ROOT .. "/session.json"
EXPO.QUICK_PICKS_CACHE_PATH = CACHE_ROOT .. "/quick_picks.json"
EXPO.THUMB_DIR = CACHE_ROOT .. "/thumbnails"
EXPO.STREAMS_CACHE_DIR = CACHE_ROOT .. "/streams"
EXPO.AUDIO_DIR = CACHE_ROOT .. "/audio"
EXPO.STATS_CACHE_PATH = CACHE_ROOT .. "/stats.json"
EXPO.OFFLINE_META_PATH = CACHE_ROOT .. "/offline_meta.json"
EXPO.CACHED_META_PATH = CACHE_ROOT .. "/cached_meta.json"

EXPO.CONTEXT = {
	context = {
		client = {
			clientName = "WEB_REMIX",
			clientVersion = EXPO.CLIENT_VERSION,
			hl = "en",
		},
	},
}

return EXPO
