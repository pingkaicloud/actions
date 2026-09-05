#!/usr/bin/env bash

set -euo pipefail

readonly CACHE_SCHEMA="rust-toolchain-v1"
readonly ACTION_REPOSITORY="dtolnay/rust-toolchain"
readonly ACTION_BRANCH="master"
readonly ACTION_REF_FILE_NAME="rust-toolchain-action-ref"
readonly INSTALL_CLAIM_FILE_NAME=".installing"
ACTION_REF=""
LOCK_HEARTBEAT_FILE=""
LOCK_HEARTBEAT_PID=""

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

validate_positive_integer() {
  local value="$1"
  local label="$2"

  [[ "${value}" =~ ^[1-9][0-9]*$ ]] || fail "${label} must be a positive integer"
}

resolve_action_ref() {
  local ref_file="${RUNNER_TEMP}/${ACTION_REF_FILE_NAME}"
  local action_sha=""

  if [ -s "${ref_file}" ]; then
    action_sha="$(<"${ref_file}")"
  fi

  if ! [[ "${action_sha}" =~ ^[0-9a-f]{40}$ ]]; then
    if ! action_sha="$(
      GIT_TERMINAL_PROMPT=0 git \
        -c http.connectTimeout=10 \
        -c http.lowSpeedLimit=1000 \
        -c http.lowSpeedTime=10 \
        ls-remote --heads --exit-code \
        "https://github.com/${ACTION_REPOSITORY}.git" \
        "refs/heads/${ACTION_BRANCH}" \
        | awk -v ref="refs/heads/${ACTION_BRANCH}" '$2 == ref { print $1; exit }'
    )"; then
      fail "failed to resolve ${ACTION_REPOSITORY}@${ACTION_BRANCH}"
    fi
    if ! [[ "${action_sha}" =~ ^[0-9a-f]{40}$ ]]; then
      fail "invalid resolved SHA for ${ACTION_REPOSITORY}@${ACTION_BRANCH}"
    fi
    local temp_ref_file="${ref_file}.$$"
    printf '%s\n' "${action_sha}" > "${temp_ref_file}"
    mv -f -- "${temp_ref_file}" "${ref_file}"
  fi

  printf '%s@%s\n' "${ACTION_REPOSITORY}" "${action_sha}"
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

