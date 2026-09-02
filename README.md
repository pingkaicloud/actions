# pingkaicloud/actions

Org-wide shared GitHub Actions. Public so any org repo can reference
them with plain `uses:` (cross-repo private actions cannot be resolved
with the job token).

## Actions

| Action | Purpose |
| --- | --- |
| [`nas-cache`](nas-cache/) | Per-repo go/npm/pip caches on the shared runner NAS (`${RUNNER_CACHE}/<org>/<repo>/...`) |

## Usage

```yaml
- uses: pingkaicloud/actions/nas-cache@v1
```

Requires the runner scale set to export `RUNNER_CACHE` (NAS mount).

## Conventions

- One directory per action: `<name>/action.yml`.
- Tag `v1`, `v2`, ... per action directory as major versions; move the
  tag forward on breaking-change-free updates.
- Canonical copies live here; consumer repos must NOT vendor them.
