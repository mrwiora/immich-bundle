#!/usr/bin/env bash
# Prepare a Debian 12/13 machine as self-hosted GitHub Actions runner for the
# "Build bundle" workflow: Docker CE (official repo), build tools and the
# actions runner as a systemd service with the label "immich-bundle".
#
# Get a registration token from: repository -> Settings -> Actions -> Runners
# -> New self-hosted runner (valid for one hour), then as root:
#
#   ./ci/setup-runner-debian.sh --url https://github.com/OWNER/REPO --token XXXX
#
# Afterwards set the repository variable BUILD_RUNNER=immich-bundle.
set -Eeuo pipefail

URL=""
TOKEN=""
RUNNER_USER=ghrunner
RUNNER_DIR=/opt/actions-runner
LABELS=immich-bundle
NAME=$(hostname)-immich-bundle

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  --url URL        repository URL (required)
  --token TOKEN    runner registration token (required)
  --user USER      local user running the service (default: $RUNNER_USER)
  --dir DIR        install directory (default: $RUNNER_DIR)
  --labels LIST    extra runner labels, comma separated (default: $LABELS)
  --name NAME      runner name (default: $NAME)
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --url) URL=$2; shift 2 ;;
    --token) TOKEN=$2; shift 2 ;;
    --user) RUNNER_USER=$2; shift 2 ;;
    --dir) RUNNER_DIR=$2; shift 2 ;;
    --labels) LABELS=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ $EUID == 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -n $URL && -n $TOKEN ]] || { usage >&2; exit 1; }
# shellcheck source=/dev/null
. /etc/os-release
[[ $ID == debian ]] || echo "WARNING: written for Debian, found $ID" >&2

echo "==> packages"
apt-get update
apt-get install -y ca-certificates curl gnupg jq patch tar gzip coreutils \
  git rsync openssh-client gh

echo "==> docker (download.docker.com)"
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $VERSION_CODENAME stable" >/etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

echo "==> user $RUNNER_USER"
id "$RUNNER_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$RUNNER_USER"
usermod -aG docker "$RUNNER_USER"

echo "==> actions runner"
case $(uname -m) in
  x86_64) arch=x64 ;;
  aarch64) arch=arm64 ;;
  *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
version=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name)
version=${version#v}
mkdir -p "$RUNNER_DIR"
if [[ ! -x $RUNNER_DIR/config.sh ]]; then
  curl -fsSL "https://github.com/actions/runner/releases/download/v$version/actions-runner-linux-$arch-$version.tar.gz" |
    tar -xz -C "$RUNNER_DIR"
fi
"$RUNNER_DIR/bin/installdependencies.sh"
chown -R "$RUNNER_USER:" "$RUNNER_DIR"

sudo -u "$RUNNER_USER" "$RUNNER_DIR/config.sh" --unattended --replace \
  --url "$URL" --token "$TOKEN" --name "$NAME" --labels "$LABELS"
( cd "$RUNNER_DIR" && ./svc.sh install "$RUNNER_USER" && ./svc.sh start )

for d in "$RUNNER_DIR" /var/lib/docker; do
  free=$(df -BG --output=avail "$d" | tail -1 | tr -dc 0-9)
  (( free >= 40 )) || echo "WARNING: only ${free}G free on $d - a build needs ~30-40G" >&2
done
echo "==> done. Set the repository variable BUILD_RUNNER=${LABELS%%,*}"