file_mtime() {
  stat -c %Y -- "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

lock_is_stale() {
  local mtime now current_heartbeat

  [ -d "${LOCK_PATH}" ] || return 1
  current_heartbeat="$(find "${LOCK_PATH}" -maxdepth 1 -type f -name 'heartbeat.*' -print -quit 2>/dev/null)"
  if [ -n "${current_heartbeat}" ]; then
    mtime="$(file_mtime "${current_heartbeat}")" || return 1
  else
    mtime="$(file_mtime "${LOCK_PATH}")" || return 1
  fi
  [[ "${mtime}" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  (( now >= mtime && now - mtime >= CACHE_LOCK_STALE_SECONDS ))
}

reclaim_lock() {
  local quarantine_path="${LOCK_PATH}.reclaim.${HOSTNAME:-unknown}-$$-${RANDOM}-$(date +%s%N)"

  # Rename is atomic within the NAS directory. A waiter that loses the race
  # cannot remove a lock acquired by the next owner.
  if mv -- "${LOCK_PATH}" "${quarantine_path}" 2>/dev/null; then
    rm -rf -- "${quarantine_path}"
    return 0
  fi
  return 1
}

start_lock_heartbeat() {
  local parent_pid=$$

  (
    while true; do
      sleep "${CACHE_LOCK_HEARTBEAT_SECONDS}"
      kill -0 "${parent_pid}" 2>/dev/null || exit 0
      [ -f "${LOCK_HEARTBEAT_FILE}" ] || exit 0
      touch -- "${LOCK_HEARTBEAT_FILE}" || true
    done
  ) &
  LOCK_HEARTBEAT_PID=$!
}

acquire_lock() {
  local deadline now

  deadline=$(( $(date +%s) + CACHE_LOCK_TIMEOUT_SECONDS ))
  while true; do
    if mkdir -- "${LOCK_PATH}" 2>/dev/null; then
      if ! touch -- "${LOCK_HEARTBEAT_FILE}"; then
        rmdir -- "${LOCK_PATH}" 2>/dev/null || true
        return 1
      fi
      start_lock_heartbeat
      return 0
    fi

    now="$(date +%s)"
    if (( now >= deadline )); then
      return 1
    fi
    if lock_is_stale && reclaim_lock; then
      continue
    fi
    sleep "${CACHE_LOCK_POLL_SECONDS}"
  done
}

release_lock() {
  if [ -n "${LOCK_HEARTBEAT_PID}" ]; then
    kill "${LOCK_HEARTBEAT_PID}" 2>/dev/null || true
    wait "${LOCK_HEARTBEAT_PID}" 2>/dev/null || true
    LOCK_HEARTBEAT_PID=""
  fi

  # Only remove the lock directory when this owner still has its heartbeat in
  # it. If stale recovery already replaced the directory, do not touch the new
  # owner's lock.
  if [ -n "${LOCK_HEARTBEAT_FILE}" ] && [ -f "${LOCK_HEARTBEAT_FILE}" ]; then
    rm -f -- "${LOCK_HEARTBEAT_FILE}" || true
    rmdir -- "${LOCK_PATH}" 2>/dev/null || true
  fi
}

claim_value() {
  local name="$1"
  local line

  while IFS= read -r line; do
    case "${line}" in
      "${name}"=*) printf '%s\n' "${line#*=}"; return 0 ;;
    esac
  done < "${INSTALL_CLAIM_PATH}"
  return 1
}

claim_owned_by_current_job() {
  [ -f "${INSTALL_CLAIM_PATH}" ] || return 1
  [ "$(claim_value owner || true)" = "${CACHE_OWNER}" ]
}

claim_is_stale() {
  local started_at now

  started_at="$(claim_value started_at || true)"
  if ! [[ "${started_at}" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  now="$(date +%s)"
  (( now >= started_at && now - started_at >= CACHE_INSTALL_LEASE_SECONDS ))
}

write_install_claim() {
  local claim_tmp

  claim_tmp="$(mktemp "${INSTALL_CLAIM_PATH}.tmp.XXXXXX")" \
    || fail "failed to create Rust toolchain installation claim temporary file"

  {
    printf 'owner=%s\n' "${CACHE_OWNER}"
    printf 'started_at=%s\n' "$(date +%s)"
  } > "${claim_tmp}"
  mv -f -- "${claim_tmp}" "${INSTALL_CLAIM_PATH}"
}

remove_owned_install_claim() {
  if claim_owned_by_current_job; then
    rm -f -- "${INSTALL_CLAIM_PATH}"
  fi
}

set_cache_miss() {
  echo "RUST_TOOLCHAIN_CACHE_HIT=false" >> "${GITHUB_ENV}"
  echo "cache-hit=false" >> "${GITHUB_OUTPUT}"
  echo "Rust toolchain cache miss: ${CACHE_KEY} (installation claim owned by this job)"
}

restore_bundle() {
  local toolchain_name toolchain_cachekey

  rm -rf -- "${LOCAL_RUSTUP_HOME}"
  mkdir -p "${LOCAL_RUSTUP_HOME}"
  rm -rf -- "${LOCAL_CARGO_HOME}/bin"
  mkdir -p "${LOCAL_CARGO_HOME}/bin"
  cp -a "${BUNDLE_DIR}/rustup" "${LOCAL_RUSTUP_HOME}/"
  cp -a "${BUNDLE_DIR}/cargo/bin/." "${LOCAL_CARGO_HOME}/bin/"
  toolchain_name="$(manifest_value "${BUNDLE_DIR}/manifest" toolchain_name)"
  toolchain_cachekey="$(manifest_value "${BUNDLE_DIR}/manifest" rustc_cachekey)"
  if ! RUSTUP_HOME="${LOCAL_RUSTUP_HOME}" \
    CARGO_HOME="${LOCAL_CARGO_HOME}" \
    PATH="${LOCAL_CARGO_HOME}/bin:${PATH}" \
    rustup run "${toolchain_name}" rustc --version >/dev/null 2>&1; then
    rm -rf -- "${LOCAL_RUSTUP_HOME}"
    mkdir -p "${LOCAL_RUSTUP_HOME}"
    rm -rf -- "${LOCAL_CARGO_HOME}/bin"
    mkdir -p "${LOCAL_CARGO_HOME}/bin"
    return 1
  fi
  {
    echo "RUST_TOOLCHAIN_NAME=${toolchain_name}"
    echo "RUST_TOOLCHAIN_CACHEKEY=${toolchain_cachekey}"
    echo "RUST_TOOLCHAIN_CACHE_HIT=true"
  } >> "${GITHUB_ENV}"
  echo "cache-hit=true" >> "${GITHUB_OUTPUT}"
  echo "Rust toolchain cache hit: ${CACHE_KEY}"
}

wait_for_install_claim() {
  local deadline now

  deadline=$(( $(date +%s) + CACHE_LOCK_TIMEOUT_SECONDS ))
  while true; do
    now="$(date +%s)"
    if (( now >= deadline )); then
      fail "timed out waiting for Rust toolchain installation claim: ${CACHE_KEY}"
    fi
    sleep 5

    if ! acquire_lock; then
      fail "timed out waiting for Rust toolchain cache lock: ${CACHE_KEY}"
    fi
    if cache_valid "${BUNDLE_DIR}" "${CACHE_KEY}"; then
      if restore_bundle; then
        release_lock
        return 0
      fi
    fi
    if [ ! -f "${INSTALL_CLAIM_PATH}" ] || claim_is_stale; then
      rm -f -- "${INSTALL_CLAIM_PATH}"
      write_install_claim
      release_lock
      set_cache_miss
      return 0
    fi
    release_lock
  done
}

prepare_paths() {
  validate_value "${RUST_TOOLCHAIN}" "toolchain"
  validate_value "${RUST_TARGETS}" "targets"
  validate_value "${RUST_TARGET}" "target"
  validate_value "${RUST_COMPONENTS}" "components"
  validate_value "${GITHUB_REPOSITORY}" "GITHUB_REPOSITORY"
  validate_value "${GITHUB_RUN_ID}" "GITHUB_RUN_ID"
  validate_value "${GITHUB_JOB}" "GITHUB_JOB"
  validate_value "${GITHUB_RUN_ATTEMPT}" "GITHUB_RUN_ATTEMPT"
  validate_value "${CACHE_LOCK_TIMEOUT_SECONDS}" "cache lock timeout"
  validate_absolute_path "${RUNNER_TEMP}" "RUNNER_TEMP"
  validate_positive_integer "${CACHE_LOCK_HEARTBEAT_SECONDS}" "cache lock heartbeat"
  validate_positive_integer "${CACHE_LOCK_STALE_SECONDS}" "cache lock stale timeout"
  validate_positive_integer "${CACHE_LOCK_POLL_SECONDS}" "cache lock poll interval"

  ACTION_REF="$(resolve_action_ref)"
  CACHE_KEY="$(hash_inputs)"
  CACHE_ROOT="${RUNNER_TOOL_CACHE:-/opt/hostedtoolcache}"
  validate_absolute_path "${CACHE_ROOT}" "RUNNER_TOOL_CACHE"
  CACHE_DIR="${CACHE_ROOT}/rust-toolchain/${CACHE_KEY}"
  BUNDLE_DIR="${CACHE_DIR}/bundle"
  LOCK_PATH="${CACHE_DIR}.lock.d"
  INSTALL_CLAIM_PATH="${CACHE_DIR}/${INSTALL_CLAIM_FILE_NAME}"
  LOCK_HEARTBEAT_FILE="${LOCK_PATH}/heartbeat.${HOSTNAME:-unknown}-$$-${RANDOM}-$(date +%s%N)"
  # RUNNER_TEMP is only unique inside each runner Pod. Use GitHub's job identity
  # so claims remain unique when multiple Pods share the same NAS cache.
  CACHE_OWNER="${GITHUB_RUN_ID}/${GITHUB_JOB}/${GITHUB_RUN_ATTEMPT}"
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

  validate_positive_integer "${CACHE_LOCK_TIMEOUT_SECONDS}" "cache-lock-timeout-seconds"
  validate_positive_integer "${CACHE_INSTALL_LEASE_SECONDS}" "cache-install-lease-seconds"

  if ! mkdir -p "${CACHE_DIR}" 2>/dev/null; then
    warn "${CACHE_DIR} is not writable; installing Rust toolchain without cache"
    echo "cache-hit=false" >> "${GITHUB_OUTPUT}"
    return 0
  fi

  if ! acquire_lock; then
    fail "timed out waiting for Rust toolchain cache lock: ${CACHE_KEY}"
  fi

  if cache_valid "${BUNDLE_DIR}" "${CACHE_KEY}"; then
    if restore_bundle; then
      release_lock
      return 0
    fi
  fi

  if [ -f "${INSTALL_CLAIM_PATH}" ] && ! claim_owned_by_current_job \
    && ! claim_is_stale; then
    release_lock
    wait_for_install_claim
    return 0
  fi

  rm -f -- "${INSTALL_CLAIM_PATH}"
  write_install_claim
  release_lock
  set_cache_miss
}

save() {
  : "${RUST_TOOLCHAIN_NAME:?Rust toolchain name is required}"
  : "${RUST_TOOLCHAIN_CACHEKEY:?Rustc cache key is required}"
  prepare_paths

  validate_value "${RUST_TOOLCHAIN_NAME}" "Rust toolchain name"
  validate_value "${RUST_TOOLCHAIN_CACHEKEY}" "Rustc cache key"
  validate_positive_integer "${CACHE_LOCK_TIMEOUT_SECONDS}" "cache-lock-timeout-seconds"
  validate_positive_integer "${CACHE_INSTALL_LEASE_SECONDS}" "cache-install-lease-seconds"

  if ! mkdir -p "${CACHE_DIR}" 2>/dev/null; then
    warn "${CACHE_DIR} is not writable; skipping Rust toolchain cache save"
    {
      echo "RUST_TOOLCHAIN_NAME=${RUST_TOOLCHAIN_NAME}"
      echo "RUST_TOOLCHAIN_CACHEKEY=${RUST_TOOLCHAIN_CACHEKEY}"
    } >> "${GITHUB_ENV}"
    return 0
  fi
  if ! acquire_lock; then
    warn "timed out waiting for Rust toolchain cache lock; skipping cache save"
    {
      echo "RUST_TOOLCHAIN_NAME=${RUST_TOOLCHAIN_NAME}"
      echo "RUST_TOOLCHAIN_CACHEKEY=${RUST_TOOLCHAIN_CACHEKEY}"
    } >> "${GITHUB_ENV}"
    return 0
  fi

  if cache_valid "${BUNDLE_DIR}" "${CACHE_KEY}"; then
    remove_owned_install_claim
    release_lock
    {
      echo "RUST_TOOLCHAIN_NAME=${RUST_TOOLCHAIN_NAME}"
      echo "RUST_TOOLCHAIN_CACHEKEY=${RUST_TOOLCHAIN_CACHEKEY}"
    } >> "${GITHUB_ENV}"
    echo "Rust toolchain cache was populated by another job: ${CACHE_KEY}"
    return 0
  fi

  if [ -f "${INSTALL_CLAIM_PATH}" ] && ! claim_owned_by_current_job; then
    fail "Rust toolchain cache installation claim belongs to another job: ${CACHE_KEY}"
  fi
  if [ ! -f "${INSTALL_CLAIM_PATH}" ]; then
    write_install_claim
  fi

  local staging_dir

  staging_dir="$(mktemp -d "${CACHE_DIR}/.staging.XXXXXX")" \
    || fail "failed to create Rust toolchain cache staging directory"
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
  remove_owned_install_claim
  release_lock
  {
    echo "RUST_TOOLCHAIN_NAME=${RUST_TOOLCHAIN_NAME}"
    echo "RUST_TOOLCHAIN_CACHEKEY=${RUST_TOOLCHAIN_CACHEKEY}"
  } >> "${GITHUB_ENV}"
  echo "Rust toolchain cache populated: ${CACHE_KEY}"
}

cleanup() {
  prepare_paths

  if ! mkdir -p "${CACHE_DIR}" 2>/dev/null; then
    return 0
  fi
  if ! acquire_lock; then
    warn "timed out waiting for Rust toolchain cache cleanup lock: ${CACHE_KEY}"
    return 0
  fi
  remove_owned_install_claim
  release_lock
}

: "${RUST_TOOLCHAIN:?toolchain is required}"
: "${RUST_TARGETS:=}"
: "${RUST_TARGET:=}"
: "${RUST_COMPONENTS:=}"
: "${CACHE_LOCK_TIMEOUT_SECONDS:=1800}"
: "${CACHE_INSTALL_LEASE_SECONDS:=7200}"
: "${CACHE_LOCK_HEARTBEAT_SECONDS:=30}"
: "${CACHE_LOCK_STALE_SECONDS:=300}"
: "${CACHE_LOCK_POLL_SECONDS:=1}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
: "${GITHUB_JOB:?GITHUB_JOB is required}"
: "${GITHUB_RUN_ATTEMPT:?GITHUB_RUN_ATTEMPT is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

trap 'release_lock' EXIT

case "${1:-}" in
  restore) restore ;;
  save) save ;;
  cleanup) cleanup ;;
  *) fail "usage: $0 restore|save" ;;
esac
