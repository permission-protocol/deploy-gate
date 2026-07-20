# GitLab Enterprise Connector Implementation Issue Breakdown
**Date:** July 2026  
**Status:** DRAFT (Awaiting Rod Review)  

This document breaks down the GitLab Enterprise Deploy Gate connector development into five distinct, trackable engineering issues.

---

## Issue 1: Core CLI Verification Runner (`pp-gitlab-gate`)
* **Category:** Core CLI Engine
* **Title:** Build core Ed25519 CLI verification runner for GitLab CI jobs
* **Description:**  
  Develop the CLI verification utility (`npx pp-gitlab-gate`) that runs inside the GitLab CI/CD pipeline job. The utility must parse GitLab CI environment variables (e.g., `CI_COMMIT_SHA`, `CI_PROJECT_ID`, `CI_ENVIRONMENT_NAME`), retrieve the corresponding Universal Action Receipt (UAR) from the PP control plane, and perform local Ed25519 cryptographic signature verification.
* **Acceptance Criteria:**
  - Exits with `0` if a valid, verified receipt exists for the active commit SHA and environment.
  - Exits with `1` if no receipt exists, or if signature verification fails.
  - Correctly implements a 30-second timeout with fallback logic.

---

## Issue 2: GitLab Ultimate External Status Check Handler
* **Category:** Integration API
* **Title:** Implement External Status Check webhook handler for GitLab Ultimate
* **Description:**  
  Build a dedicated webhook handler endpoint in our API backend (`/api/gitlab/status-check`) to support GitLab Ultimate's External Status Check feature. When GitLab posts an MR update event, PP must evaluate policy, determine if human approval is required, hold the status, and post a `passed` or `failed` status back to GitLab's external checks API once a signer makes a decision.
* **Acceptance Criteria:**
  - Correctly parses the GitLab External Status Check payload.
  - Securely validates GitLab webhook secret tokens.
  - Accurately reports status transitions back to GitLab's API.

---

## Issue 3: Local "Break-Glass" CLI & Verification Logic
* **Category:** Resilience / Security
* **Title:** Build local break-glass token minter and verification pipeline
* **Description:**  
  Implement the local break-glass escape hatch to prevent deployment blocks during PP control plane outages. Develop `npx pp-break-glass` to generate a locally signed, time-boxed token using a pre-shared master key, and update `pp-gitlab-gate` to accept and verify this local break-glass token.
* **Acceptance Criteria:**
  - Mints an Ed25519 token bound to project ID and an expiration window (max 120 minutes).
  - Verification CLI successfully parses and validates the local break-glass token without calling the external PP API.
  - Generates a local, signed artifact that can be synchronized back to the central compliance ledger once connectivity is restored.

---

## Issue 4: Microsoft Entra ID OIDC Authentication Provider
* **Category:** Identity & Auth
* **Title:** Integrate Microsoft Entra ID OIDC for human signature verification
* **Description:**  
  Add support for Microsoft Entra ID (formerly Azure AD) as an enterprise identity provider. Configure PP's web and mobile approval consoles to authenticate users via OIDC, retrieve verified email claims, and inject the authenticated identity into the signed Universal Action Receipt.
* **Acceptance Criteria:**
  - Successfully executes OIDC authorization code flow with Microsoft Entra ID.
  - Extracts the verified user email and injects it into the receipt's metadata block.
  - Blocks approval actions if the active session lacks a valid Entra ID token.

---

## Issue 5: Self-Defense Policy & Configuration Drift Telemetry
* **Category:** Threat Protection / Telemetry
* **Title:** Implement webhook monitors for pipeline tamper detection
* **Description:**  
  Develop backend listeners for GitLab MR and system webhooks to detect unauthorized configuration changes. If an MR modifies `.gitlab-ci.yml` or bypasses the `pp-gitlab-gate` job block, the backend must flag the MR and dispatch an immediate security alert.
* **Acceptance Criteria:**
  - Identifies file-path modifications touching `.gitlab-ci.yml` or project approval rules.
  - Generates compliance alerts on the master dashboard within 5 seconds of the webhook event.
  - Successfully tracks and logs pipeline status changes to the compliance ledger.
