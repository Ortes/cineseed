# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[SemVer](https://semver.org/).

## [Unreleased]

### Added
- `package:cineseed_backend` library entry point: `startServer(config, tracker:, client:,
  s3:, tmdb:)` takes optional replacements for each dependency and returns a
  `CineseedServer` with `close()`.

### Changed
- The repo is a pub workspace with a single root `pubspec.lock`; resolve with
  `flutter pub get` at the root.
- The Docker image builds Flutter from a pinned tag (`FLUTTER_VERSION`) and
  cross-compiles the backend, instead of using a third-party Flutter image.
