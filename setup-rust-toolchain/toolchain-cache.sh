#!/usr/bin/env bash

set -euo pipefail

readonly CACHE_SCHEMA="rust-toolchain-v1"
readonly ACTION_REF="dtolnay/rust-toolchain@d1031067263f94b142dd6c0ce24c5eb9d02d52a0"

fail() {
  echo "::error::$*" >&2
  exit 1
}

warn() {
  echo "::warning::$*" >&2
}

validate_value() {
  local value="$1"
  local label="$2"

  [[ "${value}" != *$'\n'* ]] || fail "${label} cannot contain a newline"
  [[ "${value}" != *$'\r'* ]] || fail "${label} cannot contain a carriage return"
}

validate_absolute_path() {
  local value="$1"
  local label="$2"

  [[ "${value}" = /* ]] || fail "${label} must be an absolute path"
  validate_value "${value}" "${label}"
}

hash_inputs() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s\0' \
      "${CACHE_SCHEMA}" \
      "${GITHUB_REPOSITORY}" \
      "${RUNNER_OS:-unknown}" \
      "${RUNNER_ARCH:-unknown}" \
      "$(uname -m)" \
      "${RUST_TOOLCHAIN}" \
      "${RUST_TARGETS}" \
      "${RUST_TARGET}" \
      "${RUST_COMPONENTS}" \
      "${ACTION_REF}" | sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s\0' \
      "${CACHE_SCHEMA}" \
      "${GITHUB_REPOSITORY}" \
      "${RUNNER_OS:-unknown}" \
      "${RUNNER_ARCH:-unknown}" \
      "$(uname -m)" \
      "${RUST_TOOLCHAIN}" \
      "${RUST_TARGETS}" \
      "${RUST_TARGET}" \
      "${RUST_COMPONENTS}" \
      "${ACTION_REF}" | shasum -a 256 | cut -d' ' -f1
  else
    fail "sha256sum or shasum is required"
  fi
}

manifest_value() {
  local manifest="$1"
  local name="$2"
  local line

  while IFS= read -r line; do
    case "${line}" in
      "${name}"=*) printf '%s\n' "${line#*=}"; return 0 ;;
    esac
  done < "${manifest}"
  return 1
}

cache_valid() {
  local bundle="$1"
  local cache_key="$2"
  local manifest="${bundle}/manifest"
  local name
  local stored_key

  [ -s "${bundle}/.complete" ] || return 1
  [ -s "${manifest}" ] || return 1
  [ -d "${bundle}/rustup" ] || return 1
  [ -x "${bundle}/cargo/bin/rustup" ] || return 1
  [ "$(manifest_value "${manifest}" schema || true)" = "${CACHE_SCHEMA}" ] || return 1
  stored_key="$(manifest_value "${manifest}" cache_key || true)"
  [ "${stored_key}" = "${cache_key}" ] || return 1
  name="$(manifest_value "${manifest}" toolchain_name || true)"
  [ -n "${name}" ] || return 1

  RUSTUP_HOME="${bundle}/rustup" \
    CARGO_HOME="${bundle}/cargo" \
    PATH="${bundle}/cargo/bin:${PATH}" \
    rustup run "${name}" rustc --version >/dev/null 2>&1
}

write_job_environment() {
  {
    echo "RUSTUP_HOME=${LOCAL_RUSTUP_HOME}"
    echo "CARGO_HOME=${LOCAL_CARGO_HOME}"
  } >> "${GITHUB_ENV}"
  echo "${LOCAL_CARGO_HOME}/bin" >> "${GITHUB_PATH}"
}

acquire_lock() {
  local lock_path="$1"

  exec 9>"${lock_path}"
  if ! flock -x -w "${CACHE_LOCK_TIMEOUT_SECONDS}" 9; then
    return 1
  fi
}

release_lock() {
  flock -u 9 2>/dev/null || true
  exec 9>&-
}

prepare_paths() {
  validate_value "${RUST_TOOLCHAIN}" "toolchain"
  validate_value "${RUST_TARGETS}" "targets"
  validate_value "${RUST_TARGET}" "target"
  validate_value "${RUST_COMPONENTS}" "components"
  validate_value "${GITHUB_REPOSITORY}" "GITHUB_REPOSITORY"
  validate_value "${CACHE_LOCK_TIMEOUT_SECONDS}" "cache lock timeout"
  validate_absolute_path "${RUNNER_TEMP}" "RUNNER_TEMP"

  CACHE_KEY="$(hash_inputs)"
  CACHE_ROOT="${RUNNER_TOOL_CACHE:-/opt/hostedtoolcache}"
  validate_absolute_path "${CACHE_ROOT}" "RUNNER_TOOL_CACHE"
  CACHE_DIR="${CACHE_ROOT}/rust-toolchain/${CACHE_KEY}"
  BUNDLE_DIR="${CACHE_DIR}/bundle"
  LOCK_PATH="${CACHE_DIR}.lock"
  # RUSTUP_HOME is job-local and only ever holds this job's toolchain.
  # CARGO_HOME is prepared by dependency-cache.sh (${RUNNER_TEMP}/cargo-home)
  # and may already contain NAS-backed registry/git links, so never wipe it.
  LOCAL_RUSTUP_HOME="${RUNNER_TEMP}/rustup-home"
  LOCAL_CARGO_HOME="${RUNNER_TEMP}/cargo-home"

  mkdir -p "${LOCAL_RUSTUP_HOME}"
  write_job_environment
}

restore() {
  prepare_paths

  if ! [[ "${CACHE_LOCK_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
    fail "cache-lock-timeout-seconds must be a positive integer"
  fi
  if ! command -v flock >/dev/null 2>&1; then
    warn "flock is unavailable; skipping Rust toolchain cache"
    echo "cache-hit=false" >> "${GITHUB_OUTPUT}"
    return 0
  fi

  if ! mkdir -p "${CACHE_DIR}" 2>/dev/null; then
    warn "${CACHE_DIR} is not writable; installing Rust toolchain without cache"
    echo "cache-hit=false" >> "${GITHUB_OUTPUT}"
    return 0
  fi

  if ! acquire_lock "${LOCK_PATH}"; then
    warn "timed out waiting for Rust toolchain cache lock; installing without cache"
    echo "cache-hit=false" >> "${GITHUB_OUTPUT}"
    return 0
  fi

  if cache_valid "${BUNDLE_DIR}" "${CACHE_KEY}"; then
    rm -rf -- "${LOCAL_RUSTUP_HOME}"
    mkdir -p "${LOCAL_RUSTUP_HOME}"
    rm -rf -- "${LOCAL_CARGO_HOME}/bin"
    mkdir -p "${LOCAL_CARGO_HOME}/bin"
    cp -a "${BUNDLE_DIR}/rustup" "${LOCAL_RUSTUP_HOME}/"
    cp -a "${BUNDLE_DIR}/cargo/bin/." "${LOCAL_CARGO_HOME}/bin/"
    toolchain_name="$(manifest_value "${BUNDLE_DIR}/manifest" toolchain_name)"
    toolchain_cachekey="$(manifest_value "${BUNDLE_DIR}/manifest" rustc_cachekey)"
    if RUSTUP_HOME="${LOCAL_RUSTUP_HOME}" \
      CARGO_HOME="${LOCAL_CARGO_HOME}" \
      PATH="${LOCAL_CARGO_HOME}/bin:${PATH}" \
      rustup run "${toolchain_name}" rustc --version >/dev/null 2>&1; then
      release_lock
      {
        echo "RUST_TOOLCHAIN_NAME=${toolchain_name}"
        echo "RUST_TOOLCHAIN_CACHEKEY=${toolchain_cachekey}"
        echo "RUST_TOOLCHAIN_CACHE_HIT=true"
      } >> "${GITHUB_ENV}"
      echo "cache-hit=true" >> "${GITHUB_OUTPUT}"
      echo "Rust toolchain cache hit: ${CACHE_KEY}"
      return 0
    fi
    rm -rf -- "${LOCAL_RUSTUP_HOME}"
    mkdir -p "${LOCAL_RUSTUP_HOME}"
    rm -rf -- "${LOCAL_CARGO_HOME}/bin"
    mkdir -p "${LOCAL_CARGO_HOME}/bin"
  fi

  release_lock
  echo "RUST_TOOLCHAIN_CACHE_HIT=false" >> "${GITHUB_ENV}"
  echo "cache-hit=false" >> "${GITHUB_OUTPUT}"
  echo "Rust toolchain cache miss: ${CACHE_KEY}"
}

save() {
  : "${RUST_TOOLCHAIN_NAME:?Rust toolchain name is required}"
  : "${RUST_TOOLCHAIN_CACHEKEY:?Rustc cache key is required}"
  prepare_paths

  validate_value "${RUST_TOOLCHAIN_NAME}" "Rust toolchain name"
  validate_value "${RUST_TOOLCHAIN_CACHEKEY}" "Rustc cache key"
  if ! [[ "${CACHE_LOCK_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
    fail "cache-lock-timeout-seconds must be a positive integer"
  fi
  if ! command -v flock >/dev/null 2>&1; then
    warn "flock is unavailable; skipping Rust toolchain cache save"
    {
      echo "RUST_TOOLCHAIN_NAME=${RUST_TOOLCHAIN_NAME}"
      echo "RUST_TOOLCHAIN_CACHEKEY=${RUST_TOOLCHAIN_CACHEKEY}"
    } >> "${GITHUB_ENV}"
    return 0
  fi

  if ! mkdir -p "${CACHE_DIR}" 2>/dev/null; then
    warn "${CACHE_DIR} is not writable; skipping Rust toolchain cache save"
    {
      echo "RUST_TOOLCHAIN_NAME=${RUST_TOOLCHAIN_NAME}"
      echo "RUST_TOOLCHAIN_CACHEKEY=${RUST_TOOLCHAIN_CACHEKEY}"
    } >> "${GITHUB_ENV}"
    return 0
  fi
  if ! acquire_lock "${LOCK_PATH}"; then
    warn "timed out waiting for Rust toolchain cache lock; skipping cache save"
    {
      echo "RUST_TOOLCHAIN_NAME=${RUST_TOOLCHAIN_NAME}"
      echo "RUST_TOOLCHAIN_CACHEKEY=${RUST_TOOLCHAIN_CACHEKEY}"
    } >> "${GITHUB_ENV}"
    return 0
  fi

  if cache_valid "${BUNDLE_DIR}" "${CACHE_KEY}"; then
    release_lock
    {
      echo "RUST_TOOLCHAIN_NAME=${RUST_TOOLCHAIN_NAME}"
      echo "RUST_TOOLCHAIN_CACHEKEY=${RUST_TOOLCHAIN_CACHEKEY}"
    } >> "${GITHUB_ENV}"
    echo "Rust toolchain cache was populated by another job: ${CACHE_KEY}"
    return 0
  fi

  local staging_dir="${CACHE_DIR}/.staging.$$"
  rm -rf -- "${staging_dir}"
  mkdir -p "${staging_dir}/bundle/cargo"
  trap 'rm -rf -- "${staging_dir}"; release_lock' EXIT

  [ -d "${LOCAL_RUSTUP_HOME}" ] || fail "${LOCAL_RUSTUP_HOME} does not exist"
  [ -d "${LOCAL_CARGO_HOME}/bin" ] || fail "${LOCAL_CARGO_HOME}/bin does not exist"
  RUSTUP_HOME="${LOCAL_RUSTUP_HOME}" \
    CARGO_HOME="${LOCAL_CARGO_HOME}" \
    PATH="${LOCAL_CARGO_HOME}/bin:${PATH}" \
    rustup run "${RUST_TOOLCHAIN_NAME}" rustc --version >/dev/null \
    || fail "installed Rust toolchain failed validation"

  cp -a "${LOCAL_RUSTUP_HOME}" "${staging_dir}/bundle/rustup"
  cp -a "${LOCAL_CARGO_HOME}/bin" "${staging_dir}/bundle/cargo/bin"
  {
    echo "schema=${CACHE_SCHEMA}"
    echo "cache_key=${CACHE_KEY}"
    echo "toolchain=${RUST_TOOLCHAIN}"
    echo "targets=${RUST_TARGETS}"
    echo "target=${RUST_TARGET}"
    echo "components=${RUST_COMPONENTS}"
    echo "toolchain_name=${RUST_TOOLCHAIN_NAME}"
    echo "rustc_cachekey=${RUST_TOOLCHAIN_CACHEKEY}"
  } > "${staging_dir}/bundle/manifest"
  printf 'complete\n' > "${staging_dir}/bundle/.complete"

  rm -rf -- "${BUNDLE_DIR}"
  mv "${staging_dir}/bundle" "${BUNDLE_DIR}"
  rm -rf -- "${staging_dir}"
  trap - EXIT
  release_lock
  {
    echo "RUST_TOOLCHAIN_NAME=${RUST_TOOLCHAIN_NAME}"
    echo "RUST_TOOLCHAIN_CACHEKEY=${RUST_TOOLCHAIN_CACHEKEY}"
  } >> "${GITHUB_ENV}"
  echo "Rust toolchain cache populated: ${CACHE_KEY}"
}

: "${RUST_TOOLCHAIN:?toolchain is required}"
: "${RUST_TARGETS:=}"
: "${RUST_TARGET:=}"
: "${RUST_COMPONENTS:=}"
: "${CACHE_LOCK_TIMEOUT_SECONDS:=1800}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

case "${1:-}" in
  restore) restore ;;
  save) save ;;
  *) fail "usage: $0 restore|save" ;;
esac
