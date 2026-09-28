#!/usr/bin/env bash
# Build an offline bundle for the latest (or a given) immich release:
#
#   1. resolve the release tag and download its docker-compose.yml / example.env
#   2. start a throw-away instance (own project name + port, so it does not
#      collide with other immich instances on this host)
#   3. create the admin user, upload a sample picture, run a smart search and
#      wait until every job queue is idle -> all ML models are downloaded
#   4. export all docker images (docker save) and the model cache (tar.gz)
#   5. write a self-contained bundle incl. the compose file patched with
#      patches/docker-compose.patch (multi-instance)
#      and deploy.sh, tar it up, optionally upload it
#
# Usage: ./build.sh [options]   (see --help)
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

# ---------------------------------------------------------------- defaults --
# config.env (optional, gitignored) may override any of these
# shellcheck disable=SC1091
[[ -f $ROOT/config.env ]] && source "$ROOT/config.env"
VERSION=${VERSION:-latest}
BUILD_NAME=${BUILD_NAME:-immich-bundle-build}
BUILD_PORT=${BUILD_PORT:-127.0.0.1:12283}
SAMPLE=${SAMPLE:-$ROOT/assets/sample.jpg}
WORK_DIR=${WORK_DIR:-$ROOT/work}
DIST_DIR=${DIST_DIR:-$ROOT/dist}
TIMEOUT=${TIMEOUT:-3600}            # seconds to wait for all jobs to finish
IDLE_CHECKS=${IDLE_CHECKS:-6}       # consecutive idle polls (5s apart) required
# OCR models to put into models.tar.gz (space separated); the OCR job is run
# once per model. Empty = only immich's default model.
# PP-OCRv5_mobile = immich default, ESLAV = Russian, Belarusian, Ukrainian, English
OCR_MODELS=${OCR_MODELS-PP-OCRv5_mobile ESLAV__PP-OCRv5_mobile}
KEEP=${KEEP:-0}
FORCE=${FORCE:-0}
UPLOAD=${UPLOAD:-0}
RESOLVE_ONLY=0
GH_REPO=immich-app/immich

usage() {
  cat <<EOF
Usage: $0 [options]

  --version TAG    immich release to bundle (default: latest, e.g. v2.1.0)
  --sample FILE    picture to upload (default: assets/sample.jpg; a real photo
                   with a face exercises face recognition best)
  --port ADDR      host port of the build instance (default: $BUILD_PORT)
  --name NAME      compose project name of the build instance (default: $BUILD_NAME)
  --timeout SEC    max. time to wait for the job queues (default: $TIMEOUT)
  --ocr-models 'A B'  OCR models to bundle (default: '${OCR_MODELS}');
                   '' = only immich's default
  --keep           keep the build instance running afterwards
  --force          rebuild even if dist/ already has a bundle for that version
  --upload         run upload.sh on the result (needs UPLOAD_TARGET)
  --resolve        only print the latest immich release tag and exit
  -h, --help       this help

Any option can also be set in config.env (see config.env.example).
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --version) VERSION=$2; shift 2 ;;
    --sample)  SAMPLE=$2; shift 2 ;;
    --port)    BUILD_PORT=$2; shift 2 ;;
    --name)    BUILD_NAME=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --ocr-models) OCR_MODELS=$2; shift 2 ;;
    --keep)    KEEP=1; shift ;;
    --force)   FORCE=1; shift ;;
    --upload)  UPLOAD=1; shift ;;
    --resolve) RESOLVE_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

