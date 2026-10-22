#!/usr/bin/env bash
# Deploys what <stage>/versions.yaml names, BE first, then FE.
#   scripts/deploy.sh staging|prod <pages-dir>
# BE: pulls the image and checks /health and /version (stands in for a real server).
# FE: downloads the web build attached to the fe release, adds config/<stage>.json as
#     config.json, and copies it into <pages-dir>/<stage> for GitHub Pages.
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
  IMAGE="ghcr.io/$OWNER/ff-poc-be:$BE"
  docker pull "$IMAGE"
  docker rm -f "be-$STAGE" >/dev/null 2>&1 || true
  docker run -d --name "be-$STAGE" -p 3000:3000 -e APP_VERSION="$BE" "$IMAGE" >/dev/null
  for _ in $(seq 1 20); do curl -fs localhost:3000/health >/dev/null && break; sleep 1; done
  curl -fs localhost:3000/health
  GOT=$(curl -fs localhost:3000/version | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
  [ "$GOT" = "$BE" ] || { echo "be answered version $GOT, expected $BE"; exit 1; }
  echo "be $BE is healthy"
fi

if [ "$FE" != none ]; then
  WORK=$(mktemp -d)
  gh release download "$STAGE/v$FE" -R "$OWNER/ff-poc-fe" -p web-build.zip -D "$WORK"
  rm -rf "${PAGES:?}/$STAGE" && mkdir -p "$PAGES/$STAGE"
  unzip -q "$WORK/web-build.zip" -d "$PAGES/$STAGE"
  jq --arg be "$BE" --arg fe "$FE" '. + {versions: {be: $be, fe: $fe}}' "config/$STAGE.json" > "$PAGES/$STAGE/config.json"
  echo "fe $FE copied to $PAGES/$STAGE"
fi
