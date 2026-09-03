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

assert_not_contains() {
  ! grep -Fq "$2" "$1" || fail "expected $1 to not contain: $2"
}

run_resolver() {
  local env_file="$1"
  local go_key="$2"
  local npm_key="$3"
  local pip_key="$4"
  local pulumi_key="$5"
  local home_dir="$6"

  local home_dir="$6"
  : > "${env_file}"
  RUNNER_CACHE="${RUNNER_CACHE}" \
  GITHUB_REPOSITORY="${REPOSITORY}" \
  GITHUB_ENV="${env_file}" \
  HOME="${home_dir}" \
  GO_CACHE_KEY="${go_key}" \
  NPM_CACHE_KEY="${npm_key}" \
  PIP_CACHE_KEY="${pip_key}" \
  PULUMI_CACHE_KEY="${pulumi_key}" \
    bash "${RESOLVER}"
}

base="${RUNNER_CACHE}/${REPOSITORY}"
HOME_MAIN="${TEST_ROOT}/home-main"
HOME_ALT="${TEST_ROOT}/home-alt"
mkdir -p "${HOME_MAIN}" "${HOME_ALT}"

# Omitted keys use stable per-repository default directories.
run_resolver "${TEST_ROOT}/default.env" "" "" "" "" "${HOME_MAIN}"
assert_dir "${base}/go/default/pkg/mod"
assert_dir "${base}/go/default/build"
assert_dir "${base}/npm/default"
assert_dir "${base}/pip/default"
assert_contains "${TEST_ROOT}/default.env" "GOMODCACHE=${base}/go/default/pkg/mod"
assert_contains "${TEST_ROOT}/default.env" "GOCACHE=${base}/go/default/build"
assert_contains "${TEST_ROOT}/default.env" "npm_config_cache=${base}/npm/default"
assert_contains "${TEST_ROOT}/default.env" "PIP_CACHE_DIR=${base}/pip/default"
assert_dir "${base}/pulumi/default/plugins"
assert_not_contains "${TEST_ROOT}/default.env" "PULUMI_HOME"
[ -L "${HOME_MAIN}/.pulumi/plugins" ] || fail "expected symlink at HOME/.pulumi/plugins"
[ "${base}/pulumi/default/plugins" = "$(readlink "${HOME_MAIN}/.pulumi/plugins")" ] \
  || fail "plugins symlink points at $(readlink "${HOME_MAIN}/.pulumi/plugins")"
assert_not_exists "${HOME_MAIN}/.pulumi/credentials.json"

# Repeated runs reuse the fixed default directories.
printf 'keep\n' > "${base}/go/default/marker"
printf 'keep\n' > "${base}/npm/default/marker"
printf 'keep\n' > "${base}/pip/default/marker"
printf 'keep\n' > "${base}/pulumi/default/marker"
run_resolver "${TEST_ROOT}/default-hit.env" "" "" "" "" "${HOME_MAIN}"
assert_contains "${base}/go/default/marker" "keep"
assert_contains "${base}/npm/default/marker" "keep"
assert_contains "${base}/pip/default/marker" "keep"
assert_contains "${base}/pulumi/default/marker" "keep"
[ -L "${HOME_MAIN}/.pulumi/plugins" ] || fail "plugins symlink lost after re-run"
assert_not_contains "${TEST_ROOT}/default-hit.env" "PULUMI_HOME"

# Explicit keys select independent directories.
run_resolver "${TEST_ROOT}/custom.env" "go-custom" "npm-custom" "pip-custom" "pulumi-custom" "${HOME_ALT}"
assert_dir "${base}/go/keys/go-custom/pkg/mod"
assert_dir "${base}/npm/keys/npm-custom"
assert_dir "${base}/pip/keys/pip-custom"
assert_dir "${base}/pulumi/keys/pulumi-custom"
[ "${base}/pulumi/keys/pulumi-custom/plugins" = "$(readlink "${HOME_ALT}/.pulumi/plugins")" ] \
  || fail "alt home symlink points at $(readlink "${HOME_ALT}/.pulumi/plugins")"
assert_contains "${base}/go/default/marker" "keep"
assert_contains "${base}/npm/default/marker" "keep"
assert_contains "${base}/pip/default/marker" "keep"

