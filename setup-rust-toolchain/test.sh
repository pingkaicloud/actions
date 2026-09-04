#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-rust-toolchain-test.XXXXXX")"
cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
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
export RUNNER_OS=Linux
export RUNNER_ARCH=X64
export RUNNER_TOOL_CACHE="${TEST_ROOT}/toolcache"
export RUNNER_TEMP="${TEST_ROOT}/runner-temp"
export GITHUB_ENV="${TEST_ROOT}/github.env"
export GITHUB_OUTPUT="${TEST_ROOT}/github.output"
export GITHUB_PATH="${TEST_ROOT}/github.path"
export RUST_TOOLCHAIN=nightly-2026-01-30
export RUST_TARGETS=""
export RUST_TARGET=""
export RUST_COMPONENTS="clippy,rustfmt"
export CACHE_LOCK_TIMEOUT_SECONDS=5

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
mkdir -p "${RUNNER_TEMP}/rust-toolchain/${cache_key}/rustup" "${RUNNER_TEMP}/rust-toolchain/${cache_key}/cargo/bin"
mkdir -p "${RUNNER_TEMP}/rust-toolchain/${cache_key}/rustup/toolchains/nightly-2026-01-30/bin"
printf 'rustc\n' > "${RUNNER_TEMP}/rust-toolchain/${cache_key}/rustup/toolchains/nightly-2026-01-30/bin/rustc"
cp "${TEST_ROOT}/bin/rustup" "${RUNNER_TEMP}/rust-toolchain/${cache_key}/cargo/bin/rustup"
RUSTUP_HOME="${RUNNER_TEMP}/rust-toolchain/${cache_key}/rustup" \
  CARGO_HOME="${RUNNER_TEMP}/rust-toolchain/${cache_key}/cargo" \
  RUST_TOOLCHAIN_NAME=nightly-2026-01-30 \
  RUST_TOOLCHAIN_CACHEKEY=20260130fake \
  bash "${SCRIPT_DIR}/toolchain-cache.sh" save

: > "${GITHUB_OUTPUT}"
bash "${SCRIPT_DIR}/toolchain-cache.sh" restore
grep -Fq 'cache-hit=true' "${GITHUB_OUTPUT}" || fail "warm restore was not a hit"
grep -Fq 'RUST_TOOLCHAIN_NAME=nightly-2026-01-30' "${GITHUB_ENV}" || fail "toolchain name was not exported"

# Different parameters must use a different cache directory.
export RUST_COMPONENTS=rustfmt
: > "${GITHUB_OUTPUT}"
bash "${SCRIPT_DIR}/toolchain-cache.sh" restore
grep -Fq 'cache-hit=false' "${GITHUB_OUTPUT}" || fail "different parameters reused the cache"

echo "PASS: setup-rust-toolchain"
