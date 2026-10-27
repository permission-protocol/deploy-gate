# Durable customer deployment recovery

Date: 2026-10-27
Branch: codex/durable-deployment-recovery

## Objective
Recover transient approval failures after the original workflow stops, preserving required human signatures, receipt expiry, exact scope and single redemption. Initially implemented locally. The user now authorizes draft PR publication; no merge, tag or release is part of this request.

## Scope and dependencies
Based on origin/main 214e1de (v2.4.0). Existing open PRs #47 and #48 also touch action.yml/docs/tests; their diffs were rechecked before publication; coordinate their eventual merges with this Action change. Server-side exact-attempt reconciliation is implemented in the companion app's codex/durable-deployment-recovery branch. Older servers fail closed if that read-back is unavailable.

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

## Publication review

Refreshed origin/main to 214e1de on 2026-10-27; no existing PR uses this branch. Reviewed #47 (carry-forward default), #48 (draft-PR behavior) and #67 (fix.md only). #47/#48 overlap action.yml and documentation/tests; their separate proposals are not folded into this diff. Publication is a draft PR only. The companion server must ship before an Action release; uncertain responses against older servers remain fail-closed.

## CI repair after publication

- The required gate job failed before any approval request: GitHub rejected the released v2.4.0 composite's large Bash body because six embedded GitHub expressions exceeded its 21,000-character expression limit. Use the existing `PP_REPOSITORY` and `GH_TOKEN` environment mappings inside that body instead.
- Bootstrap this repository's gate from immutable released commit `214e1de8d966e1b757b172f6d0fae41620307e15`, verifying the original Action SHA-256 before replacing only those six equivalent interpolations. Candidate Action code never handles this gate's credentials. An unexpected release digest, script structure or expression fails closed.
- Preserve the same production/deploy:main inputs and explicit closed failure mode. Re-run the gate on ready_for_review. The active App-pinned `permission-protocol/approval` ruleset (integration 3065051) and required `Permission Protocol` job were inspected and remain unchanged. The PR remains draft; no merge, tag or release occurred.
- `node --test test/recovery.test.mjs test/permission-gate.test.mjs`: 8 passed, including actual released-code normalization and tamper refusal.
- `bash test/run-tests.sh`: 146 shell assertions and 8 Node tests passed. `git diff --check`: passed. These are local results; GitHub execution is verified after pushing.