# An exact hit reuses each same-key writable directory.
printf 'keep\n' > "${base}/go/keys/go-custom/marker"
printf 'keep\n' > "${base}/npm/keys/npm-custom/marker"
printf 'keep\n' > "${base}/pip/keys/pip-custom/marker"
printf 'keep\n' > "${base}/pulumi/keys/pulumi-custom/marker"
run_resolver "${TEST_ROOT}/exact.env" "go-custom" "npm-custom" "pip-custom" "pulumi-custom" "${HOME_ALT}"
assert_contains "${base}/go/keys/go-custom/marker" "keep"
assert_contains "${base}/npm/keys/npm-custom/marker" "keep"
assert_contains "${base}/pip/keys/pip-custom/marker" "keep"
assert_contains "${base}/pulumi/keys/pulumi-custom/marker" "keep"

# Unsafe and overlong keys are rejected before constructing paths.
if run_resolver "${TEST_ROOT}/invalid-go.env" "../escape" "safe" "safe" "" "${HOME_MAIN}" >/dev/null 2>&1; then
  fail "path-traversing Go key was accepted"
fi
if run_resolver "${TEST_ROOT}/invalid-npm.env" "safe" "../escape" "safe" "" "${HOME_MAIN}" >/dev/null 2>&1; then
  fail "path-traversing npm key was accepted"
fi
if run_resolver "${TEST_ROOT}/invalid-pip.env" "safe" "safe" "../escape" "" "${HOME_MAIN}" >/dev/null 2>&1; then
  fail "path-traversing pip key was accepted"
fi
if run_resolver "${TEST_ROOT}/invalid-pulumi.env" "safe" "safe" "safe" "../escape" "${HOME_MAIN}" >/dev/null 2>&1; then
  fail "path-traversing Pulumi key was accepted"
fi
assert_not_exists "${base}/go/escape"
assert_not_exists "${base}/npm/escape"
assert_not_exists "${base}/pip/escape"
assert_not_exists "${base}/pulumi/escape"
long_key="$(printf '%0256d' 0 | tr '0' 'a')"
if run_resolver "${TEST_ROOT}/long-key.env" "${long_key}" "safe" "safe" "" "${HOME_MAIN}" >/dev/null 2>&1; then
  fail "overlong Go key was accepted"
fi
ln -s "${TEST_ROOT}" "${base}/npm/keys/npm-symlink"
if run_resolver "${TEST_ROOT}/symlink.env" "safe" "npm-symlink" "safe" "" "${HOME_MAIN}" >/dev/null 2>&1; then
  fail "symbolic-link npm key was accepted"
fi
ln -s "${TEST_ROOT}" "${base}/pulumi/keys/pulumi-symlink"
if run_resolver "${TEST_ROOT}/pulumi-symlink.env" "safe" "safe" "safe" "pulumi-symlink" "${HOME_MAIN}" >/dev/null 2>&1; then
  fail "symbolic-link Pulumi key was accepted"
fi

# A pre-existing non-symlink plugins directory is preserved, not replaced.
HOME_THIRD="${TEST_ROOT}/home-third"
mkdir -p "${HOME_THIRD}/.pulumi/plugins"
printf 'local\n' > "${HOME_THIRD}/.pulumi/plugins/marker"
run_resolver "${TEST_ROOT}/realdir.env" "" "" "" "" "${HOME_THIRD}" >/dev/null 2>&1
assert_contains "${HOME_THIRD}/.pulumi/plugins/marker" "local"
[ ! -L "${HOME_THIRD}/.pulumi/plugins" ] || fail "real plugins directory was replaced by a symlink"

# Concurrent default-cache cold starts converge on the same directories.
rm -rf "${base}/go/default" "${base}/npm/default" "${base}/pip/default" "${base}/pulumi/default"
run_resolver "${TEST_ROOT}/concurrent-1.env" "" "" "" "" "${HOME_MAIN}" > "${TEST_ROOT}/concurrent-1.log" &
pid1=$!
run_resolver "${TEST_ROOT}/concurrent-2.env" "" "" "" "" "${HOME_ALT}" > "${TEST_ROOT}/concurrent-2.log" &
pid2=$!
wait "${pid1}"
wait "${pid2}"
assert_dir "${base}/go/default/pkg/mod"
assert_dir "${base}/npm/default"
assert_dir "${base}/pip/default"
assert_dir "${base}/pulumi/default/plugins"
[ -L "${HOME_MAIN}/.pulumi/plugins" ] || fail "concurrent: HOME_MAIN plugins symlink missing"
[ -L "${HOME_ALT}/.pulumi/plugins" ] || fail "concurrent: HOME_ALT plugins symlink missing"
assert_not_contains "${TEST_ROOT}/concurrent-1.env" "PULUMI_HOME"

echo "PASS: nas-cache resolver"
