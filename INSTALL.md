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
      - uses: permission-protocol/deploy-gate@v1
        with:
          pp-api-key: ${{ secrets.PP_API_KEY }}
```

Optional (auto-create request on missing receipt):

```yaml
      - uses: permission-protocol/deploy-gate@v1
        with:
          pp-api-key: ${{ secrets.PP_API_KEY }}
          pp-request-create-token: ${{ secrets.PP_REQUEST_CREATE_TOKEN }}
```

Commit and push.

---

## Step 4: Test It (30 sec)

```bash
git checkout -b test-gate
echo "# test" >> deploy/config.yml  # or any file in .github/workflows/
git add . && git commit -m "test: trigger deploy gate"
git push origin test-gate
```

Open a PR to `main`. Watch it fail. Click the approval link. Approve. Re-run.

**That's it. You're protected.**

---

## What You'll See When It Fails

```
═══════════════════════════════════════════════════════════
  🔐 PERMISSION PROTOCOL - Deploy Authorization Required
═══════════════════════════════════════════════════════════

❌ NO RECEIPT - Human approval required

This PR changes protected deployment files.
A human must approve before merge.

👉 APPROVE HERE: https://permissionprotocol.com/review/dr_abc123

After approval, re-run this workflow.
═══════════════════════════════════════════════════════════
```

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
- Add your repo in **Settings → Repos**

### No protected paths detected (action passes unexpectedly)
```
✅ No protected paths changed - merge allowed
```
**Fix:** Your PR doesn't touch protected paths.
- Default protected: `deploy/*` and `.github/workflows/*`
- Customize with `protected-paths` input:
```yaml
- uses: permission-protocol/deploy-gate@v1
  with:
    pp-api-key: ${{ secrets.PP_API_KEY }}
    protected-paths: '^(src/critical/|infra/|deploy/)'
```

### Workflow not triggering
**Fix:** Make sure the workflow triggers on `pull_request` to `main`:
```yaml
on:
  pull_request:
    branches: [main]
```

---

## Optional: Customize Protected Paths

Default protected paths: `deploy/` and `.github/workflows/`

To protect different paths:

```yaml
- uses: permission-protocol/deploy-gate@v1
  with:
    pp-api-key: ${{ secrets.PP_API_KEY }}
    protected-paths: '^(src/critical/|infra/|k8s/|terraform/)'
```

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
