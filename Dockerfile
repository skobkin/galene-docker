# syntax=docker/dockerfile:1.7

FROM golang:1.24-alpine AS build

ARG GALENE_TAG
# TARGETARCH is a predefined BuildKit argument; asserted below so each
# platform's binary is verified to match the platform it is built for.
ARG TARGETARCH

WORKDIR /src

RUN test -n "${GALENE_TAG}"

RUN apk add --no-cache curl

# Build strictly from the resolved upstream release tag; never from master.
RUN curl -fsSL "https://github.com/jech/galene/archive/refs/tags/${GALENE_TAG}.tar.gz" \
	| tar -xz --strip-components=1

# Build-time assertion: the web UI sources must be present.
RUN test -f static/galene.html

# CGO_ENABLED=0 produces static binaries; Galène is pure Go. VCS stamping is
# disabled: the source is an extracted tag tarball with no git metadata, and
# provenance is carried by the GALENE_TAG/GALENE_COMMIT build arguments.
RUN --mount=type=cache,target=/go/pkg/mod \
	--mount=type=cache,target=/root/.cache/go-build \
	CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags='-s -w' -o /out/galene .

# galenectl lives in a subdirectory of the same Go module.
RUN --mount=type=cache,target=/go/pkg/mod \
	--mount=type=cache,target=/root/.cache/go-build \
	CGO_ENABLED=0 go build -C galenectl -buildvcs=false -trimpath -ldflags='-s -w' -o /out/galenectl .

# Build validation: both binaries must exist and be executable.
RUN test -x /out/galene && test -x /out/galenectl
RUN test "$(go env GOARCH)" = "${TARGETARCH}"

FROM alpine:3.23

# ARGs do not cross stage boundaries; re-declare the ones used for labels.
ARG GALENE_VERSION
ARG GALENE_COMMIT
ARG GALENE_CREATED
# SOURCE_DATE_EPOCH is a predefined BuildKit argument; declaring it keeps the
# declaration explicit. BuildKit uses it to set the image's "created" field.
ARG SOURCE_DATE_EPOCH

LABEL org.opencontainers.image.title="Galène" \
	org.opencontainers.image.description="Galène WebRTC video conferencing server" \
	org.opencontainers.image.source="https://github.com/jech/galene" \
	org.opencontainers.image.licenses="MIT" \
	org.opencontainers.image.version="${GALENE_VERSION}" \
	org.opencontainers.image.revision="${GALENE_COMMIT}" \
	org.opencontainers.image.created="${GALENE_CREATED}"

RUN apk add --no-cache ca-certificates \
	&& addgroup -g 1000 -S galene \
	&& adduser -S -D -H -u 1000 -G galene galene

COPY --from=build /out/galene /usr/local/bin/galene
COPY --from=build /out/galenectl /usr/local/bin/galenectl
COPY --from=build /src/static /app/static
COPY --from=build /src/LICENCE /usr/share/licenses/galene/LICENCE

# Persistent state (data/, groups/, recordings/) must be writable by the
# runtime user; operators normally mount these from the host or volumes.
RUN mkdir -p /app/data /app/groups /app/recordings \
	&& chown -R 1000:1000 /app

WORKDIR /app

USER 1000:1000

# 8443: HTTPS (or HTTP with -insecure) web listener.
# 1194: built-in TURN server (UDP and TCP), active unless disabled via -turn.
EXPOSE 8443 1194/tcp 1194/udp

# Default command starts the server; galène's relative default paths resolve
# against WORKDIR /app. Pass galène's own flags as container arguments, or
# override --entrypoint to run galenectl.
ENTRYPOINT ["/usr/local/bin/galene"]
