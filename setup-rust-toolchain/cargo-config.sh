#!/usr/bin/env bash

# Configure Cargo networking (retries, git fetch via CLI) and the crates.io
# mirror for the shared CARGO_HOME prepared by dependency-cache.sh. This is
# generic runner-platform behavior; repo-specific warm-up stays with callers.

set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

: "${GITHUB_ENV:?GITHUB_ENV is required}"

cat >> "${GITHUB_ENV}" <<'EOF'
CARGO_NET_GIT_FETCH_WITH_CLI=true
CARGO_HTTP_TIMEOUT=120
CARGO_NET_RETRY=3
EOF

case "${CRATES_MIRROR:-aliyun}" in
  none)
    exit 0
    ;;
  aliyun)
    mirror_url="sparse+https://mirrors.aliyun.com/crates.io-index/"
    ;;
  *)
    fail "unsupported crates-mirror: ${CRATES_MIRROR} (expected aliyun or none)"
    ;;
esac

: "${CARGO_HOME:?CARGO_HOME is required (run dependency-cache first)}"
mkdir -p "${CARGO_HOME}"
cat > "${CARGO_HOME}/config.toml" <<EOF
[source.crates-io]
replace-with = 'aliyun'
[source.aliyun]
registry = "${mirror_url}"
EOF
echo "crates.io mirror configured: ${mirror_url}"
