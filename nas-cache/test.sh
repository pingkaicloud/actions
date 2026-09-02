#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="${SCRIPT_DIR}/resolve-cache-keys.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nas-cache-test.XXXXXX")"
RUNNER_CACHE="${TEST_ROOT}/cache"
REPOSITORY="pingkaicloud/example"
mkdir -p "${RUNNER_CACHE}"

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
  local go_key="$2"
  local npm_key="$3"
  local pip_key="$4"
  local go_dependency_hash="$5"
  local npm_dependency_hash="$6"
  local pip_dependency_hash="$7"

  : > "${env_file}"
  RUNNER_CACHE="${RUNNER_CACHE}" \
  GITHUB_REPOSITORY="${REPOSITORY}" \
  GITHUB_ENV="${env_file}" \
  GO_CACHE_KEY="${go_key}" \
  GO_DEPENDENCY_HASH="${go_dependency_hash}" \
  NPM_CACHE_KEY="${npm_key}" \
  NPM_DEPENDENCY_HASH="${npm_dependency_hash}" \
  PIP_CACHE_KEY="${pip_key}" \
  PIP_DEPENDENCY_HASH="${pip_dependency_hash}" \
    bash "${RESOLVER}"
}

base="${RUNNER_CACHE}/${REPOSITORY}"

# Missing lock files use stable per-tool keys.
run_resolver "${TEST_ROOT}/default.env" "" "" "" "" "" ""
assert_dir "${base}/go/keys/go-no-lockfile/pkg/mod"
assert_dir "${base}/go/keys/go-no-lockfile/build"
assert_dir "${base}/npm/keys/npm-no-lockfile"
assert_dir "${base}/pip/keys/pip-no-lockfile"
assert_contains "${TEST_ROOT}/default.env" "GOMODCACHE=${base}/go/keys/go-no-lockfile/pkg/mod"
assert_contains "${TEST_ROOT}/default.env" "GOCACHE=${base}/go/keys/go-no-lockfile/build"
assert_contains "${TEST_ROOT}/default.env" "npm_config_cache=${base}/npm/keys/npm-no-lockfile"
assert_contains "${TEST_ROOT}/default.env" "PIP_CACHE_DIR=${base}/pip/keys/pip-no-lockfile"

# Dependency hashes and explicit keys select independent directories.
run_resolver "${TEST_ROOT}/hash.env" "" "" "" abc123 def456 ghi789
assert_dir "${base}/go/keys/go-abc123/pkg/mod"
assert_dir "${base}/npm/keys/npm-def456"
assert_dir "${base}/pip/keys/pip-ghi789"
run_resolver "${TEST_ROOT}/custom.env" "go-custom" "npm-custom" "pip-custom" ignored ignored ignored
assert_dir "${base}/go/keys/go-custom/pkg/mod"
assert_dir "${base}/npm/keys/npm-custom"
assert_dir "${base}/pip/keys/pip-custom"

# An exact hit reuses each same-key writable directory.
printf 'keep\n' > "${base}/go/keys/go-custom/marker"
printf 'keep\n' > "${base}/npm/keys/npm-custom/marker"
printf 'keep\n' > "${base}/pip/keys/pip-custom/marker"
run_resolver "${TEST_ROOT}/exact.env" "go-custom" "npm-custom" "pip-custom" ignored ignored ignored
assert_contains "${base}/go/keys/go-custom/marker" "keep"
assert_contains "${base}/npm/keys/npm-custom/marker" "keep"
assert_contains "${base}/pip/keys/pip-custom/marker" "keep"

# Unsafe and overlong keys are rejected before constructing paths.
if run_resolver "${TEST_ROOT}/invalid-go.env" "../escape" "safe" "safe" hash hash hash >/dev/null 2>&1; then
  fail "path-traversing Go key was accepted"
fi
if run_resolver "${TEST_ROOT}/invalid-npm.env" "safe" "../escape" "safe" hash hash hash >/dev/null 2>&1; then
  fail "path-traversing npm key was accepted"
fi
if run_resolver "${TEST_ROOT}/invalid-pip.env" "safe" "safe" "../escape" hash hash hash >/dev/null 2>&1; then
  fail "path-traversing pip key was accepted"
fi
assert_not_exists "${base}/go/escape"
assert_not_exists "${base}/npm/escape"
assert_not_exists "${base}/pip/escape"
long_key="$(printf '%0256d' 0 | tr '0' 'a')"
if run_resolver "${TEST_ROOT}/long-key.env" "${long_key}" "safe" "safe" hash hash hash >/dev/null 2>&1; then
  fail "overlong Go key was accepted"
fi
ln -s "${TEST_ROOT}" "${base}/npm/keys/npm-symlink"
if run_resolver "${TEST_ROOT}/symlink.env" "safe" "npm-symlink" "safe" hash hash hash >/dev/null 2>&1; then
  fail "symbolic-link npm key was accepted"
fi

# Concurrent cold starts converge on the same per-tool directories.
run_resolver "${TEST_ROOT}/concurrent-1.env" "go-concurrent" "npm-concurrent" "pip-concurrent" hash hash hash > "${TEST_ROOT}/concurrent-1.log" &
pid1=$!
run_resolver "${TEST_ROOT}/concurrent-2.env" "go-concurrent" "npm-concurrent" "pip-concurrent" hash hash hash > "${TEST_ROOT}/concurrent-2.log" &
pid2=$!
wait "${pid1}"
wait "${pid2}"
assert_dir "${base}/go/keys/go-concurrent/pkg/mod"
assert_dir "${base}/npm/keys/npm-concurrent"
assert_dir "${base}/pip/keys/pip-concurrent"

echo "PASS: nas-cache resolver"
