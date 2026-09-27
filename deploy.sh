#!/usr/bin/env bash
# Create or upgrade a named immich instance from an offline bundle.
# Runs without internet access. Shipped inside every bundle; run it from the
# extracted bundle directory:
#
#   tar -xf immich-offline-vX.Y.Z.tar && cd immich-offline-vX.Y.Z
#   ./deploy.sh --name up --dir /srv/immich/up --port 2284 --start
set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

NAME=""
DIR=""
PORT=""
LOAD=1
START=0

usage() {
  cat <<EOF
Usage: $0 --name NAME [options]

  --name NAME    instance / compose project name (containers: NAME-immich-server-1, ...)
  --dir DIR      instance directory (default: ./NAME next to the bundle)
  --port PORT    published port, may include a bind address (default 2283;
                 kept from .env on upgrades)
  --skip-load    do not 'docker load' the images (already loaded on this host)
  --start        run 'docker compose up -d' afterwards

If DIR already contains a .env the instance is upgraded: docker-compose.yml is
replaced, IMMICH_VERSION is updated and the model cache is refreshed. Your
.env (passwords, locations) is kept.
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --name) NAME=$2; shift 2 ;;
    --dir)  DIR=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;
    --skip-load) LOAD=0; shift ;;
    --start) START=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

[[ -n $NAME ]] || { usage >&2; die "--name is required"; }
[[ $NAME =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "invalid name '$NAME' (lowercase letters, digits, - and _)"
need docker tar gzip sha256sum awk sed
need_compose
DIR=${DIR:-$(pwd)/$NAME}

log "verifying bundle checksums"
( cd "$HERE" && sha256sum --quiet -c SHA256SUMS ) || die "bundle is corrupt"
TAG=$(sed -n 's/^IMMICH_VERSION=//p' "$HERE/example.env")

if [[ $LOAD == 1 ]]; then
  log "loading docker images (immich $TAG)"
  docker load -i "$HERE/images.tar.gz"
fi

mkdir -p "$DIR"
UPGRADE=0
[[ -f $DIR/.env ]] && UPGRADE=1

if [[ -f $DIR/docker-compose.yml ]]; then
  cp "$DIR/docker-compose.yml" "$DIR/docker-compose.yml.bak"
fi
# already patched at build time (patches/); the instance name comes from .env
cp "$HERE/docker-compose.yml" "$DIR/docker-compose.yml"
for f in hwaccel.ml.yml hwaccel.transcoding.yml; do
  [[ -f $HERE/$f ]] && cp "$HERE/$f" "$DIR/$f"
done

if [[ $UPGRADE == 1 ]]; then
  log "upgrading existing instance in $DIR to $TAG"
  cp "$DIR/.env" "$DIR/.env.bak"
  set_env "$DIR/.env" IMMICH_VERSION "$TAG"
  set_env "$DIR/.env" INSTANCE_NAME "$NAME"
  [[ -n $(get_env "$DIR/.env" MODEL_LOCATION) ]] || set_env "$DIR/.env" MODEL_LOCATION ./model-cache
  [[ -n $(get_env "$DIR/.env" IMMICH_PORT) ]]    || set_env "$DIR/.env" IMMICH_PORT "${PORT:-2283}"
  [[ -z $PORT ]] || set_env "$DIR/.env" IMMICH_PORT "$PORT"
else
  log "creating instance '$NAME' in $DIR"
  cp "$HERE/example.env" "$DIR/.env"
  set_env "$DIR/.env" INSTANCE_NAME "$NAME"
  set_env "$DIR/.env" DB_PASSWORD "$(random_alnum 32)"
  set_env "$DIR/.env" IMMICH_PORT "${PORT:-2283}"
  chmod 600 "$DIR/.env"
fi

# model cache -> MODEL_LOCATION (relative paths are relative to DIR)
ML_DIR=$(get_env "$DIR/.env" MODEL_LOCATION)
[[ $ML_DIR == /* ]] || ML_DIR=$DIR/${ML_DIR#./}
log "extracting models to $ML_DIR"
mkdir -p "$ML_DIR"
tar -xzf "$HERE/models.tar.gz" -C "$ML_DIR"

( cd "$DIR" && docker compose config -q ) || die "generated compose config is invalid"

if [[ $START == 1 ]]; then
  log "starting instance '$NAME'"
  ( cd "$DIR" && docker compose up -d --pull never )
fi

log "done. instance '$NAME' ($TAG) in $DIR, port $(get_env "$DIR/.env" IMMICH_PORT)"
[[ $START == 1 ]] || echo "   start with: cd $DIR && docker compose up -d --pull never"
