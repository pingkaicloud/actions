#!/bin/sh
# Check and repair local Gitleaks hooks without replacing unrelated hooks.
set -eu

VERSION=8.30.1
MODE=repair
REPO_ARG=.

usage() {
    printf '%s\n' 'Usage: setup.sh [--check] [--repo PATH]' >&2
}

die() {
    printf 'gitleaks-hooks: %s\n' "$*" >&2
    exit 1
}

info() {
    printf 'gitleaks-hooks: %s\n' "$*"
}

# Keep hook bodies inline so setup.sh also works when streamed to sh.
render_template() {
    case "$1" in
        pre-commit)
            cat <<'PRE_COMMIT_HOOK'
#!/bin/sh
# Managed by pingkaicloud/actions/gitleaks-hooks
set -eu

PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

if ! command -v gitleaks >/dev/null 2>&1; then
    echo "gitleaks is unavailable; run gitleaks-hooks/setup.sh" >&2
    exit 1
fi

gitleaks git --staged --redact --no-banner
PRE_COMMIT_HOOK
            ;;
        pre-push)
            cat <<'PRE_PUSH_HOOK'
#!/bin/sh
# Managed by pingkaicloud/actions/gitleaks-hooks
set -eu

PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

if ! command -v gitleaks >/dev/null 2>&1; then
    echo "gitleaks is unavailable; run gitleaks-hooks/setup.sh" >&2
    exit 1
fi

while read -r local_ref local_sha remote_ref remote_sha; do
    case "$local_sha" in
        0000000000000000000000000000000000000000|\
        0000000000000000000000000000000000000000000000000000000000000000)
            continue
            ;;
    esac

    tag_object=$local_sha
    tag_type=$(git cat-file -t "$tag_object") || exit 1
    while [ "$tag_type" = tag ]; do
        tag_data=$(git cat-file tag "$tag_object") || exit 1
        printf '%s\n' "$tag_data" | gitleaks stdin --redact --no-banner
        tag_object=$(printf '%s\n' "$tag_data" | sed -n '1s/^object //p')
        [ -n "$tag_object" ] || exit 1
        tag_type=$(git cat-file -t "$tag_object") || exit 1
    done

    case "$remote_sha" in
        0000000000000000000000000000000000000000|\
        0000000000000000000000000000000000000000000000000000000000000000)
            # For new refs, exclude history in locally cached remote-tracking refs.
            range="$local_sha --not --remotes=$1"
            ;;
        *)
            if ! git cat-file -e "$remote_sha^{commit}" 2>/dev/null; then
                echo "missing old tip for $remote_ref; fetch the remote and retry" >&2
                exit 1
            fi
            range="$remote_sha..$local_sha"
            ;;
    esac

    echo "gitleaks: scanning $remote_ref" >&2
    gitleaks git --redact --no-banner --log-opts="$range"
done
PRE_PUSH_HOOK
            ;;
        *)
            die "unknown hook template: $1"
            ;;
    esac
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check)
            MODE=check
            shift
            ;;
        --repo)
            [ "$#" -ge 2 ] || { usage; exit 2; }
            REPO_ARG=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            die "unknown argument: $1"
            ;;
    esac
done

REPO_ROOT=$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null) || die "not a Git working tree: $REPO_ARG"
[ "$(git -C "$REPO_ROOT" rev-parse --is-bare-repository)" = false ] || die "bare repositories are unsupported"
HOOKS_DIR=$REPO_ROOT/.githooks

PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

compatible_gitleaks() {
    candidate=$1
    help_text=$("$candidate" git --help 2>&1) || return 1
    case "$help_text" in *--staged*) ;; *) return 1 ;; esac
    case "$help_text" in *--log-opts*) ;; *) return 1 ;; esac
    case "$help_text" in *--redact*) ;; *) return 1 ;; esac
    case "$help_text" in *--no-banner*) ;; *) return 1 ;; esac
    "$candidate" stdin --help >/dev/null 2>&1 || return 1
}

