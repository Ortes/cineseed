# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[SemVer](https://semver.org/).

## [Unreleased]

### Added
- `package:cineseed_backend` library entry point: `startServer(config, tracker:, client:,
  s3:, tmdb:)` takes optional replacements for each dependency and returns a
  `CineseedServer` with `close()`.
- `packages/cineseed_streaming`: the live-HLS engine as a torrent-agnostic package.
  Sources come from a `MediaSourceResolver` (`HttpMediaSource` through the caching
  range proxy, or `FileMediaSource` served by the new loopback `LocalRangeServer`).

- Local-only storage: S3 is optional. With no `S3_*` variables, finished films stay on
  the local disk and are streamed (direct and HLS) and downloaded from there. A partial
  S3 configuration refuses to boot.

### Changed
- The repo is a pub workspace with a single root `pubspec.lock`; resolve with
  `flutter pub get` at the root.
- The Docker image builds Flutter from a pinned tag (`FLUTTER_VERSION`) and
  cross-compiles the backend, instead of using a third-party Flutter image.
