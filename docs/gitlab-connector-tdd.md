# GitLab Enterprise Deploy Gate Connector Technical Design Document (TDD)
**Date:** July 2026  
**Status:** DRAFT (Awaiting Rod Review)  
**Baseline Reference:** GitHub Deploy Gate v2 (`deploy-gate/action.yml`)  

---

## 1. Overview & Business Requirements

This document specifies the architecture and design for the GitLab Enterprise Deploy Gate connector. This connector brings our out-of-band "Signer of Record" authorization primitive to self-managed and cloud-hosted GitLab environments. 

The primary target customer is Bridgewater Associates (Santi Weight), which requires a self-managed, single-tenant GitLab installation, Microsoft Entra ID single sign-on, and a fail-closed deploy check.

---

## 2. Integration Mechanism Analysis

We evaluated three potential hooks for integrating Permission Protocol (PP) into the GitLab Merge Request (MR) and deployment pipeline:

### Option A: GitLab External Status Checks (Ultimate Only)
GitLab Ultimate provides "External Status Checks" which send a POST payload to an external API (Permission Protocol) when an MR is created or updated. The MR is blocked from merging until the external service posts a `passed` status back via the GitLab API.
* *Pros:* Native UI integration; blocks merges cleanly; behaves identically to GitHub Status Checks.
* *Cons:* Requires GitLab Ultimate tier (premium pricing); not available to Core or Premium customers.

### Option B: CI/CD Pipeline Job Gate (Recommended Primary)
A required job is added to the `.gitlab-ci.yml` pipeline that executes a lightweight CLI runner (`npx pp-gitlab-gate`). This job calls the Permission Protocol API to check for a valid, signed receipt matching the commit SHA. If no receipt exists, the job blocks, preventing the pipeline from succeeding and blocking the deployment.
* *Pros:* Works across all GitLab tiers (including Core/Community Edition); fits into existing MR pipelines; easy to customize via environment variables.
* *Cons:* Resides inside the codebase's CI configuration (requires self-defense policies to prevent deletion).

### Option C: Merge Request Approval Rules (Fallback)
Using GitLab's MR Approval Rules API, PP adds an external approval rule requiring a specific "PP Bot" approval. The MR is locked until the PP API service posts an approval via the Merge Requests API.
* *Pros:* Built-in approval UI on the MR page.
* *Cons:* Harder to enforce deterministically in self-managed environments without administrative overrides.

### Recommendation
* **Primary Integration:** **Option B (CI/CD Pipeline Job Gate)** combined with **Option C (MR Approval Rules)** where supported. This guarantees multi-tier compatibility. The CI job will run on every merge request and deployment pipeline, acting as the ultimate enforcement point.
* **Secondary Integration:** **Option A (External Status Checks)** as a native high-end enterprise toggle for Ultimate customers.

---

## 3. Receipt Binding & Cryptographic Verification

The GitLab Deploy Gate uses Ed25519 signatures to guarantee tamper-evident authority records. The Universal Action Receipt (UAR) binds the following fields to the cryptographic signature:

```json
{
  "commit_sha": "a1b2c3d4e5f6...",
  "project_id": "998273",
  "environment": "production",
  "issuer": "permission-protocol",
  "signer_identity": "entra-id:santi.weight@bridgewater.com",
  "timestamp": "2026-07-07T15:32:00Z",
  "nonce": "f8923bc789ade"
}
```

The verification CLI (`npx pp-gitlab-gate`) retrieves this payload from the PP backend, extracts the signature, and validates it locally using the public key pre-provisioned in the project's CI variables. If the signature fails verification or if any fields (commit SHA, project ID, environment) are modified post-authorization, the gate fails closed.

---

## 4. Fail-Closed Semantics & "Break-Glass" Escape Hatch

### Fail-Closed by Default
For production-associated branches and environments, the gate operates in strict fail-closed mode (`fail-mode: closed`). If the Permission Protocol API is unreachable due to a network partition, the deployment pipeline halts immediately.

### The Break-Glass Receipt Path
To prevent critical infrastructure blockages during unplanned PP downtime, we implement an auditable, time-boxed **Break-Glass Receipt**. This is our primary answer to developer resistance regarding fail-closed blocks:

1. **Trigger:** The developer cannot merge due to PP unavailability.
2. **Access:** A designated senior engineer or compliance officer (not the developer) executes a local CLI command to mint a local, time-boxed break-glass token:
   `npx pp-break-glass --project-id 998273 --duration 60m`
3. **Receipt Generation:** This command generates an Ed25519-signed local receipt flagged `break_glass: true` and records the identity of the person who minted it.
4. **Pipeline Execution:** The developer commits the break-glass token to the pipeline variables. The CI job detects the signed break-glass receipt, validates its expiration window, and allows the deploy to proceed.
5. **Auditing:** The moment PP connectivity is restored, the break-glass receipt is synchronized to the compliance ledger, generating a high-priority alert and a dedicated Action Replay page. This converts an outage into an audit-compliant, traceable event.

