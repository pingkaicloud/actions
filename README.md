# pingkaicloud/actions

Org-wide shared GitHub Actions. Public so any org repo can reference
them with plain `uses:` (cross-repo private actions cannot be resolved
with the job token).

## Actions

| Action | Purpose |
| --- | --- |
| [`nas-cache`](nas-cache/) | Per-repo Go/npm/pip caches on the shared runner NAS (`${RUNNER_CACHE}/<org>/<repo>/...`) |

## Usage

```yaml
- uses: pingkaicloud/actions/nas-cache@v1
  with:
    go-cache-key: go-custom-key
    npm-cache-key: npm-custom-key
    pip-cache-key: pip-custom-key
```

Requires the runner scale set to export `RUNNER_CACHE` (NAS mount).
The NAS mount must provide cross-client file locking because Go coordinates
concurrent module downloads with file locks. Go, npm, and pip caches are
isolated by repository and their respective cache keys; keys are retained
until a separate, active-runner-aware cleanup job removes them.

All cache-key inputs are optional. Without explicit keys, the action hashes
the corresponding dependency files (`go.mod` and `go.sum` for Go) and uses a
stable `*-no-lockfile` key when no matching files exist. Cache keys do not
support restore prefixes or copying from other keys.

## Conventions

- One directory per action: `<name>/action.yml`.
- Tag `v1`, `v2`, ... per action directory as major versions; move the
  tag forward on breaking-change-free updates.
- Canonical copies live here; consumer repos must NOT vendor them.
