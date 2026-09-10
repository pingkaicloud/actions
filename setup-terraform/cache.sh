#!/usr/bin/env bash
set -euo pipefail

version="${TERRAFORM_VERSION_INPUT#v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "::error::terraform-version must be an exact release version (for example 1.9.8)"
  exit 1
fi
case "$TERRAFORM_WRAPPER" in
  true|false) ;;
  *) echo "::error::terraform-wrapper must be true or false"; exit 1 ;;
esac
case "$(uname -s)" in
  Linux) platform=linux ;;
  Darwin) platform=darwin ;;
  *) echo "::error::unsupported operating system $(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64) arch=x64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo "::error::unsupported architecture $(uname -m)"; exit 1 ;;
esac
cache_root="${RUNNER_TOOL_CACHE:-/opt/hostedtoolcache}"
case "$cache_root" in
  /*) ;;
  *) echo "::error::RUNNER_TOOL_CACHE must be an absolute path"; exit 1 ;;
esac
case "$cache_root" in
  *$'\n'*|*$'\r'*) echo "::error::RUNNER_TOOL_CACHE must not contain newlines"; exit 1 ;;
esac
# Upstream's wrapper passes the binary path as an unquoted command string.
if [ "$TERRAFORM_WRAPPER" = true ] && [[ "$cache_root" =~ [[:space:]] ]]; then
  echo "::error::terraform-wrapper=true requires RUNNER_TOOL_CACHE without whitespace (upstream wrapper limitation)"
  exit 1
fi
dest="$cache_root/terraform/$version/$platform/$arch/wrapper-$TERRAFORM_WRAPPER"
binary=terraform
if [ "$TERRAFORM_WRAPPER" = true ]; then binary=terraform-bin; fi

valid_install() {
  local reported
  [ -x "$1/terraform" ] && [ -x "$1/$binary" ] || return 1
  reported="$(CHECKPOINT_DISABLE=1 "$1/$binary" version 2>/dev/null)" || return 1
  [ "${reported%%$'\n'*}" = "Terraform v$version" ]
}

activate() {
  echo "$dest" >> "$GITHUB_PATH"
  if [ "$TERRAFORM_WRAPPER" = true ]; then
    echo "TERRAFORM_CLI_PATH=$dest" >> "$GITHUB_ENV"
  fi
}

case "${1:?expected restore or save}" in
  restore)
    echo "version=$version" >> "$GITHUB_OUTPUT"
    if [ -f "$dest/.complete" ] && valid_install "$dest"; then
      activate
      echo "cache-hit=true" >> "$GITHUB_OUTPUT"
      echo "Reusing cached Terraform v$version at $dest"
    else
      echo "cache-hit=false" >> "$GITHUB_OUTPUT"
      echo "Terraform v$version not found in tool cache ($dest); installing with hashicorp/setup-terraform"
    fi
    ;;
  save)
    source_dir="$(dirname "$(command -v terraform)")"
    if ! valid_install "$source_dir"; then
      echo "::error::upstream Terraform installation failed version validation"
      exit 1
    fi
    mkdir -p "$dest"
    # Publish complete files with atomic renames on the cache filesystem.
    # Concurrent writers install the same version and wrapper mode. Existing
    # readers keep their open executable inode while each file is replaced.
    pending=""
    trap 'if [ -n "$pending" ]; then rm -f "$pending"; fi' EXIT
    files=(terraform)
    if [ "$TERRAFORM_WRAPPER" = true ]; then files+=(terraform-bin); fi
    for file in "${files[@]}"; do
      pending="$(mktemp "$dest/.${file}.XXXXXXXXXX")"
      cp "$source_dir/$file" "$pending"
      chmod 755 "$pending"
      mv -f "$pending" "$dest/$file"
      pending=""
    done
    touch "$dest/.complete"
    activate
    echo "Cached Terraform v$version at $dest"
    ;;
  *) echo "::error::expected restore or save"; exit 1 ;;
esac
