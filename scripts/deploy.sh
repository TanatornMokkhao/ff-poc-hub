#!/usr/bin/env bash
# Deploys what <stage>/versions.yaml names, BE first, then FE.
#   scripts/deploy.sh staging|prod <pages-dir>
# BE: which keys it needs is its .env.example at the tag being deployed ("# secret" marks a secret).
#     Values live in Parameter Store under /ff-poc/<stage>/be/. This script runs as the deploy role,
#     which can list names but never read a value; it checks every key is there (secrets as
#     SecureString) before anything deploys. The server reads the values itself at boot, as the
#     runtime role, whose short-lived credentials come in RUNTIME_*.
# FE: the fe release carries one web build per stage with its config.json already baked in (fe
#     checks its own keys at build time); the hub only adds the versions, then copies it to the
#     stage's S3 bucket (WEB_BUCKET) behind CloudFront. GitHub Pages gets the same copy.
set -euo pipefail

STAGE="$1"
PAGES="$2"
FILE="$STAGE/versions.yaml"
OWNER="tanatornmokkhao"
SSM_PATH="/ff-poc/$STAGE/be/"

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
# Runs a command as the runtime role (the server's identity) instead of the deploy role.
as_runtime() {
  AWS_ACCESS_KEY_ID="$RUNTIME_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$RUNTIME_SECRET_ACCESS_KEY" \
    AWS_SESSION_TOKEN="$RUNTIME_SESSION_TOKEN" "$@"
}

BE=$(get be)
FE=$(get fe)
echo "Deploying $STAGE: be=$BE fe=$FE"
PROBLEMS=()

if [ "$BE" != none ]; then
  BE_EXAMPLE=$(example be "$BE")
  # "<KEY> <Type>" for every parameter under the path: names and types only, never values.
  STORE=$(aws ssm describe-parameters --parameter-filters "Key=Path,Values=${SSM_PATH%/}" \
    --query 'Parameters[].[Name,Type]' --output text | awk '{n=$1; sub(".*/", "", n); print n, $2}')
  type_of() { awk -v k="$1" '$1 == k {print $2}' <<<"$STORE"; }
  if [ -z "$BE_EXAMPLE" ]; then
    echo "be $BE has no .env.example: its settings are not checked."
  else
    for k in $(public_keys <<<"$BE_EXAMPLE"); do
      [ -n "$(type_of "$k")" ] || PROBLEMS+=("be: $k has no value at $SSM_PATH$k")
    done
    for k in $(secret_keys <<<"$BE_EXAMPLE"); do
      case "$(type_of "$k")" in
        SecureString) ;;
        "") PROBLEMS+=("be: secret $k has no value at $SSM_PATH$k") ;;
        *) PROBLEMS+=("be: secret $k is stored as $(type_of "$k") at $SSM_PATH$k; it must be SecureString") ;;
      esac
    done
    EXTRA=$(comm -13 <(keys <<<"$BE_EXAMPLE") <(awk '{print $1}' <<<"$STORE" | sort -u) | paste -sd, -)
    [ -z "$EXTRA" ] || echo "::warning::$SSM_PATH has keys be $BE does not read: $EXTRA"
    echo "be $BE needs public: $(public_keys <<<"$BE_EXAMPLE" | paste -sd, -)"
    echo "be $BE needs secret: $(secret_keys <<<"$BE_EXAMPLE" | paste -sd, -)"
    echo "Found under $SSM_PATH: $(paste -sd, <<<"$STORE" | sed 's/ /:/g')"
  fi
fi

