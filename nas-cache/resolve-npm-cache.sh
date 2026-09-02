#!/usr/bin/env bash

set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

validate_component() {
  local value="$1"
  local label="$2"

  if [ "${#value}" -gt 255 ] \
     || [[ ! "${value}" =~ ^[A-Za-z0-9._-]+$ ]] \
     || [ "${value}" = "." ] \
     || [ "${value}" = ".." ]; then
    fail "${label} must be 1-255 characters from [A-Za-z0-9._-] and cannot be . or .."
  fi
}

validate_repository() {
  local owner="${GITHUB_REPOSITORY%%/*}"
  local repo="${GITHUB_REPOSITORY#*/}"

  if [ "${owner}" = "${GITHUB_REPOSITORY}" ] || [[ "${repo}" == */* ]]; then
    fail "GITHUB_REPOSITORY must have the owner/repository form"
  fi
  validate_component "${owner}" "repository owner"
  validate_component "${repo}" "repository name"
}

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${NPM_CACHE_KEY:=}"
: "${DEFAULT_LOCK_HASH:=}"

RUNNER_CACHE="${RUNNER_CACHE:-/mnt/dependency-cache}"
if [[ "${RUNNER_CACHE}" != /* ]] || [[ "${RUNNER_CACHE}" == *$'\n'* ]] || [[ "${RUNNER_CACHE}" == *$'\r'* ]]; then
  fail "RUNNER_CACHE must be an absolute path without newlines"
fi
validate_repository

if [ -z "${NPM_CACHE_KEY}" ]; then
  if [ -n "${DEFAULT_LOCK_HASH}" ]; then
    NPM_CACHE_KEY="npm-${DEFAULT_LOCK_HASH}"
  else
    NPM_CACHE_KEY="npm-no-lockfile"
  fi
fi
validate_component "${NPM_CACHE_KEY}" "npm cache key"

BASE="${RUNNER_CACHE}/${GITHUB_REPOSITORY}/npm"
KEYS_DIR="${BASE}/keys"
KEY_DIR="${KEYS_DIR}/${NPM_CACHE_KEY}"
mkdir -p "${KEYS_DIR}"

if [ -L "${KEY_DIR}" ]; then
  fail "npm cache key path cannot be a symbolic link: ${KEY_DIR}"
fi

if mkdir "${KEY_DIR}" 2>/dev/null; then
  echo "npm cache miss: ${NPM_CACHE_KEY}; created an empty cache"
elif [ -d "${KEY_DIR}" ]; then
  echo "npm cache exact hit: ${NPM_CACHE_KEY}"
else
  fail "npm cache key path is not a directory: ${KEY_DIR}"
fi

echo "npm_config_cache=${KEY_DIR}" >> "${GITHUB_ENV}"
