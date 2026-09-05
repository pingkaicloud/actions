#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-rust-toolchain-test.XXXXXX")"
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

mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/toolcache" "${TEST_ROOT}/runner-temp"
if ! command -v flock >/dev/null 2>&1; then
  # macOS does not ship util-linux flock; use a no-op shim for this single-process test.
  cat > "${TEST_ROOT}/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${TEST_ROOT}/bin/flock"
fi
cat > "${TEST_ROOT}/bin/rustup" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = run ]; then
  [ "${3:-}" = rustc ] || exit 2
  printf 'rustc 1.88.0 (%s)\n' "${1}"
  exit 0
fi
if [ "${1:-}" = default ]; then
  exit 0
fi
exit 2
EOF
chmod +x "${TEST_ROOT}/bin/rustup"
cat > "${TEST_ROOT}/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case " $* " in
  *" ls-remote "*)
    printf '%s\trefs/heads/master\n' '0123456789abcdef0123456789abcdef01234567'
    ;;
  *)
    echo "unexpected git invocation: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${TEST_ROOT}/bin/git"
cat > "${TEST_ROOT}/bin/rustc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[ "${1:-}" = +nightly-2026-01-30 ] || exit 2
[ "${2:-}" = --print ] || exit 2
[ "${3:-}" = sysroot ] || exit 2
printf '%s/toolchains/nightly-2026-01-30\n' "${RUSTUP_HOME}"
EOF
chmod +x "${TEST_ROOT}/bin/rustc"

export PATH="${TEST_ROOT}/bin:${PATH}"
export GITHUB_REPOSITORY=pingkaicloud/cloud-storage-engine
export GITHUB_RUN_ID=primary-run
export GITHUB_JOB=primary
export GITHUB_RUN_ATTEMPT=1
export RUNNER_OS=Linux
export RUNNER_ARCH=X64
export RUNNER_TOOL_CACHE="${TEST_ROOT}/toolcache"
export RUNNER_TEMP="${TEST_ROOT}/runner-temp"
export RUNNER_CACHE="${TEST_ROOT}/dependency-cache"
export GITHUB_ENV="${TEST_ROOT}/github.env"
export GITHUB_OUTPUT="${TEST_ROOT}/github.output"
export GITHUB_PATH="${TEST_ROOT}/github.path"
export RUST_TOOLCHAIN=nightly-2026-01-30
export RUST_TARGETS=""
export RUST_TARGET=""
export RUST_COMPONENTS="clippy,rustfmt"
export CACHE_LOCK_TIMEOUT_SECONDS=5
export ENABLE_CARGO_CACHE=true
export CARGO_CACHE_KEY=cse-rust-linux-amd64
export LINDERA_CACHE_KEY=lindera-0.43.1-test

: > "${GITHUB_ENV}"
: > "${GITHUB_OUTPUT}"
: > "${GITHUB_PATH}"

mkdir -p "${RUNNER_CACHE}"

# Dependency caches: job-local Cargo home with NAS-backed download/git links
# and unpacked sources kept local; Lindera dirs are created and exported.
bash "${SCRIPT_DIR}/dependency-cache.sh"
cargo_home="${RUNNER_TEMP}/cargo-home"
cargo_cache_dir="${RUNNER_CACHE}/${GITHUB_REPOSITORY}/cargo/keys/${CARGO_CACHE_KEY}"
lindera_cache_dir="${RUNNER_CACHE}/${GITHUB_REPOSITORY}/lindera/keys/${LINDERA_CACHE_KEY}"
assert_dir "${cargo_home}/bin"
assert_dir "${cargo_home}/git"
assert_dir "${cargo_home}/registry/src"
assert_dir "${cargo_cache_dir}/registry/cache"
assert_dir "${cargo_cache_dir}/git-db"
assert_file "${cargo_cache_dir}/.package-cache"
assert_file "${cargo_cache_dir}/.package-cache-mutate"
[ -L "${cargo_home}/registry/cache" ] || fail "expected crate download cache symlink"
[ "${cargo_cache_dir}/registry/cache" = "$(readlink "${cargo_home}/registry/cache")" ] \
  || fail "crate download cache symlink points at $(readlink "${cargo_home}/registry/cache")"
[ -L "${cargo_home}/git/db" ] || fail "expected Cargo git DB symlink"
[ "${cargo_cache_dir}/git-db" = "$(readlink "${cargo_home}/git/db")" ] \
  || fail "Cargo git DB symlink points at $(readlink "${cargo_home}/git/db")"
