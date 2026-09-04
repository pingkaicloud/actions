#!/usr/bin/env bash

set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

validate_absolute_path() {
  local value="$1"
  local label="$2"

  if [[ "${value}" != /* ]] || [[ "${value}" == *$'\n'* ]] || [[ "${value}" == *$'\r'* ]]; then
    fail "${label} must be an absolute path without newlines"
  fi
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

ensure_directory() {
  local path="$1"
  local label="$2"

  if [ -L "${path}" ]; then
    fail "${label} cannot be a symbolic link: ${path}"
  fi
  mkdir -p "${path}"
  [ -d "${path}" ] || fail "${label} is not a directory: ${path}"
}

ensure_directory_link() {
  local link_path="$1"
  local target_path="$2"
  local label="$3"

  if [ -L "${link_path}" ]; then
    [ "$(readlink "${link_path}")" = "${target_path}" ] \
      || fail "${label} points to an unexpected target: ${link_path}"
    return
  fi
  [ ! -e "${link_path}" ] || fail "${label} already exists and is not a symbolic link: ${link_path}"
  ln -s "${target_path}" "${link_path}"
}

ensure_file() {
  local path="$1"
  local label="$2"

  if [ -L "${path}" ]; then
    fail "${label} cannot be a symbolic link: ${path}"
  fi
  if [ -e "${path}" ] && [ ! -f "${path}" ]; then
    fail "${label} is not a regular file: ${path}"
  fi
  touch "${path}"
  [ -f "${path}" ] || fail "${label} is not a regular file: ${path}"
}

ensure_file_link() {
  local link_path="$1"
  local target_path="$2"
  local label="$3"

  if [ -L "${link_path}" ]; then
    [ "$(readlink "${link_path}")" = "${target_path}" ] \
      || fail "${label} points to an unexpected target: ${link_path}"
    return
  fi
  [ ! -e "${link_path}" ] || fail "${label} already exists and is not a symbolic link: ${link_path}"
  ln -s "${target_path}" "${link_path}"
}

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GO_CACHE_KEY:=}"
: "${NPM_CACHE_KEY:=}"
: "${PIP_CACHE_KEY:=}"
: "${PULUMI_CACHE_KEY:=}"
: "${ENABLE_CARGO_CACHE:=false}"
: "${CARGO_CACHE_KEY:=}"
: "${ENABLE_LINDERA_CACHE:=false}"
: "${LINDERA_CACHE_KEY:=}"

case "${ENABLE_CARGO_CACHE}" in
  true|1) cargo_cache_enabled=true ;;
  false|0) cargo_cache_enabled=false ;;
  *) fail "ENABLE_CARGO_CACHE must be true or false" ;;
esac
case "${ENABLE_LINDERA_CACHE}" in
  true|1) lindera_cache_enabled=true ;;
  false|0) lindera_cache_enabled=false ;;
  *) fail "ENABLE_LINDERA_CACHE must be true or false" ;;
esac

RUNNER_CACHE="${RUNNER_CACHE:-/mnt/dependency-cache}"
validate_absolute_path "${RUNNER_CACHE}" "RUNNER_CACHE"
if ! [ -d "${RUNNER_CACHE}" ]; then
  echo "::warning::${RUNNER_CACHE} does not exist; the runner pod may not have the NAS cache volume mounted. Caches will not persist."
fi
validate_repository
# REPO_CACHE can be preset to share or relocate the whole per-repo cache root
# (e.g. buildx local cache backends); it defaults to the per-repo NAS path.
: "${REPO_CACHE:=${RUNNER_CACHE}/${GITHUB_REPOSITORY}}"
validate_absolute_path "${REPO_CACHE}" "REPO_CACHE"
BASE="${REPO_CACHE}"

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

if [ "${cargo_cache_enabled}" = true ]; then
  : "${RUNNER_TEMP:?RUNNER_TEMP is required when Cargo caching is enabled}"
  validate_absolute_path "${RUNNER_TEMP}" "RUNNER_TEMP"
  : "${GITHUB_PATH:?GITHUB_PATH is required when Cargo caching is enabled}"

  resolve_cache_dir "cargo" "${CARGO_CACHE_KEY}"
  CARGO_CACHE_DIR="${RESOLVED_CACHE_DIR}"
  ensure_directory "${CARGO_CACHE_DIR}/registry" "Cargo registry cache"
  ensure_directory "${CARGO_CACHE_DIR}/git-db" "Cargo git DB cache"
  ensure_file "${CARGO_CACHE_DIR}/.package-cache" "Cargo download lock"
  ensure_file "${CARGO_CACHE_DIR}/.package-cache-mutate" "Cargo mutation lock"

  CARGO_HOME="${RUNNER_TEMP}/cargo-home"
  ensure_directory "${CARGO_HOME}" "job-local Cargo home"
  ensure_directory "${CARGO_HOME}/git" "job-local Cargo git directory"
  ensure_directory "${CARGO_HOME}/bin" "job-local Cargo bin directory"
  ensure_directory_link "${CARGO_HOME}/registry" "${CARGO_CACHE_DIR}/registry" "Cargo registry link"
  ensure_directory_link "${CARGO_HOME}/git/db" "${CARGO_CACHE_DIR}/git-db" "Cargo git DB link"
  ensure_file_link "${CARGO_HOME}/.package-cache" "${CARGO_CACHE_DIR}/.package-cache" "Cargo download lock link"
  ensure_file_link "${CARGO_HOME}/.package-cache-mutate" "${CARGO_CACHE_DIR}/.package-cache-mutate" "Cargo mutation lock link"
fi

if [ "${lindera_cache_enabled}" = true ]; then
  resolve_cache_dir "lindera" "${LINDERA_CACHE_KEY}"
  LINDERA_CACHE_DIR="${RESOLVED_CACHE_DIR}"
  ensure_directory "${LINDERA_CACHE_DIR}" "Lindera cache"
  ensure_file "${LINDERA_CACHE_DIR}/.lock" "Lindera cache lock"
fi

{
  echo "REPO_CACHE=${BASE}"
  echo "GOMODCACHE=${GO_CACHE_DIR}/pkg/mod"
  echo "GOCACHE=${GO_CACHE_DIR}/build"
  echo "npm_config_cache=${NPM_CACHE_DIR}"
  echo "PIP_CACHE_DIR=${PIP_CACHE_DIR}"
  if [ "${cargo_cache_enabled}" = true ]; then
    echo "CARGO_HOME=${CARGO_HOME}"
  fi
  if [ "${lindera_cache_enabled}" = true ]; then
    echo "LINDERA_CACHE=${LINDERA_CACHE_DIR}"
    echo "LINDERA_CACHE_LOCK=${LINDERA_CACHE_DIR}/.lock"
    echo "LINDERA_CACHE_READY=${LINDERA_CACHE_DIR}/.ready"
  fi
} >> "${GITHUB_ENV}"

if [ "${cargo_cache_enabled}" = true ]; then
  echo "${CARGO_HOME}/bin" >> "${GITHUB_PATH}"
fi
