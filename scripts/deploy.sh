#!/usr/bin/env bash
# Deploys what <stage>/versions.yaml names, BE first, then FE.
#   scripts/deploy.sh staging|prod <pages-dir>
# BE: which keys it needs is its .env.example at the tag being deployed ("# secret" marks a secret).
#     Real values: Parameter Store /ff-poc/<stage>/be/<KEY> (String, or SecureString for a secret),
#     read by the server. Here (no AWS): this GitHub environment's variables BE_<KEY> (VARS_JSON)
#     and secrets BE_<KEY> (SECRETS_JSON). All are checked before anything deploys.
# FE: the fe release carries one web build per stage with its config.json already baked in (fe
#     checks its own keys at build time); the hub only adds the versions.
set -euo pipefail

STAGE="$1"
PAGES="$2"
FILE="$STAGE/versions.yaml"
OWNER="tanatornmokkhao"
SJ="${SECRETS_JSON:-}"
[ -n "$SJ" ] || SJ='{}'
VJ="${VARS_JSON:-}"
[ -n "$VJ" ] || VJ='{}'

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
# BE keys set in a store (variables or secrets JSON), without the BE_ prefix.
be_keys() { jq -r 'keys[] | select(startswith("BE_")) | sub("^BE_"; "")' <<<"$1" | sort -u; }
be_val() { jq -r --arg k "BE_$2" '.[$k] // empty' <<<"$1"; }

BE=$(get be)
FE=$(get fe)
echo "Deploying $STAGE: be=$BE fe=$FE"
PROBLEMS=()

if [ "$BE" != none ]; then
  BE_EXAMPLE=$(example be "$BE")
  ENVFILE=$(mktemp)
  if [ -z "$BE_EXAMPLE" ]; then
    echo "be $BE has no .env.example: its settings are not checked; passing every BE_ value."
    for k in $(be_keys "$VJ"); do printf '%s=%s\n' "$k" "$(be_val "$VJ" "$k")" >> "$ENVFILE"; done
    for k in $(be_keys "$SJ"); do printf '%s=%s\n' "$k" "$(be_val "$SJ" "$k")" >> "$ENVFILE"; done
  else
    for k in $(comm -12 <(be_keys "$VJ") <(secret_keys <<<"$BE_EXAMPLE")); do
      PROBLEMS+=("be: $k is a secret but is a visible variable (BE_$k) in $STAGE; delete it and set it as a secret")
    done
    for k in $(public_keys <<<"$BE_EXAMPLE"); do
      v=$(be_val "$VJ" "$k")
      if [ -z "$v" ]; then PROBLEMS+=("be: $k has no value in $STAGE (variable BE_$k)")
      else printf '%s=%s\n' "$k" "$v" >> "$ENVFILE"; fi
    done
    for k in $(secret_keys <<<"$BE_EXAMPLE"); do
      v=$(be_val "$SJ" "$k")
      if [ -z "$v" ]; then PROBLEMS+=("be: secret $k has no value in $STAGE (secret BE_$k)")
      else printf '%s=%s\n' "$k" "$v" >> "$ENVFILE"; fi
    done
    EXTRA=$(comm -13 <(keys <<<"$BE_EXAMPLE") <(cat <(be_keys "$VJ") <(be_keys "$SJ") | sort -u) | paste -sd, -)
    [ -z "$EXTRA" ] || echo "::warning::$STAGE has BE_ values that be $BE does not read: $EXTRA"
    echo "be $BE needs public: $(public_keys <<<"$BE_EXAMPLE" | paste -sd, -)"
    echo "be $BE needs secret: $(secret_keys <<<"$BE_EXAMPLE" | paste -sd, -) (real: /ff-poc/$STAGE/be/<KEY>, role ${AWS_ROLE_ARN:-not set})"
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
  CONF="$PAGES/$STAGE/config.json"
  rm -rf "${PAGES:?}/$STAGE" && mkdir -p "$PAGES/$STAGE"
  if gh release download "$STAGE/v$FE" -R "$OWNER/ff-poc-fe" -p "web-build-$STAGE.zip" -D "$WORK" 2>/dev/null; then
    unzip -q "$WORK/web-build-$STAGE.zip" -d "$PAGES/$STAGE"
    [ -f "$CONF" ] || { echo "web-build-$STAGE.zip of fe $FE has no config.json"; exit 1; }
  else
    # Releases made before per-stage builds have one web-build.zip without a config.json.
    gh release download "$STAGE/v$FE" -R "$OWNER/ff-poc-fe" -p web-build.zip -D "$WORK"
    unzip -q "$WORK/web-build.zip" -d "$PAGES/$STAGE"
    jq -n --arg s "$STAGE" '{env: $s, flags: {}}' > "$CONF"
    echo "::warning::fe $FE predates per-stage builds: it gets no runtime settings."
  fi
  jq --arg be "$BE" --arg fe "$FE" '. + {versions: {be: $be, fe: $fe}}' "$CONF" > "$CONF.new" && mv "$CONF.new" "$CONF"
  echo "fe $FE ($STAGE build) copied to $PAGES/$STAGE with runtime keys: $(jq -r '.runtime // {} | keys | join(", ")' "$CONF")"
fi
