#!/bin/sh

# Offline unit tests for ci/prepare-release.sh release discovery.
# Feeds the script fixture tag listings through file:// URL overrides and
# checks the selected release, the generated release.env/tags.txt, and the
# failure paths (empty tag list, malformed upstream response).
#
# Usage: sh tests/test-discovery.sh

set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
prepare="${repo_root}/ci/prepare-release.sh"
fixtures="${script_dir}/fixtures"

TEST_SHA="0123456789abcdef0123456789abcdef01234567"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT INT TERM

failures=0

run_case() {
	# $1 = case name, $2 = tags fixture file; returns the script's exit code.
	case_dir="${tmp_dir}/${1}"
	mkdir -p "${case_dir}"
	(
		export GALENE_TAGS_URL="file://${2}"
		export GALENE_COMMITS_URL="file://${fixtures}/commits"
		export GALENE_SKIP_REGISTRY_CHECK=1
		export DOCKERHUB_IMAGE_REPO="example/galene-docker-test"
		export GHCR_IMAGE_REPO="ghcr.io/example/galene-docker-test"
		export RELEASE_ENV_FILE="${case_dir}/release.env"
		export TAGS_FILE="${case_dir}/tags.txt"
		sh "${prepare}"
	) > "${case_dir}/stdout.log" 2> "${case_dir}/stderr.log"
}

assert_env_line() {
	# $1 = release.env path, $2 = expected full line
	if ! grep -Fqx "$2" "$1"; then
		echo "FAIL: $1 does not contain the line: $2" >&2
		failures=$((failures + 1))
	fi
}

assert_epoch() {
	# $1 = release.env path
	if ! grep -Eq '^SOURCE_DATE_EPOCH=[0-9]+$' "$1"; then
		echo "FAIL: $1 has no numeric SOURCE_DATE_EPOCH" >&2
		failures=$((failures + 1))
	fi
}

assert_tags_file() {
	# $1 = tags.txt path, $2 = expected version line
	lines="$(wc -l < "$1")"
	if [ "${lines}" -ne 2 ]; then
		echo "FAIL: $1 should hold exactly two lines, found ${lines}" >&2
		failures=$((failures + 1))
	fi
	if ! grep -Fqx "$2" "$1"; then
		echo "FAIL: $1 does not contain the version line: $2" >&2
		failures=$((failures + 1))
	fi
	if ! grep -Fqx 'latest' "$1"; then
		echo "FAIL: $1 does not contain the latest tag" >&2
		failures=$((failures + 1))
	fi
}

echo "case: semantic ordering (1.10.0 beats 1.9.0, 1.2.1 beats 1.2)"
if run_case semantic "${fixtures}/tags-semantic.json"; then
	env_file="${tmp_dir}/semantic/release.env"
	assert_env_line "${env_file}" "GALENE_TAG=galene-1.10.0"
	assert_env_line "${env_file}" "GALENE_VERSION=1.10.0"
	assert_env_line "${env_file}" "GALENE_COMMIT=${TEST_SHA}"
	assert_env_line "${env_file}" "GALENE_CREATED=2026-09-08T16:12:32Z"
	assert_epoch "${env_file}"
	assert_env_line "${env_file}" "SHOULD_BUILD=1"
	assert_tags_file "${tmp_dir}/semantic/tags.txt" "1.10.0"
else
	echo "FAIL: prepare-release.sh exited non-zero on the semantic fixture" >&2
	failures=$((failures + 1))
fi

echo "case: prerelease and junk tags are ignored"
if run_case junk "${fixtures}/tags-junk.json"; then
	env_file="${tmp_dir}/junk/release.env"
	assert_env_line "${env_file}" "GALENE_TAG=galene-1.2.1"
	assert_env_line "${env_file}" "GALENE_VERSION=1.2.1"
	assert_tags_file "${tmp_dir}/junk/tags.txt" "1.2.1"
else
	echo "FAIL: prepare-release.sh exited non-zero on the junk fixture" >&2
	failures=$((failures + 1))
fi

echo "case: empty tag list aborts the run"
if run_case empty "${fixtures}/tags-empty.json"; then
	echo "FAIL: prepare-release.sh succeeded on an empty tag list" >&2
	failures=$((failures + 1))
elif [ -f "${tmp_dir}/empty/release.env" ]; then
	echo "FAIL: release.env was written despite the failure" >&2
	failures=$((failures + 1))
else
	echo "ok: empty tag list aborted with no release.env"
fi

echo "case: malformed upstream response aborts the run"
if run_case malformed "${fixtures}/tags-malformed.json"; then
	echo "FAIL: prepare-release.sh succeeded on malformed JSON" >&2
	failures=$((failures + 1))
elif [ -f "${tmp_dir}/malformed/release.env" ]; then
	echo "FAIL: release.env was written despite the failure" >&2
	failures=$((failures + 1))
else
	echo "ok: malformed JSON aborted with no release.env"
fi

if [ "${failures}" -ne 0 ]; then
	echo "${failures} discovery test(s) failed." >&2
	exit 1
fi

echo "All discovery tests passed."