[ ! -L "${cargo_home}/registry/src" ] || fail "registry/src must stay job-local"
[ ! -e "${cargo_cache_dir}/registry/src" ] || fail "registry/src must not be created on the cache"
assert_dir "${lindera_cache_dir}"
assert_file "${lindera_cache_dir}/.lock"
assert_contains "${GITHUB_ENV}" "CARGO_HOME=${cargo_home}"
assert_contains "${GITHUB_ENV}" "LINDERA_CACHE=${lindera_cache_dir}"
assert_contains "${GITHUB_ENV}" "LINDERA_CACHE_LOCK=${lindera_cache_dir}/.lock"
assert_contains "${GITHUB_ENV}" "LINDERA_CACHE_READY=${lindera_cache_dir}/.ready"
assert_contains "${GITHUB_PATH}" "${cargo_home}/bin"
: > "${GITHUB_ENV}"
: > "${GITHUB_OUTPUT}"
: > "${GITHUB_PATH}"

bash "${SCRIPT_DIR}/toolchain-cache.sh" restore
grep -Fq 'cache-hit=false' "${GITHUB_OUTPUT}" || fail "cold restore was not a miss"

cache_key=""
for cache_dir in "${RUNNER_TOOL_CACHE}"/rust-toolchain/*; do
  if [ -d "${cache_dir}" ]; then
    cache_key="${cache_dir##*/}"
    break
  fi
done
[ -n "${cache_key}" ] || fail "cache directory was not created"
assert_file "${RUNNER_TEMP}/rust-toolchain-action-ref"
assert_contains "${RUNNER_TEMP}/rust-toolchain-action-ref" "0123456789abcdef0123456789abcdef01234567"
claim_file="${RUNNER_TOOL_CACHE}/rust-toolchain/${cache_key}/.installing"
assert_file "${claim_file}"
assert_contains "${claim_file}" "owner=${GITHUB_RUN_ID}/${GITHUB_JOB}/${GITHUB_RUN_ATTEMPT}"
mkdir -p "${RUNNER_TEMP}/rustup-home/toolchains/nightly-2026-01-30/bin" "${RUNNER_TEMP}/cargo-home/bin"
printf 'rustc\n' > "${RUNNER_TEMP}/rustup-home/toolchains/nightly-2026-01-30/bin/rustc"
cp "${TEST_ROOT}/bin/rustup" "${RUNNER_TEMP}/cargo-home/bin/rustup"
RUSTUP_HOME="${RUNNER_TEMP}/rustup-home" \
  CARGO_HOME="${RUNNER_TEMP}/cargo-home" \
  RUST_TOOLCHAIN_NAME=nightly-2026-01-30 \
  RUST_TOOLCHAIN_CACHEKEY=20260130fake \
  bash "${SCRIPT_DIR}/toolchain-cache.sh" save
assert_not_exists "${claim_file}"

# The dependency-cache links inside cargo-home must survive a warm restore.
: > "${GITHUB_OUTPUT}"
bash "${SCRIPT_DIR}/toolchain-cache.sh" restore
grep -Fq 'cache-hit=true' "${GITHUB_OUTPUT}" || fail "warm restore was not a hit"
grep -Fq 'RUST_TOOLCHAIN_NAME=nightly-2026-01-30' "${GITHUB_ENV}" || fail "toolchain name was not exported"
assert_file "${RUNNER_TEMP}/cargo-home/bin/rustup"
[ -L "${RUNNER_TEMP}/cargo-home/registry/cache" ] || fail "registry/cache link lost after restore"
[ -L "${RUNNER_TEMP}/cargo-home/git/db" ] || fail "git/db link lost after restore"
assert_not_exists "${cargo_cache_dir}/registry/src"

