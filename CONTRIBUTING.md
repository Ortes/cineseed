# Contributing

## Setup

The repo is a pub workspace (`shared`, `backend`, `frontend`) with one root `pubspec.lock`.
Resolve it with Flutter; plain `dart pub get` can't resolve a Flutter member.

```bash
flutter pub get                 # at the repo root
cp .env.example .env            # fill in tracker, Transmission, S3
cd backend && dart run bin/server.dart
cd frontend && flutter run -d web-server --web-port 8090
```

The server also needs `ffmpeg`/`ffprobe` on `PATH`.

## Before opening a PR

CI runs exactly this; run it locally first:

```bash
dart format .
dart analyze --fatal-infos shared backend
(cd frontend && flutter analyze)
(cd backend && dart test)
(cd frontend && flutter test --platform chrome)   # web-only imports → Chrome
```

One logical change per PR. Add a line under `## [Unreleased]` in `CHANGELOG.md` for
anything user-visible.

## Bugs

Report the root cause, not only the symptom: logs from `CINESEED_DEBUG=true` (backend +
browser console) and the exact timestamp or byte range where playback breaks help most.
A fix should address the cause; retries or swallowed errors that hide a failure won't be
merged.
