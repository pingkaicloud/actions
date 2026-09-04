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

assert_file() {
  [ -f "$1" ] || fail "expected file: $1"
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
  local cargo_enabled="${7:-false}"
  local cargo_key="${8:-}"
  local lindera_enabled="${9:-false}"
  local lindera_key="${10:-}"
  local run_name
  local runner_temp
  local github_path

  run_name="$(basename "${env_file}" .env)"
  runner_temp="${TEST_ROOT}/runner-temp-${run_name}"
  github_path="${TEST_ROOT}/github-path-${run_name}"
  : > "${env_file}"
  : > "${github_path}"
  env -u CARGO_HOME -u LINDERA_CACHE \
  RUNNER_CACHE="${RUNNER_CACHE}" \
  GITHUB_REPOSITORY="${REPOSITORY}" \
  GITHUB_ENV="${env_file}" \
  GITHUB_PATH="${github_path}" \
  HOME="${home_dir}" \
  RUNNER_TEMP="${runner_temp}" \
  GO_CACHE_KEY="${go_key}" \
  NPM_CACHE_KEY="${npm_key}" \
  PIP_CACHE_KEY="${pip_key}" \
  PULUMI_CACHE_KEY="${pulumi_key}" \
  ENABLE_CARGO_CACHE="${cargo_enabled}" \
  CARGO_CACHE_KEY="${cargo_key}" \
  ENABLE_LINDERA_CACHE="${lindera_enabled}" \
  LINDERA_CACHE_KEY="${lindera_key}" \
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

# Cargo and Lindera caches are opt-in and use independent, versioned directories.
cargo_key="cse-rust-linux-amd64"
lindera_key="lindera-0.43.1-3e266dd69cae7ff1e894208cbfb9afa20d3e9965"
run_resolver "${TEST_ROOT}/cargo.env" "" "" "" "" "${HOME_ALT}" true "${cargo_key}" true "${lindera_key}"
cargo_cache_dir="${base}/cargo/keys/${cargo_key}"
cargo_home="${TEST_ROOT}/runner-temp-cargo/cargo-home"
lindera_cache_dir="${base}/lindera/keys/${lindera_key}"
assert_dir "${cargo_cache_dir}/registry"
assert_dir "${cargo_cache_dir}/git-db"
assert_dir "${cargo_home}/git"
assert_dir "${cargo_home}/bin"
assert_file "${cargo_cache_dir}/.package-cache"
assert_file "${cargo_cache_dir}/.package-cache-mutate"
[ -L "${cargo_home}/registry" ] || fail "expected Cargo registry symlink"
[ "${cargo_cache_dir}/registry" = "$(readlink "${cargo_home}/registry")" ] \
  || fail "Cargo registry symlink points at $(readlink "${cargo_home}/registry")"
[ -L "${cargo_home}/git/db" ] || fail "expected Cargo git DB symlink"
[ "${cargo_cache_dir}/git-db" = "$(readlink "${cargo_home}/git/db")" ] \
  || fail "Cargo git DB symlink points at $(readlink "${cargo_home}/git/db")"
[ -L "${cargo_home}/.package-cache" ] || fail "expected Cargo download lock symlink"
[ "${cargo_cache_dir}/.package-cache" = "$(readlink "${cargo_home}/.package-cache")" ] \
  || fail "Cargo download lock symlink points at $(readlink "${cargo_home}/.package-cache")"
[ -L "${cargo_home}/.package-cache-mutate" ] || fail "expected Cargo mutation lock symlink"
[ "${cargo_cache_dir}/.package-cache-mutate" = "$(readlink "${cargo_home}/.package-cache-mutate")" ] \
  || fail "Cargo mutation lock symlink points at $(readlink "${cargo_home}/.package-cache-mutate")"
assert_dir "${lindera_cache_dir}"
assert_file "${lindera_cache_dir}/.lock"
assert_contains "${TEST_ROOT}/cargo.env" "CARGO_HOME=${cargo_home}"
assert_contains "${TEST_ROOT}/cargo.env" "LINDERA_CACHE=${lindera_cache_dir}"
assert_contains "${TEST_ROOT}/cargo.env" "LINDERA_CACHE_LOCK=${lindera_cache_dir}/.lock"
assert_contains "${TEST_ROOT}/cargo.env" "LINDERA_CACHE_READY=${lindera_cache_dir}/.ready"
assert_contains "${TEST_ROOT}/github-path-cargo" "${cargo_home}/bin"
assert_not_exists "${cargo_home}/config.toml"
assert_not_exists "${cargo_home}/git/checkouts"
assert_not_exists "${lindera_cache_dir}/.ready"

# Disabled optional caches do not create directories or export their variables.
run_resolver "${TEST_ROOT}/disabled.env" "" "" "" "" "${HOME_MAIN}"
assert_not_exists "${TEST_ROOT}/runner-temp-disabled/cargo-home"
assert_not_contains "${TEST_ROOT}/disabled.env" "CARGO_HOME="
assert_not_contains "${TEST_ROOT}/disabled.env" "LINDERA_CACHE="
assert_not_contains "${TEST_ROOT}/disabled.env" "LINDERA_CACHE_LOCK="
assert_not_contains "${TEST_ROOT}/disabled.env" "LINDERA_CACHE_READY="
assert_not_exists "${base}/cargo/default"
assert_not_exists "${base}/lindera/default"

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
if run_resolver "${TEST_ROOT}/invalid-cargo.env" "safe" "safe" "safe" "" "${HOME_MAIN}" true "../escape" >/dev/null 2>&1; then
  fail "path-traversing Cargo key was accepted"
fi
if run_resolver "${TEST_ROOT}/invalid-lindera.env" "safe" "safe" "safe" "" "${HOME_MAIN}" false "" true "../escape" >/dev/null 2>&1; then
  fail "path-traversing Lindera key was accepted"
fi
if run_resolver "${TEST_ROOT}/invalid-cargo-enabled.env" "safe" "safe" "safe" "" "${HOME_MAIN}" maybe >/dev/null 2>&1; then
  fail "invalid Cargo enable value was accepted"
fi
if run_resolver "${TEST_ROOT}/invalid-lindera-enabled.env" "safe" "safe" "safe" "" "${HOME_MAIN}" false "" maybe >/dev/null 2>&1; then
  fail "invalid Lindera enable value was accepted"
fi
assert_not_exists "${base}/go/escape"
assert_not_exists "${base}/npm/escape"
assert_not_exists "${base}/pip/escape"
assert_not_exists "${base}/pulumi/escape"
assert_not_exists "${base}/cargo/escape"
assert_not_exists "${base}/lindera/escape"
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
mkdir -p "${base}/cargo/keys" "${base}/lindera/keys"
ln -s "${TEST_ROOT}" "${base}/cargo/keys/cargo-symlink"
if run_resolver "${TEST_ROOT}/cargo-symlink.env" "safe" "safe" "safe" "" "${HOME_MAIN}" true "cargo-symlink" >/dev/null 2>&1; then
  fail "symbolic-link Cargo key was accepted"
fi
ln -s "${TEST_ROOT}" "${base}/lindera/keys/lindera-symlink"
if run_resolver "${TEST_ROOT}/lindera-symlink.env" "safe" "safe" "safe" "" "${HOME_MAIN}" false "" true "lindera-symlink" >/dev/null 2>&1; then
  fail "symbolic-link Lindera key was accepted"
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

# Concurrent Cargo/Lindera cold starts converge without sharing job-local Cargo homes.
rm -rf "${base}/cargo/default" "${base}/lindera/default"
run_resolver "${TEST_ROOT}/concurrent-cargo-1.env" "" "" "" "" "${HOME_MAIN}" true "" true "" > "${TEST_ROOT}/concurrent-cargo-1.log" &
pid1=$!
run_resolver "${TEST_ROOT}/concurrent-cargo-2.env" "" "" "" "" "${HOME_ALT}" true "" true "" > "${TEST_ROOT}/concurrent-cargo-2.log" &
pid2=$!
wait "${pid1}"
wait "${pid2}"
assert_dir "${base}/cargo/default/registry"
assert_dir "${base}/cargo/default/git-db"
assert_dir "${base}/lindera/default"
assert_file "${base}/cargo/default/.package-cache"
assert_file "${base}/cargo/default/.package-cache-mutate"
assert_file "${base}/lindera/default/.lock"
[ -L "${TEST_ROOT}/runner-temp-concurrent-cargo-1/cargo-home/registry" ] \
  || fail "concurrent Cargo job 1 registry symlink missing"
[ -L "${TEST_ROOT}/runner-temp-concurrent-cargo-2/cargo-home/registry" ] \
  || fail "concurrent Cargo job 2 registry symlink missing"
assert_contains "${TEST_ROOT}/github-path-concurrent-cargo-1" "/runner-temp-concurrent-cargo-1/cargo-home/bin"
assert_contains "${TEST_ROOT}/github-path-concurrent-cargo-2" "/runner-temp-concurrent-cargo-2/cargo-home/bin"

echo "PASS: nas-cache resolver"
