# Cineseed — agent notes

Flutter (web) + Dart (`shelf`): Torznab search → Transmission → stream from the local disk,
or from S3-compatible storage via presigned URLs when `S3_*` is set. Backend runs as a Docker
container on a Linux server, managed by `docker compose`. CI builds the image and ships it via
GHCR. The Flutter web build is baked into the image at `/app/public` and served by the backend
itself.

## Fixing bugs — ABSOLUTE, NON-NEGOTIABLE RULE

**NEVER PATCH, SILENCE, MASK, OR WORK AROUND A PROBLEM BEFORE THE ROOT CAUSE IS
IDENTIFIED WITH 100% CERTAINTY AND THE EXACT FIX IS KNOWN.** No exceptions, ever.

- DO NOT swallow errors, catch-and-ignore, add retry/recovery loops, "self-heal",
  fall back, restart, reset state, or otherwise hide a failure to make symptoms go
  away. Silencing a network error and seeking back to the start is exactly the kind
  of garbage that is FORBIDDEN.
- Until the source of the problem is found and understood EXACTLY — what fails, where,
  and why — we are in DEBUG MODE ONLY. We investigate; we do not "repair".
- Debugging means using real tools: enable debug/verbose flags, read the frontend logs
  AND the backend logs, inspect the actual local media file, probe exact byte ranges /
  timestamps, add targeted logging to pinpoint the failure. The user can supply exact
  timestamps of where playback breaks — use them.
- Only once the root cause is proven 100% and the correct fix is clear do we change
  code. Then fix the root cause, never the symptom. Keep the fix simple and concise.
- If the root cause is not yet known, say so plainly and keep investigating. Never
  pretend something is fixed when it is not. Never sweep anything under the rug.

## Flutter state management

Always use `hooks_riverpod` + `flutter_hooks` for state management. No `StatefulWidget`,
`ConsumerStatefulWidget`, or `ConsumerState` — use `HookConsumerWidget` with `useState`,
`useEffect`, `useTextEditingController`, etc. instead. To keep a tab child alive across
`TabBarView` switches (e.g. preserve a search/filter field), call `useAutomaticKeepAlive()` at
the top of `build` — no `AutomaticKeepAliveClientMixin` shell needed.

## Workflow

Work directly on `main` — commit and push straight to it. No worktrees, no feature
branches, no PRs for this project. CI (`.github/workflows/ci.yml`) runs on every push.
The repo is a pub workspace: run `flutter pub get` at the root.

## Testing the frontend

**ALWAYS test in a real Chrome browser. NEVER use a headless preview tool.** Headless
browsers do not render this Flutter web app reliably (blank canvas) and aren't
representative. Run the dev server (`flutter run -d web-server`) and open it in Chrome
to verify any UI change.

## Deploy

CI publishes a multi-arch image on every push to `main` (`sha-<7>`, `edge`) and on `v*`
tags (`X.Y.Z`, `latest`). Pushes to `main` (not tags) then dispatch a deploy to the repo in
the `DEPLOY_REPO` variable (the private ops repo), which syncs the compose files and
restarts cineseed.
`deploy/deploy.sh` is the manual fallback: builds `linux/amd64` locally, pushes
`$IMAGE:sha-<7>`, rsyncs compose + Caddyfile + override + `.env`, pins `CINESEED_IMAGE`
in the server's `.env`, and recreates only the cineseed service. Targets come from
`deploy/deploy.env` (gitignored). Host-specific mounts go in
`deploy/docker-compose.override.yml` (gitignored). The server-side `.env` holds all
runtime envvars (chmod 600).

## Streaming — watch-while-downloading

Torrents are added with **sequential download** so pieces fill front-to-back, and download to
a **plain local disk** — never a network/FUSE mount. `/api/stream/:hash` returns the presigned
S3 URL once the object is on S3; until then (and always without S3) it serves the local file
via `/api/file/:hash` over HTTP Range (206), reading straight from the local disk.
Transmission 4.1 fetches each file's first and last piece first, so the MKV index (Cues, always
in the last piece) is there within seconds.

The in-app player (HLS) also starts mid-download: `TorrentMediaResolver` hands ffmpeg the local
copy through `LocalRangeServer`, which only serves pieces Transmission has verified (its
`pieces` bitfield; a sparse `.part` holds zeros past the download point) and waits up to 30 s
for the next one. It reopens the file per 4 MiB chunk, so the `.part` rename and the
post-upload delete just work, and once the local copy is gone it 302s ffmpeg to the S3 proxy.
While a file downloads, HLS routes answer 503 (hls.js retries 5xx, never 4xx).

### Upload to S3 (backend-driven, no Transmission hook)

With S3 configured, the backend uploads finished files to S3 **itself**, in Dart: a 1 s sweep
(running only while something downloads, + the `/torrents` poll) calls `S3Signer.putFile` →
minio `fPutObject`, streaming the file from the local disk. Once the object is confirmed on S3
it relocates Transmission onto the post-upload location (`torrent-set-location`, `move:false`,
so it still "sees" its files — e.g. an rclone mount of the same bucket) and deletes the local
copy. See `S3Offloader` in `backend/lib/src/storage/s3_offloader.dart`.

**Why not write through an rclone mount?** A read through the rclone VFS bumps the cache
file's mod time, which makes rclone abort its in-flight multipart upload (`source file is
being updated`) and retry forever — so any film watched while it was still uploading never
landed on S3. Keeping reads on the plain local disk and uploading via the S3 API sidesteps
this entirely. A Transmission `script-torrent-done` hook is unnecessary — the backend owns
the whole lifecycle.

## Playback — codec/container constraints (no video transcode is ever needed)

- **Chrome video:** HEVC/MKV from S3 plays fine (hardware-decoded on macOS). The "browsers can't
  decode HEVC" assumption is wrong for the video path.
- **Chrome audio:** Dolby (E-AC3/AC3) and DTS aren't decoded
  (`canPlayType('audio/mp4; codecs="ec-3"')` → `""`). Picture plays, no sound. Workarounds: Edge
  (has Dolby licenses), native libmpv/media_kit, or audio-only remux
  (`ffmpeg -c:v copy -c:a aac`).
- **Safari:** rejects the Matroska container (`canPlayType('video/x-matroska')` → `''`), but the
  codecs are fine (`hvc1`, `ec-3` → `probably`). Stream-copy MKV→MP4 (`ffmpeg -c copy`, instant)
  plays with HEVC + EAC3.

## Secrets

Never commit secrets. They live only in the server's env file (chmod 600) and the local
`.env`. The repo is public; `.env.example` has names only. The frontend defaults
to same-origin — no server hostnames hardcoded in tracked source.
