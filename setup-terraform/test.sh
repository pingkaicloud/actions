#!/usr/bin/env bash
set -euo pipefail
ACTION_PATH="$(cd "$(dirname "$0")" && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export RUNNER_TOOL_CACHE="$test_root/cache root"
export GITHUB_PATH="$test_root/path" GITHUB_ENV="$test_root/env" GITHUB_OUTPUT="$test_root/output"
export TERRAFORM_VERSION_INPUT=v1.9.8 TERRAFORM_WRAPPER=false
mkdir -p "$test_root/upstream"
cat > "$test_root/upstream/terraform" <<'CLI'
#!/usr/bin/env bash
printf 'Terraform v1.9.8\non test_platform\n'
CLI
chmod +x "$test_root/upstream/terraform"
export PATH="$test_root/upstream:$PATH"
reset_outputs() { : > "$GITHUB_PATH"; : > "$GITHUB_ENV"; : > "$GITHUB_OUTPUT"; }
reset_outputs
bash "$ACTION_PATH/cache.sh" restore
 grep -qx 'cache-hit=false' "$GITHUB_OUTPUT"
bash "$ACTION_PATH/cache.sh" save
cached="$(tail -n 1 "$GITHUB_PATH")"
[ -x "$cached/terraform" ]
[ "$("$cached/terraform" version | head -n 1)" = 'Terraform v1.9.8' ]
reset_outputs
bash "$ACTION_PATH/cache.sh" restore
 grep -qx 'cache-hit=true' "$GITHUB_OUTPUT"
[ "$(cat "$GITHUB_PATH")" = "$cached" ]
[ ! -s "$GITHUB_ENV" ]
# An interrupted write without a completion marker must never be a hit.
rm "$cached/.complete"
reset_outputs
bash "$ACTION_PATH/cache.sh" restore
 grep -qx 'cache-hit=false' "$GITHUB_OUTPUT"
# Concurrent cold writers publish complete executables into the fixed path.
bash "$ACTION_PATH/cache.sh" save &
writer=$!
bash "$ACTION_PATH/cache.sh" save
wait "$writer"
reset_outputs
bash "$ACTION_PATH/cache.sh" restore
 grep -qx 'cache-hit=true' "$GITHUB_OUTPUT"
# Wrapper mode uses its own cache and restores the binary lookup environment.
export TERRAFORM_WRAPPER=true
if bash "$ACTION_PATH/cache.sh" restore; then exit 1; fi
export RUNNER_TOOL_CACHE="$test_root/cache"
mv "$test_root/upstream/terraform" "$test_root/upstream/terraform-bin"
cat > "$test_root/upstream/terraform" <<'WRAPPER'
#!/usr/bin/env bash
exec "$TERRAFORM_CLI_PATH/terraform-bin" "$@"
WRAPPER
chmod +x "$test_root/upstream/terraform"
reset_outputs
bash "$ACTION_PATH/cache.sh" restore
 grep -qx 'cache-hit=false' "$GITHUB_OUTPUT"
bash "$ACTION_PATH/cache.sh" save
reset_outputs
bash "$ACTION_PATH/cache.sh" restore
 grep -qx 'cache-hit=true' "$GITHUB_OUTPUT"
wrapped_cache="$(cat "$GITHUB_PATH")"
[ "$wrapped_cache" != "$cached" ]
[ "$(cat "$GITHUB_ENV")" = "TERRAFORM_CLI_PATH=$wrapped_cache" ]
[ "$(TERRAFORM_CLI_PATH="$wrapped_cache" "$wrapped_cache/terraform" version | head -n 1)" = 'Terraform v1.9.8' ]
# Reject corrupted and different-version entries.
printf '#!/bin/sh\necho "Terraform v0.0.0"\n' > "$wrapped_cache/terraform-bin"
reset_outputs
bash "$ACTION_PATH/cache.sh" restore
 grep -qx 'cache-hit=false' "$GITHUB_OUTPUT"
for invalid in latest '../1.9.8' '1.9'; do
  if TERRAFORM_VERSION_INPUT="$invalid" bash "$ACTION_PATH/cache.sh" restore; then exit 1; fi
done
if RUNNER_TOOL_CACHE=relative bash "$ACTION_PATH/cache.sh" restore; then exit 1; fi
if RUNNER_TOOL_CACHE=$'/tmp/cache\nbad' bash "$ACTION_PATH/cache.sh" restore; then exit 1; fi
 echo 'PASS: cache miss/save/hit, concurrent writers, wrapper isolation and activation, incomplete/corrupt cache, invalid inputs'
