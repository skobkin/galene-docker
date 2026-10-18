# galene-docker

Automatically builds and publishes Docker images of [Galène](https://galene.org/), the open-source WebRTC video conferencing server, using [Woodpecker CI](https://woodpecker-ci.org/).

On every scheduled or manual run the pipeline checks upstream for a new stable release. If the matching image is already published to both configured registries, the run exits successfully without building. Otherwise it builds a multi-architecture image from the exact upstream release tag and pushes it to Docker Hub and GHCR with a versioned tag and `latest`.

The image is deliberately minimal: the two upstream binaries (`galene`, `galenectl`) and the upstream web UI on a small Alpine base. It does not configure TLS termination, Traefik, room definitions, credentials, or any other deployment-specific state — that belongs to the deployment repository (e.g. a Docker Compose stack behind a reverse proxy).

* Upstream project: <https://github.com/jech/galene>
* Documentation: <https://galene.org/> · <https://galene.org/galene-install.html>

## How the pipeline works

`.woodpecker/ci.yaml` defines three steps:

1. **prepare-release** — runs `sh tests/test-discovery.sh` (offline unit tests for the discovery logic) and `sh ci/prepare-release.sh`, which:
   * lists upstream git tags from the GitHub API (`/repos/jech/galene/tags`, paginated),
   * keeps only tags matching `galene-X.Y` / `galene-X.Y.Z`, sorts them by numeric version components and picks the newest,
   * resolves the tag's commit SHA and commit date,
   * checks whether the corresponding versioned image tag already exists **in both** target registries (Docker Registry HTTP API v2 manifest request with a pull-scope token),
   * writes `.woodpecker/release.env` (`GALENE_TAG`, `GALENE_VERSION`, `GALENE_COMMIT`, `GALENE_CREATED`, `SOURCE_DATE_EPOCH`, `SHOULD_BUILD`) and `.woodpecker/tags.txt` (`<version>` + `latest`).
2. **publish-dockerhub** and **publish-ghcr** — run in parallel via `woodpeckerci/plugin-docker-buildx` (privileged) and `ci/run-buildx.sh`, which builds `linux/amd64` and `linux/arm64` from the upstream release tarball, validates both binaries per platform, and pushes a multi-platform manifest under the versioned tag and `latest`. Build layer cache is kept in a `:buildcache` tag of each registry.

Steps only run on `manual` or on the `release-check` cron; ordinary repository pushes never trigger a build.

### Upstream release mechanism

Galène does **not** publish GitHub Releases objects (`/releases/latest` answers 404). Stable releases are git tags named `galene-X.Y` or `galene-X.Y.Z` (e.g. `galene-1.2.1`); release notes live in the upstream `CHANGES` file. Discovery therefore uses the git tags API, never the releases endpoint, and compares versions numerically rather than lexicographically (`1.10.0` sorts after `1.9.0`). Tags that do not match the strict release format (prereleases, ad-hoc tags) are ignored. The pipeline never builds `master`.

### Skip logic and idempotency

The existence check looks at the **versioned** tag only (e.g. `1.2.1`), in both registries:

* Both registries have it → `SHOULD_BUILD=0`, the publish steps exit successfully without building.
* Either registry is missing it → the image is built and published to both.

Implications to be aware of:

* `latest` is *not* checked; it is republished together with a new version. If someone deletes `latest` manually, it is only restored when the next upstream release appears (or when the matching version tag is also removed).
* If a published **versioned** tag is deleted from a registry, the next run will notice the missing image and rebuild + republish that version (and re-point `latest` at it if it is still the newest release). This is intentional: deletion means "not published" and is repaired on the next check — it never happens silently.
* A build is never published if the build itself fails; the pipeline fails before pushing.

## Published images

For upstream release `galene-1.2.1` the pipeline publishes:

| Registry | Tags |
|---|---|
| Docker Hub | `<DOCKERHUB_IMAGE_REPO>:1.2.1`, `<DOCKERHUB_IMAGE_REPO>:latest` |
| GHCR | `<GHCR_IMAGE_REPO>:1.2.1`, `<GHCR_IMAGE_REPO>:latest` |

`<DOCKERHUB_IMAGE_REPO>` has the Docker Hub form `namespace/repository` (e.g. `skobkin/galene`); `<GHCR_IMAGE_REPO>` has the form `ghcr.io/namespace/repository` (e.g. `ghcr.io/skobkin/galene-docker`).

Both tags always carry a multi-platform manifest containing the **same upstream release** for `linux/amd64` and `linux/arm64`.

Images carry OCI labels: title, description, upstream source URL, upstream version, upstream commit, release date (`created`), and `licenses=MIT`.

## Woodpecker setup

1. Enable the repository in Woodpecker and mark it **trusted** — the publish steps run the buildx plugin with `privileged: true` (the plugin runs its own BuildKit daemon), and Woodpecker grants privileged steps only to trusted repositories. This is a per-repository flag and does not carry over from other repositories.
2. Server/agent-level plugin allowlist: `WOODPECKER_PLUGINS_PRIVILEGED` must include `woodpeckerci/plugin-docker-buildx`. Any instance that already publishes another repository with the same plugin (the `:6` tag here) has this configured; it only needs revisiting if the plugin tag is bumped in `ci.yaml`.
3. Multi-arch builds require `binfmt_misc`/QEMU handlers on the CI agent for `linux/arm64` (`docker run --privileged tonistiigi/binfmt --install arm64` on the agent host).
4. Add the secrets below.
5. Create a cron job in the repository settings:
   * Name: `release-check`
   * Schedule: `0 */6 * * *` (every 6 hours; keeps release latency well under 24 hours; evaluation uses the Woodpecker server's timezone, typically UTC)
6. "Manual" runs from the UI use the same code path.

### Required secrets

| Secret | Contents |
|---|---|
| `DOCKERHUB_IMAGE_REPO` | Docker Hub target, e.g. `skobkin/galene` |
| `DOCKERHUB_LOGIN` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token |
| `GHCR_IMAGE_REPO` | GHCR target, e.g. `ghcr.io/skobkin/galene-docker` |
| `GHCR_LOGIN` | GitHub username owning the package |
| `GHCR_TOKEN` | GitHub token with `write:packages` |

All repository-specific input is modeled as secrets so manual and cron runs share the same configuration path. Credentials are only ever passed as environment variables to the publishing steps and never appear in logs, image layers, or build arguments.

## The image

* `ENTRYPOINT` is the `galene` server; there is no `CMD`, so container arguments are passed straight to Galène. Run `galenectl` by overriding the entrypoint (below).
* Runs as user/group `1000:1000`, working directory `/app`.
* Upstream default paths resolve against `/app`: `static/` (baked into the image), `data/`, `groups/`, `recordings/` (mount points).
* Web listener: `8443` — HTTPS with a self-signed certificate by default (auto-generated in `data/` on first start when `data/cert.pem` is absent); plain HTTP with `-insecure` (the typical mode behind a reverse proxy that terminates TLS).
* Built-in TURN server: `1194` TCP+UDP, active unless disabled with `-turn ""` or overridden by `data/ice-servers.json`.
* `SIGTERM`/`SIGINT` trigger a clean shutdown (safe as PID 1).
* No `HEALTHCHECK` is baked in: the correct probe depends on whether the operator runs TLS or `-insecure` and on the listener address. Define one in the deployment (e.g. with `-insecure` against `/`).
* No administrative credentials, users, groups, or rooms are included; an empty `data/` and `groups/` start a server that only you can configure (use `galenectl initial-setup`, see upstream docs).

### Running locally

```sh
mkdir -p data groups recordings
sudo chown -R 1000:1000 data groups recordings

docker run -d --name galene \
  -p 8443:8443 -p 1194:1194/tcp -p 1194:1194/udp \
  -v "$PWD/data:/app/data" \
  -v "$PWD/groups:/app/groups" \
  -v "$PWD/recordings:/app/recordings" \
  <registry>/galene:latest -insecure
# Web UI on http://localhost:8443/
```

* Mount `data/`, `groups/`, `recordings/` from the host or named volumes; they must be writable by uid `1000`. Empty directories are fine — Galène initializes what it needs (self-signed certificate, token storage).
* For production behind a reverse proxy: run with `-insecure`, terminate TLS externally, and set `proxyURL` / `canonicalHost` in `data/config.json` (created with `galenectl initial-setup`). The image itself never terminates TLS.
* Raise the file descriptor limit in the deployment for large meetings (upstream recommends a 65536 `nofile` limit).
* Host networking is fully supported (useful for the built-in TURN server and WebRTC NAT traversal): add `--network host` and drop the `-p` flags.

### Running `galenectl`

```sh
docker run --rm --entrypoint galenectl \
  -v "$PWD/data:/app/data" \
  <registry>/galene:latest \
  -url https://galene.example.org -admin-admin ... <command>
```

See `galenectl -h` and the upstream documentation for the full command set (`initial-setup`, `hash-password`, `delete-password`, …).

### Optional upstream assets excluded from the image

Galène's optional client-side **background blur** uses MediaPipe assets that upstream deliberately does not commit (`static/third-party/tasks-vision` is in upstream's `.gitignore`), and its model file is only published under an unpinned `latest` URL. The image therefore ships without them; Galène simply hides the background-blur menu entries and every other feature works normally.

To enable the feature without rebuilding, mount the assets from upstream's documented recipe (npm package `@mediapipe/tasks-vision` plus `selfie_segmenter.tflite`) over:

```
/app/static/third-party/tasks-vision
```

## Updating and Watchtower

Watchtower-style tools work off the `latest` tag: when upstream publishes a release, the next `release-check` run (within ~6 hours) republishes `latest`, and Watchtower recreates containers from it. Versioned tags are never overwritten for an already-published release (rebuilding the same version after a manual tag deletion produces a fresh image for that version). Pin a specific version tag in the deployment if you want updates to be an explicit act.

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

If the local Docker CLI has no buildx plugin, run the smoke test through the bundled one against your host daemon:

```sh
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$PWD:$PWD" -w "$PWD" \
  docker:28-cli sh ci/smoke-test.sh
```

The smoke test builds the image for the native architecture, checks that both binaries, the web UI, the licence file and the writable mount points are present, that no Go toolchain leaked into the runtime image, starts the server with a throwaway configuration, fetches the web UI through the container's HTTP listener, executes `galenectl`, and verifies graceful shutdown on `SIGTERM`.

A plain local build without CI:

```sh
docker build \
  --build-arg GALENE_TAG=galene-1.2.1 \
  --build-arg GALENE_VERSION=1.2.1 \
  -t galene:local .
```

## Troubleshooting

* **Prepare step fails with rate-limit / GitHub API errors** — discovery talks to `api.github.com` unauthenticated (60 requests/hour per IP). If the agent's IP is exhausted the run fails loudly and safely; re-run later or add authentication if this recurs.
* **Publish fails with `denied`/`unauthorized`** — check the registry secrets and that the GHCR token has `write:packages`; on Docker Hub use an access token rather than the account password.
* **`exec format error` or arm64 build failures in CI** — the agent is missing QEMU `binfmt_misc` handlers; install `tonistiigi/binfmt` for `arm64` on the agent host.
* **Plugin refuses to start (`privilege` errors)** — the repository is not trusted, or `woodpeckerci/plugin-docker-buildx` is missing from `WOODPECKER_PLUGINS_PRIVILEGED` on the server/agent.
* **Upstream bumped its Go requirement** — `Dockerfile` builds with `golang:1.24-alpine`; if a future release requires a newer toolchain, bump the builder image tag.
* **Server starts but has no TLS cert / cannot write files** — the mounted `data/` is not writable by uid `1000`; fix ownership (`chown -R 1000:1000`).
