# In-repository replacement for fork PR #47

Date: 2026-10-30
Branch: codex/deploy-gate-pr47
PR: https://github.com/permission-protocol/deploy-gate/pull/74

## Objective
Publish the tested enforcement fix where the unchanged trusted gate workflow can use normal repository credentials. GitHub withholds its PP key on fork PR #47. The original stays open for provenance.

## Scope and dependencies
Preserves contributor history and main at ec9549d. Same implementation as tested source 00b562c; this follow-up adds only this worklog. No secrets, rulesets, workflow code, tags or releases changed. Merge #73 before #74 and refresh approval for any subsequent head update required by the repository.

## Validation
- bash test/run-tests.sh on 00b562c: 193 shell assertions and 8 Node tests passed, zero failures; gh/curl stubbed.
- Embedded Action Bash syntax, bash -n test/run-tests.sh and git diff --check: passed.
- Original PR Action script CI passed on this source; replacement CI runs separately.
- Both final implementation patches applied cleanly to each other; git merge-tree also succeeded without conflicts.
- No build step exists in this Bash composite Action repository. No live receipt or deployment test was run.

## Impact and risks
Preserves INV-10 and INV-16. Draft workflow success is not signer authorization; ready_for_review reruns the trusted gate. Remains draft because marking ready can arm auto-merge and merge/release has not been authorized. Human PP signer decisions remain required.
