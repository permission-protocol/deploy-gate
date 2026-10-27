# Stopped deployment recovery (local, unreleased changes)

This version adds a durable coordinator and exact-attempt redemption read-back.
It has not been pushed or released. The `v2` examples below apply only after a
reviewed release contains these changes; pin a reviewed release commit in use.

## What recovers

The deploy Action persists an immutable run-attempt record when its read-only
approval wait ends. The separate recovery workflow checks it after the original
runner has stopped and resumes the newest matching run through the same gate.
Provider retry deadlines survive the runner. Every approval is checked again;
expired approvals still require fresh human signatures. Used approvals cannot
authorize another execution.

A lost final redemption response is reconciled only by reads of the exact
receipt, run, attempt, job, Action and scope. PP must confirm the same attempt
consumed a still-valid receipt and recheck current policy and signing authority.
No second redemption is sent. Older PP servers without this correlation remain
fail-closed on an uncertain response.

## Configure a separate recovery workflow

Use one deployment job with named approval and submission steps. For example,
`deploy.yml` has job display name `Deploy production`, gate step `Verify permission`
and provider submission step `Submit deployment`. List every submission step;
missing, renamed or duplicate names disable automatic recovery.

Save this as `.github/workflows/production-recovery.yml`:

```yaml
name: Recover deployment waits
on:
  workflow_run:
    workflows: ['Production Deploy'] # deployment workflow's display name
    types: [completed]
    branches: [main]
  schedule:
    - cron: '*/5 * * * *'
  workflow_dispatch:
permissions:
  contents: read
  actions: write
concurrency:
  group: pp-deployment-recovery
  cancel-in-progress: false
jobs:
  recover:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: permission-protocol/deploy-gate/recovery@v2
        with:
          workflow-file: deploy.yml
          branch: main
          job-name: Deploy production
          gate-steps: '["Verify permission"]'
          execution-steps: '["Submit deployment"]'
          github-token: ${{ github.token }}
```

The coordinator needs only its repository's ephemeral workflow credential.
It has no PP key, provider key, passkey or signing key. It cannot bypass the
deployment workflow's environment protection, approval gate or receipt expiry.
It downloads only data from an owned push/dispatch run; it never executes code
from a failed run's artifact. Completion events and periodic checks both drive
recovery; GitHub schedules can be delayed.

## Cases that require inspection

- The workflow contains multiple jobs, is not the declared branch/workflow,
  or its execution steps do not match the declared contract.
- The newest commit or run changed. The older run is never chosen instead.
- A provider submission may have started, a redemption remains uncertain,
  or GitHub's rerun response was lost without a newer attempt becoming visible.
- The recovery record is missing, invalid or older than 28 days. Records and
  submission journals are retained for 30 days.

A submission journal is persisted before the one retry request. After an
uncertain request, subsequent coordinators observe GitHub rather than send it
again. GitHub does not expose an idempotency key for this endpoint; deleting
journals or automatically replaying uncertain provider writes is unsafe.

The Actions permission above is scoped to the recovery workflow's own
repository. It does not expand the installed PP App's permissions.
