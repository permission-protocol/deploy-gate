# Transient verification recovery

Date: 2026-10-23
Branch: codex/verify-transient-recovery
Base: origin/main 788dd7b
Release target: v2.4.0 and the v2 major tag, after required approvals and merge.

## Objective
Keep transient PP errors from permanently failing a customer deployment while preserving production fail-closed enforcement and one-time redemption (INV-10, INV-16).

## Changes
- Verify through non-redeeming reads before any redemption, preserving the exact PR/head/environment/capability scope.
- Retry temporary network, database/gateway, rate-limit and GitHub policy-read failures every 15 seconds. Reads use the configured request timeout (default 30 seconds); the recovery budget is five minutes, or 30 minutes when waiting for a deploy approval.
- Deploy mode waits for a human signature or eligible renewal by default and prints the existing signing link. `wait-for-approval: false` keeps immediate missing/expired-approval responses. PR mode still returns missing approvals immediately.
- Do not retry authentication, signature, scope, revocation or policy refusals. Never retry a final redemption or accept a partial response. Pending human approval cannot turn into a non-production fail-open at the deadline. Ambiguous final redemption fails closed as PP_REDEMPTION_UNCERTAIN even outside production.

## Validation
`bash test/run-tests.sh`: final run passed, 140 assertions and zero failures. Coverage includes transient database/gateway and GitHub policy-read errors, interrupted transfers, human renewal, persistent outages, terminal refusals, PR reads, ambiguous redemption and non-production approval timeouts. Tests use stubbed gh/curl/date/sleep and do not contact GitHub, PP or deployment providers. `git diff --check` passed.

## Dependencies and limitations
Open PRs #47 and #48 edit action.yml; inspected their changed files before implementation. They are separate carried-forward-receipt and draft-PR changes, not recovery fixes. This local branch requires review and publication of a new deploy-gate version; the app repository's changes do not update existing customer action pins. No tag moved, PR published, merge or deployment performed. Expired authorization still needs a human signature; persistent outages and ambiguous final redemption responses fail closed with a recovery message.
