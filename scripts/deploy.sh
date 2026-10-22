#!/usr/bin/env bash
# Deploys what <stage>/versions.yaml names, BE first, then FE.
#   scripts/deploy.sh staging|prod <pages-dir>
# Settings come from git, secrets from Parameter Store (see infra/README.md):
#   config/be/<stage>.env    BE settings that are not secret
#   config/be/secrets.list   names of BE secrets; values at /ff-poc/<stage>/be/<NAME>
#   config/fe/<stage>.json   FE config.json (public: the browser reads it)
# AWS is simulated here: AWS_ROLE_ARN is a mock, so the secrets get placeholder values. On a real
# account the deploy role writes the .env values to Parameter Store and the server reads its path.
set -euo pipefail

STAGE="$1"
PAGES="$2"
FILE="$STAGE/versions.yaml"
OWNER="tanatornmokkhao"
BE_CONF="config/be/$STAGE.env"
SECRETS="config/be/secrets.list"
FE_CONF="config/fe/$STAGE.json"

get() { sed -n "s/^$1:[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$FILE"; }
lines() { grep -Ev '^[[:space:]]*(#|$)' "$1" || true; }
names() { lines "$1" | sed 's/=.*//'; }
BE=$(get be)
FE=$(get fe)
echo "Deploying $STAGE: be=$BE fe=$FE"

if [ "$BE" != none ]; then
  LEAK=$(comm -12 <(names "$BE_CONF" | sort) <(names "$SECRETS" | sort))
  [ -z "$LEAK" ] || { echo "$BE_CONF holds secrets ($LEAK): remove them and set them in Parameter Store."; exit 1; }

  echo "AWS role (simulated): ${AWS_ROLE_ARN:-not set}"
  echo "Would write to /ff-poc/$STAGE/be/ as String: $(names "$BE_CONF" | paste -sd, -)"
  echo "Would check these SecureString names exist: $(names "$SECRETS" | paste -sd, -)"

  ENVFILE=$(mktemp)
  lines "$BE_CONF" > "$ENVFILE"
  for k in $(names "$SECRETS"); do echo "$k=simulated-from-parameter-store" >> "$ENVFILE"; done
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
  echo "be $BE is healthy with the $STAGE settings"
fi

if [ "$FE" != none ]; then
  WORK=$(mktemp -d)
  gh release download "$STAGE/v$FE" -R "$OWNER/ff-poc-fe" -p web-build.zip -D "$WORK"
  rm -rf "${PAGES:?}/$STAGE" && mkdir -p "$PAGES/$STAGE"
  unzip -q "$WORK/web-build.zip" -d "$PAGES/$STAGE"
  jq --arg be "$BE" --arg fe "$FE" '. + {versions: {be: $be, fe: $fe}}' "$FE_CONF" > "$PAGES/$STAGE/config.json"
  echo "fe $FE copied to $PAGES/$STAGE with runtime keys: $(jq -r '.runtime // {} | keys | join(", ")' "$FE_CONF")"
fi
