# PR #47 enforcement fix

Date: 2026-10-30
Branch: fix/reject-carried-forward-receipts
PR: https://github.com/permission-protocol/deploy-gate/pull/47

## Objective
Prevent a carried-forward approval from authorizing a gate, and reject it before consuming the receipt. Related to #46 and #36.

## Scope and dependencies
Existing contributor PR updated in a dedicated local worktree. Base: main `ec9549d`. Owned changes: action.yml, README.md, INSTALL.md, test/run-tests.sh, this log. Both PRs remain independent and preserve each other's scope; merge #48 before #47. No workflow/ruleset/security credential changes.

## Changes
- Updated the existing contributor branch with main at `ec9549d`, retaining deployment lookup, read-only retry and exact-attempt recovery.
- Reject carried-forward results during the non-redeeming verification read, before receipt selection and redemption. There is no carry-forward input.
- Inspect both top-level and nested markers, reject malformed markers and recheck final redemption/reconciliation responses before reporting approval.
- Added regression cases for PR/deploy modes, masked and malformed markers, legacy opt-outs, transient recovery, fresh receipts and changed final responses. Rejected reads assert zero redeem=true requests.

## Validation
- bash test/run-tests.sh: 193 shell assertions and 8 Node tests passed, zero failures on final source; all GitHub and PP API calls stubbed.
- node --test test/recovery.test.mjs test/permission-gate.test.mjs: 8 passed.
- git apply --check of PR #48 final patch against this worktree: passed, with no edits.
- `bash -n test/run-tests.sh`: passed.
- Extracted the embedded Action script and ran `bash -n` through Python with UTF-8 encoding: passed.
- `git diff --check`: passed; no conflict markers in changed sources.
- No npm build step exists in this Bash composite Action repository.

## Impact and risks
Improves receipt enforcement while preserving INV-10 and INV-16 and single-use redemption. The Action still delegates signature, tenant and exact-head scope verification to the server; it neither signs nor replays redemption.

This deliberately also refuses carry-forward used for same-head scope normalization; obtain fresh approval matching the exact scope. A refusal discovered only in the final response fails the gate but cannot undo a redemption already sent; the initial read prevents consumption of already reported carry-forward. Source inspection of the app verifier shows same-commit and same-environment restrictions, but this is not live verification. No signing, server enforcement, customer workflow, tag or release was changed or tested live. Merge after #48 and retain both independent protections.