if [ ${#PROBLEMS[@]} -gt 0 ]; then
  printf '::error::%s\n' "${PROBLEMS[@]}"
  echo "Nothing was deployed."
  exit 1
fi

if [ "$BE" != none ]; then
  # The deploy role must not be able to read a value, and this stage's server must not be able
  # to read the other stage's values. Either one working is a broken setup, so it stops here.
  OTHER=$([ "$STAGE" = prod ] && echo staging || echo prod)
  if aws ssm get-parameters-by-path --path "$SSM_PATH" --with-decryption --query 'length(Parameters)' >/dev/null 2>&1; then
    echo "::error::The deploy role can read values under $SSM_PATH; it must only list names."; exit 1
  fi
  echo "Check: the deploy role cannot read values under $SSM_PATH (denied)"
  if as_runtime aws ssm get-parameters-by-path --path "/ff-poc/$OTHER/be/" --query 'length(Parameters)' >/dev/null 2>&1; then
    echo "::error::The $STAGE runtime role can read /ff-poc/$OTHER/be/."; exit 1
  fi
  echo "Check: the $STAGE server cannot read /ff-poc/$OTHER/be/ (denied)"

  IMAGE="$ECR_REPOSITORY_URL:$BE"
  if ! docker pull -q "$IMAGE" 2>/dev/null; then
    # Releases from before ECR exist only in GHCR and cannot read Parameter Store.
    IMAGE="ghcr.io/$OWNER/ff-poc-be:$BE"
    docker pull -q "$IMAGE"
    echo "::warning::be $BE predates ECR: pulled from GHCR; it does not load settings from Parameter Store."
  fi
  ENVFILE=$(mktemp)
  chmod 600 "$ENVFILE"
  printf '%s\n' "AWS_ACCESS_KEY_ID=$RUNTIME_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY=$RUNTIME_SECRET_ACCESS_KEY" \
    "AWS_SESSION_TOKEN=$RUNTIME_SESSION_TOKEN" "AWS_REGION=$AWS_REGION" "SSM_PATH=$SSM_PATH" > "$ENVFILE"
  docker rm -f "be-$STAGE" >/dev/null 2>&1 || true
  docker run -d --name "be-$STAGE" -p 3000:3000 --env-file "$ENVFILE" -e APP_VERSION="$BE" "$IMAGE" >/dev/null
  rm -f "$ENVFILE"
  for _ in $(seq 1 30); do curl -fs localhost:3000/health >/dev/null && break; sleep 1; done
  if ! curl -fs localhost:3000/health >/dev/null; then
    echo "::error::be $BE did not start. Its log:"; docker logs "be-$STAGE" 2>&1 | tail -20; exit 1
  fi
  docker logs "be-$STAGE" 2>&1 | head -3
  GOT=$(curl -fs localhost:3000/version | jq -r .version)
  [ "$GOT" = "$BE" ] || { echo "be answered version $GOT, expected $BE"; exit 1; }
  INFO=$(curl -fs localhost:3000/info)
  echo "be /info: $INFO"
  if [ "$(jq -r '.env // empty' <<<"$INFO")" != "" ] && [ "$IMAGE" = "$ECR_REPOSITORY_URL:$BE" ]; then
    [ "$(jq -r .env <<<"$INFO")" = "$STAGE" ] || { echo "be runs with APP_ENV=$(jq -r .env <<<"$INFO"), expected $STAGE"; exit 1; }
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

  if [ -n "${WEB_BUCKET:-}" ]; then
    # Hashed assets can be cached for good; index.html and config.json must be fetched fresh.
    aws s3 sync "$PAGES/$STAGE/" "s3://$WEB_BUCKET/" --delete --only-show-errors \
      --exclude index.html --exclude config.json --cache-control "public, max-age=31536000, immutable"
    for f in index.html config.json; do
      aws s3 cp "$PAGES/$STAGE/$f" "s3://$WEB_BUCKET/$f" --only-show-errors --cache-control "no-store"
    done
    aws cloudfront create-invalidation --distribution-id "$CF_DISTRIBUTION_ID" \
      --paths /index.html /config.json --query Invalidation.Id --output text >/dev/null
    echo "fe $FE uploaded to s3://$WEB_BUCKET and CloudFront refreshed: ${WEB_URL:-}"
  else
    echo "::warning::WEB_BUCKET is not set for $STAGE: the web went to GitHub Pages only."
  fi
fi
