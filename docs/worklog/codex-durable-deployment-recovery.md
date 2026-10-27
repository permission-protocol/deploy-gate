# Durable customer deployment recovery

Date: 2026-10-27
Branch: codex/durable-deployment-recovery

## Objective
Recover transient approval failures after the original workflow stops, preserving required human signatures, receipt expiry, exact scope and single redemption. Local changes only; no push, PR, tag or release.

## Scope and dependencies
Based on origin/main 214e1de (v2.4.0). Existing open PRs #47 and #48 also touch action.yml/docs/tests; their overlap must be checked again before future publication. Server-side exact-attempt reconciliation is implemented in the app's local codex/durable-deployment-recovery branch. Older servers fail closed if that read-back is unavailable.

## Changes
- Persist confirmed read-only timeout metadata and provider retry deadlines as immutable run-attempt artifacts.
- Supply a separate opt-in recovery composite Action with an explicit single-job, one-consuming-gate and named provider-step contract. It checks the newest run, branch head, repository, attempt and provider evidence before one normal gated rerun.
- Persist a submission journal before the retry request; observe uncertain outcomes without replaying writes.
- Select the exact receipt before redemption and correlate its one use to run/attempt/job/Action/scope. Recover a lost response with non-redeeming reads only; require current signature, scope, expiry, policy and signer checks.
- Document setup and inspection cases in RECOVERY.md. These changes are unreleased and existing v2 installations do not contain them.

## Validation
- `bash -n test/run-tests.sh`: passed.
- `bash test/run-tests.sh`: 146 shell assertions passed; 4 Node coordinator tests passed. Includes lost final-response read-back, no second redemption, terminal refusals, provider deadlines, custom workflow identity, restarted coordinator journal and missing execution-step refusal.
- `git diff --check`: passed.
- No live customer workflow or provider submission was started.

## Impact and risks
No approval bypass, TTL extension, secret access or new PP credential privileges. The recovery workflow needs only its own repository's ephemeral GITHUB_TOKEN with Actions write and Contents read. It cannot sign or deploy independently. Cancellation, missing evidence, multiple jobs/gates, started provider submission, records older than 28 days and journaled requests without a newer observed attempt require inspection. GitHub schedule delivery is best effort and its rerun API has no atomic conditional or idempotency key. Generic customer recovery is explicitly opt-in; no installed client configuration was changed.
