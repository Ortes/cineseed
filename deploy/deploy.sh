#!/usr/bin/env bash
# Manual deploy: build the image here, push it, sync config + .env to the
# server, restart the service. (CI can do the same on every push; this is the
# fallback.) Deploy targets are personal, so they live in deploy/deploy.env
# (gitignored) — copy deploy/deploy.env.example to get started.
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
# Same tag CI gives this commit. `:latest` is left to tagged releases.
TAG="$IMAGE:sha-$(git rev-parse --short=7 HEAD)"

docker buildx build --platform linux/amd64 --push -t "$TAG" -f deploy/Dockerfile .

files=(deploy/docker-compose.yml deploy/Caddyfile .env)
[[ -e deploy/docker-compose.override.yml ]] && files+=(deploy/docker-compose.override.yml)
ssh "$SERVER" "mkdir -p $REMOTE"
rsync -azL "${files[@]}" "$SERVER:$REMOTE/"

# Pin the image in the server's .env, so any later `docker compose up` there
# keeps running exactly this build. Only cineseed is recreated: transmission
# and caddy are left running as-is. Then prune dangling images so superseded
# layers don't slowly fill the server disk — a full disk breaks the next pull.
ssh "$SERVER" "cd $REMOTE && sed -i '/^CINESEED_IMAGE=/d' .env && echo 'CINESEED_IMAGE=$TAG' >> .env \
  && docker compose pull cineseed && docker compose up -d --no-deps cineseed && docker image prune -f"
