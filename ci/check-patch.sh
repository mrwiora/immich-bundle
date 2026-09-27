#!/usr/bin/env bash
# Check that patches/ still apply to an immich release's compose file and that
# the result is a valid compose project. Needs no docker daemon.
#
# Usage: ci/check-patch.sh [TAG]   (default: latest release)
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
need curl patch docker jq
need_compose

TAG=${1:-latest}
if [[ $TAG == latest ]]; then
  DL=https://github.com/immich-app/immich/releases/latest/download
else
  DL=https://github.com/immich-app/immich/releases/download/$TAG
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

log "checking patches against immich $TAG"
curl -fsSL -o "$TMP/docker-compose.upstream.yml" "$DL/docker-compose.yml"
curl -fsSL -o "$TMP/example.upstream.env" "$DL/example.env"
mkdir -p "$TMP/out"
apply_patches "$TMP/docker-compose.upstream.yml" "$TMP/example.upstream.env" "$ROOT/patches" "$TMP/out"
strip_digests "$TMP/out/docker-compose.yml"
mv "$TMP/out/example.env" "$TMP/out/.env"
set_env "$TMP/out/.env" INSTANCE_NAME patchcheck
set_env "$TMP/out/.env" HOST_PORT 2299

name=$(cd "$TMP/out" && docker compose config --format json) || die "patched compose file is invalid"
jq -e '.name == "patchcheck"' <<<"$name" >/dev/null || die "INSTANCE_NAME is not used as project name"
jq -e '[.services[].container_name] | all(. == null)' <<<"$name" >/dev/null || die "container_name still set"
jq -e '.services["immich-server"].ports[0].published == "2299"' <<<"$name" >/dev/null || die "HOST_PORT not used"
log "ok: patches apply to $TAG"
