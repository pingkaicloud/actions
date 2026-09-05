#!/usr/bin/env bash

# Set up the job-local Cargo home and the optional Lindera cache on the
# shared runner NAS volume. Moved here from nas-cache so that
# setup-rust-toolchain is a one-stop Rust environment action.
#
# Layout:
#   CARGO_HOME (job-local, under RUNNER_TEMP)
#     bin/                     toolchain shims (restored/installed by the action)
#     registry/src/            unpacked crate sources, job-local on purpose
#     registry/cache/  -> NAS  downloaded .crate files (safe to share)
#     git/db/          -> NAS  cargo git dependency database
#     .package-cache(-mutate) -> NAS download/mutation lock files
#
# registry/src stays job-local: concurrent jobs unpacking the same crate
# into a shared src directory fail with "File exists" races, while
# re-unpacking from the shared cache is cheap and needs no network.

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

validate_value() {
  local value="$1"
  local label="$2"

  [[ "${value}" != *$'\n'* ]] || fail "${label} cannot contain a newline"
  [[ "${value}" != *$'\r'* ]] || fail "${label} cannot contain a carriage return"
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
: "${GITHUB_PATH:?GITHUB_PATH is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${ENABLE_CARGO_CACHE:=true}"
: "${CARGO_CACHE_KEY:=}"
: "${LINDERA_CACHE_KEY:=}"

validate_value "${CARGO_CACHE_KEY}" "cargo cache key"
validate_value "${LINDERA_CACHE_KEY}" "lindera cache key"
validate_absolute_path "${RUNNER_TEMP}" "RUNNER_TEMP"

case "${ENABLE_CARGO_CACHE}" in
  true|1) cargo_cache_enabled=true ;;
  false|0) cargo_cache_enabled=false ;;
  *) fail "ENABLE_CARGO_CACHE must be true or false" ;;
esac

RUNNER_CACHE="${RUNNER_CACHE:-/mnt/dependency-cache}"
validate_absolute_path "${RUNNER_CACHE}" "RUNNER_CACHE"
if ! [ -d "${RUNNER_CACHE}" ]; then
  echo "::warning::${RUNNER_CACHE} does not exist; the runner pod may not have the NAS cache volume mounted. Caches will not persist."
fi
validate_repository
# REPO_CACHE can be preset to share or relocate the whole per-repo cache root.
: "${REPO_CACHE:=${RUNNER_CACHE}/${GITHUB_REPOSITORY}}"
validate_absolute_path "${REPO_CACHE}" "REPO_CACHE"
BASE="${REPO_CACHE}"

CARGO_HOME="${RUNNER_TEMP}/cargo-home"
ensure_directory "${CARGO_HOME}" "job-local Cargo home"
ensure_directory "${CARGO_HOME}/bin" "job-local Cargo bin directory"
ensure_directory "${CARGO_HOME}/git" "job-local Cargo git directory"
ensure_directory "${CARGO_HOME}/registry" "job-local Cargo registry directory"
ensure_directory "${CARGO_HOME}/registry/src" "job-local Cargo registry sources"

if [ "${cargo_cache_enabled}" = true ]; then
  resolve_cache_dir "cargo" "${CARGO_CACHE_KEY}"
  CARGO_CACHE_DIR="${RESOLVED_CACHE_DIR}"
  # Reuse the registry subtree created by the previous nas-cache layout so
  # populated .crate downloads keep working; only cache/ is shared now.
  ensure_directory "${CARGO_CACHE_DIR}/registry" "Cargo registry cache"
  ensure_directory "${CARGO_CACHE_DIR}/registry/cache" "Cargo crate download cache"
  ensure_directory "${CARGO_CACHE_DIR}/git-db" "Cargo git DB cache"
  ensure_file "${CARGO_CACHE_DIR}/.package-cache" "Cargo download lock"
  ensure_file "${CARGO_CACHE_DIR}/.package-cache-mutate" "Cargo mutation lock"

  ensure_directory_link "${CARGO_HOME}/registry/cache" "${CARGO_CACHE_DIR}/registry/cache" "Cargo crate download cache link"
  ensure_directory_link "${CARGO_HOME}/git/db" "${CARGO_CACHE_DIR}/git-db" "Cargo git DB link"
  ensure_file_link "${CARGO_HOME}/.package-cache" "${CARGO_CACHE_DIR}/.package-cache" "Cargo download lock link"
  ensure_file_link "${CARGO_HOME}/.package-cache-mutate" "${CARGO_CACHE_DIR}/.package-cache-mutate" "Cargo mutation lock link"
fi

if [ -n "${LINDERA_CACHE_KEY}" ]; then
  resolve_cache_dir "lindera" "${LINDERA_CACHE_KEY}"
  LINDERA_CACHE_DIR="${RESOLVED_CACHE_DIR}"
  ensure_directory "${LINDERA_CACHE_DIR}" "Lindera cache"
  ensure_file "${LINDERA_CACHE_DIR}/.lock" "Lindera cache lock"
fi

{
  echo "CARGO_HOME=${CARGO_HOME}"
  if [ -n "${LINDERA_CACHE_KEY}" ]; then
    echo "LINDERA_CACHE=${LINDERA_CACHE_DIR}"
    echo "LINDERA_CACHE_LOCK=${LINDERA_CACHE_DIR}/.lock"
    echo "LINDERA_CACHE_READY=${LINDERA_CACHE_DIR}/.ready"
  fi
} >> "${GITHUB_ENV}"
echo "${CARGO_HOME}/bin" >> "${GITHUB_PATH}"
