# syntax=docker/dockerfile:1.7
#
# Cineseed — single image that bundles
#   1. the Dart backend, compiled to a native Linux/amd64 binary
#   2. the Flutter web build it serves as static assets out of /app/public
#
# Build context = repo root. Invoked by deploy/deploy.sh as:
#   docker buildx build --platform linux/amd64 --push \
#       --build-arg CINESEED_API_BASE=<url> \
#       -t <registry>/cineseed:<tag> -f deploy/Dockerfile .

# ─── Stage 1: Flutter web build ─────────────────────────────────────
# cirruslabs/flutter is the de-facto Flutter-in-Docker image. Pinned to
# `stable` to track the same channel as a developer's local SDK.
FROM ghcr.io/cirruslabs/flutter:stable AS flutter-build
WORKDIR /app

# `cineseed_shared` is a path: dependency. `pub get` only needs the dep's
# pubspec — copy that + frontend manifests first so the pub-get layer
# caches across source-only changes.
COPY shared/pubspec.yaml ./shared/pubspec.yaml
COPY frontend/pubspec.yaml frontend/pubspec.lock ./frontend/
RUN cd frontend && flutter pub get

# Now the source.
COPY shared/ ./shared/
COPY frontend/ ./frontend/

# Baked into the Flutter bundle at compile time. Empty value → the app
# uses same-origin, which is what we want in prod (the Dart backend
# serves both the API and the web build).
ARG CINESEED_API_BASE=""
RUN cd frontend && flutter build web --wasm --release \
    --dart-define=CINESEED_API_BASE="$CINESEED_API_BASE"

# ─── Stage 2: compile the Dart backend to a native binary ──────────
# `dart:stable` is debian-bookworm-slim under the hood — glibc matches
# the runtime stage below, so the native exe is portable between them.
FROM dart:stable AS dart-build
WORKDIR /app

COPY shared/pubspec.yaml ./shared/pubspec.yaml
COPY backend/pubspec.yaml backend/pubspec.lock ./backend/
RUN cd backend && dart pub get

COPY shared/ ./shared/
COPY backend/ ./backend/
RUN cd backend && dart compile exe bin/server.dart -o /cineseed-server

# ─── Stage 3: slim runtime ─────────────────────────────────────────
FROM debian:bookworm-slim AS runtime
# ca-certificates: required for outbound TLS (S3, TMDB, tracker).
# ffmpeg: provides ffprobe + ffmpeg for the live HLS remux path.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY --from=dart-build    /cineseed-server         /usr/local/bin/cineseed-server
COPY --from=flutter-build /app/frontend/build/web  /app/public

# These two ENV are the only defaults the image enforces. Everything else
# (tracker, Transmission, S3, TMDB) comes from the env_file mounted by
# docker-compose at runtime.
ENV PUBLIC_DIR=/app/public
ENV PORT=8080

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/cineseed-server"]
