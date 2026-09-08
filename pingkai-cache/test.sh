#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${SCRIPT_DIR}/action.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -Fq 'value: ${{ steps.cache.outputs.cache-hit }}' "${ACTION}" \
  || fail "cache-hit output is not forwarded from runs-on/cache"
grep -Fq 'id: cache' "${ACTION}" \
  || fail "nested cache step has no id for output forwarding"
grep -Fq 'AWS_ACCESS_KEY_ID: ${{ inputs.access-key-id }}' "${ACTION}" \
  || fail "access key is not scoped to the nested cache action"
grep -Fq 'AWS_SECRET_ACCESS_KEY: ${{ inputs.secret-access-key }}' "${ACTION}" \
  || fail "secret key is not scoped to the nested cache action"
if grep -Fq '>> "$GITHUB_ENV"' "${ACTION}"; then
  fail "cache configuration leaks credentials or backend settings to later job steps"
fi
grep -Fq 'bucket=${bucket}' "${ACTION}" \
  || fail "resolved bucket is not exported as a step output"
grep -Fq 'RUNS_ON_S3_BUCKET_CACHE: ${{ steps.backend.outputs.bucket }}' "${ACTION}" \
  || fail "nested cache action does not consume the resolved backend"
grep -Fq 'RUNS_ON_S3_FORCE_PATH_STYLE: ${{ steps.backend.outputs.path_style }}' "${ACTION}" \
  || fail "nested cache action does not consume the resolved path-style setting"
grep -Fq 'RUNS_ON_RUNNER_NAME: ""' "${ACTION}" \
  || fail "nested cache action does not clear instance-profile mode"
grep -Fq 'pingkai-cache clears it for the nested cache step' "${ACTION}" \
  || fail "instance-profile override is not reported"

echo "PASS: pingkai-cache"
