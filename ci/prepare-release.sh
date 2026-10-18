#!/bin/sh

set -eu

: "${DOCKERHUB_IMAGE_REPO:?DOCKERHUB_IMAGE_REPO is required}"
: "${GHCR_IMAGE_REPO:?GHCR_IMAGE_REPO is required}"

UPSTREAM_REPO="${UPSTREAM_REPO:-jech/galene}"
RELEASE_ENV_FILE="${RELEASE_ENV_FILE:-.woodpecker/release.env}"
TAGS_FILE="${TAGS_FILE:-.woodpecker/tags.txt}"

# Upstream Galène does not publish GitHub Releases objects; git tags in the
# "galene-X.Y[.Z]" format are the authoritative release mechanism. Both URL
# prefixes are overridable so tests can point them at local fixtures.
GALENE_TAGS_URL="${GALENE_TAGS_URL:-https://api.github.com/repos/${UPSTREAM_REPO}/tags}"
GALENE_COMMITS_URL="${GALENE_COMMITS_URL:-https://api.github.com/repos/${UPSTREAM_REPO}/commits}"

PER_PAGE=100
MAX_TAG_PAGES="${MAX_TAG_PAGES:-10}"

page_files=""

cleanup() {
	if [ -n "${page_files}" ]; then
		# Intentional word splitting: one mktemp path per page.
		# shellcheck disable=SC2086
		rm -f ${page_files}
	fi
}
trap cleanup EXIT INT TERM

fetch_json() {
	# $1 = URL; prints the response body. Fails hard on HTTP errors.
	curl -fsSL \
		-H "Accept: application/vnd.github+json" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		"$1"
}

fetch_tags_page() {
	# $1 = page number; prints one JSON array of tag objects to stdout.
	# Fixture (file://) URLs are fetched verbatim: query parameters would be
	# part of the file path, so only page 1 carries data.
	page="$1"

	case "${GALENE_TAGS_URL}" in
		file://*)
			if [ "${page}" -gt 1 ]; then
				printf '[]'
				return 0
			fi
			fetch_json "${GALENE_TAGS_URL}"
			;;
		*)
			case "${GALENE_TAGS_URL}" in
				*\?*) separator='&' ;;
				*) separator='?' ;;
			esac
			fetch_json "${GALENE_TAGS_URL}${separator}per_page=${PER_PAGE}&page=${page}"
			;;
	esac
}

fetch_commit() {
	# Prints the GitHub commit object for the resolved release tag.
	# Fixture bases are directories holding "<sha>.json" files.
	case "${GALENE_COMMITS_URL}" in
		file://*)
			fetch_json "${GALENE_COMMITS_URL}/${GALENE_COMMIT}.json"
			;;
		*)
			fetch_json "${GALENE_COMMITS_URL}/${GALENE_COMMIT}"
			;;
	esac
}

dockerhub_token() {
	curl -fsSL \
		"https://auth.docker.io/token?service=registry.docker.io&scope=repository:${1}:pull" \
		| jq -r '.token'
}

