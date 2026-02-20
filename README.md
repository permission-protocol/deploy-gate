<p align="center">
  <img src="https://img.shields.io/badge/❌_No_Receipt-No_Merge-red?style=for-the-badge" alt="No Receipt = No Merge">
</p>

<h1 align="center">Deploy Gate</h1>

<p align="center">
  <strong>One line. Human approval required. No exceptions.</strong>
</p>

<p align="center">
  <a href="https://github.com/permission-protocol/deploy-gate/actions">
    <img src="https://img.shields.io/github/actions/workflow/status/permission-protocol/deploy-gate/test.yml?style=flat-square&label=tests" alt="Tests">
  </a>
  <a href="https://github.com/marketplace/actions/deploy-gate">
    <img src="https://img.shields.io/badge/GitHub_Marketplace-Deploy_Gate-blue?style=flat-square" alt="Marketplace">
  </a>
  <a href="https://permissionprotocol.com">
    <img src="https://img.shields.io/badge/Permission_Protocol-Visit-black?style=flat-square" alt="Permission Protocol">
  </a>
</p>

---

## Quick Start

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
      - uses: permission-protocol/deploy-gate@v1
        with:
          pp-api-key: ${{ secrets.PP_API_KEY }}
```

**That's it.** PRs touching protected paths now require human approval.

---

## What Happens

```
PR opened
    │
    ▼
┌──────────────────┐
│ Protected path?  │──── NO ───▶ ✅ Merge allowed
└────────┬─────────┘
         │ YES
         ▼
┌──────────────────┐
│ Receipt exists?  │──── YES ──▶ ✅ Merge allowed
└────────┬─────────┘
         │ NO
         ▼
┌──────────────────┐
│   ❌ CI FAILS    │
│                  │
│  Approval URL    │
│  shown in logs   │
└──────────────────┘
         │
         ▼
   Human approves
   in PP dashboard
         │
         ▼
   Re-run CI → ✅
```

---

## Setup

### 1. Get API Key

Sign up at [permissionprotocol.com](https://permissionprotocol.com) and create an API key.

### 2. Add Secret

```bash
gh secret set PP_API_KEY -b "pp_live_your_key_here"
```

### 3. Add Workflow

Create `.github/workflows/deploy-gate.yml`:

```yaml
name: Deploy Gate

on:
  pull_request:
    branches: [main]

jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: permission-protocol/deploy-gate@v1
        with:
          pp-api-key: ${{ secrets.PP_API_KEY }}
```

### 4. Open a PR

Touch a protected path. Watch it fail. Approve. Merge.

---

## Configuration

| Input | Description | Default |
|-------|-------------|---------|
| `pp-api-key` | Your Permission Protocol API key | **Required** |
| `pp-base-url` | PP API base URL | `https://app.permissionprotocol.com` |
| `protected-paths` | Regex for protected paths | `^(deploy/\|\.github/workflows/)` |
| `fail-on-missing` | Fail if no receipt | `true` |

### Custom Protected Paths

```yaml
- uses: permission-protocol/deploy-gate@v1
  with:
    pp-api-key: ${{ secrets.PP_API_KEY }}
    protected-paths: '^(src/critical/|infra/|\.env)'
```

---

## Outputs

| Output | Description |
|--------|-------------|
| `approved` | `true` if approved, `false` otherwise |
| `request-id` | Deploy request ID (if created) |
| `approval-url` | URL to approve the deploy |

```yaml
- uses: permission-protocol/deploy-gate@v1
  id: gate
  with:
    pp-api-key: ${{ secrets.PP_API_KEY }}

- run: echo "Approval URL: ${{ steps.gate.outputs.approval-url }}"
  if: failure()
```

---

## Why?

Your AI agent just pushed to main.  
It passed CI.  
It deployed to production.

**Who approved it?**

Not a human. Not a policy. Nobody.

Deploy Gate closes that gap.

---

## Live Demo

See it in action: [permission-protocol/pp-demo](https://github.com/permission-protocol/pp-demo)

---

<p align="center">
  <a href="https://permissionprotocol.com">
    <img src="https://img.shields.io/badge/Get_Permission_Protocol-black?style=for-the-badge" alt="Get PP">
  </a>
</p>

<p align="center">
  <sub>Built by <a href="https://permissionprotocol.com">Permission Protocol</a> · The Signer of Record for Autonomous Systems</sub>
</p>
