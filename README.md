# Cineseed

> Drive your torrent client and watch your films from a single app — self-hosted and open source.

Cineseed is a **Flutter** web app backed by a single-binary **Dart** server that:

1. **searches** torrents on any **Torznab**-compatible indexer (Prowlarr, Jackett, or a
   tracker exposing a Torznab feed directly);
2. **adds** the `.torrent` to a torrent client (**Transmission**) with sequential download
   and tracks progress;
3. **streams** the video — while it is still downloading (HTTP Range over the growing
   local file), then from **S3-compatible storage** via presigned URLs once uploaded.

All wrapped in a media-library UI: poster grid (TMDB metadata), download progress,
seeding dashboard, and an integrated player.

## Features

- **Watch while downloading** — sequential download + HTTP Range (206) streaming of the
  in-progress file; playback switches to a presigned S3 URL once the object is uploaded.
- **Backend-driven S3 offload** — finished files are uploaded to the bucket by the server
  itself, then Transmission is relocated onto an rclone mount of the same bucket so it
  keeps seeding with no local copy.
- **Live HLS remuxing** — on-demand fMP4 segmentation with ffmpeg (video stream-copied,
  never transcoded): multiple audio tracks, subtitle renditions (WebVTT), and Dolby/DTS →
  AAC audio transcoding for browsers without those licenses. Fed by a caching S3 range
  proxy tuned for high-TTFB object storage.
- **Chromecast** support and a full in-app player (audio/subtitle track switching,
  keyboard seeking, fullscreen).
- **TMDB integration** — poster grid, film pages grouping all releases of a title.
- **Debug mode** — one env flag turns on full backend + frontend + player tracing.

## Architecture

```
Flutter Web  ──►  Dart backend (shelf, 1 binary, serves the web build too)
                   ├─ Torznab search proxy (any indexer)
                   ├─ .torrent fetch (Torznab t=get) → Transmission RPC
                   ├─ /api/file    HTTP-Range streaming of the growing local file
                   ├─ /api/stream  presigned S3 URL once the object is uploaded
                   └─ /api/hls     live HLS: playlists, fMP4 segments, VTT subtitles
                                    └─ ffmpeg ◄─ caching S3 range proxy ◄─ S3
```

| Directory | Role |
|---|---|
| `frontend/` | Flutter app (hooks_riverpod, go_router, chewie) |
| `backend/` | Dart `shelf` server (API + static web build) |
| `shared/` | Models shared between front and back |
| `deploy/` | `Dockerfile`, `docker-compose.yml`, `Caddyfile`, `deploy.sh` |

## Requirements

- A **Torznab** endpoint (Prowlarr / Jackett / a tracker's native feed) and its API key
- **Transmission** (RPC) — the `TorrentClient` interface is small; other clients could be added
- **S3-compatible storage** (AWS, Scaleway, MinIO, Backblaze…)
- **ffmpeg / ffprobe** on the server (HLS remuxing and track probing)
- Optionally a **TMDB API key** for posters and metadata

## Getting started (dev)

```bash
cp .env.example .env        # fill in tracker, Transmission, S3 (see comments)
cd backend && dart run bin/server.dart
```

```bash
cd frontend && flutter run -d web-server --web-port 8090
# the frontend targets http://localhost:8080 by default (CINESEED_API_BASE dart-define)
```

## Configuration

Everything is environment variables — see [.env.example](.env.example), which documents
each knob including the HLS/S3 latency tuning. Secrets are never committed.

## Deployment

A single Docker image contains the compiled backend and the Flutter web build
([deploy/Dockerfile](deploy/Dockerfile)). The reference setup
([deploy/docker-compose.yml](deploy/docker-compose.yml)) runs cineseed + Caddy (TLS,
compression) + Transmission on one host; [deploy/deploy.sh](deploy/deploy.sh) builds,
pushes to your registry, rsyncs config + `.env` to the server, and restarts the service —
copy `deploy/deploy.env.example` to `deploy/deploy.env` and fill in your targets. Set
`CINESEED_DOMAIN` in `.env` for Caddy.

> **Security note:** the API has **no authentication** — anyone who can reach it can
> search, add torrents, and stream. Run it on a private network / VPN, or put your own
> auth (e.g. Caddy `basic_auth`, an OAuth proxy) in front.

## Legal

Cineseed is a self-hosting tool. Use it only with trackers you are authorized to access
and content you have the right to download and store. You are responsible for complying
with the laws of your jurisdiction.

## License

[MIT](LICENSE)
