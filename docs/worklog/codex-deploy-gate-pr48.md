# In-repository replacement for fork PR #48

Date: 2026-10-30
Branch: codex/deploy-gate-pr48
PR: https://github.com/permission-protocol/deploy-gate/pull/73

## Objective
Publish the tested enforcement fix where the unchanged trusted gate workflow can use normal repository credentials. GitHub withholds its PP key on fork PR #48. The original stays open for provenance.

## Scope and dependencies
Preserves contributor history and main at ec9549d. Same implementation as tested source ed401df; this follow-up adds only this worklog. No secrets, rulesets, workflow code, tags or releases changed. Merge #73 before #74 and refresh approval for any subsequent head update required by the repository.

## Validation
- bash test/run-tests.sh on ed401df: 174 shell assertions and 9 Node tests passed, zero failures; gh/curl stubbed.
- Embedded Action Bash syntax, bash -n test/run-tests.sh and git diff --check: passed.
- Original PR Action script CI passed on this source; replacement CI runs separately.
- Both final implementation patches applied cleanly to each other; git merge-tree also succeeded without conflicts.
- No build step exists in this Bash composite Action repository. No live receipt or deployment test was run.

## Impact and risks
Preserves INV-10 and INV-16. Draft workflow success is not signer authorization; ready_for_review reruns the trusted gate. Remains draft because marking ready can arm auto-merge and merge/release has not been authorized. Human PP signer decisions remain required.
