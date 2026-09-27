# shellcheck shell=bash
# Shared helpers for build.sh, deploy.sh and upload.sh.

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

need_compose() {
  docker compose version >/dev/null 2>&1 || die "'docker compose' (v2 plugin) is required"
}

random_alnum() { # immich only accepts A-Za-z0-9 for DB_PASSWORD
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "${1:-32}" || true
}

# Set KEY=VALUE in an env file (replace if present, append otherwise).
set_env() {
  local file=$1 key=$2 value=$3
  if grep -qE "^[#[:space:]]*${key}=" "$file"; then
    # replace the first (possibly commented) occurrence, drop the others
    awk -v k="$key" -v v="$value" '
      $0 ~ "^[#[:space:]]*" k "=" { if (!done) { print k "=" v; done=1 }; next }
      { print }' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

get_env() { # print value of KEY from an env file
  sed -n "s/^$2=//p" "$1" | tail -n1
}

# apply_patches UPSTREAM_COMPOSE UPSTREAM_ENV PATCH_DIR OUT_DIR
#
# Creates OUT_DIR/docker-compose.yml and OUT_DIR/example.env from the upstream
# files plus the separately maintained changes in PATCH_DIR:
#   docker-compose.patch  unified diff against the upstream docker-compose.yml
#   env.additions         lines appended to the upstream example.env
apply_patches() {
  local compose=$1 env=$2 pdir=$3 out=$4
  cp "$compose" "$out/docker-compose.yml"
  patch -d "$out" -p1 --forward --no-backup-if-mismatch --reject-file=- \
    <"$pdir/docker-compose.patch" >&2 ||
    die "$pdir/docker-compose.patch does not apply to this release's docker-compose.yml - please update it"
  cp "$env" "$out/example.env"
  cat "$pdir/env.additions" >>"$out/example.env"

  # sanity checks: fail loudly instead of producing a half-patched file
  ! grep -q 'container_name:' "$out/docker-compose.yml" || die "patch: container_name still present"
  # shellcheck disable=SC2016
  grep -q '\${MODEL_LOCATION}:/cache' "$out/docker-compose.yml" || die "patch: model cache mount missing"
  # shellcheck disable=SC2016
  grep -q '^name: \${INSTANCE_NAME' "$out/docker-compose.yml" || die "patch: instance name missing"
}

# strip_digests FILE
#
# Offline adjustment (not part of the patch, digests change every release):
# remove "@sha256:..." from image references so images restored with
# `docker load` are found by tag - docker load does not restore repo digests
# with the classic image store, and compose would try to pull them.
strip_digests() {
  sed -i -E 's/^([[:space:]]+image:[^@]*)@sha256:[0-9a-f]+/\1/' "$1"
}
