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
  in-progress file; with S3, playback switches to a presigned URL once it is uploaded.
- **Local disk or S3** — without S3, finished films stay on the local disk and are
  streamed from there. With S3, the server uploads them itself, then relocates
  Transmission onto an rclone mount of the bucket so it keeps seeding with no local copy.
- **Live HLS remuxing** — on-demand fMP4 segmentation with ffmpeg (video stream-copied,
  never transcoded): multiple audio tracks, subtitle renditions (WebVTT), and Dolby/DTS →
  AAC audio transcoding for browsers without those licenses. S3 sources go through a
  caching range proxy tuned for high-TTFB object storage.
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
| `packages/cineseed_streaming/` | Live HLS engine (MKV → fMP4 over HTTP Range, S3 or local disk), no torrent knowledge |
| `deploy/` | `Dockerfile`, `docker-compose.yml`, `Caddyfile`, `deploy.sh` |

## Requirements

- A **Torznab** endpoint (Prowlarr / Jackett / a tracker's native feed) and its API key
- **Transmission** (RPC) — the `TorrentClient` interface is small; other clients could be added
- **ffmpeg / ffprobe** on the server (HLS remuxing and track probing)
- Optionally **S3-compatible storage** (AWS, Scaleway, MinIO, Backblaze…) — without it,
  films stay on the local disk and are streamed from there
- Optionally a **TMDB API key** for posters and metadata

## Getting started (dev)

```bash
flutter pub get             # at the repo root (pub workspace, one lockfile)
cp .env.example .env        # fill in tracker, Transmission, S3 (see comments)
cd backend && dart run bin/server.dart
```

```bash
cd frontend && flutter run -d web-server --web-port 8090
# the frontend targets http://localhost:8080 by default (CINESEED_API_BASE dart-define)
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the checks CI runs.

## Configuration

Everything is environment variables — see [.env.example](.env.example), which documents
each knob including the HLS/S3 latency tuning. Secrets are never committed.

## Extending

The backend is also a library (`package:cineseed_backend`). Every dependency of
`startServer` defaults to what `.env` describes, and any of them can be swapped (another
torrent client, indexer or storage) without forking:

```yaml
dependencies:
  cineseed_backend:
    git: {url: https://github.com/Ortes/cineseed.git, path: backend, ref: <tag>}
```

```dart
import 'package:cineseed_backend/cineseed_backend.dart';

Future<void> main() async {
  final server = await startServer(Config.fromEnv(loadDotenv()),
      client: MyQbittorrentClient()); // implements TorrentClient
}
```

`TorrentClient` and `TrackerConnector` are the extension points.

## Deployment

One multi-arch image (`linux/amd64`, `linux/arm64`) contains the compiled backend and
the Flutter web build: `ghcr.io/ortes/cineseed:latest` (or `:X.Y.Z`). The reference
setup runs cineseed + Caddy (TLS) + Transmission on one host:

```bash
cd deploy && cp ../.env.example .env   # tracker, CINESEED_DOMAIN, optional S3
docker compose up -d
```

Host paths, image and user come from `.env` (`CINESEED_DATA`, `CINESEED_IMAGE`, `PUID`);
anything more specific (e.g. an rclone mount) goes in a `docker-compose.override.yml`
next to it. [deploy/deploy.sh](deploy/deploy.sh) builds your own image, pushes it and
restarts a remote host (targets in `deploy/deploy.env`, see the `.example`).

> **Security note:** the API has **no authentication** — anyone who can reach it can
> search, add torrents, and stream. Run it on a private network / VPN, or put your own
> auth (e.g. Caddy `basic_auth`, an OAuth proxy) in front.

## Legal

Cineseed is a self-hosting tool. Use it only with trackers you are authorized to access
and content you have the right to download and store. You are responsible for complying
with the laws of your jurisdiction.

## License

[MIT](LICENSE)