---

## 5. Codebase Self-Defense & Telemetry

Because the CI gate resides inside `.gitlab-ci.yml`, we must protect it from rogue or compromised AI agents attempting to bypass or delete the check.

### 1. GitLab Push Rules (Enterprise / Premium)
Configure GitLab Push Rules to reject any commit modifying `.gitlab-ci.yml` or files in the `.github/` or `deploy-gate/` paths unless approved by a designated member of the `security-owners` group.

### 2. CODEOWNERS Enforcement
Set `CODEOWNERS` rule:
`/.gitlab-ci.yml @security-team`
This ensures any modification to the pipeline configuration requires an explicit human review and approval from the security team, which an agent cannot bypass.

### 3. Change Telemetry
PP's backend subscribes to GitLab Merge Request and System Webhooks. If a Merge Request modifies `.gitlab-ci.yml` or removes the PP status check job, PP immediately flags the MR as "compromised" on the compliance owner's dashboard and posts an alert to the security channel. The modification is treated as a severe security drift event.

---

## 6. On-Premises single-Tenant Topology

To satisfy Bridgewater's strict network isolation requirements, the connector supports a fully on-premises deployment:

```
[Customer Secure VPC]
┌────────────────────────────────────────────────────────┐
│  GitLab Runner ──► npx pp-gitlab-gate                  │
│                         │                              │
│                         ▼                              │
│                [PP Local Agent]                        │
│                         │ (Outbound Only)              │
│                         ▼                              │
│                 [PP Cloud / Edge]                      │
└────────────────────────────────────────────────────────┘
```

1. **Outbound-Only Connectivity:** The local PP agent inside the customer VPC communicates with the PP Cloud control plane via outbound-only HTTPS requests. No inbound ports are opened on the customer firewall.
2. **Data Residency:** All private data (such as code metadata or developer usernames) is hashed locally before transmission. The raw code never leaves the customer boundary.
3. **Air-Gapped Limitations:** In a fully air-gapped environment (no internet access), PP can be deployed as an on-prem Docker container. However, email/Slack approval routing defaults to local corporate SMTP or webhooks.

---

## 7. Microsoft Entra ID SSO Integration

Signer identity mapping is enforced through OpenID Connect (OIDC).
* **Identity Token exchange:** When a human clicks "Approve" on the PP mobile or web console, PP exchanges the active session's authentication token with Microsoft Entra ID.
* **Identity Injection:** The Entra-verified email address (e.g., `santi.weight@bridgewater.com`) is injected directly into the signature block of the Universal Action Receipt. This ensures the receipt carries legally binding, identity-provider-backed human attribution.

---

## 8. Two-Week Forward Deployed Engineer (FDE) Runbook

This runbook outlines the day-by-day roadmap for our FDE to execute a complete on-prem installation at Bridgewater in under two weeks:

* **Day 1–2: Network & Environment Provisioning**
  - Verify VPC boundaries, open outbound proxy ports, and set up the on-prem PP container.
* **Day 3–4: Entra ID Integration**
  - Configure OIDC/SAML application registration in Entra ID; map compliance groups to PP role-based access.
* **Day 5–7: GitLab Pipeline Integration**
  - Integrate `npx pp-gitlab-gate` into the target pilot repository's merge pipelines; configure `CODEOWNERS` and push rules.
* **Day 8–9: "Observe Mode" Rollout**
  - Run the gate in `fail-mode: open` (Observe Mode) for 48 hours to collect baseline telemetry and verify webhook delivery.
* **Day 10–11: Fail-Closed Enforcement Activation**
  - Activate `fail-mode: closed` on the production branch; run verification tests.
* **Day 12: Break-Glass Validation & Chaos Testing**
  - Simulate a complete PP API outage; verify the break-glass receipt path allows safe releases while generating alerts.
* **Day 13–14: Handover & Training**
  - Walk the compliance and platform engineering teams through the Portfolio Agent Risk Report and hand over operational runbooks.

---

## 9. Testing & Quality Assurance Plan

1. **Unit Testing:** Verify the Ed25519 verification logic against mock Git metadata and simulated receipt inputs.
2. **GitLab Integration Testing:** Spin up a local GitLab self-managed instance in Docker and run MR pipelines to verify successful receipt checks.
3. **Chaos Outage Simulation:** Run an automated pipeline merge train, simulate a PP API crash mid-run, and verify that production deploys successfully block (fail-closed) while staging deploys fail-open (if configured). Verify that the break-glass CLI successfully bypasses the block and logs the event.
