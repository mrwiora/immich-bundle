# immichOFF

Offline bundles for [immich](https://immich.app), plus multi-instance deployment.

`build.sh` automates the manual steps for the latest release:

1. Resolves the latest release tag, e.g. `v3.0.1`. It then downloads that
   release's `docker-compose.yml` and `example.env`, plus `hwaccel.*.yml` if
   the release has them.
2. Starts a throw-away instance. It gets its own project name
   (`immichoff-build`) and listens on `127.0.0.1:12283`, so it doesn't collide
   with the instances already running on the server.
3. Uses the API to create the first admin user and upload a sample picture.
   It then runs one smart search, because the text half of the CLIP model only
   loads during a search.
4. Polls the job queues until they are idle, meaning thumbnails, CLIP, face
   detection and recognition, and OCR have all finished and the ML models are
   downloaded.
5. Exports the model cache directly from the docker volume
   (`docker cp <ml-container>:/cache`). No bind mount is needed while building.
6. Exports every image the compose file uses into one `docker save` archive.
7. Writes the bundle, deletes the build instance, and optionally uploads the
   result.

## Build

Requirements: `docker` with the compose plugin, `curl`, `jq`, `tar`, `gzip`,
`sha256sum`.

```sh
./build.sh                          # latest release
./build.sh --version v3.0.1         # specific release
./build.sh --sample ~/me.jpg        # real photo with a face (recommended)
./build.sh --keep                   # leave the build instance running to inspect it
./build.sh --upload                 # upload afterwards (see below)
```

Output:

```
dist/immich-offline-v3.0.1.tar          # the bundle
dist/immich-offline-v3.0.1.tar.sha256
dist/immich-offline-latest.tar          # symlink to the newest bundle
work/v3.0.1/cache/                      # extracted model cache (plain folder)
```

If the bundle for the current latest release already exists, `build.sh` does
nothing unless you pass `--force`. You can therefore run it from cron to always
follow the latest release:

```cron
0 4 * * *  cd /opt/immichOFF && ./build.sh --upload >> build.log 2>&1
```

### Bundle content

| file | purpose |
|---|---|
| `images.tar.gz` | `docker save` of all images (server, ML, valkey, postgres) |
| `models.tar.gz` | ML model cache (clip, facial-recognition, ocr, …) |
| `docker-compose.yml` | multi-instance template (see below) |
| `example.env` | upstream env with `IMMICH_VERSION` pinned, plus `MODEL_LOCATION` and `IMMICH_PORT` |
| `docker-compose.upstream.yml`, `example.upstream.env` | unmodified upstream files |
| `hwaccel.*.yml` | upstream hardware acceleration files (if present) |
| `deploy.sh`, `lib/` | installer for the offline host |
| `manifest.json`, `images.txt` | version, build info, image references and IDs |
| `SHA256SUMS` | checksums of all of the above |

## Deploy (offline host)

```sh
tar -xf immich-offline-v3.0.1.tar
cd immich-offline-v3.0.1
./deploy.sh --name up   --dir /srv/immich/up   --port 2284 --start
./deploy.sh --name down --dir /srv/immich/down --port 2285 --start --skip-load
```

`deploy.sh` does the following:

- verifies the checksums
- runs `docker load` on the images
- writes `docker-compose.yml` with `name: <NAME>`
- creates `.env` with a random `DB_PASSWORD`
- extracts the models to `MODEL_LOCATION` (default `<dir>/model-cache`)

Nothing is pulled from the internet: start the instance with
`docker compose up -d --pull never`.

**Upgrades:** run `deploy.sh` with the same `--name` and `--dir` from a newer
bundle. It keeps your `.env` and only updates `IMMICH_VERSION`, the compose
file and the models. It saves `.bak` copies of the previous `.env` and
compose file. Back up the database and read the immich release notes before
upgrading.

### Changes to the upstream compose file

These are the changes from your manual diff, plus two additions:

```diff
-name: immich
+name: up
-    container_name: immich_server        # (all four container_name lines)
-      - '2283:2283'
+      - '${IMMICH_PORT:-2283}:2283'      # port per instance via .env
-      - model-cache:/cache
+      - ${MODEL_LOCATION}:/cache
-    image: docker.io/valkey/valkey:9@sha256:…
+    image: docker.io/valkey/valkey:9     # digest removed, see below
-volumes:
-  model-cache:
```

- **Port:** `IMMICH_PORT` sets the published port for each instance. It can
  include a bind address, for example `127.0.0.1:2284`.
- **Image digests:** these are removed from the deployment template.
  `docker load` doesn't restore repo digests with the classic image store, so
  compose would otherwise try to pull the images. The digests were verified
  when the images were pulled during the build. They are recorded in
  `images.txt` and `manifest.json`, and `SHA256SUMS` protects the bundle.

If upstream changes its compose layout and a patch no longer applies, the
scripts stop with an error instead of producing a broken file.

## Upload

Copy `config.env.example` to `config.env` and set `UPLOAD_TARGET`:

```sh
UPLOAD_TARGET=user@host:/srv/immich-offline/      # rsync (or scp)
UPLOAD_TARGET=https://files.example.org/immich/   # HTTP PUT via curl
UPLOAD_CURL_OPTS="--user uploader:secret"
UPLOAD_TARGET=/mnt/share/immich-offline           # local / mounted directory
```

Then use `./build.sh --upload`, or `./upload.sh dist/immich-offline-v3.0.1.tar*`.
