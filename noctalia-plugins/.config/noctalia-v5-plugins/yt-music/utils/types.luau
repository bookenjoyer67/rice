
export type Track = {
	id: string,
	title: string,
	artist: string,
	album: string?,
	duration: number?,
	duration_text: string?,
	thumbnail_url: string?,
	thumb_path: string?,
}

export type Playlist = {
	id: string,
	title: string,
	subtitle: string?,
	count: number?,
	artist: string?,
	thumbnail_url: string?,
	thumb_path: string?,
}

export type PlaylistPageResult = {
	tracks: { Track },
	next_token: string?,
	total_count: number?,
}

export type SearchResult = Track | (Playlist & { type: string? })

export type Player = {
	status: string,
	title: string,
	artist: string,
	id: string,
	position: number,
	duration: number,
	volume: number,
	index: number,
	shuffle: boolean,
	repeat_mode: string,
	queue: { Track },
	thumbnail_url: string?,
	thumb_path: string?,
	codec_fetched: boolean?,
	bitrate: number?,
	codec: string?,
	samplerate: number?,
	views: number?,
	likes: number?,
}

return {}
