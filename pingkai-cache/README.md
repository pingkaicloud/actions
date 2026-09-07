# pingkai-cache

OSS-backed GitHub Actions cache for the CN self-hosted runner pools. It is a
thin wrapper around the pinned [`runs-on/cache`](https://github.com/runs-on/cache)
fork (MIT, drop-in for `actions/cache`) with an Aliyun OSS bucket as the
backend, keeping the `path` / `key` / `restore-keys` semantics of
`actions/cache`.

## Why

- `actions/cache` stores entries in GitHub's cache service; the data plane is
  cross-border from CN runners and slow.
- Direct NAS mounts have concurrency hazards (half-written entries under
  concurrent cold starts, NFS locking gaps) and no service-side GC.
- An object-storage backend restores transfer semantics: saves are atomic
  object PUTs, restores are read-only downloads, and GC is a bucket lifecycle
  rule. No shared mutable directory is involved.

## Usage

With runner-level injection of the backend vars (recommended, no `env:`
block needed in workflows):

```yaml
- uses: pingkaicloud/actions/pingkai-cache@v1
  with:
    # credentials: org-level GitHub secrets only, never env
    access-key-id: ${{ secrets.PINGKAI_CACHE_ACCESS_KEY_ID }}
    secret-access-key: ${{ secrets.PINGKAI_CACHE_SECRET_ACCESS_KEY }}
    # actions/cache-compatible inputs
    path: |
      ~/.npm
      node_modules
    key: npm-${{ runner.os }}-${{ hashFiles('**/package-lock.json') }}
    restore-keys: |
      npm-${{ runner.os }}-
```

Without runner injection, map the org variables once per workflow instead:

```yaml
env:
  PINGKAI_CACHE_BUCKET: ${{ vars.PINGKAI_CACHE_BUCKET }}
  PINGKAI_CACHE_ENDPOINT: ${{ vars.PINGKAI_CACHE_ENDPOINT }}
  PINGKAI_CACHE_REGION: ${{ vars.PINGKAI_CACHE_REGION }}
```

Save happens in the action's post step (same as `actions/cache`); a restore
miss does not fail the job.

## Configuration

Credentials and backend parameters are deliberately split:

- **Credentials are inputs** sourced from **org-level GitHub secrets**.
  The `secrets` context is not available inside composite actions (GitHub
  platform restriction), so callers must pass them explicitly in the
  `with:` block — this cannot be automated away. Secret values are masked
  in job logs automatically. Credentials must never be provided via org
  variables, runner env, or any other plaintext environment.
- **Backend parameters are environment variables** (non-secret). The
  action reads them from the job env, so either provisioning path below
  works and callers write no `env:` block:
  - **Runner-level injection (recommended)**: set the vars in the runner
    scale-set values. Each pool can then point at its own regional backend
    (Shanghai ACK → OSS internal endpoint, TKE pools → COS), and workflows
    are region-agnostic.
  - **Org variables + workflow `env:` block**: the GitHub-native path when
    runner config must stay untouched — map `vars.PINGKAI_CACHE_*` in a
    workflow-level `env:` block as shown in the usage example.

| Input | Required | Notes |
| --- | --- | --- |
| `access-key-id` | yes | pass `secrets.PINGKAI_CACHE_ACCESS_KEY_ID` |
| `secret-access-key` | yes | pass `secrets.PINGKAI_CACHE_SECRET_ACCESS_KEY` |

| Variable | Required | Default / example | Notes |
| --- | --- | --- | --- |
| `PINGKAI_CACHE_BUCKET` | yes | `pingkai-ci-cache` | dedicated cache bucket |
| `PINGKAI_CACHE_ENDPOINT` | yes | `https://oss-cn-shanghai-internal.aliyuncs.com` | internal endpoint for ACK Shanghai runners; public endpoint otherwise |
| `PINGKAI_CACHE_REGION` | no | `cn-shanghai` | SigV4 signing region, use the bucket region |
| `PINGKAI_CACHE_PATH_STYLE` | no | `false` | set `true` for path-style backends (e.g. MinIO) |

### Org-level provisioning (configure once)

- **Org secrets** (credentials, consumed via `with:`):
  `PINGKAI_CACHE_ACCESS_KEY_ID`, `PINGKAI_CACHE_SECRET_ACCESS_KEY`
- **Org variables** (backend params, consumed via workflow `env:`):
  `PINGKAI_CACHE_BUCKET`, `PINGKAI_CACHE_ENDPOINT`, `PINGKAI_CACHE_REGION`

## Bucket preparation

- Standard storage class in the runners' region; internal endpoint when
  runners are in the same cloud/region.
- Lifecycle rule expiring objects under `cache/` after N days (e.g. 30) —
  this is the GC; the action itself never deletes objects.
- Minimal RAM policy scoped to the bucket: `oss:GetObject`, `oss:PutObject`,
  `oss:ListObjects`, `oss:AbortMultipartUpload` on `acs:oss:*:<account>:<bucket>/*`.
- For the TKE pool, provision an equivalent COS bucket and point the env vars
  at its S3-compatible endpoint; the wrapper is unchanged.

## Behavior notes

- **Backend preflight**: before handing over to runs-on/cache, the wire-up
  step probes the backend with one signed `ListObjectsV2` (max-keys=1). A
  deterministic configuration error — unknown access key, rejected signature,
  missing bucket, denied ListObjects policy — fails the job in seconds with
  `::error::` instead of wasting a full cold build. Transient issues
  (unreachable endpoint, HTTP 5xx, timeouts) stay `::warning::` and continue,
  preserving the best-effort cache semantics. This exists because
  runs-on/cache swallows backend errors into a silent cache miss.
- Object layout is `cache/<repo>/<version>/<key>`, where `<version>` is a
  hash of the cached paths and compression method — per-repo isolation is
  built in; no manual key prefixing is needed. `RUNS_ON_S3_CACHE_REPO_PREFIX`
  can override the layout if ever required.
- Restore keys are string prefixes matched via `ListObjectsV2`, most recent
  match wins — same feel as `actions/cache` restore-keys.
- Restores download a tar archive and extract it; GB-scale caches take
  minutes, unlike zero-copy NAS mounts. Prefer narrow `path` sets.
- `RUNS_ON_RUNNER_NAME` must stay unset on our runners: the backend drops
  static AWS credentials in favor of an instance profile when it is set.
- Endpoint canonical form is `https://oss-<region>[-internal].aliyuncs.com`
  **without** the bucket in the hostname (virtual-hosted addressing adds it).
  The wire-up step auto-normalizes common mistakes: it prepends `https://`
  when the scheme is missing and strips a leading `<bucket>.` from the
  hostname. Keep the org variable canonical anyway — the AWS SDK fails with
  `Invalid URL` on scheme-less endpoints and the backend swallows restore
  errors into a silent cache miss.

## Pin

The underlying action is pinned to
`runs-on/cache@3c223729b4fda74ee12f4976048dd69b420fdd26` (v5). Bump
deliberately after reviewing upstream changes; public repo tags can be
repointed.

## Before first use against a new backend

Validate S3 compatibility once with a scratch workflow: restore-miss then
save a small cache, run again to confirm the hit, and check the object
appears under `cache/<repo>/...` in the bucket. Known compat surface:
SigV4 signing (set `PINGKAI_CACHE_REGION` to the bucket region),
multipart upload (32MB parts), `ListObjectsV2` prefix matching.
