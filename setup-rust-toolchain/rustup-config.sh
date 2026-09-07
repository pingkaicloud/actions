#!/usr/bin/env bash

set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

validate_value() {
  local value="$1"
  local label="$2"

  [ -n "${value}" ] || fail "${label} must not be empty"
  [[ "${value}" != *$'\n'* ]] || fail "${label} cannot contain a newline"
  [[ "${value}" != *$'\r'* ]] || fail "${label} cannot contain a carriage return"
}

: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${RUSTUP_DIST_SERVER_DEFAULT:?RUSTUP_DIST_SERVER_DEFAULT is required}"
: "${RUSTUP_UPDATE_ROOT_DEFAULT:?RUSTUP_UPDATE_ROOT_DEFAULT is required}"

# Preserve an existing job-level setting while centralizing the normal default.
dist_server="${RUSTUP_DIST_SERVER:-${RUSTUP_DIST_SERVER_DEFAULT}}"
update_root="${RUSTUP_UPDATE_ROOT:-${RUSTUP_UPDATE_ROOT_DEFAULT}}"
validate_value "${dist_server}" "RUSTUP_DIST_SERVER"
validate_value "${update_root}" "RUSTUP_UPDATE_ROOT"

{
  printf 'RUSTUP_DIST_SERVER=%s\n' "${dist_server}"
  printf 'RUSTUP_UPDATE_ROOT=%s\n' "${update_root}"
} >> "${GITHUB_ENV}"
{
  printf 'dist_server=%s\n' "${dist_server}"
  printf 'update_root=%s\n' "${update_root}"
} >> "${GITHUB_OUTPUT}"
