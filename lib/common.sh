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
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}" || true
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

# patch_compose IN OUT PROJECT_NAME MODE STRIP_DIGESTS
#
# Applies the multi-instance changes to an upstream immich docker-compose.yml:
#   * top-level `name:` is replaced by PROJECT_NAME
#   * all `container_name:` lines are removed (compose then derives unique
#     names from the project name, e.g. up-immich-server-1)
#   * the published port becomes '${IMMICH_PORT:-2283}:2283'
#   * MODE=bind:   model-cache volume -> ${MODEL_LOCATION}:/cache and the
#                  top-level named volume declaration is removed
#     MODE=volume: model-cache stays a named docker volume
#   * STRIP_DIGESTS=1 removes "@sha256:..." from image references so images
#     restored with `docker load` are found by tag (docker load does not
#     restore repo digests with the classic image store).
patch_compose() {
  local in=$1 out=$2 name=$3 mode=$4 strip=${5:-0}
  awk -v name="$name" -v mode="$mode" -v strip="$strip" -v q="'" '
    # --- top-level volumes: section (only rewritten in bind mode) ---
    in_vol && /^[^[:space:]#]/ { in_vol = 0 }
    in_vol {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^[[:space:]]+model-cache:[[:space:]]*$/) next
      if (vol_hdr_pending) { print "volumes:"; vol_hdr_pending = 0 }
      print; next
    }
    mode == "bind" && /^volumes:[[:space:]]*$/ { in_vol = 1; vol_hdr_pending = 1; next }

    /^name:/                         { print "name: " name; next }
    /^[[:space:]]+container_name:/   { next }
    $0 ~ "^[[:space:]]+- [\"" q "]?2283:2283[\"" q "]?[[:space:]]*$" {
      sub("[\"" q "]?2283:2283[\"" q "]?", q "${IMMICH_PORT:-2283}:2283" q); print; next
    }
    mode == "bind" && /^[[:space:]]+- model-cache:\/cache/ {
      sub(/model-cache:/, "${MODEL_LOCATION}:"); print; next
    }
    strip == 1 && /^[[:space:]]+image:/ { sub(/@sha256:[0-9a-f]+/, ""); print; next }
    { print }
  ' "$in" >"$out"

  # Fail loudly if upstream changed the file layout and a patch did not apply.
  grep -qx "name: $name" "$out"                 || die "patch: project name not set in $out"
  ! grep -q 'container_name:' "$out"            || die "patch: container_name still present in $out"
  grep -q 'IMMICH_PORT:-2283}:2283' "$out"      || die "patch: port mapping not found in $out"
  if [[ $mode == bind ]]; then
    # shellcheck disable=SC2016
    grep -q '\${MODEL_LOCATION}:/cache' "$out"  || die "patch: model-cache mount not found in $out"
    ! grep -q 'model-cache' "$out"              || die "patch: model-cache still referenced in $out"
  else
    grep -q 'model-cache:/cache' "$out"         || die "patch: model-cache volume not found in $out"
  fi
  if [[ $strip == 1 ]]; then
    ! grep -qE '^[[:space:]]+image:.*@sha256:' "$out" || die "patch: image digests still present in $out"
  fi
}
