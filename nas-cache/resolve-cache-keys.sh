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
  local cache_label
  local parent_dir

  if [ -z "${cache_key}" ]; then
    parent_dir="${BASE}/${cache_name}"
    RESOLVED_CACHE_DIR="${parent_dir}/default"
    cache_label="default"
  else
    validate_component "${cache_key}" "${cache_name} cache key"
    parent_dir="${BASE}/${cache_name}/keys"
    RESOLVED_CACHE_DIR="${parent_dir}/${cache_key}"
    cache_label="key ${cache_key}"
  fi
  mkdir -p "${parent_dir}"

  if [ -L "${RESOLVED_CACHE_DIR}" ]; then
    fail "${cache_name} cache path cannot be a symbolic link: ${RESOLVED_CACHE_DIR}"
  fi
  if mkdir "${RESOLVED_CACHE_DIR}" 2>/dev/null; then
    echo "${cache_name} cache miss: ${cache_label}; created an empty cache"
  elif [ -d "${RESOLVED_CACHE_DIR}" ]; then
    echo "${cache_name} cache hit: ${cache_label}"
  else
    fail "${cache_name} cache path is not a directory: ${RESOLVED_CACHE_DIR}"
  fi
}

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GO_CACHE_KEY:=}"
: "${NPM_CACHE_KEY:=}"
: "${PIP_CACHE_KEY:=}"
: "${PULUMI_CACHE_KEY:=}"

RUNNER_CACHE="${RUNNER_CACHE:-/mnt/dependency-cache}"
if [[ "${RUNNER_CACHE}" != /* ]] || [[ "${RUNNER_CACHE}" == *$'\n'* ]] || [[ "${RUNNER_CACHE}" == *$'\r'* ]]; then
  fail "RUNNER_CACHE must be an absolute path without newlines"
fi
if ! [ -d "${RUNNER_CACHE}" ]; then
  echo "::warning::${RUNNER_CACHE} does not exist; the runner pod may not have the NAS cache volume mounted. Caches will not persist."
fi
validate_repository
BASE="${RUNNER_CACHE}/${GITHUB_REPOSITORY}"

resolve_cache_dir "go" "${GO_CACHE_KEY}"
GO_CACHE_DIR="${RESOLVED_CACHE_DIR}"
mkdir -p "${GO_CACHE_DIR}/pkg/mod" "${GO_CACHE_DIR}/build"

resolve_cache_dir "npm" "${NPM_CACHE_KEY}"
NPM_CACHE_DIR="${RESOLVED_CACHE_DIR}"

resolve_cache_dir "pip" "${PIP_CACHE_KEY}"
PIP_CACHE_DIR="${RESOLVED_CACHE_DIR}"

resolve_cache_dir "pulumi" "${PULUMI_CACHE_KEY}"
PULUMI_CACHE_DIR="${RESOLVED_CACHE_DIR}"
mkdir -p "${PULUMI_CACHE_DIR}/plugins"

# Share only the plugin directory. PULUMI_HOME itself must stay pod-local:
# concurrent jobs of the same repository log in to different Pulumi backends
# (e.g. with and without ?profile=...), and a shared credentials.json lets
# them clobber each other's "current" backend.
pulumi_plugins="${HOME:-/home/runner}/.pulumi/plugins"
if [ -L "${pulumi_plugins}" ]; then
  ln -sfn "${PULUMI_CACHE_DIR}/plugins" "${pulumi_plugins}"
elif [ -e "${pulumi_plugins}" ]; then
  echo "::warning::${pulumi_plugins} already exists and is not a symlink; leaving it in place, plugins will not be shared"
else
  mkdir -p "${HOME:-/home/runner}/.pulumi"
  ln -s "${PULUMI_CACHE_DIR}/plugins" "${pulumi_plugins}"
fi

{
  echo "GOMODCACHE=${GO_CACHE_DIR}/pkg/mod"
  echo "GOCACHE=${GO_CACHE_DIR}/build"
  echo "npm_config_cache=${NPM_CACHE_DIR}"
  echo "PIP_CACHE_DIR=${PIP_CACHE_DIR}"
} >> "${GITHUB_ENV}"
