# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[SemVer](https://semver.org/).

## [Unreleased]

### Changed
- The repo is a pub workspace with a single root `pubspec.lock`; resolve with
  `flutter pub get` at the root.
- The Docker image builds Flutter from a pinned tag (`FLUTTER_VERSION`) and
  cross-compiles the backend, instead of using a third-party Flutter image.
