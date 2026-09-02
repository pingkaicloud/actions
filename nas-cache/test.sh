#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="${SCRIPT_DIR}/resolve-npm-cache.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nas-cache-test.XXXXXX")"
RUNNER_CACHE="${TEST_ROOT}/cache"
REPOSITORY="pingkaicloud/example"

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_dir() {
  [ -d "$1" ] || fail "expected directory: $1"
}

assert_not_exists() {
  [ ! -e "$1" ] || fail "expected path not to exist: $1"
}

assert_contains() {
  grep -Fq "$2" "$1" || fail "expected $1 to contain: $2"
}

run_resolver() {
  local env_file="$1"
  local key="$2"
  local lock_hash="$3"

  : > "${env_file}"
  RUNNER_CACHE="${RUNNER_CACHE}" \
  GITHUB_REPOSITORY="${REPOSITORY}" \
  GITHUB_ENV="${env_file}" \
  NPM_CACHE_KEY="${key}" \
  DEFAULT_LOCK_HASH="${lock_hash}" \
    bash "${RESOLVER}"
}

keys_dir="${RUNNER_CACHE}/${REPOSITORY}/npm/keys"

# No lockfile gets a stable, explicit cold-cache key.
run_resolver "${TEST_ROOT}/default.env" "" ""
assert_dir "${keys_dir}/npm-no-lockfile"
assert_contains "${TEST_ROOT}/default.env" "npm_config_cache=${keys_dir}/npm-no-lockfile"

# The default lockfile hash and an explicit key select separate directories.
run_resolver "${TEST_ROOT}/hash.env" "" "abc123"
assert_dir "${keys_dir}/npm-abc123"
run_resolver "${TEST_ROOT}/custom.env" "npm-cd-release" "ignored"
assert_dir "${keys_dir}/npm-cd-release"

# An exact hit reuses the same writable directory without copying it.
printf 'keep\n' > "${keys_dir}/npm-cd-release/marker"
run_resolver "${TEST_ROOT}/exact.env" "npm-cd-release" "ignored"
assert_contains "${keys_dir}/npm-cd-release/marker" "keep"

# Unsafe and overlong keys are rejected before constructing paths.
if run_resolver "${TEST_ROOT}/invalid-key.env" "../escape" "hash" >/dev/null 2>&1; then
  fail "path-traversing npm key was accepted"
fi
assert_not_exists "${RUNNER_CACHE}/${REPOSITORY}/npm/escape"
long_key="$(printf '%0256d' 0 | tr '0' 'a')"
if run_resolver "${TEST_ROOT}/long-key.env" "${long_key}" "hash" >/dev/null 2>&1; then
  fail "overlong npm key was accepted"
fi
ln -s "${TEST_ROOT}" "${keys_dir}/npm-symlink"
if run_resolver "${TEST_ROOT}/symlink.env" "npm-symlink" "hash" >/dev/null 2>&1; then
  fail "symbolic-link npm key was accepted"
fi

# Concurrent cold starts both succeed and converge on the same directory.
run_resolver "${TEST_ROOT}/concurrent-1.env" "npm-concurrent" "hash" > "${TEST_ROOT}/concurrent-1.log" &
pid1=$!
run_resolver "${TEST_ROOT}/concurrent-2.env" "npm-concurrent" "hash" > "${TEST_ROOT}/concurrent-2.log" &
pid2=$!
wait "${pid1}"
wait "${pid2}"
assert_dir "${keys_dir}/npm-concurrent"

echo "PASS: nas-cache resolver"
