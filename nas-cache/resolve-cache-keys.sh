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

resolve_cache_dir() {
  local cache_name="$1"
  local cache_key="$2"
  local dependency_hash="$3"
  local keys_dir

  if [ -z "${cache_key}" ]; then
    if [ -n "${dependency_hash}" ]; then
      cache_key="${cache_name}-${dependency_hash}"
    else
      cache_key="${cache_name}-no-lockfile"
    fi
  fi
  validate_component "${cache_key}" "${cache_name} cache key"

  keys_dir="${BASE}/${cache_name}/keys"
  RESOLVED_CACHE_DIR="${keys_dir}/${cache_key}"
  mkdir -p "${keys_dir}"

  if [ -L "${RESOLVED_CACHE_DIR}" ]; then
    fail "${cache_name} cache key path cannot be a symbolic link: ${RESOLVED_CACHE_DIR}"
  fi
  if mkdir "${RESOLVED_CACHE_DIR}" 2>/dev/null; then
    echo "${cache_name} cache miss: ${cache_key}; created an empty cache"
  elif [ -d "${RESOLVED_CACHE_DIR}" ]; then
    echo "${cache_name} cache exact hit: ${cache_key}"
  else
    fail "${cache_name} cache key path is not a directory: ${RESOLVED_CACHE_DIR}"
  fi
}

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GO_CACHE_KEY:=}"
: "${GO_DEPENDENCY_HASH:=}"
: "${NPM_CACHE_KEY:=}"
: "${NPM_DEPENDENCY_HASH:=}"
: "${PIP_CACHE_KEY:=}"
: "${PIP_DEPENDENCY_HASH:=}"

RUNNER_CACHE="${RUNNER_CACHE:-/mnt/dependency-cache}"
if [[ "${RUNNER_CACHE}" != /* ]] || [[ "${RUNNER_CACHE}" == *$'\n'* ]] || [[ "${RUNNER_CACHE}" == *$'\r'* ]]; then
  fail "RUNNER_CACHE must be an absolute path without newlines"
fi
if ! [ -d "${RUNNER_CACHE}" ]; then
  echo "::warning::${RUNNER_CACHE} does not exist; the runner pod may not have the NAS cache volume mounted. Caches will not persist."
fi
validate_repository
BASE="${RUNNER_CACHE}/${GITHUB_REPOSITORY}"

resolve_cache_dir "go" "${GO_CACHE_KEY}" "${GO_DEPENDENCY_HASH}"
GO_CACHE_DIR="${RESOLVED_CACHE_DIR}"
mkdir -p "${GO_CACHE_DIR}/pkg/mod" "${GO_CACHE_DIR}/build"

resolve_cache_dir "npm" "${NPM_CACHE_KEY}" "${NPM_DEPENDENCY_HASH}"
NPM_CACHE_DIR="${RESOLVED_CACHE_DIR}"

resolve_cache_dir "pip" "${PIP_CACHE_KEY}" "${PIP_DEPENDENCY_HASH}"
PIP_CACHE_DIR="${RESOLVED_CACHE_DIR}"

{
  echo "GOMODCACHE=${GO_CACHE_DIR}/pkg/mod"
  echo "GOCACHE=${GO_CACHE_DIR}/build"
  echo "npm_config_cache=${NPM_CACHE_DIR}"
  echo "PIP_CACHE_DIR=${PIP_CACHE_DIR}"
} >> "${GITHUB_ENV}"
