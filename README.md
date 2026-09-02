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
```

Requires the runner scale set to export `RUNNER_CACHE` (NAS mount).
The NAS mount must provide cross-client file locking because Go coordinates
concurrent module downloads with file locks. npm caches are isolated by
repository and `npm-cache-key`; keys are retained until a separate,
active-runner-aware cleanup job removes them.

## Conventions

- One directory per action: `<name>/action.yml`.
- Tag `v1`, `v2`, ... per action directory as major versions; move the
  tag forward on breaking-change-free updates.
- Canonical copies live here; consumer repos must NOT vendor them.
