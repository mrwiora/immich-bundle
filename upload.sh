#!/usr/bin/env bash
# Upload bundle files to the central server.
#
# Target comes from UPLOAD_TARGET (environment or config.env):
#   user@host:/path/        -> rsync (falls back to scp); ssh options via
#                              RSYNC_RSH / SCP_OPTS, e.g. "ssh -i key"
#   https://host/path/      -> HTTP PUT per file via curl (e.g. WebDAV, S3 presigned
#                              prefix, nginx dav); extra curl options in UPLOAD_CURL_OPTS
#   /local/or/mounted/path  -> cp
#
# Usage: ./upload.sh FILE...
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091
[[ -f $ROOT/config.env ]] && source "$ROOT/config.env"

[[ $# -gt 0 ]] || die "usage: $0 FILE..."
[[ -n ${UPLOAD_TARGET:-} ]] || die "UPLOAD_TARGET is not set (see config.env.example)"

case $UPLOAD_TARGET in
  http://*|https://*)
    need curl
    # shellcheck disable=SC2206 # intentional word splitting of user options
    opts=(${UPLOAD_CURL_OPTS:-})
    for f in "$@"; do
      log "PUT $(basename "$f") -> ${UPLOAD_TARGET%/}/"
      curl -fS --retry 3 "${opts[@]}" -T "$f" "${UPLOAD_TARGET%/}/$(basename "$f")"
    done
    ;;
  *:*)
    if command -v rsync >/dev/null 2>&1; then
      log "rsync -> $UPLOAD_TARGET"
      rsync -aL --partial --progress "$@" "$UPLOAD_TARGET"
    else
      need scp
      log "scp -> $UPLOAD_TARGET"
      # shellcheck disable=SC2086 # SCP_OPTS: intentional word splitting
      scp ${SCP_OPTS:-} "$@" "$UPLOAD_TARGET"
    fi
    ;;
  *)
    log "cp -> $UPLOAD_TARGET"
    mkdir -p "$UPLOAD_TARGET"
    cp -L "$@" "$UPLOAD_TARGET"/
    ;;
esac
log "upload finished"
