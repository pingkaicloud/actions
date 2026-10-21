#!/bin/sh
# Isolated regression tests; no network or real secrets are used.
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
command -v curl >/dev/null 2>&1 || { printf '%s\n' 'curl is required for streaming tests' >&2; exit 1; }
tmp_base=${TEST_TMP_ROOT:-${TMPDIR:-/tmp}}
test_dir=$(mktemp -d "${tmp_base%/}/gitleaks-hooks-test.XXXXXX")
trap 'rm -rf "$test_dir"' 0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

repo=$test_dir/repo
remote=$test_dir/remote.git
mkdir -p "$repo"
git init --bare -q "$remote"
git -C "$repo" init -q -b main
git -C "$repo" config user.name 'Gitleaks Hook Test'
git -C "$repo" config user.email 'gitleaks-hook-test@example.invalid'
git -C "$repo" remote add origin "$remote"

printf 'baseline\n' > "$repo/readme.txt"
cat > "$repo/.gitleaks.toml" <<'EOF'
title = "Synthetic hook test"

[extend]
useDefault = true

[[rules]]
id = "synthetic-secret"
description = "Matches only this test's fake key"
regex = '''TEST_SECRET_[A-Z0-9]{8}'''
secretGroup = 0
EOF
git -C "$repo" add readme.txt .gitleaks.toml
git -C "$repo" commit -q -m 'test: add baseline'
git -C "$repo" push -q origin HEAD:refs/heads/main
base=$(git -C "$repo" rev-parse HEAD)

stream_repo=$test_dir/stream-repo
git init -q -b main "$stream_repo"
curl -fsSL "file://$SCRIPT_DIR/setup.sh" | \
    (cd "$stream_repo" && sh -s --) > "$test_dir/stream-setup.log" 2>&1 || fail 'fresh streamed setup failed'
cmp -s "$SCRIPT_DIR/templates/pre-commit" "$stream_repo/.githooks/pre-commit" || fail 'streamed setup installed the wrong pre-commit template'
cmp -s "$SCRIPT_DIR/templates/pre-push" "$stream_repo/.githooks/pre-push" || fail 'streamed setup installed the wrong pre-push template'
[ "$(git -C "$stream_repo" config --local --get core.hooksPath)" = .githooks ] || fail 'streamed setup did not configure hooksPath'

printf '#!/bin/sh\nexit 0\n' > "$repo/.git/hooks/commit-msg"
chmod 755 "$repo/.git/hooks/commit-msg"
if "$SCRIPT_DIR/setup.sh" --repo "$repo" > "$test_dir/default-hook-conflict.log" 2>&1; then
    fail 'setup shadowed an existing commit-msg hook'
fi
grep -q 'would be shadowed' "$test_dir/default-hook-conflict.log" || fail 'default hook conflict was not reported'
[ ! -e "$repo/.githooks" ] || fail 'setup changed hooks before reporting a default hook conflict'
rm "$repo/.git/hooks/commit-msg"
mkdir -p "$repo/.git/hooks/shared"

"$SCRIPT_DIR/setup.sh" --repo "$repo" > "$test_dir/setup.log" 2>&1 || fail 'initial setup failed'
"$SCRIPT_DIR/setup.sh" --check --repo "$repo" > "$test_dir/check.log" 2>&1 || fail 'read-only check failed'
curl -fsSL "file://$SCRIPT_DIR/setup.sh" | \
    (cd "$test_dir" && sh -s -- --check --repo "$repo") > "$test_dir/stream-check.log" 2>&1 || fail 'streamed check failed'
"$SCRIPT_DIR/setup.sh" --repo "$repo" > "$test_dir/repeat.log" 2>&1 || fail 'idempotent setup failed'
cmp -s "$SCRIPT_DIR/templates/pre-commit" "$repo/.githooks/pre-commit" || fail 'wrong pre-commit template'
cmp -s "$SCRIPT_DIR/templates/pre-push" "$repo/.githooks/pre-push" || fail 'wrong pre-push template'

chmod -x "$repo/.githooks/pre-commit"
if "$SCRIPT_DIR/setup.sh" --check --repo "$repo" > "$test_dir/broken.log" 2>&1; then
    fail 'check accepted a non-executable hook'
fi
"$SCRIPT_DIR/setup.sh" --repo "$repo" > "$test_dir/repair.log" 2>&1 || fail 'executable-bit repair failed'
[ -x "$repo/.githooks/pre-commit" ] || fail 'executable bit was not restored'

rm "$repo/.githooks/pre-push"
curl -fsSL "file://$SCRIPT_DIR/setup.sh" | \
    (cd "$repo" && sh -s --) > "$test_dir/missing.log" 2>&1 || fail 'streamed missing hook repair failed'
[ -x "$repo/.githooks/pre-push" ] || fail 'missing pre-push hook was not restored'
cmp -s "$SCRIPT_DIR/templates/pre-push" "$repo/.githooks/pre-push" || fail 'streamed repair installed the wrong pre-push template'

git -C "$repo" config --local --unset core.hooksPath
"$SCRIPT_DIR/setup.sh" --repo "$repo" > "$test_dir/config.log" 2>&1 || fail 'core.hooksPath repair failed'
[ "$(git -C "$repo" config --local --get core.hooksPath)" = .githooks ] || fail 'core.hooksPath was not restored'

printf '#!/bin/sh\n# Managed by pingkaicloud/actions/gitleaks-hooks\nexit 0\n' > "$repo/.githooks/pre-commit"
if "$SCRIPT_DIR/setup.sh" --repo "$repo" > "$test_dir/managed-conflict.log" 2>&1; then
    fail 'setup overwrote a modified managed hook'
