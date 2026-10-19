# galene-docker

Automatically builds and publishes Docker images of [Galène](https://galene.org/), the open-source WebRTC video conferencing server, using [Woodpecker CI](https://woodpecker-ci.org/).

On every scheduled or manual run the pipeline checks upstream for a new stable release and, unless both configured registries already have it, builds a multi-architecture image from the exact upstream release tag and pushes it to Docker Hub and GHCR.

The image is deliberately minimal: the upstream binaries (`galene`, `galenectl`) and web UI on a small Alpine base. TLS termination, rooms, and credentials are deployment concerns (e.g. a Compose stack behind a reverse proxy) and are not included.

* Upstream project: <https://github.com/jech/galene>
* Documentation: <https://galene.org/> · <https://galene.org/galene-install.html>

## Pulling the image

```sh
# Docker Hub
docker pull skobkin/galene:latest

# GHCR
docker pull ghcr.io/skobkin/galene-docker:latest
```

Every tag is a multi-platform manifest (`linux/amd64`, `linux/arm64`) built from the same upstream release. Published tags are `<version>` (e.g. `1.2.1`) and `latest`; pin the versioned tag if updates should be an explicit act. Images carry OCI labels: title, description, upstream source URL, version, commit, release date, `licenses=MIT`.

## How the pipeline works

`.woodpecker/ci.yaml` defines three steps, triggered only on `manual` runs and the `release-check` cron — ordinary pushes never build:

1. **prepare-release** — runs the offline discovery tests (`tests/test-discovery.sh`) and `ci/prepare-release.sh`, which lists upstream git tags via the GitHub API (paginated), picks the newest `galene-X.Y[.Z]` tag by numeric comparison, resolves its commit SHA/date, checks whether that version already exists **in both** registries, and writes `.woodpecker/release.env` (release tag/version/commit/date, `SOURCE_DATE_EPOCH`, `SHOULD_BUILD`) and `.woodpecker/tags.txt` (`<version>` + `latest`).
2. **publish-dockerhub** and **publish-ghcr** (parallel) — `woodpeckerci/plugin-docker-buildx` via `ci/run-buildx.sh` builds both platforms from the upstream release tarball, validates the binaries per platform, and pushes the versioned tag and `latest`. Build cache lives in a `:buildcache` tag per registry.

### Upstream release mechanism

Galène does **not** publish GitHub Releases objects; stable releases are git tags named `galene-X.Y[.Z]` (release notes in upstream `CHANGES`). Discovery therefore uses the git tags API and compares versions numerically (`1.10.0` sorts after `1.9.0`). Prereleases and other non-matching tags are ignored; `master` is never built.

### Skip logic

The existence check looks at the **versioned** tag only, in both registries: both present → `SHOULD_BUILD=0`, the run exits without building; either missing → build and publish to both.

* `latest` is never checked; it is republished with each new version. If deleted manually, it only returns with the next release.
* Deleting a published **versioned** tag makes the next run rebuild and republish that version (re-pointing `latest` if still the newest release). Deletion is treated as "not published" and repaired on the next check.
* A failed build is never published — the pipeline fails before pushing.

## Woodpecker setup

1. Enable the repository in Woodpecker and mark it **trusted** — the publish steps run the buildx plugin with `privileged: true` (it runs its own BuildKit daemon), and Woodpecker grants privileged steps only to trusted repositories. This is a per-repository flag and does not carry over from other repositories.
2. Server/agent-level plugin allowlist: `WOODPECKER_PLUGINS_PRIVILEGED` must include `woodpeckerci/plugin-docker-buildx`. Any instance already publishing another repository with the same plugin (the `:6` tag here) has this configured; revisit only if the plugin tag is bumped in `ci.yaml`.
3. Multi-arch builds need QEMU `binfmt_misc` handlers on the CI agent for `linux/arm64` (`docker run --privileged tonistiigi/binfmt --install arm64`).
4. Add the secrets below.
5. Create a cron job named `release-check` (e.g. `0 */6 * * *` — every 6 hours; evaluated in the server's timezone, typically UTC). Manual runs from the UI use the same code path.

### Required secrets

| Secret | Contents |
|---|---|
| `DOCKERHUB_IMAGE_REPO` | Docker Hub target, form `namespace/repository` (e.g. `skobkin/galene`) |
| `DOCKERHUB_LOGIN` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token |
| `GHCR_IMAGE_REPO` | GHCR target, form `ghcr.io/namespace/repository` (e.g. `ghcr.io/skobkin/galene-docker`) |
| `GHCR_LOGIN` | GitHub username owning the package |
| `GHCR_TOKEN` | GitHub token with `write:packages` |

All repository-specific input is modeled as secrets so manual and cron runs share one configuration path. Credentials reach only the publishing steps as environment variables and never appear in logs, image layers, or build arguments.

## The image

* `ENTRYPOINT` is the `galene` server; there is no `CMD`, so container arguments go straight to Galène. Run `galenectl` by overriding the entrypoint (below).
* Runs as uid/gid `1000`, workdir `/app`; upstream default paths resolve against it: `static/` (baked in), `data/`, `groups/`, `recordings/` (mount points).
* Web listener `8443`: HTTPS with a self-signed certificate (auto-generated in `data/` on first start) or plain HTTP with `-insecure` — the typical mode behind a reverse proxy that terminates TLS.
* Built-in TURN server on `1194` TCP+UDP, active unless disabled with `-turn ""` or overridden via `data/ice-servers.json`.
* `SIGTERM`/`SIGINT` trigger a clean shutdown (safe as PID 1).
* No `HEALTHCHECK`: the right probe depends on TLS vs `-insecure` and the listener address — define one in the deployment.
* No administrative credentials, users, groups, or rooms included; empty `data/` and `groups/` start a server only you can configure (`galenectl initial-setup`).

### Running locally

```sh
mkdir -p data groups recordings
sudo chown -R 1000:1000 data groups recordings

docker run -d --name galene \
  -p 8443:8443 -p 1194:1194/tcp -p 1194:1194/udp \
  -v "$PWD/data:/app/data" \
  -v "$PWD/groups:/app/groups" \
  -v "$PWD/recordings:/app/recordings" \
  skobkin/galene:latest -insecure
# Web UI on http://localhost:8443/
```

* Mounts must be writable by uid `1000`; empty directories are fine — Galène initializes what it needs (self-signed certificate, token storage).
* Production behind a reverse proxy: run with `-insecure`, terminate TLS externally, set `proxyURL`/`canonicalHost` in `data/config.json` (via `galenectl initial-setup`). The image never terminates TLS.
* Raise the file descriptor limit for large meetings (upstream recommends `nofile` 65536).
* Host networking is fully supported (useful for TURN and WebRTC NAT traversal): add `--network host` and drop the `-p` flags.

### Running `galenectl`

```sh
docker run --rm --entrypoint galenectl \
  -v "$PWD/data:/app/data" \
  skobkin/galene:latest \
  -url https://galene.example.org -admin-admin ... <command>
```

See `galenectl -h` and the upstream documentation for the full command set (`initial-setup`, `hash-password`, `delete-password`, …).

### Background blur assets

Galène's optional client-side background blur needs MediaPipe assets upstream deliberately does not commit (`static/third-party/tasks-vision`) and publishes only under an unpinned `latest` URL. The image ships without them — Galène simply hides the blur menu entries. To enable the feature without rebuilding, mount npm package `@mediapipe/tasks-vision` plus `selfie_segmenter.tflite` (upstream recipe) over `/app/static/third-party/tasks-vision`.

## Updating and Watchtower

Watchtower-style tools work off `latest`: a new upstream release is republished within ~6 hours of the next `release-check`, and Watchtower recreates containers from it. Versioned tags of already-published releases are never overwritten (rebuilding the same version after a manual tag deletion produces a fresh image for it).

## Building and testing locally

```sh
# resolve a release and generate .woodpecker/release.env
DOCKERHUB_IMAGE_REPO=local/test GHCR_IMAGE_REPO=ghcr.io/local/test \
  sh ci/prepare-release.sh

# discovery unit tests (offline)
sh tests/test-discovery.sh

# build + runtime smoke test
sh ci/smoke-test.sh
```

If the local Docker CLI lacks the buildx plugin, run the smoke test through the bundled one against the host daemon:

```sh
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:$PWD" -w "$PWD" \
  docker:28-cli sh ci/smoke-test.sh
```

The smoke test builds natively, checks binaries, web UI, licence file and writable mounts, verifies no Go toolchain leaked into the runtime image, starts the server, fetches the web UI over HTTP, runs `galenectl`, and checks graceful `SIGTERM` shutdown.

A plain build without CI:

```sh
docker build \
  --build-arg GALENE_TAG=galene-1.2.1 \
  --build-arg GALENE_VERSION=1.2.1 \
  -t galene:local .
```

## Troubleshooting

* **Prepare fails with GitHub API rate-limit errors** — discovery queries `api.github.com` unauthenticated (60 req/hour per IP); the run fails loudly and safely. Re-run later or add authentication if this recurs.
* **Publish fails with `denied`/`unauthorized`** — check the registry secrets: the GHCR token needs `write:packages`; on Docker Hub use an access token, not the account password.
* **`exec format error` or arm64 build failures** — the agent lacks QEMU `binfmt_misc` handlers; install `tonistiigi/binfmt` for `arm64` on the agent host.
* **Plugin refuses to start (privilege errors)** — the repository is not trusted, or `woodpeckerci/plugin-docker-buildx` is missing from `WOODPECKER_PLUGINS_PRIVILEGED`.
* **Upstream bumps its Go requirement** — the Dockerfile builds with `golang:1.24-alpine`; bump the builder tag if a future release needs newer.
* **Server starts without TLS cert / cannot write files** — `data/` is not writable by uid `1000`; `chown -R 1000:1000`.