ghcr_token() {
	if [ -n "${GHCR_LOGIN:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
		curl -fsSL \
			-u "${GHCR_LOGIN}:${GHCR_TOKEN}" \
			"https://ghcr.io/token?service=ghcr.io&scope=repository:${1}:pull" \
			| jq -r '.token'
		return
	fi

	curl -fsSL \
		"https://ghcr.io/token?service=ghcr.io&scope=repository:${1}:pull" \
		| jq -r '.token'
}

registry_manifest_status() {
	registry_url="$1"
	repo="$2"
	tag="$3"
	token="$4"

	curl -sS -o /dev/null -w '%{http_code}' \
		-H "Authorization: Bearer ${token}" \
		-H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
		"${registry_url}/v2/${repo}/manifests/${tag}"
}

tag_exists_in_dockerhub() {
	status="$(registry_manifest_status "https://registry-1.docker.io" "$1" "$2" "$(dockerhub_token "$1")")"
	[ "${status}" = "200" ]
}

tag_exists_in_ghcr() {
	status="$(registry_manifest_status "https://ghcr.io" "$1" "$2" "$(ghcr_token "$1")")"
	[ "${status}" = "200" ]
}

# Download every tag listing page, stopping at the first empty or short page.
page=1
while :; do
	page_file="$(mktemp)"
	fetch_tags_page "${page}" > "${page_file}"
	page_files="${page_files} ${page_file}"

	page_length="$(jq -r 'if type == "array" then length else -1 end' "${page_file}")"
	if [ "${page_length}" -lt 0 ]; then
		echo "Tag listing page ${page} is not a JSON array; aborting." >&2
		exit 1
	fi
	[ "${page_length}" -eq 0 ] && break
	[ "${page_length}" -lt "${PER_PAGE}" ] && break

	page=$((page + 1))
	if [ "${page}" -gt "${MAX_TAG_PAGES}" ]; then
		echo "Tag listing did not fit in ${MAX_TAG_PAGES} pages; aborting." >&2
		exit 1
	fi
done

# Pick the newest stable tag. Version components are compared numerically
# ("1.10.0" sorts after "1.9.0", "1.2.1" after "1.2"); anything not matching
# the strict release format (prereleases, junk) is discarded.
# shellcheck disable=SC2086
selected="$(jq -s '
	add
	| map(select(.name | test("^galene-[0-9]+\\.[0-9]+(\\.[0-9]+)?$")))
	| sort_by(.name | sub("^galene-"; "") | split(".") | map(tonumber))
	| if length > 0 then .[-1] else empty end
' ${page_files})"

if [ -z "${selected}" ]; then
	echo "No stable Galène release tags found in ${GALENE_TAGS_URL}." >&2
	exit 1
fi

GALENE_TAG="$(printf '%s' "${selected}" | jq -r '.name')"
GALENE_COMMIT="$(printf '%s' "${selected}" | jq -r '.commit.sha')"

if [ -z "${GALENE_TAG}" ] || [ "${GALENE_TAG}" = "null" ]; then
	echo "Unable to determine the latest Galène release tag." >&2
	exit 1
fi
if [ -z "${GALENE_COMMIT}" ] || [ "${GALENE_COMMIT}" = "null" ]; then
	echo "Unable to determine the commit of ${GALENE_TAG}." >&2
	exit 1
fi

GALENE_VERSION="${GALENE_TAG#galene-}"

commit_json="$(fetch_commit)"
GALENE_CREATED="$(printf '%s' "${commit_json}" | jq -r '.commit.committer.date')"
SOURCE_DATE_EPOCH="$(printf '%s' "${commit_json}" | jq -r '.commit.committer.date | fromdateiso8601')"

if [ -z "${GALENE_CREATED}" ] || [ "${GALENE_CREATED}" = "null" ]; then
	echo "Unable to determine the release date of ${GALENE_TAG}." >&2
	exit 1
fi

should_build=1

if [ "${GALENE_SKIP_REGISTRY_CHECK:-0}" = "1" ]; then
	echo "Skipping registry existence check (GALENE_SKIP_REGISTRY_CHECK=1)."
elif tag_exists_in_dockerhub "${DOCKERHUB_IMAGE_REPO}" "${GALENE_VERSION}" \
	&& tag_exists_in_ghcr "${GHCR_IMAGE_REPO}" "${GALENE_VERSION}"; then
	should_build=0
fi

mkdir -p "$(dirname "${RELEASE_ENV_FILE}")"

cat > "${RELEASE_ENV_FILE}" <<EOF
GALENE_TAG=${GALENE_TAG}
GALENE_VERSION=${GALENE_VERSION}
GALENE_COMMIT=${GALENE_COMMIT}
GALENE_CREATED=${GALENE_CREATED}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}
SHOULD_BUILD=${should_build}
EOF

cat > "${TAGS_FILE}" <<EOF
${GALENE_VERSION}
latest
EOF

echo "Resolved Galène release: ${GALENE_TAG} (${GALENE_COMMIT}, ${GALENE_CREATED})"
if [ "${should_build}" = "1" ]; then
	echo "At least one target registry is missing ${GALENE_VERSION}; build will proceed."
else
	echo "Both target registries already have ${GALENE_VERSION}; build will be skipped."
fi
