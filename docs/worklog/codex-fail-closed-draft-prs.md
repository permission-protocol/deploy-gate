# PR #48 enforcement fix

Date: 2026-10-30
Branch: codex/fail-closed-draft-prs
PR: https://github.com/permission-protocol/deploy-gate/pull/48

## Objective
Stop a draft PR from leaving a green required check on the same head SHA after it is marked ready for review. Fixes #45; related to #36.

## Scope and dependencies
Existing contributor PR updated in a dedicated local worktree. Base: main `ec9549d`. Owned changes: action.yml, README.md, INSTALL.md, test/run-tests.sh, this log, and test/permission-gate.test.mjs. Both PRs remain independent and preserve each other's scope; merge #48 before #47. No workflow/ruleset/security credential changes.

## Changes
- Updated the existing contributor branch with main at `ec9549d`, retaining deployment lookup, read-only retry and exact-attempt recovery.
- Draft PRs stop with `PP_DRAFT_PR_BLOCKED`, `approved=false` and `decision=DRAFT_BLOCKED` before any PP API call. There is no skip input.
- Retained the PR-mode guard so push-mode deployments never perform a draft lookup. Missing, failed or malformed draft metadata now stops with `PP_PR_LOOKUP_FAILED`.
- Added `ready_for_review` to all install examples and regression coverage for the same-head draft-to-ready transition, missing/fresh receipts and attempted opt-outs.

## Validation
- bash test/run-tests.sh: 174 shell assertions and 9 Node tests passed, zero failures; all GitHub and PP API calls stubbed.
- git apply --check of PR #47 final patch against this worktree: passed, with no edits.
- `bash -n test/run-tests.sh`: passed.
- Extracted the embedded Action script and ran `bash -n` through Python with UTF-8 encoding: passed.
- `git diff --check`: passed; no conflict markers in changed sources.
- No npm build step exists in this Bash composite Action repository.

## Impact and risks
Improves enforcement and activation reliability without granting authority. Preserves INV-10 and INV-16: an unverified draft cannot report approval, and a ready PR still requires verification for its current head.

Draft workflows now fail until ready; metadata outages also stop closed. Existing installations receive the change only after a separately authorized Action release. The security-sensitive behavior is covered with stubbed gh/curl tests; no live customer workflow, receipt signing or production deployment was tested. The initial local run exposed an empty decision output (173 passed, 1 failed); the helper was corrected and the full suite rerun. This PR and #47 remain separate changes against the same main; merge #48 first, refresh #47 only if integration requires it.