# ------------------------------------------------------- resolve version ----
resolve_latest() {
  local tag
  local auth=()   # a token avoids the anonymous API rate limit (CI runners)
  [[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  tag=$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/$GH_REPO/releases/latest" 2>/dev/null |
    jq -r '.tag_name // empty') || true
  if [[ -z $tag ]]; then # API rate limit etc. -> follow the web redirect
    tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$GH_REPO/releases/latest" |
      sed -n 's#.*/tag/##p') || true
  fi
  [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || die "could not determine latest immich release (got '$tag')"
  echo "$tag"
}

if [[ $RESOLVE_ONLY == 1 ]]; then   # used by CI to decide whether to build
  need curl jq sed
  resolve_latest
  exit 0
fi

need docker curl jq tar gzip sha256sum awk sed patch
need_compose
[[ -f $SAMPLE ]] || die "sample picture not found: $SAMPLE"

if [[ $VERSION == latest ]]; then
  TAG=$(resolve_latest)
else
  TAG=$VERSION
  [[ $TAG == v* ]] || TAG=v$TAG
fi
log "immich release: $TAG"

BUNDLE_NAME=immich-bundle-$TAG
BUNDLE_TAR=$DIST_DIR/$BUNDLE_NAME.tar
if [[ -f $BUNDLE_TAR && $FORCE != 1 ]]; then
  log "$BUNDLE_TAR already exists - nothing to do (use --force to rebuild)"
  if [[ $UPLOAD == 1 ]]; then "$ROOT/upload.sh" "$BUNDLE_TAR" "$BUNDLE_TAR.sha256"; fi
  exit 0
fi

INST=$WORK_DIR/$TAG/instance
BUNDLE=$WORK_DIR/$TAG/$BUNDLE_NAME
rm -rf "$BUNDLE" && mkdir -p "$INST" "$BUNDLE" "$DIST_DIR"

# ------------------------------------------------------ upstream files ------
DL=https://github.com/$GH_REPO/releases/download/$TAG
log "downloading docker-compose.yml and example.env for $TAG"
curl -fsSL -o "$BUNDLE/docker-compose.upstream.yml" "$DL/docker-compose.yml"
curl -fsSL -o "$BUNDLE/example.upstream.env"        "$DL/example.env"
for f in hwaccel.ml.yml hwaccel.transcoding.yml; do   # optional, handy offline
  curl -fsSL -o "$BUNDLE/$f" "$DL/$f" 2>/dev/null || rm -f "$BUNDLE/$f"
done

# ------------------------------------------------------ build instance ------
# The build instance runs the same patched compose file that goes into the
# bundle (patches/), with the image digests still in place.
apply_patches "$BUNDLE/docker-compose.upstream.yml" "$BUNDLE/example.upstream.env" \
  "$ROOT/patches" "$INST"
mv "$INST/example.env" "$INST/.env"
set_env "$INST/.env" IMMICH_VERSION "$TAG"
set_env "$INST/.env" INSTANCE_NAME "$BUILD_NAME"
set_env "$INST/.env" UPLOAD_LOCATION ./library
set_env "$INST/.env" DB_DATA_LOCATION ./postgres
set_env "$INST/.env" MODEL_LOCATION ./model-cache
set_env "$INST/.env" DB_PASSWORD "$(random_alnum 32)"
set_env "$INST/.env" HOST_PORT "$BUILD_PORT"

dc() { docker compose --project-directory "$INST" -f "$INST/docker-compose.yml" "$@"; }

cleanup() {
  local rc=$?
  if [[ $KEEP == 1 ]]; then
    log "build instance kept running: cd $INST && docker compose ps"
  else
    log "removing build instance"
    dc down -v --remove-orphans >/dev/null 2>&1 || true
    # data folders are owned by container users -> delete from inside
    if [[ -d $INST/postgres || -d $INST/library || -d $INST/model-cache ]]; then
      docker run --rm -v "$INST:/w" --entrypoint /bin/sh \
        "ghcr.io/immich-app/immich-server:$TAG" \
        -c 'rm -rf /w/postgres /w/library /w/model-cache' >/dev/null 2>&1 || true
    fi
  fi
  exit $rc
}
trap cleanup EXIT

dc config -q || die "generated compose file is invalid"
log "pulling images"
# registries (ghcr.io) answer bursts with "toomanyrequests" - retry with backoff
for attempt in 1 2 3 4 5; do
  dc pull && break
  (( attempt < 5 )) || die "pulling images failed"
  warn "pull failed (attempt $attempt/5), retrying in $((attempt * 30))s"
  sleep $((attempt * 30))
done
log "starting build instance '$BUILD_NAME' on $BUILD_PORT"
dc up -d

API=http://${BUILD_PORT/#0.0.0.0/127.0.0.1}/api
[[ $BUILD_PORT == *:* ]] || API=http://127.0.0.1:$BUILD_PORT/api

log "waiting for the server ($API)"
deadline=$((SECONDS + 600))
until curl -fsS "$API/server/ping" 2>/dev/null | grep -q pong; do
  (( SECONDS < deadline )) || { dc logs --tail 50 immich-server >&2; die "server did not come up"; }
  # a crash loop (e.g. invalid env) will not heal - fail fast
  restarts=$(docker inspect -f '{{.RestartCount}}' "$(dc ps -aq immich-server)" 2>/dev/null || echo 0)
  (( restarts < 3 )) || { dc logs --tail 50 immich-server >&2; die "server keeps restarting"; }
  sleep 5
done

# ------------------------------------------------------ admin + upload ------
EMAIL=admin@immich-bundle.local
PASS=$(random_alnum 24)
log "creating admin user $EMAIL"
curl -fsS -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$EMAIL" --arg p "$PASS" '{email:$e,password:$p,name:"Admin"}')" \
  "$API/auth/admin-sign-up" >/dev/null || die "admin sign-up failed"
TOKEN=$(curl -fsS -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$EMAIL" --arg p "$PASS" '{email:$e,password:$p}')" \
  "$API/auth/login" | jq -r .accessToken)
[[ -n $TOKEN && $TOKEN != null ]] || die "login failed"
AUTH=(-H "Authorization: Bearer $TOKEN")

# ------------------------------------------------------ ocr models ----------
# The ML container only downloads the OCR model that is configured, so the
# first model is set before the upload and the others get their own OCR run
# further down (after the queues are idle).
read -ra OCR_LIST <<<"$OCR_MODELS"
if (( ${#OCR_LIST[@]} )) &&
   ! curl -fsS "${AUTH[@]}" "$API/system-config" | jq -e '.machineLearning.ocr' >/dev/null; then
  warn "this immich release has no OCR settings - ignoring OCR_MODELS"
  OCR_LIST=()
fi

set_ocr_model() {
  log "setting OCR model to $1"
  curl -fsS "${AUTH[@]}" "$API/system-config" |
    jq --arg m "$1" '.machineLearning.ocr.modelName = $m' |
    curl -fsS -X PUT "${AUTH[@]}" -H 'Content-Type: application/json' -d @- \
      "$API/system-config" >/dev/null || die "setting OCR model '$1' failed"
}
(( ${#OCR_LIST[@]} )) && set_ocr_model "${OCR_LIST[0]}"

log "uploading $(basename "$SAMPLE")"
now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
form=(-F "assetData=@$SAMPLE" -F "fileCreatedAt=$now" -F "fileModifiedAt=$now")
code=$(curl -sS -o "$INST/upload.json" -w '%{http_code}' "${AUTH[@]}" "${form[@]}" "$API/assets")
if [[ $code == 400 ]]; then # older releases require device ids
  code=$(curl -sS -o "$INST/upload.json" -w '%{http_code}' "${AUTH[@]}" "${form[@]}" \
    -F "deviceAssetId=immich-bundle-sample-$(date +%s)" -F "deviceId=immich-bundle" "$API/assets")
fi
[[ $code == 20? ]] || die "upload failed (HTTP $code): $(cat "$INST/upload.json")"

# ------------------------------------------------------ wait for jobs -------
# Sum of active+waiting+delayed over all queues; works for /api/queues (v2.2+)
# and the older /api/jobs response.
pending_jobs() {
  local body
  body=$(curl -fsS "${AUTH[@]}" "$API/queues" 2>/dev/null) ||
    body=$(curl -fsS "${AUTH[@]}" "$API/jobs") || { echo -1; return; }
  jq '[.. | objects | select(has("active") and has("waiting"))
        | (.active + .waiting + (.delayed // 0))] | add // 0' <<<"$body"
}

wait_idle() {
  local idle=0 n deadline=$((SECONDS + TIMEOUT))
  sleep 15 # give the server time to queue the follow-up jobs
  while (( idle < IDLE_CHECKS )); do
    (( SECONDS < deadline )) || die "timeout: job queues still busy after ${TIMEOUT}s"
    n=$(pending_jobs)
    if [[ $n == 0 ]]; then idle=$((idle + 1)); else idle=0; fi
    printf '\r   pending jobs: %-6s idle checks: %d/%d ' "$n" "$idle" "$IDLE_CHECKS" >&2
    sleep 5
  done
  echo >&2
}

log "waiting for all jobs (thumbnails, CLIP, faces, OCR, ...) to finish"
wait_idle

# The text half of the CLIP model is only loaded for searches.
log "running a smart search to load the CLIP text model"
curl -fsS "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"query":"a sign with text"}' "$API/search/smart" >/dev/null ||
  warn "smart search failed - CLIP text model may be missing"
wait_idle

# further OCR models: switch the model and re-run OCR on all assets
for m in "${OCR_LIST[@]:1}"; do
  set_ocr_model "$m"
  log "re-running OCR with $m"
  curl -fsS -X PUT "${AUTH[@]}" -H 'Content-Type: application/json' \
    -d '{"command":"start","force":true}' "$API/jobs/ocr" >/dev/null ||
    die "starting the OCR job failed"
  wait_idle
done

SERVER_VERSION=$(curl -fsS "${AUTH[@]}" "$API/server/version" | jq -r '"v\(.major).\(.minor).\(.patch)"')
[[ $SERVER_VERSION == "$TAG" ]] || warn "server reports $SERVER_VERSION, expected $TAG"

# ------------------------------------------------------ export models -------
log "exporting model cache"
ML=$(dc ps -q immich-machine-learning)
[[ -n $ML ]] || die "machine-learning container not running"
rm -rf "$WORK_DIR/$TAG/cache"
docker cp "$ML:/cache" - | tar -x -C "$WORK_DIR/$TAG"
echo "   model cache content:" >&2
( cd "$WORK_DIR/$TAG/cache" && find . -mindepth 2 -maxdepth 2 -type d | sed 's#^\./#     #' ) >&2
for d in clip facial-recognition "${OCR_LIST[@]/#/ocr/}"; do
  [[ -d $WORK_DIR/$TAG/cache/$d ]] || warn "no '$d' models in cache - was the job skipped?"
done
tar -czf "$BUNDLE/models.tar.gz" -C "$WORK_DIR/$TAG/cache" .

# ------------------------------------------------------ export images -------
log "exporting docker images"
mapfile -t REFS < <(dc config --images | sort -u)
: >"$BUNDLE/images.txt"
TAGGED=()
for ref in "${REFS[@]}"; do
  plain=${ref%@sha256:*}                       # repo:tag without digest
  docker image inspect "$ref" >/dev/null 2>&1 || docker pull "$ref"
  docker tag "$ref" "$plain"                   # make sure the tag exists locally
  id=$(docker image inspect -f '{{.Id}}' "$ref")
  printf '%s\t%s\t%s\n' "$plain" "$id" "$ref" >>"$BUNDLE/images.txt"
  TAGGED+=("$plain")
done
docker save "${TAGGED[@]}" | gzip >"$BUNDLE/images.tar.gz"

# ------------------------------------------------------ bundle files --------
log "writing bundle files"
# deployment template: patches/ + digests removed for `docker load`;
# INSTANCE_NAME, port etc. are set per instance in .env by deploy.sh
apply_patches "$BUNDLE/docker-compose.upstream.yml" "$BUNDLE/example.upstream.env" \
  "$ROOT/patches" "$BUNDLE"
strip_digests "$BUNDLE/docker-compose.yml"
set_env "$BUNDLE/example.env" IMMICH_VERSION "$TAG"
mkdir -p "$BUNDLE/patches" && cp "$ROOT"/patches/* "$BUNDLE/patches/"
cp "$ROOT/deploy.sh" "$BUNDLE/deploy.sh"
mkdir -p "$BUNDLE/lib" && cp "$ROOT/lib/common.sh" "$BUNDLE/lib/common.sh"

jq -n --arg tag "$TAG" --arg server "$SERVER_VERSION" \
  --arg built "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$(hostname)" \
  --arg arch "$(uname -m)" --rawfile images "$BUNDLE/images.txt" \
  '{immich_version:$tag, server_version:$server, built_at:$built, built_on:$host, arch:$arch,
    images: ($images | split("\n") | map(select(length>0) | split("\t")
             | {ref:.[0], id:.[1], source:.[2]}))}' >"$BUNDLE/manifest.json"

( cd "$BUNDLE" && find . -type f -printf '%P\n' | sort | xargs sha256sum >"$WORK_DIR/$TAG/SHA256SUMS" )
mv "$WORK_DIR/$TAG/SHA256SUMS" "$BUNDLE/SHA256SUMS"

log "creating $BUNDLE_TAR"
tar -cf "$BUNDLE_TAR.partial" -C "$WORK_DIR/$TAG" "$BUNDLE_NAME"
mv "$BUNDLE_TAR.partial" "$BUNDLE_TAR"
rm -rf "$BUNDLE"   # everything is in the tar now; work/$TAG/cache stays for reference
( cd "$DIST_DIR" && sha256sum "$BUNDLE_NAME.tar" >"$BUNDLE_NAME.tar.sha256" )
ln -sfn "$BUNDLE_NAME.tar" "$DIST_DIR/immich-bundle-latest.tar"

log "done: $BUNDLE_TAR ($(du -h "$BUNDLE_TAR" | cut -f1))"

if [[ $UPLOAD == 1 ]]; then
  "$ROOT/upload.sh" "$BUNDLE_TAR" "$BUNDLE_TAR.sha256"
fi
