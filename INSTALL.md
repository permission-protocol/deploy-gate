# Install Deploy Gate (3 minutes)

No dependencies. No config files. One workflow, one secret.

---

## Step 1: Get Your API Key (1 min)

1. Go to [app.permissionprotocol.com](https://app.permissionprotocol.com)
2. Sign up / log in
3. Go to **Settings → API Keys → Create Key**
4. Name: `deploy-gate` 
5. Scopes: `receipts.verify,deployRequests.create`
6. **Copy the key** (shown only once)

> 🔒 **Security note:** This key can create approval requests and verify receipts. It CANNOT approve requests or access other tenants. Least privilege by design.

If you want **automatic deploy-request creation** when no receipt exists, also create a request-create token in Permission Protocol and keep it for Step 2.

---

## Step 2: Add Secret (30 sec)

**Option A: GitHub CLI**
```bash
gh secret set PP_API_KEY -b "pp_live_your_key_here"
# Optional: enable auto-request creation on missing receipts
gh secret set PP_REQUEST_CREATE_TOKEN -b "pp_req_create_..."
```

**Option B: GitHub UI**
1. Go to your repo → **Settings → Secrets and variables → Actions**
2. Click **New repository secret**
3. Name: `PP_API_KEY`
4. Value: paste your key
5. Click **Add secret**
6. Optional for auto-request creation: add `PP_REQUEST_CREATE_TOKEN`

---

## Step 3: Add Workflow (1 min)

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
      - uses: permission-protocol/deploy-gate@v2
        with:
          pp-api-key: ${{ secrets.PP_API_KEY }}
```

Optional (auto-create request on missing receipt):

```yaml
      - uses: permission-protocol/deploy-gate@v2
        with:
          pp-api-key: ${{ secrets.PP_API_KEY }}
          pp-request-create-token: ${{ secrets.PP_REQUEST_CREATE_TOKEN }}
```

Optional (explicitly allow PR-level approval carry-forward):

```yaml
      - uses: permission-protocol/deploy-gate@v2
        with:
          pp-api-key: ${{ secrets.PP_API_KEY }}
          allow-carry-forward: true
```

By default, carried-forward approvals fail closed so each pushed PR head needs its own valid receipt.

Commit and push.

---

## Step 4: Test It (30 sec)

```bash
git checkout -b test-gate
echo "# test" >> README.md
git add . && git commit -m "test: trigger deploy gate"
git push origin test-gate
```

Open a PR to `main`. Deploy Gate always creates/verifies a PP request and posts a PR comment with the review link.

**That's it. You're protected.**

---

## What You'll See In PRs

```
═══════════════════════════════════════════════════════════
  🔐 PERMISSION PROTOCOL - Deploy Authorization Required
═══════════════════════════════════════════════════════════

❌ NO RECEIPT - Human approval required

A human must approve before merge.

👉 APPROVE HERE: https://app.permissionprotocol.com/pp/deploy-requests/dr_abc123

After approval, re-run this workflow.
═══════════════════════════════════════════════════════════
```

PR comment (auto-approved / verified):
```markdown
✅ **Permission Protocol:** Approved
[View receipt →](https://app.permissionprotocol.com/pp/deploy-requests/{requestId})
```

PR comment (approval required):
```markdown
⏳ **Permission Protocol:** Approval required
[Review & approve →](https://app.permissionprotocol.com/pp/deploy-requests/{requestId})
```

---

## ⚠️ CRITICAL: GitHub Rulesets & Strict Mode

If you use **GitHub Repository Rulesets** (recommended) to enforce this check, follow these rules to avoid merge loops:

1. **Create TWO rulesets** instead of one.
2. **Ruleset 1: "Permission Protocol"**
   - Required status check: `Permission Protocol`
   - **Strict mode: OFF** (`strict_required_status_checks_policy: false`)
   - *Why?* Authorization doesn't go stale when `main` advances. Strict mode creates phantom "Expected" errors that block merges unnecessarily.
3. **Ruleset 2: "Build Protection"**
   - Required status check: `Build and test` (or your CI check)
   - **Strict mode: ON** (`strict_required_status_checks_policy: true`)
   - *Why?* This ensures your code actually compiles with the latest `main` before merging.

**Result:** Your code stays fresh, but your human approvals don't get wiped out every time someone else merges to `main`.

---

## Gate the deploy itself (Vercel, Netlify, Railway, Fly.io)

The PR gate stops unapproved code merging. To also stop it shipping, run the deploy from a workflow that redeems the same approval. In `mode: deploy` (the default on `push` and `workflow_dispatch`), Deploy Gate:

1. Finds the pull request that merged the commit being deployed.
2. Verifies the receipt a signer approved for that PR's head commit.
3. Redeems it, so one approval ships once.

It fails closed when the commit did not come from a merged PR (a direct push), when no approval exists, or when the approval was already used. `redeem: false` and `fail-on-missing: false` are rejected in this mode.

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    branches: [main]

concurrency:
  group: production-deploy
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production        # holds the provider token; restrict it to main
    permissions:
      contents: read
      pull-requests: read          # to find the merged PR
    steps:
      - uses: actions/checkout@v4
      - uses: permission-protocol/deploy-gate@v2
        with:
          pp-api-key: ${{ secrets.PP_API_KEY }}
          # Must match the PR gate's environment and capability.
      - run: npx vercel deploy --prod --yes --token "$VERCEL_TOKEN"
        env:
          VERCEL_TOKEN: ${{ secrets.VERCEL_TOKEN }}
          VERCEL_ORG_ID: ${{ secrets.VERCEL_ORG_ID }}
          VERCEL_PROJECT_ID: ${{ secrets.VERCEL_PROJECT_ID }}
```

Swap the last step for your provider:

| Provider | Deploy step | Turn off its own deploys |
| --- | --- | --- |
| Vercel | `npx vercel deploy --prod --yes --token "$VERCEL_TOKEN"` | `"git": { "deploymentEnabled": false }` in `vercel.json` |
| Netlify | `npx netlify-cli deploy --prod --dir <build dir>` with `NETLIFY_AUTH_TOKEN`, `NETLIFY_SITE_ID` | Site settings → Build & deploy → Stop builds |
| Railway | `npx @railway/cli up --service <service>` with `RAILWAY_TOKEN` | Service settings → disconnect the GitHub repo trigger |
| Fly.io | `flyctl deploy --remote-only` with `FLY_API_TOKEN` (via `superfly/flyctl-actions/setup-flyctl`) | Remove any GitHub deploy integration |

The gate only holds if this workflow is the only way to deploy:

- **Turn off the provider's own Git deploys** (table above). Otherwise the provider ships every push to `main` before this workflow runs.
- **Keep the provider token in a GitHub Environment** restricted to `main`, so a pull request workflow cannot read it.
- **Gate changes to `.github/workflows/`** at the PR gate, so nobody can delete the deploy gate step without a signature.
- **Anyone with the provider's dashboard, CLI or token can still deploy around it.** Limit who holds them.

Production approvals expire 15 minutes after they are signed, so merge promptly after approval (GitHub auto-merge does this for you). A deploy that runs after the approval expired fails with `RECEIPT_EXPIRED`. If the gate passed but a later step failed, the approval is already used; re-running fails with `RECEIPT_ALREADY_REDEEMED`.

---

## Common Errors

### 401 Unauthorized
```
Error: Request failed with status code 401
```
**Fix:** Your API key is invalid or expired.
- Check the key is correct (starts with `pp_live_` or `pp_test_`)
- Regenerate if needed

### 403 Forbidden  
```
Error: Request failed with status code 403
```
**Fix:** Your API key is missing required scopes.
- Go to Settings → API Keys
- Ensure scopes include: `receipts.verify,deployRequests.create`
- Regenerate key with correct scopes

### 404 Not Found
```
Error: Request failed with status code 404
```
**Fix:** Your repo isn't registered with Permission Protocol.
- Go to [app.permissionprotocol.com](https://app.permissionprotocol.com)
- Connect the repo to your Permission Protocol account

### PP unavailable (fail-open)
```
⚠️ PP unavailable - fail-open
```
**What it means:** Permission Protocol API did not respond before timeout (`fail-open-timeout`, default `30s`).
- Deploy Gate sets commit status to success with `PP unavailable — fail-open`
- Merge is not blocked by PP downtime
- Retry later to restore normal gating behavior

### Workflow not triggering
**Fix:** Make sure the workflow triggers on `pull_request` to `main`:
```yaml
on:
  pull_request:
    branches: [main]
```

---

## Optional: Risk Metadata Paths

Default protected paths: `deploy/` and `.github/workflows/`

To send different risk metadata signals:

```yaml
- uses: permission-protocol/deploy-gate@v2
  with:
    pp-api-key: ${{ secrets.PP_API_KEY }}
    protected-paths: '^(src/critical/|infra/|k8s/|terraform/)'
```
These paths are sent to PP as metadata and do not decide whether the gate runs.

---

## Need Help?

- [Documentation](https://permissionprotocol.com/docs)
- [Discord](https://discord.gg/permissionprotocol)
- [GitHub Issues](https://github.com/permission-protocol/deploy-gate/issues)

---

<p align="center">
<strong>Total install time: ~3 minutes</strong><br>
<sub>Time to first blocked PR: ~1 minute after that</sub>
</p>
