# Deploy Gate

**Stop AI coding agents from shipping production changes you didn't authorize.**

When Cursor / Codex / Copilot / Claude Code opens a PR that touches `deploy/`, `.github/workflows/`, or any path you mark sensitive, Deploy Gate blocks the merge until a named human signs an approval and produces a signed receipt that proves who authorized what against which policy.

- ⛔ **Fails closed by default** for production environments
- ✍️ **Ed25519-signed receipts** bound to the exact action
- ⚡ **<200ms enforcement** in the GitHub status check
- 🆓 **MIT-licensed action**

> "GitHub asks 'did a reviewer approve?' Deploy Gate asks 'did a named human authorize this exact AI action?' and gives you signed proof."

## Why this exists

AI agents are moving from "suggest text" to "take actions": committing code, modifying workflows, and deploying to production. GitHub controls like branch protection, environments, and required reviewers gate humans, not agents.

Deploy Gate is the missing primitive: a deterministic gate keyed to the exact action the agent is taking, with a signed authority receipt as the audit artifact.

When audit time comes, you do not want to hand over a mutable PR comment thread. You want a chain of signed receipts that can be independently verified.

## Quickstart

Add to your workflow:

```yaml
# .github/workflows/deploy-gate.yml
name: Deploy Gate

on:
  pull_request:
    branches: [main]

jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: permission-protocol/deploy-gate@v2
        with:
          pp-api-key: ${{ secrets.PP_API_KEY }}
```

1. Get API key at https://app.permissionprotocol.com
2. Add secret:

```bash
gh secret set PP_API_KEY -b "pp_live_..."
```

3. Open a PR and watch deploy-sensitive changes block until approval

Full install guide: [INSTALL.md](./INSTALL.md)

## Failure modes

`v2` defaults to fail-closed when the Permission Protocol API is unavailable. **A security tool that fails open in a network blip is not a security tool.**

| Environment | `fail-mode` | Result on API unavailable |
| --- | --- | --- |
| Production (`production`, `prod`, `live` by default) | `closed` or `open` (forced to closed) | ❌ Fails closed. No deploy. |
| Non-production (`staging`, `preview`, etc.) | `closed` (default) | ❌ Fails closed. No deploy. |
| Non-production | `open` (opt-in) | ✅ Pass with `::warning::` log |

Inputs:

- `fail-mode`: `closed` (default) or `open` — only honored in non-production environments.
- `production-environments`: comma-separated environment names treated as production, default `production,prod,live`.
- `fail-open-timeout`: API timeout in seconds. It controls timeout duration only, not failure policy.

### Release notes (v2)

- **BREAKING**: defaults to fail-closed. To restore v1 behavior, set `fail-mode: open` and remove `production-environments`.

## How it works

*Block -> Approve -> Verify -> Merge.*

```text
PR opened
   │
   ▼
Deploy Gate checks for valid receipt
   │
   ├── Receipt exists ----------> Merge allowed
   │
   └── No receipt --------------> Blocked
                                     │
                                     ▼
                              PR comment with approval link
                                     │
                                     ▼
                              Human approves + signs
                                     │
                                     ▼
                              Re-run CI -> Merge allowed
```

## What it does

- Blocks risky PRs with a required status check
- Posts a PR comment with a direct approval link
- Unblocks the PR instantly after approval
- Produces a tamper-evident approval receipt

## Comparison

| Option | Human authorization on AI action | Cryptographic proof | Default under outage |
| --- | --- | --- | --- |
| GitHub required reviewer only | Partial | No | Often workflow-dependent |
| PR comments + screenshots | No | No | Open to mutation |
| Deploy Gate | Yes | Yes (Ed25519 receipt) | Fails closed for production |

## License

MIT - see [LICENSE](./LICENSE)
