#!/usr/bin/env bash
# Deploys what <stage>/versions.yaml names, BE first, then FE.
#   scripts/deploy.sh staging|prod <pages-dir>
# Env vars (secrets of the GitHub Environment the job runs in):
#   BE_ENV  the BE .env for this stage, passed to the container as --env-file
#   FE_ENV  KEY=VALUE lines added to the FE config.json under "runtime" (public: the browser reads it)
# BE: pulls the image, runs it with BE_ENV, checks /health, /version and /info (stands in for a real server).
# FE: downloads the web build attached to the fe release, writes config.json from config/<stage>.json
#     and FE_ENV, and copies it into <pages-dir>/<stage> for GitHub Pages.
set -euo pipefail

STAGE="$1"
PAGES="$2"
FILE="$STAGE/versions.yaml"
OWNER="tanatornmokkhao"

get() { sed -n "s/^$1:[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$FILE"; }
BE=$(get be)
FE=$(get fe)
echo "Deploying $STAGE: be=$BE fe=$FE"

if [ "$BE" != none ]; then
  [ -n "${BE_ENV:-}" ] || { echo "BE_ENV is empty: add it to the '$STAGE' environment's secrets."; exit 1; }
  ENVFILE=$(mktemp)
  printf '%s\n' "$BE_ENV" > "$ENVFILE"
  WANT_ENV=$(sed -n 's/^APP_ENV=//p' "$ENVFILE")
  IMAGE="ghcr.io/$OWNER/ff-poc-be:$BE"
  docker pull "$IMAGE"
  docker rm -f "be-$STAGE" >/dev/null 2>&1 || true
  docker run -d --name "be-$STAGE" -p 3000:3000 --env-file "$ENVFILE" -e APP_VERSION="$BE" "$IMAGE" >/dev/null
  rm -f "$ENVFILE"
  for _ in $(seq 1 20); do curl -fs localhost:3000/health >/dev/null && break; sleep 1; done
  curl -fs localhost:3000/health
  GOT=$(curl -fs localhost:3000/version | jq -r .version)
  [ "$GOT" = "$BE" ] || { echo "be answered version $GOT, expected $BE"; exit 1; }
  INFO=$(curl -fs localhost:3000/info)
  echo "be /info: $INFO"
  if [ "$(jq -r '.env // empty' <<<"$INFO")" != "" ]; then
    [ "$(jq -r .env <<<"$INFO")" = "$WANT_ENV" ] || { echo "be runs with APP_ENV=$(jq -r .env <<<"$INFO"), expected $WANT_ENV"; exit 1; }
  fi
  echo "be $BE is healthy with the $STAGE env"
fi

if [ "$FE" != none ]; then
  WORK=$(mktemp -d)
  gh release download "$STAGE/v$FE" -R "$OWNER/ff-poc-fe" -p web-build.zip -D "$WORK"
  rm -rf "${PAGES:?}/$STAGE" && mkdir -p "$PAGES/$STAGE"
  unzip -q "$WORK/web-build.zip" -d "$PAGES/$STAGE"
  RUNTIME=$(printf '%s\n' "${FE_ENV:-}" | jq -Rn '[inputs | select(test("^[A-Za-z_][A-Za-z0-9_]*=")) | capture("^(?<k>[^=]+)=(?<v>.*)$")] | map({(.k): .v}) | add // {}')
  jq --arg be "$BE" --arg fe "$FE" --argjson runtime "$RUNTIME" \
    '. + {versions: {be: $be, fe: $fe}, runtime: $runtime}' "config/$STAGE.json" > "$PAGES/$STAGE/config.json"
  echo "fe $FE copied to $PAGES/$STAGE with runtime keys: $(jq -r 'keys | join(", ")' <<<"$RUNTIME")"
fi