find_gitleaks() {
    candidate=$(command -v gitleaks 2>/dev/null) || return 1
    compatible_gitleaks "$candidate" || return 1
    GITLEAKS_BIN=$candidate
}

asset_details() {
    os=$(uname -s)
    arch=$(uname -m)
    case "$os/$arch" in
        Darwin/arm64|Darwin/aarch64)
            platform=darwin_arm64
            expected_sha=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5
            ;;
        Darwin/x86_64|Darwin/amd64)
            platform=darwin_x64
            expected_sha=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709
            ;;
        Linux/aarch64|Linux/arm64)
            platform=linux_arm64
            expected_sha=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080
            ;;
        Linux/x86_64|Linux/amd64)
            platform=linux_x64
            expected_sha=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
            ;;
        *) die "unsupported OS/architecture: $os/$arch" ;;
    esac
    asset=gitleaks_${VERSION}_${platform}.tar.gz
}

download_asset() {
    url=$1
    destination=$2
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error --retry 3 \
            --connect-timeout 15 --max-time 300 --output "$destination" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget --quiet --tries=3 --timeout=30 --output-document="$destination" "$url"
    else
        die "install curl or wget to download Gitleaks"
    fi
}

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        die "install shasum or sha256sum to verify Gitleaks"
    fi
}

install_gitleaks() {
    asset_details
    command -v tar >/dev/null 2>&1 || die "tar is required to unpack Gitleaks"
    tmp_base=${TMPDIR:-/tmp}
    tmp_dir=$(mktemp -d "${tmp_base%/}/gitleaks-install.XXXXXX") || die "cannot create download directory"
    trap 'rm -f "$tmp_dir/archive" "$tmp_dir/gitleaks"; rmdir "$tmp_dir" 2>/dev/null || :' 0

    base=${GITLEAKS_DOWNLOAD_BASE:-https://github.com/gitleaks/gitleaks/releases/download/v${VERSION}}
    info "downloading official Gitleaks $VERSION asset $asset"
    download_asset "${base%/}/$asset" "$tmp_dir/archive" || die "download failed; check HTTPS_PROXY or GITLEAKS_DOWNLOAD_BASE"
    actual_sha=$(sha256_file "$tmp_dir/archive")
    [ "$actual_sha" = "$expected_sha" ] || die "SHA-256 mismatch for $asset"

    tar -xzf "$tmp_dir/archive" -C "$tmp_dir" gitleaks || die "invalid Gitleaks archive"
    [ -f "$tmp_dir/gitleaks" ] || die "Gitleaks binary is absent from archive"
    chmod 755 "$tmp_dir/gitleaks"
    [ "$("$tmp_dir/gitleaks" version)" = "$VERSION" ] || die "downloaded Gitleaks has an unexpected version"

    install_dir=$HOME/.local/bin
    mkdir -p "$install_dir"
    target=$install_dir/gitleaks
    [ ! -L "$target" ] || die "refusing to replace symlink: $target"
    if [ -e "$target" ]; then
        backup=$target.before-${VERSION}-$(date -u +%Y%m%dT%H%M%SZ)-$$
        cp -p "$target" "$backup" || die "cannot back up $target"
        info "backed up previous binary to $backup"
    fi
    pending=$install_dir/.gitleaks.new.$$
    cp "$tmp_dir/gitleaks" "$pending" || die "cannot copy Gitleaks to $install_dir"
    chmod 755 "$pending"
    mv -f "$pending" "$target" || die "cannot install Gitleaks at $target"
    info "installed Gitleaks $VERSION at $target"
}

absolute_git_path() {
    path=$(git -C "$REPO_ROOT" rev-parse --git-path "$1")
    case "$path" in
        /*) printf '%s\n' "$path" ;;
        *) printf '%s/%s\n' "$REPO_ROOT" "$path" ;;
    esac
}

preflight_hooks() {
    [ ! -L "$HOOKS_DIR" ] || die "refusing symlinked hooks directory: $HOOKS_DIR"
    [ ! -e "$HOOKS_DIR" ] || [ -d "$HOOKS_DIR" ] || die "hooks path is not a directory: $HOOKS_DIR"

    current=$(git -C "$REPO_ROOT" config --get core.hooksPath || :)
    case "$current" in
        ''|.githooks|"$HOOKS_DIR") ;;
        *) die "core.hooksPath is already '$current'; merge hooks manually" ;;
    esac

    if [ -z "$current" ]; then
        default_dir=$(absolute_git_path hooks)
        for hook in "$default_dir"/*; do
            [ -e "$hook" ] || [ -L "$hook" ] || continue
            [ -f "$hook" ] || [ -L "$hook" ] || continue
            case "$hook" in *.sample) continue ;; esac
            name=${hook##*/}
            if [ -x "$hook" ] || [ -L "$hook" ] || [ "$name" = pre-commit ] || [ "$name" = pre-push ]; then
                die "existing $hook would be shadowed; merge hooks manually"
            fi
        done
    fi

    for name in pre-commit pre-push; do
        target=$HOOKS_DIR/$name
        [ ! -L "$target" ] || die "refusing symlinked hook: $target"
        if [ -e "$target" ]; then
            [ -f "$target" ] || die "hook is not a regular file: $target"
            if ! render_template "$name" | cmp -s - "$target"; then
                die "hook differs from managed template: $target; merge it manually"
            fi
        fi
    done
}