fi
grep -q 'hook differs' "$test_dir/managed-conflict.log" || fail 'modified managed hook conflict was not reported'
grep -q '^exit 0$' "$repo/.githooks/pre-commit" || fail 'modified managed hook content was changed'
cp "$SCRIPT_DIR/templates/pre-commit" "$repo/.githooks/pre-commit"

printf 'token = "TEST_SECRET_ABCDEF12"\n' > "$repo/leak.txt"
git -C "$repo" add leak.txt
if (cd "$repo" && .githooks/pre-commit) > "$test_dir/precommit.log" 2>&1; then
    fail 'pre-commit missed a staged synthetic secret'
fi
grep -q 'leaks found' "$test_dir/precommit.log" || fail 'pre-commit failed for a reason other than a leak'
if git -C "$repo" commit -m 'test: blocked synthetic secret' > "$test_dir/git-commit.log" 2>&1; then
    fail 'git commit bypassed the installed pre-commit hook'
fi
grep -q 'leaks found' "$test_dir/git-commit.log" || fail 'git commit failed for a reason other than a leak'

# Construct a two-commit history without sending either commit to the bare remote.
git -C "$repo" -c core.hooksPath=/dev/null commit -q -m 'test: add synthetic secret'
git -C "$repo" rm -q leak.txt
git -C "$repo" -c core.hooksPath=/dev/null commit -q -m 'test: remove synthetic secret'
tip=$(git -C "$repo" rev-parse HEAD)
if printf 'refs/heads/main %s refs/heads/main %s\n' "$tip" "$base" | \
    (cd "$repo" && .githooks/pre-push origin "$remote") > "$test_dir/prepush.log" 2>&1; then
    fail 'pre-push missed a secret in an earlier outgoing commit'
fi
grep -q 'leaks found' "$test_dir/prepush.log" || fail 'pre-push failed for a reason other than a leak'
if git -C "$repo" push origin HEAD:refs/heads/main > "$test_dir/git-push.log" 2>&1; then
    fail 'git push bypassed the installed pre-push hook'
fi
grep -q 'leaks found' "$test_dir/git-push.log" || fail 'git push failed for a reason other than a leak'
[ "$(git --git-dir="$remote" rev-parse refs/heads/main)" = "$base" ] || fail 'blocked push changed the remote'

git -C "$repo" tag -a clean-tag "$base" -m 'Clean release tag'
clean_tag=$(git -C "$repo" rev-parse refs/tags/clean-tag)
printf 'refs/tags/clean-tag %s refs/tags/clean-tag %040d\n' "$clean_tag" 0 | \
    (cd "$repo" && .githooks/pre-push origin "$remote") > "$test_dir/clean-tag.log" 2>&1 || fail 'pre-push rejected a clean annotated tag'

git -C "$repo" tag -a leak-tag "$base" -m 'TEST_SECRET_TAGTOKN1'
leak_tag=$(git -C "$repo" rev-parse refs/tags/leak-tag)
if printf 'refs/tags/leak-tag %s refs/tags/leak-tag %040d\n' "$leak_tag" 0 | \
    (cd "$repo" && .githooks/pre-push origin "$remote") > "$test_dir/leak-tag.log" 2>&1; then
    fail 'pre-push missed a secret in an annotated tag message'
fi
grep -q 'leaks found' "$test_dir/leak-tag.log" || fail 'tag pre-push failed for a reason other than a leak'
if grep -q 'TEST_SECRET_TAGTOKN1' "$test_dir/leak-tag.log"; then
    fail 'pre-push printed the annotated tag secret'
fi

git -C "$repo" tag -a nested-tag refs/tags/leak-tag -m 'Clean outer tag' 2> "$test_dir/nested-tag-create.log"
nested_tag=$(git -C "$repo" rev-parse refs/tags/nested-tag)
if printf 'refs/tags/nested-tag %s refs/tags/nested-tag %040d\n' "$nested_tag" 0 | \
    (cd "$repo" && .githooks/pre-push origin "$remote") > "$test_dir/nested-tag.log" 2>&1; then
    fail 'pre-push missed a secret in a nested annotated tag'
fi
grep -q 'leaks found' "$test_dir/nested-tag.log" || fail 'nested tag pre-push failed for a reason other than a leak'

if [ -n "${TEST_RELEASE_DIR:-}" ]; then
    test_home=$test_dir/home
    mkdir -p "$test_home/.local/bin"
    printf '#!/bin/sh\nexit 1\n' > "$test_home/.local/bin/gitleaks"
    chmod 755 "$test_home/.local/bin/gitleaks"
    if ! curl -fsSL "file://$SCRIPT_DIR/setup.sh" | \
        HOME="$test_home" GITLEAKS_DOWNLOAD_BASE="file://$TEST_RELEASE_DIR" \
        sh -s -- --repo "$repo" > "$test_dir/install.log" 2>&1; then
        fail 'streamed verified release installation failed'
    fi
    [ "$("$test_home/.local/bin/gitleaks" version)" = 8.30.1 ] || fail 'installed binary has the wrong version'
    find "$test_home/.local/bin" -type f -name 'gitleaks.before-*' | grep -q . || fail 'prior binary was not backed up'
fi

printf '#!/bin/sh\nexit 0\n' > "$repo/.githooks/pre-commit"
if "$SCRIPT_DIR/setup.sh" --repo "$repo" > "$test_dir/conflict.log" 2>&1; then
    fail 'setup overwrote an unmanaged hook'
fi
grep -q 'hook differs' "$test_dir/conflict.log" || fail 'unmanaged hook conflict was not reported'
grep -q '^exit 0$' "$repo/.githooks/pre-commit" || fail 'unmanaged hook content was changed'

printf '%s\n' 'PASS: local/streamed setup, repair, hook conflicts, commit/push integration, history and tag scans'
