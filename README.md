# pingkaicloud/actions

Org-wide shared GitHub Actions. Public so any org repo can reference
them with plain `uses:` (cross-repo private actions cannot be resolved
with the job token).

## Actions

| Action | Purpose |
| --- | --- |
| [`nas-cache`](nas-cache/) | Per-repo Go/npm/pip/Pulumi/Cargo/Lindera caches on the shared runner NAS (`${RUNNER_CACHE}/<org>/<repo>/...`) |
| [`pingkai-cache`](pingkai-cache/) | OSS-backed `actions/cache` drop-in (wraps pinned `runs-on/cache`) for CN runner pools; credentials via org secrets inputs, backend via `PINGKAI_CACHE_*` env vars, GC via bucket lifecycle |
| [`setup-pulumi`](setup-pulumi/) | Reuse/install the Pulumi CLI in the shared runner tool cache and prepend it to `GITHUB_PATH` so `pulumi/actions` skips its reinstall |
| [`setup-terraform`](setup-terraform/) | Reuse Terraform CLI from the shared runner tool cache; install with `hashicorp/setup-terraform@v3` skips its reinstall |

## Usage

```yaml
- uses: pingkaicloud/actions/nas-cache@v1
  with:
    go-cache-key: go-custom-key
    npm-cache-key: npm-custom-key
    pip-cache-key: pip-custom-key
    pulumi-cache-key: pulumi-custom-key
    enable-cargo-cache: 'true'
    cargo-cache-key: cargo-custom-key
    enable-lindera-cache: 'true'
    lindera-cache-key: lindera-0.43.1
```

The `pulumi-cache-key` input symlinks `~/.pulumi/plugins` at the resolved
cache directory (`<repo>/pulumi/default` or `keys/<key>`), so downloaded
resource plugins persist on the NAS instead of refetching ~475MB per fresh
runner pod. `PULUMI_HOME` itself stays pod-local: concurrent jobs of the
same repository log in to different Pulumi backends, and a shared
credentials.json would let them clobber each other's current backend.
Plugin downloads are guarded by Pulumi's per-plugin lock files; the
NFSv4.0 PV provides the cross-client file locks they rely on.

All cache-key inputs are optional. Without an explicit key, each tool uses its
repository-scoped fixed `default` directory. Explicit keys use separate
`keys/<key>` directories and do not support restore prefixes or copying from
other keys.

The resulting paths are `<repo>/<tool>/default` without a key and
`<repo>/<tool>/keys/<key>` with an explicit key.

Cargo caching is opt-in. It sets a job-local `CARGO_HOME`, symlinks the Cargo
registry, git DB, and Cargo's two cache lock files into the NAS cache, and adds
the job-local `CARGO_HOME/bin` to `GITHUB_PATH`. Cargo git checkouts,
configuration, credentials, and installed binaries are not shared between jobs.
This keeps workflows that modify a fetched checkout isolated while still
reusing large dependency downloads. Lindera caching is also opt-in and exports
`LINDERA_CACHE`, `LINDERA_CACHE_LOCK`, and `LINDERA_CACHE_READY` for a
repository/key-scoped NAS directory. On a cold cache, callers must hold the lock
with `flock -x`, populate the cache, then create the ready file while still
holding the lock. Check the ready file both before and after acquiring the lock.
Lindera's build script uses fixed temporary paths and is not safe for concurrent
cold starts. Include all manifests that affect Lindera features in the cache key
so a ready marker cannot hide a changed dictionary set.

The `nas-cache` action requires the runner scale set to export `RUNNER_CACHE`
(NAS mount).
The NAS mount must provide cross-client file locking because Go coordinates
concurrent module downloads with file locks and Cargo uses two shared package
cache lock files. Go, npm, and pip caches are isolated by repository. Explicit
cache keys provide additional isolation; keys are retained until a separate,
active-runner-aware cleanup job removes them.

```yaml
- uses: pingkaicloud/actions/setup-pulumi@v1
  with:
    pulumi-version: '3.228.0'
```

`setup-pulumi` replaces the standalone "Install Pulumi CLI" step. It checks
`$RUNNER_TOOL_CACHE/pulumi/<version>/<arch>` first: on a hit the directory is
prepended to `GITHUB_PATH` and the embedded install-only `pulumi/actions@v6`
step logs "already installed ... Skipping download" without touching
api.pulumi.com; on a miss the embedded step installs as usual and its
tool-cache registration warms the cache for later jobs. Either way later
`pulumi/actions` preview/up steps in the job pin the same version and also
skip their reinstall.

```yaml
- uses: pingkaicloud/actions/setup-terraform@v1
  with:
    terraform_version: '1.9.8'
```

`setup-terraform` accepts `terraform_version` (required, an exact release
version such as `1.9.8`, optionally prefixed with `v`) and `terraform_wrapper`
(default `true`).

It checks `$RUNNER_TOOL_CACHE/terraform/<version>/<arch>/wrapper-<true|false>`
and runs `terraform version`. On a match it reuses the cached installation
and skips `hashicorp/setup-terraform@v3`. On a miss it calls that action with
both inputs to install into the runner's default temporary directory, then
copies the CLI and optional wrapper to the fixed cache path for later jobs.
In both cases, the fixed cache directory is added to `GITHUB_PATH` for
subsequent steps. When the wrapper is enabled, `TERRAFORM_CLI_PATH` is also
set to that directory so it can find the cached binary. The cache root
defaults to `/opt/hostedtoolcache`.

## Conventions

- One directory per action: `<name>/action.yml`.
- Tag `v1`, `v2`, ... per action directory as major versions; move the
  tag forward on breaking-change-free updates.
- Canonical copies live here; consumer repos must NOT vendor them.