check_hooks() {
    [ -d "$HOOKS_DIR" ] || die "missing $HOOKS_DIR"
    for name in pre-commit pre-push; do
        target=$HOOKS_DIR/$name
        [ -f "$target" ] && [ -x "$target" ] || die "missing or non-executable hook: $target"
        render_template "$name" | cmp -s - "$target" || die "hook differs from managed template: $target"
        sh -n "$target" || die "shell syntax error: $target"
    done
    current=$(git -C "$REPO_ROOT" config --get core.hooksPath || :)
    case "$current" in
        .githooks|"$HOOKS_DIR") ;;
        *) die "core.hooksPath does not point to .githooks" ;;
    esac
    info "Gitleaks and both hooks are ready in $REPO_ROOT"
}

repair_hook() {
    name=$1
    target=$HOOKS_DIR/$name
    if [ -f "$target" ] && render_template "$name" | cmp -s - "$target"; then
        if [ ! -x "$target" ]; then
            chmod 755 "$target"
            info "restored executable bit on $target"
        fi
        return
    fi

    [ ! -e "$target" ] && [ ! -L "$target" ] || die "hook changed during repair: $target"

    pending=$(mktemp "$HOOKS_DIR/.$name.XXXXXX") || die "cannot stage $name"
    if ! render_template "$name" > "$pending" || ! chmod 755 "$pending" || ! mv -f "$pending" "$target"; then
        rm -f "$pending"
        die "cannot install $target"
    fi
    info "installed $target"
}

preflight_hooks
if find_gitleaks; then
    info "using $GITLEAKS_BIN ($("$GITLEAKS_BIN" version))"
elif [ "$MODE" = check ]; then
    die "Gitleaks is missing or incompatible; run setup.sh without --check"
else
    install_gitleaks
    find_gitleaks || die "installed Gitleaks is not usable"
fi

if [ "$MODE" = check ]; then
    check_hooks
    exit 0
fi

mkdir -p "$HOOKS_DIR"
repair_hook pre-commit
repair_hook pre-push
if [ "$(git -C "$REPO_ROOT" config --local --get core.hooksPath || :)" != .githooks ]; then
    git -C "$REPO_ROOT" config --local core.hooksPath .githooks
    info "configured repository-local core.hooksPath=.githooks"
fi
check_hooks