# Concurrent miss handling: a second job waits for the first job to publish the
# bundle instead of installing the same toolchain independently.
export RUST_COMPONENTS=rustfmt
: > "${GITHUB_OUTPUT}"
bash "${SCRIPT_DIR}/toolchain-cache.sh" restore
grep -Fq 'cache-hit=false' "${GITHUB_OUTPUT}" || fail "different parameters reused the cache"
second_claim_file=""
for candidate in "${RUNNER_TOOL_CACHE}"/rust-toolchain/*/.installing; do
  if [ -f "${candidate}" ]; then
    second_claim_file="${candidate}"
    break
  fi
done
[ -n "${second_claim_file}" ] || fail "second cache miss did not create an installation claim"

# Separate Pods can expose the same RUNNER_TEMP path. Keep it identical here
# and vary only the GitHub job identity to exercise the cross-Pod case.
waiter_temp="${RUNNER_TEMP}"
: > "${TEST_ROOT}/waiter.env"
: > "${TEST_ROOT}/waiter.output"
: > "${TEST_ROOT}/waiter.path"
(
  RUNNER_TEMP="${waiter_temp}" \
  GITHUB_RUN_ID=waiter-run \
  GITHUB_JOB=waiter \
  GITHUB_RUN_ATTEMPT=1 \
  GITHUB_ENV="${TEST_ROOT}/waiter.env" \
  GITHUB_OUTPUT="${TEST_ROOT}/waiter.output" \
  GITHUB_PATH="${TEST_ROOT}/waiter.path" \
    bash "${SCRIPT_DIR}/toolchain-cache.sh" restore
) &
waiter_pid=$!
sleep 1
if ! kill -0 "${waiter_pid}" 2>/dev/null; then
  fail "concurrent restore did not wait for the installation claim"
fi

mkdir -p "${RUNNER_TEMP}/rustup-home/toolchains/nightly-2026-01-30/bin" "${RUNNER_TEMP}/cargo-home/bin"
printf 'rustc\n' > "${RUNNER_TEMP}/rustup-home/toolchains/nightly-2026-01-30/bin/rustc"
cp "${TEST_ROOT}/bin/rustup" "${RUNNER_TEMP}/cargo-home/bin/rustup"
RUSTUP_HOME="${RUNNER_TEMP}/rustup-home" \
  CARGO_HOME="${RUNNER_TEMP}/cargo-home" \
  RUST_TOOLCHAIN_NAME=nightly-2026-01-30 \
  RUST_TOOLCHAIN_CACHEKEY=20260130fake-second \
  bash "${SCRIPT_DIR}/toolchain-cache.sh" save
wait "${waiter_pid}"
grep -Fq 'cache-hit=true' "${TEST_ROOT}/waiter.output" \
  || fail "concurrent restore did not reuse the populated cache"
assert_not_exists "${second_claim_file}"

# A failed install must clean up its claim so a later job can retry immediately.
export RUST_COMPONENTS=clippy
: > "${GITHUB_OUTPUT}"
bash "${SCRIPT_DIR}/toolchain-cache.sh" restore
failed_claim_file=""
for candidate in "${RUNNER_TOOL_CACHE}"/rust-toolchain/*/.installing; do
  if [ -f "${candidate}" ]; then
    failed_claim_file="${candidate}"
    break
  fi
done
[ -n "${failed_claim_file}" ] || fail "failed install did not create an installation claim"
bash "${SCRIPT_DIR}/toolchain-cache.sh" cleanup
assert_not_exists "${failed_claim_file}"

# A disabled Cargo cache still exports a job-local CARGO_HOME, without links.
fresh_temp="${TEST_ROOT}/runner-temp-nolinks"
mkdir -p "${fresh_temp}"
RUNNER_TEMP="${fresh_temp}" \
ENABLE_CARGO_CACHE=false \
CARGO_CACHE_KEY="" \
LINDERA_CACHE_KEY="" \
GITHUB_ENV="${TEST_ROOT}/nolinks.env" \
GITHUB_PATH="${TEST_ROOT}/nolinks.path" \
  bash "${SCRIPT_DIR}/dependency-cache.sh"
nolinks_home="${fresh_temp}/cargo-home"
assert_dir "${nolinks_home}/registry/src"
[ ! -L "${nolinks_home}/registry" ] || fail "registry must not be a link when the cache is disabled"
assert_contains "${TEST_ROOT}/nolinks.env" "CARGO_HOME=${nolinks_home}"
! grep -Fq "LINDERA_CACHE=" "${TEST_ROOT}/nolinks.env" || fail "Lindera exported without a key"

# Cargo network config and the crates.io mirror land in the shared CARGO_HOME.
: > "${TEST_ROOT}/mirror.env"
CARGO_HOME="${cargo_home}" \
GITHUB_ENV="${TEST_ROOT}/mirror.env" \
CRATES_MIRROR=aliyun \
  bash "${SCRIPT_DIR}/cargo-config.sh"
assert_contains "${TEST_ROOT}/mirror.env" "CARGO_NET_GIT_FETCH_WITH_CLI=true"
assert_contains "${TEST_ROOT}/mirror.env" "CARGO_HTTP_TIMEOUT=120"
assert_contains "${TEST_ROOT}/mirror.env" "CARGO_NET_RETRY=3"
assert_contains "${cargo_home}/config.toml" "sparse+https://mirrors.aliyun.com/crates.io-index/"

# crates-mirror=none keeps the official registry and writes no config.
rm -f "${cargo_home}/config.toml"
: > "${TEST_ROOT}/nomirror.env"
CARGO_HOME="${cargo_home}" \
GITHUB_ENV="${TEST_ROOT}/nomirror.env" \
CRATES_MIRROR=none \
  bash "${SCRIPT_DIR}/cargo-config.sh"
assert_not_exists "${cargo_home}/config.toml"
assert_contains "${TEST_ROOT}/nomirror.env" "CARGO_NET_RETRY=3"
if CARGO_HOME="${cargo_home}" GITHUB_ENV="${TEST_ROOT}/badmirror.env" CRATES_MIRROR=mirror-x \
  bash "${SCRIPT_DIR}/cargo-config.sh" >/dev/null 2>&1; then
  fail "unsupported crates-mirror was accepted"
fi

echo "PASS: setup-rust-toolchain"
