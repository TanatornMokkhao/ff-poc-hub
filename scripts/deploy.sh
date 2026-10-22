#!/usr/bin/env bash
# Deploys what <stage>/versions.yaml names, BE first, then FE.
#   scripts/deploy.sh staging|prod <pages-dir>
# Which keys each app needs: its .env.example at the tag being deployed ("# secret" marks a secret).
# Where the values are:
#   config/be/<stage>.env    BE values that are not secret (git, reviewed in PRs)
#   secret store             BE secrets. Real: Parameter Store /ff-poc/<stage>/be/<KEY>.
#                            Here (no AWS): GitHub environment secrets named BE_<KEY>, in SECRETS_JSON.
#   config/fe/<stage>.json   FE values under "runtime" (public: the browser reads them)
# Everything is checked before anything is deployed; a missing key stops the deploy and names it.
set -euo pipefail

STAGE="$1"
PAGES="$2"
FILE="$STAGE/versions.yaml"
OWNER="tanatornmokkhao"
BE_CONF="config/be/$STAGE.env"
FE_CONF="config/fe/$STAGE.json"
SJ="${SECRETS_JSON:-}"
[ -n "$SJ" ] || SJ='{}'

get() { sed -n "s/^$1:[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$FILE"; }
lines() { grep -Ev '^[[:space:]]*(#|$)' || true; }
keys() { lines | sed 's/=.*//' | sort -u; }
secret_keys() { grep -E '#[[:space:]]*secret[[:space:]]*$' | keys; }
public_keys() { lines | grep -Ev '#[[:space:]]*secret[[:space:]]*$' | keys; }
# .env.example of an app at the release being deployed; empty when that release has none.
# On a 404, gh still prints the error body to stdout, so only a successful call's output counts.
example() {
  local out
  if out=$(gh api "repos/$OWNER/ff-poc-$1/contents/.env.example?ref=$STAGE/v$2" -H "Accept: application/vnd.github.raw" 2>/dev/null); then
    printf '%s\n' "$out"
  fi
}

BE=$(get be)
FE=$(get fe)
echo "Deploying $STAGE: be=$BE fe=$FE"
PROBLEMS=()

if [ "$BE" != none ]; then
  BE_EXAMPLE=$(example be "$BE")
  ENVFILE=$(mktemp)
  lines < "$BE_CONF" > "$ENVFILE"
  if [ -z "$BE_EXAMPLE" ]; then
    echo "be $BE has no .env.example: its settings are not checked."
  else
    for k in $(comm -12 <(keys < "$BE_CONF") <(secret_keys <<<"$BE_EXAMPLE")); do
      PROBLEMS+=("be: $k is a secret but is in $BE_CONF; move it to the secret store")
    done
    for k in $(comm -23 <(public_keys <<<"$BE_EXAMPLE") <(keys < "$BE_CONF")); do
      PROBLEMS+=("be: $k has no value in $BE_CONF")
    done
    for k in $(secret_keys <<<"$BE_EXAMPLE"); do
      v=$(jq -r --arg k "BE_$k" '.[$k] // empty' <<<"$SJ")
      if [ -z "$v" ]; then PROBLEMS+=("be: secret $k has no value in the $STAGE secret store (BE_$k)")
      else printf '%s=%s\n' "$k" "$v" >> "$ENVFILE"; fi
    done
    EXTRA=$(comm -13 <(keys <<<"$BE_EXAMPLE") <(keys < "$BE_CONF") | paste -sd, -)
    [ -z "$EXTRA" ] || echo "::warning::$BE_CONF has keys be $BE does not read: $EXTRA"
    echo "be $BE needs public: $(public_keys <<<"$BE_EXAMPLE" | paste -sd, -)"
    echo "be $BE needs secret: $(secret_keys <<<"$BE_EXAMPLE" | paste -sd, -) (real: /ff-poc/$STAGE/be/<KEY>, role ${AWS_ROLE_ARN:-not set})"
  fi
fi

if [ "$FE" != none ]; then
  FE_EXAMPLE=$(example fe "$FE")
  if [ -z "$FE_EXAMPLE" ]; then
    echo "fe $FE has no .env.example: its settings are not checked."
  else
    HAVE=$(jq -r '.runtime // {} | to_entries[] | select(.value != "") | .key' "$FE_CONF" | sort -u)
    for k in $(comm -23 <(keys <<<"$FE_EXAMPLE") <(echo "$HAVE")); do
      PROBLEMS+=("fe: $k has no value in $FE_CONF")
    done
    echo "fe $FE needs: $(keys <<<"$FE_EXAMPLE" | paste -sd, -)"
  fi
fi

if [ ${#PROBLEMS[@]} -gt 0 ]; then
  printf '::error::%s\n' "${PROBLEMS[@]}"
  rm -f "${ENVFILE:-}"
  echo "Nothing was deployed."
  exit 1
fi

if [ "$BE" != none ]; then
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
