# LATdx CI Fork

This is [nebulity](https://github.com/nebulity)'s fork of
[jongpie/NebulaLogger](https://github.com/jongpie/NebulaLogger). Its purpose is
to run Nebula Logger's real-world pull requests through the
[LATdx](https://latdx.com) Apex test runner, keeping everything else about the
upstream pipeline (scratch org lifecycle, deploys, code quality checks) as
close to upstream as possible.

Every open upstream PR is mirrored here automatically and built with the
fork's CI, so each upstream contribution doubles as a live compatibility and
timing sample for LATdx. Upstream's own CI run on the same PR provides the
side-by-side baseline.

## What differs from upstream

All divergence lives in `.github/` plus this file:

- `.github/workflows/build.yml`:
  - The two `Run Apex Tests (A)synchronously` steps in each scratch-org job
    are replaced by one `Run Apex Tests with LATdx` step
    (`.github/actions/latdx-test`). The `sf project deploy validate
--test-level RunLocalTests` step is untouched, so the suite still runs
    server-side once per job as part of the deploy lifecycle.
  - Org provisioning: upstream creates a throwaway scratch org per run; the
    fork instead authorizes one long-lived org (`TARGET_ORG_SFDX_AUTH_URL`)
    and redeploys NebulaLogger onto it every build (idempotent). The org is
    created once from NebulaLogger's own `config/scratch-orgs/base-scratch-def.json`
    on the LATdx pool Dev Hub (`latdx-dh`), with a 30-day duration, so its
    shape (edition, features, settings) matches what the base job expects —
    not the LATdx pool's scratch shape. It carries no `Pooltag__c`, so sfp's
    pool prepare ignores it.
  - Upstream-only concerns are gated on `github.repository ==
'jongpie/NebulaLogger'`: Codecov uploads, the core coverage suite run,
    package version verification, and the three package-versioning jobs
    (their 2GP packages live in the upstream maintainer's Dev Hub).
  - The five feature-permutation scratch jobs (advanced, event monitoring,
    experience cloud, OmniStudio, platform cache) are upstream-only: they
    need fresh feature-specific scratch orgs the fork cannot create. The
    fork runs code quality, LWC tests, and the base scratch org job against
    the single reserved pool org; pushes to fork main skip the org job.
  - `workflow_dispatch` trigger and a read-only default token
    (`permissions:` block) are added; `id-token: write` lets jobs mint the
    OIDC token used for the LATdx OSS license exchange.
- `.github/actions/latdx-test/`: composite action that installs the LATdx
  CLI, resolves a license, and runs `latdx test run` against the job's
  default org (the scratch org each job creates).
- `.github/workflows/mirror-upstream-prs.yml`: every 30 minutes, mirrors open
  upstream PRs into `upstream-pr-<n>` branches, opens fork PRs labeled
  `upstream-mirror`, and dispatches Build (capped per cycle to protect the
  scratch org budget). Closes mirrors whose upstream PR closed.
- `.github/workflows/sync-upstream.yml`: daily merge of upstream main into
  fork main; opens an issue on conflict.

## Test semantics

- `latdx test run` with no selection discovers org test classes with
  `NamespacePrefix = NULL`, matching `RunLocalTests` semantics (the OmniStudio
  managed package's tests stay excluded).
- Upstream runs the suite twice per job (async + sync) to cover an
  AuthSession nuance; the fork runs it once via LATdx. The async/sync
  permutation remains covered by upstream's own CI.

## Security model

Mirrored branches contain upstream-authored code, so the pipeline assumes the
code is untrusted:

- The mirror overlays `.github/` from fork main onto every mirrored branch;
  workflow or action changes from upstream PRs never execute here.
- `build.yml` runs with a read-only `GITHUB_TOKEN`, so a checkout credential
  leak cannot push or read secrets.
- The reserved org's credentials are exposed only to the org-auth and the
  `npx sf` deploy steps, which resolve `sf` from `node_modules`, so PRs
  touching `package.json` / `package-lock.json` are mirrored with the
  `held-sensitive` label and are NOT auto-built; review the manifest diff,
  then dispatch Build on the branch manually. The blast radius is one
  disposable scratch org, not a Dev Hub.
- Revoke a leaked org by releasing it on the pool Dev Hub (set
  `Allocation_status__c` back to `Available` or delete the org) and rotating
  `TARGET_ORG_SFDX_AUTH_URL` to a freshly reserved org.

## Secrets

| Secret                     | Required | Purpose                                                                                                                                                         |
| -------------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TARGET_ORG_SFDX_AUTH_URL` | yes      | SFDX auth URL of the long-lived org the fork deploys to and tests, created from `base-scratch-def.json` on the pool Dev Hub. Rotate when it expires (~30 days). |
| `LATDX_CI_LICENSE_KEY`     | no       | LATdx TEAM/CI license key. Without it the action falls back to the OSS OIDC exchange; if that path is unavailable, runs cap at 100 tests and exit 2.            |

## Operations

- Mirrored PRs always show a parked `pull_request` run ("workflow awaiting
  approval"): GitHub requires approval for runs on PRs authored by
  first-time contributors, and `github-actions[bot]` forever stays one. Do NOT
  approve these; the mirror dispatches the real Build run, which needs no
  approval and reports on the same commit. On a `held-sensitive` PR,
  "Approve and run" would bypass the manifest-review hold.
- Mirror or sync manually: `gh workflow run mirror-upstream-prs.yml` /
  `gh workflow run sync-upstream.yml` (both also run on schedule).
- Build a held PR after review: `gh workflow run build.yml --ref
upstream-pr-<n>`.
- All fork builds serialize on the single reserved org via a `concurrency`
  group (`nebula-fork-shared-org`, queue not cancel), so a second build
  waits rather than clashing on the shared org's deploy. The mirror's
  per-cycle build cap defaults to 1; raise it for a manual run with
  `gh workflow run mirror-upstream-prs.yml -f max-builds=3` (extra builds
  queue behind the concurrency group).
- Rotate the org when it nears expiry (~30 days): recreate it from the def
  on the pool Dev Hub and update the secret:
  `sf org create scratch --target-dev-hub latdx-dh --no-namespace
--no-track-source --definition-file ./config/scratch-orgs/base-scratch-def.json
--duration-days 30 --alias nebula-fork-shaped`, then
  `sf org auth show-sfdx-auth-url -o nebula-fork-shaped` and store the URL as
  the `TARGET_ORG_SFDX_AUTH_URL` repo secret. Delete the expired org.

## Known issues

- Full-suite run fails (`An unknown exception occurred`): once the OSS
  auto-license uncaps the run, `latdx test run` over NebulaLogger's full
  org suite (73 local Apex test classes) errors on every class, while stock
  `sf apex run test --test-level RunLocalTests` passes all 1366 tests on the
  same org. This is a LATdx bug in the uncapped full-suite submission path
  (not an org, shape, or NebulaLogger problem), and it is the kind of
  real-world signal this fork exists to surface. The base job stays red
  until LATdx fixes it; the LATdx licensing, org provisioning, deploy, and
  capped runs all work.

## Timing comparison caveats

When comparing this fork's runs against upstream's runs on the same PR, the
defensible comparison is the test-execution step only. Org shape differs
(different Dev Hubs, instance pools), the fork skips the second (synchronous)
suite run and the coverage suite run, and LATdx result caching means repeat
runs of unchanged code are not equivalent to cold runs. Quote raw step
durations with these caveats, not a synthesized speedup number.
