# syntax=docker/dockerfile:1.7
#
# Cineseed — single image that bundles
#   1. the Dart backend, compiled to a native Linux binary
#   2. the Flutter web build it serves as static assets out of /app/public
#
# Build context = repo root:
#   docker buildx build --platform linux/amd64 \
#       --build-arg CINESEED_API_BASE=<url> \
#       -t <registry>/cineseed:<tag> -f deploy/Dockerfile .

# Same version as CI (.github/workflows/ci.yml). Flutter is installed from its
# git tag rather than a third-party image so the two can never drift.
ARG FLUTTER_VERSION=3.47.3

# ─── Stage 1: build (web + backend) ────────────────────────────────
# Runs on the BUILD platform: the web output is arch-independent and the
# backend is cross-compiled, so a multi-arch build needs no emulation.
# One stage for both because the pub workspace contains a Flutter package,
# which only `flutter pub get` can resolve.
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS build
ARG FLUTTER_VERSION
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git /opt/flutter
ENV PATH=/opt/flutter/bin:$PATH
RUN flutter config --no-analytics --no-cli-animations \
    && flutter precache --web --no-android --no-ios --no-linux --no-macos --no-windows
WORKDIR /app

# Manifests first so the pub-get layer caches across source-only changes.
COPY pubspec.yaml pubspec.lock ./
COPY shared/pubspec.yaml shared/
COPY backend/pubspec.yaml backend/
COPY frontend/pubspec.yaml frontend/
COPY packages/cineseed_streaming/pubspec.yaml packages/cineseed_streaming/
RUN flutter pub get

COPY shared/ shared/
COPY backend/ backend/
COPY frontend/ frontend/
COPY packages/ packages/

# Baked into the Flutter bundle at compile time. Empty value → the app
# uses same-origin, which is what we want in prod (the Dart backend
# serves both the API and the web build).
ARG CINESEED_API_BASE=""
RUN cd frontend && flutter build web --wasm --release \
    --dart-define=CINESEED_API_BASE="$CINESEED_API_BASE"

# Docker names the arch amd64, Dart names it x64.
ARG TARGETARCH
RUN cd backend && dart compile exe bin/server.dart \
    --target-os=linux --target-arch="$([ "$TARGETARCH" = amd64 ] && echo x64 || echo "$TARGETARCH")" \
    -o /cineseed-server

# ─── Stage 2: slim runtime (per target platform) ───────────────────
FROM debian:bookworm-slim AS runtime
# ca-certificates: required for outbound TLS (S3, TMDB, tracker).
# ffmpeg: provides ffprobe + ffmpeg for the live HLS remux path.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /cineseed-server        /usr/local/bin/cineseed-server
COPY --from=build /app/frontend/build/web /app/public

# These two ENV are the only defaults the image enforces. Everything else
# (tracker, Transmission, S3, TMDB) comes from the env_file mounted by
# docker-compose at runtime.
ENV PUBLIC_DIR=/app/public
ENV PORT=8080

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/cineseed-server"]
