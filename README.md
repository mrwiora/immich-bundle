# immich-bundle

Offline bundles for [immich](https://immich.app), plus multi-instance deployment.

> [!IMPORTANT]
> **No pre-built bundles are published here. Build your own. It takes one command.**
>
> **Why:** a bundle contains the machine-learning models that immich normally
> downloads by itself on first use. Not all of them may be passed on freely.
> The face recognition model (`buffalo_l` by
> [InsightFace](https://github.com/deepinsight/insightface#license)) is
> licensed for *non-commercial research purposes only*, so sharing it inside a
> download bundle is not allowed without InsightFace's permission. The other
> parts (immich and VectorChord under AGPL-3.0, CLIP under MIT, the PaddleOCR
> models under Apache-2.0) would also require licence texts and source
> references to be distributed alongside. For that reason, this repository
> only ships the **tooling**, not the result.
>
> **What you can do:** build the bundles yourself, for your own use. You
> download the same files immich would download on your server anyway. You
> just do it once, in advance. You have two options:
>
> 1. **On premise, without GitHub**, on any Linux machine with Docker (Debian
>    recommended):
>    ```sh
>    git clone https://github.com/mrwiora/immich-bundle && cd immich-bundle
>    ./build.sh            # -> dist/immich-bundle-vX.Y.Z.tar
>    ```
>    `build.sh`, `deploy.sh` and `upload.sh` are plain shell scripts. They
>    need neither GitHub Actions nor the `gh` CLI nor a GitHub account. They only
>    download immich's public release files, container images and models.
>    Use cron to follow new releases automatically (see [Build](#build)).
> 2. **In a *private* GitHub repository** with the included workflow
>    ([Automated builds](#automated-builds-github-actions)). The simplest way
>    is to **fork** this repository: a fork of a private repository stays
>    private. Then enable Actions in your fork.
>    If you got the code from a *public* copy, don't fork it, because forks of
>    public repositories are always public. Create a private copy instead:
>    ```sh
>    # first create an empty *private* repository, e.g. YOU/immich-bundle
>    git clone --bare https://github.com/mrwiora/immich-bundle
>    git -C immich-bundle.git push --mirror https://github.com/YOU/immich-bundle
>    ```
>    As a safeguard, the workflow only attaches the bundle to a release if the
>    repository is private.
>
> Keep the bundles to yourself or your own organisation, and don't upload them
> anywhere public. This note is not legal advice. If you want to pass bundles
> on, check the licences of everything they contain first.

`build.sh` automates the manual steps for the latest release:

1. Resolves the latest release tag, e.g. `v3.0.1`. It then downloads that
   release's `docker-compose.yml` and `example.env`, plus `hwaccel.*.yml` if
   the release has them.
2. Starts a throw-away instance. It gets its own project name
   (`immich-bundle-build`) and listens on `127.0.0.1:12283`, so it doesn't collide
   with the instances already running on the server.
3. Uses the API to create the first admin user and upload a sample picture.
   It then runs one smart search, because the text half of the CLIP model only
   loads during a search.
4. Polls the job queues until they are idle, meaning thumbnails, CLIP, face
   detection and recognition, and OCR have all finished and the ML models are
   downloaded. Then, for every further OCR model in `OCR_MODELS`, it switches
   the OCR model and re-runs OCR on all assets, so that model is downloaded
   too. By default both `PP-OCRv5_mobile` (immich's default) and
   `ESLAV__PP-OCRv5_mobile` (Russian, Belarusian, Ukrainian and English) are
   bundled, so either can be selected offline under Administration → Settings
   → Machine Learning → OCR.
5. Exports the model cache from the ML container with
   `docker cp <ml-container>:/cache`. The build instance runs the same patched
   compose file as your instances, so the cache is in `MODEL_LOCATION`.
6. Exports every image the compose file uses into one `docker save` archive.
7. Writes the bundle, deletes the build instance, and optionally uploads the
   result.

## Build

Requirements: `docker` with the compose plugin, `curl`, `jq`, `tar`, `gzip`,
`sha256sum`, `patch`.

```sh
./build.sh                          # latest release
./build.sh --version v3.0.1         # specific release
./build.sh --sample ~/me.jpg        # real photo with a face (recommended)
./build.sh --keep                   # leave the build instance running to inspect it
./build.sh --upload                 # upload afterwards (see below)
```

Output:

```
dist/immich-bundle-v3.0.1.tar           # the bundle
dist/immich-bundle-v3.0.1.tar.sha256
dist/immich-bundle-latest.tar           # symlink to the newest bundle
work/v3.0.1/cache/                      # extracted model cache (plain folder)
```

If the bundle for the current latest release already exists, `build.sh` does
nothing unless you pass `--force`. You can therefore run it from cron to always
follow the latest release:

```cron
0 4 * * *  cd /opt/immich-bundle && ./build.sh --upload >> build.log 2>&1
```

### Bundle content

| file | purpose |
|---|---|
| `images.tar.gz` | `docker save` of all images (server, ML, valkey, postgres) |
| `models.tar.gz` | ML model cache (clip, facial-recognition, ocr, …) |
| `docker-compose.yml` | upstream file with `patches/docker-compose.patch` applied (see below) |
| `example.env` | upstream env with `IMMICH_VERSION` pinned, plus `patches/env.additions` |
| `patches/` | the patches used for this bundle |
| `docker-compose.upstream.yml`, `example.upstream.env` | unmodified upstream files |
| `hwaccel.*.yml` | upstream hardware acceleration files (if present) |
| `deploy.sh`, `lib/` | installer for the offline host |
| `manifest.json`, `images.txt` | version, build info, image references and IDs |
| `SHA256SUMS` | checksums of all of the above |

## Deploy (offline host)

```sh
tar -xf immich-bundle-v3.0.1.tar
cd immich-bundle-v3.0.1
./deploy.sh --name up   --dir /srv/immich/up   --port 2284 --start
./deploy.sh --name down --dir /srv/immich/down --port 2285 --start --skip-load
```

`deploy.sh` does the following:

- verifies the checksums
- runs `docker load` on the images
- copies the patched `docker-compose.yml`
- creates `.env` with `INSTANCE_NAME=<NAME>`, your port and a random `DB_PASSWORD`
- extracts the models to `MODEL_LOCATION` (default `<dir>/model-cache`)

Nothing is pulled from the internet: start the instance with
`docker compose up -d --pull never`.

**Upgrades:** run `deploy.sh` with the same `--name` and `--dir` from a newer
bundle. It keeps your `.env` and only updates `IMMICH_VERSION`, the compose
file and the models. It saves `.bak` copies of the previous `.env` and
compose file. Back up the database and read the immich release notes before
upgrading.

### Changes to the upstream compose file

All changes live in `patches/`, separate from the scripts:

| file | applied as |
|---|---|
| [`patches/docker-compose.patch`](patches/docker-compose.patch) | unified diff, `patch -p1` against the release's `docker-compose.yml` |
| [`patches/env.additions`](patches/env.additions) | appended to the release's `example.env` |

The patch is your manual diff. The instance name and port are now variables,
so the same compose file works for every instance:

```diff
-name: immich
+name: ${INSTANCE_NAME:-immich}
-    container_name: immich_server        # (all four container_name lines)
-      - '2283:2283'
+      - '${HOST_PORT:-2283}:2283'
-      - model-cache:/cache
+      - ${MODEL_LOCATION}:/cache
-volumes:
-  model-cache:
```

`INSTANCE_NAME`, `MODEL_LOCATION` and `HOST_PORT` are set in each
instance's `.env`, and `deploy.sh --name/--port` fills them in. The build
instance uses the same patched file, so every build also tests the patch.

The patch uses one line of context, so it still applies when upstream changes
image digests or moves lines around. If it no longer applies, `build.sh` stops.
To update it:

```sh
curl -fsSLo a.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
cp a.yml b.yml && $EDITOR b.yml
diff -U1 --label a/docker-compose.yml --label b/docker-compose.yml a.yml b.yml > patches/docker-compose.patch
```

**Offline adjustment, not part of the patch:** the bundle's compose file also
has the `@sha256:` digests removed from the valkey and postgres images, because
the digests change with every release. `docker load` doesn't restore repo
digests with the classic image store, so compose would otherwise try to pull
the images. The digests are verified when the images are pulled during the
build and are recorded in `images.txt` and `manifest.json`.

## Upload

Copy `config.env.example` to `config.env` and set `UPLOAD_TARGET`:

```sh
UPLOAD_TARGET=user@host:/srv/immich-bundle/      # rsync (or scp)
UPLOAD_TARGET=https://files.example.org/immich/   # HTTP PUT via curl
UPLOAD_CURL_OPTS="--user uploader:secret"
UPLOAD_TARGET=/mnt/share/immich-bundle           # local / mounted directory
```

Then use `./build.sh --upload`, or `./upload.sh dist/immich-bundle-v3.0.1.tar*`.

## Automated builds (GitHub Actions)

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs every night.
It builds a bundle only when a new immich release exists.

- **Record of built versions:** each built version gets a release in this
  repository with the same tag (e.g. `v3.0.1`). A version that already has a
  release is skipped.
- **Release files:** the release holds `manifest.json`, the patched
  `docker-compose.yml`, `example.env`, the checksums and the bundle itself.
  The bundle is only attached if the repository is **private** (see the note
  at the top). In a public repository it is left out automatically.
  Release assets are limited to 2 GiB each, so the bundle is split into
  `.part-NN` files. Put it back together with:
  `cat immich-bundle-vX.Y.Z.tar.part-* > immich-bundle-vX.Y.Z.tar`.
- **Upload:** if `UPLOAD_TARGET` is set, the bundle is also sent to your server.
- **Manual runs:** *Actions → Build bundle → Run workflow* builds any version.
  Tick `force` to rebuild a version that already has a release.

[`.github/workflows/check.yml`](.github/workflows/check.yml) runs on every
push and pull request. It runs shellcheck and checks that `patches/` still
applies to the latest immich compose file (`ci/check-patch.sh`). It also
checks that the scripts run without GitHub: no `gh` calls, and `build.sh`
works with the Actions environment cleared. This check needs no Docker daemon.

Settings (*Settings → Secrets and variables → Actions*):

| name | kind | purpose |
|---|---|---|
| `BUILD_RUNNER` | variable | runner label, default `ubuntu-latest`; `immich-bundle` for the self-hosted runner below |
| `RELEASE_BUNDLE` | variable | `false`: don't attach the bundle parts to the release (never attached in a public repository) |
| `UPLOAD_TARGET` | secret | `user@host:/path/`, `https://…/` or a mounted path (see [Upload](#upload)) |
| `UPLOAD_SSH_KEY` | secret | private key for rsync/scp targets |
| `UPLOAD_KNOWN_HOSTS` | secret | `ssh-keyscan <host>` output for rsync/scp targets |
| `UPLOAD_CURL_OPTS` | secret | extra curl options for https targets |

### GitHub-hosted or self-hosted runner

GitHub's `ubuntu-latest` runners come with Docker and Docker Compose, so the
workflow should run there without a server of your own. The workflow first
frees about 30 GB of preinstalled software, because a build needs roughly
30–40 GB of disk. The bundle is built for the runner's architecture, which is
x86_64.

Use a self-hosted runner if the hosted one runs out of disk or time, or if you
want to upload into your internal network. **Use Debian, not Arch Linux.**

- **Docker:** Docker publishes official `docker-ce` packages for Debian. Arch
  only has community packages that follow its rolling updates.
- **Actions runner:** the runner's `installdependencies.sh` supports
  Debian/Ubuntu (and RHEL, SUSE). Arch isn't supported.
- **Maintenance:** Debian stable changes little between releases, which suits
  an unattended build machine. A rolling distribution can break Docker or the
  runner with any update.

Set up a fresh Debian 12 or 13 machine as root with a registration token from
*Settings → Actions → Runners → New self-hosted runner*:

```sh
git clone https://github.com/OWNER/REPO && cd REPO
./ci/setup-runner-debian.sh --url https://github.com/OWNER/REPO --token <TOKEN>
```

Then set the variable `BUILD_RUNNER=immich-bundle`. The script does four
things:

- installs Docker from `download.docker.com`
- installs the build tools, including `gh`
- creates a `ghrunner` user in the `docker` group
- registers the runner as a systemd service with the label `immich-bundle`

Use a dedicated machine or VM. The workflow deletes the images it pulled after
each build, but it leaves images that containers are using.
