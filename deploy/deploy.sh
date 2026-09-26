#!/usr/bin/env bash
# Build the image, push it to a container registry, sync config + .env to the
# server, restart the service. Deploy targets are personal, so they live in
# deploy/deploy.env (gitignored) — copy deploy/deploy.env.example to get started.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f deploy/deploy.env ]]; then
  echo "deploy/deploy.env not found — copy deploy/deploy.env.example and fill it in." >&2
  exit 1
fi
source deploy/deploy.env
: "${SERVER:?deploy/deploy.env must set SERVER (e.g. user@your-server)}"
: "${REMOTE:?deploy/deploy.env must set REMOTE (e.g. /home/user/cineseed)}"
: "${IMAGE:?deploy/deploy.env must set IMAGE (e.g. ghcr.io/you/cineseed)}"
SHA="$(git rev-parse --short HEAD)"

docker buildx build --platform linux/amd64 --push \
  -t "$IMAGE:$SHA" -t "$IMAGE:latest" -f deploy/Dockerfile .

ssh "$SERVER" "mkdir -p $REMOTE"
rsync -az deploy/docker-compose.yml deploy/Caddyfile .env "$SERVER:$REMOTE/"

# Only cineseed changes on a deploy; transmission (which may have a fixed
# container_name or be managed outside compose) and caddy are left running
# as-is — scoping to cineseed sidesteps "container name already in use" errors
# a full `up -d` can hit. Then prune dangling images so superseded `:latest`
# layers don't slowly fill the server disk — a full disk breaks the next
# `docker compose pull`.
ssh "$SERVER" "cd $REMOTE && docker compose pull cineseed && docker compose up -d --no-deps cineseed && docker image prune -f"
