import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const WORKFLOW = '.github/workflows/production-deploy.yml';
export const DEFAULT_POLICY = { workflow: WORKFLOW, branch: 'main', job: 'Detect Risk Level + Deploy',
  gates: ['Verify + Redeem Earlier Changes (Restricted)', 'Verify + Redeem Permission (Restricted)'],
  effects: ['Trigger Render Deploy', 'Trigger worker deploy'] };
function workflowPath(env) {
  const ref = env.PP_RECOVERY_WORKFLOW_REF?.match(/^[\w.-]+\/[\w.-]+\/(\.github\/workflows\/[\w.-]+\.ya?ml)@refs\/heads\/[\w./-]+$/);
  if (env.PP_RECOVERY_WORKFLOW_REF && !ref) throw new Error('The deployment workflow reference could not be validated.');
  const path = env.PP_RECOVERY_WORKFLOW_PATH || ref?.[1] || WORKFLOW;
  if (!/^\.github\/workflows\/[\w.-]+\.ya?ml$/.test(path)) throw new Error('The deployment workflow path could not be validated.');
  return path;
}
export function recoveryPolicy(env) {
  const policy = { workflow: workflowPath(env), branch: env.PP_RECOVERY_BRANCH || 'main',
    job: env.PP_RECOVERY_JOB || DEFAULT_POLICY.job,
    gates: env.PP_RECOVERY_GATES ? JSON.parse(env.PP_RECOVERY_GATES) : DEFAULT_POLICY.gates,
    effects: env.PP_RECOVERY_EFFECTS ? JSON.parse(env.PP_RECOVERY_EFFECTS) : DEFAULT_POLICY.effects };
  if (!/^\.github\/workflows\/[\w.-]+\.ya?ml$/.test(policy.workflow) || !/^[\w./-]+$/.test(policy.branch) ||
      policy.branch.includes('..') || policy.branch.startsWith('/') || policy.branch.endsWith('/') || policy.branch.includes('//') ||
      typeof policy.job !== 'string' || !policy.job || policy.job.length > 200 ||
      ![policy.gates, policy.effects].every(items => Array.isArray(items) && items.length > 0 && items.length <= 20 &&
        new Set(items).size === items.length && items.every(item => typeof item === 'string' && item.length > 0 && item.length <= 200 && !/[\r\n]/.test(item)))) {
    throw new Error('Recovery requires an explicit workflow, branch, job, gate and execution-step contract.');
  }
  const standard = policy.workflow === WORKFLOW && policy.job === DEFAULT_POLICY.job &&
    JSON.stringify(policy.gates) === JSON.stringify(DEFAULT_POLICY.gates) && JSON.stringify(policy.effects) === JSON.stringify(DEFAULT_POLICY.effects);
  if (policy.gates.length !== 1 && !standard) throw new Error('Multiple consuming gates require a reviewed continuation adapter; automatic recovery is disabled.');
  return policy;
}
export const RECORD_NAME = 'pp-deployment-recovery';
const MAX_AGE = 28 * 24 * 60 * 60_000;
const REASONS = new Set(['provider_unavailable', 'approval_wait']);
const numeric = value => typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
const same = (a, b) => Number(a) === Number(b);
export const artifactName = run => `${RECORD_NAME}-${run.id}-${run.run_attempt}-retry`;
export const submissionName = run => `pp-recovery-submission-${run.id}-${run.run_attempt}`;

/** An execution hint, never an approval. The original workflow rechecks every gate. */
export function recoveryRecord(env, now = Date.now()) {
  // The failed Action records identity only. The independent coordinator must
  // supply and validate its own reviewed job/gate/execution-step contract.
  const workflow = workflowPath(env);
  const reason = env.PP_RECOVERY_REASON;
  const retry = Date.parse(env.PP_RECOVERY_RETRY_AT ?? '');
  const safeToRetry = env.PP_RECOVERY_SAFE === 'true' && REASONS.has(reason);
  return { version: 1, repository: env.GITHUB_REPOSITORY, workflow,
    runId: Number(env.GITHUB_RUN_ID), runAttempt: Number(env.GITHUB_RUN_ATTEMPT),
    sha: env.GITHUB_SHA, safeToRetry, reason: safeToRetry ? reason : 'inspection_required',
    retryAt: new Date(Math.max(now + 5 * 60_000, Number.isFinite(retry) ? retry : 0)).toISOString(),
    recordedAt: new Date(now).toISOString() };
}

export function validateRun(run, repository, now = Date.now(), policy = DEFAULT_POLICY) {
  if (!run || !numeric(run.id) || !numeric(run.run_attempt) || run.head_branch !== policy.branch ||
      run.path !== policy.workflow || !['push', 'workflow_dispatch'].includes(run.event) ||
      run.head_repository?.full_name?.toLowerCase() !== repository.toLowerCase() ||
      !/^[a-f0-9]{40}$/.test(run.head_sha ?? '') || !Number.isFinite(Date.parse(run.created_at)) ||
      Date.parse(run.created_at) > now || now - Date.parse(run.created_at) > MAX_AGE) {
    throw new Error('Recovery refused: workflow identity or age could not be established.');
  }
  return run;
}

export function validateRecord(record, run, repository, now = Date.now(), policy = DEFAULT_POLICY) {
  validateRun(run, repository, now, policy);
  if (record?.version !== 1 || record.repository?.toLowerCase() !== repository.toLowerCase() ||
      !numeric(record.runId) || !numeric(record.runAttempt) ||
      record.workflow !== policy.workflow || !same(record.runId, run.id) || !same(record.runAttempt, run.run_attempt) ||
      record.sha !== run.head_sha || record.safeToRetry !== true || !REASONS.has(record.reason) ||
      !Number.isFinite(Date.parse(record.recordedAt)) || Date.parse(record.recordedAt) < Date.parse(run.created_at) ||
      Date.parse(record.recordedAt) > now + 60_000 || !Number.isFinite(Date.parse(record.retryAt))) {
    throw new Error('Recovery requires inspection: no matching, confirmed read-only failure was recorded.');
  }
  return Date.parse(record.retryAt) <= now;
}

/** No side effect is repeated based on an artifact alone. Re-read provider evidence. */
export async function currentCandidate(api, repository, expected, now = Date.now(), policy = DEFAULT_POLICY) {
  const root = `/repos/${repository}`;
  const listing = await api(`${root}/actions/workflows/${policy.workflow.split('/').pop()}/runs?per_page=1`);
  const latest = validateRun(listing.workflow_runs?.[0], repository, now, policy);
  if (expected && (!same(latest.id, expected.id) || !same(latest.run_attempt, expected.run_attempt) || latest.head_sha !== expected.head_sha)) return null;
  if (latest.status !== 'completed' || latest.conclusion !== 'failure') return null;
  const branch = await api(`${root}/git/ref/heads/${policy.branch}`);
  if (branch.object?.sha !== latest.head_sha) return null;
  const detail = validateRun(await api(`${root}/actions/runs/${latest.id}`), repository, now, policy);
  if (!same(detail.run_attempt, latest.run_attempt) || detail.head_sha !== latest.head_sha || detail.status !== 'completed' || detail.conclusion !== 'failure') return null;
  const jobs = await api(`${root}/actions/runs/${latest.id}/jobs?filter=latest&per_page=100`);
  if (!Array.isArray(jobs.jobs) || jobs.total_count !== 1 || jobs.jobs.length !== 1) return null;
  const job = jobs.jobs[0];
  if (job.name !== policy.job || job.status !== 'completed' || job.conclusion !== 'failure') return null;
  // Any own redemption or provider submission may already have executed.
  const forbidden = policy.effects;
  const steps = job.steps ?? [];
  if (![...policy.gates, ...policy.effects].every(name => steps.filter(step => step.name === name).length === 1)) return null;
  if (forbidden.some(name => steps.some(step => step.name === name && step.started_at && step.conclusion !== 'skipped'))) return null;
  const own = steps.find(step => step.name === policy.gates.at(-1));
  if (!own || own.conclusion === 'success' || !['failure', 'skipped'].includes(own.conclusion)) return null;
  const failedGate = steps.some(step => policy.gates.includes(step.name) && step.conclusion === 'failure');
  return failedGate ? latest : null;
}

export async function submissionState(api, repository, run) {
  const result = await api(`/repos/${repository}/actions/artifacts?name=${submissionName(run)}&per_page=100`);
  if (!Array.isArray(result.artifacts) || !Number.isInteger(result.total_count)) throw new Error('Recovery submission journal could not be read.');
  // Even an expired journal proves an attempt may have happened; absence is
  // only usable inside the shorter, bounded recovery retention window.
  return result.artifacts.filter(item => item.name === submissionName(run));
}

export async function prepareRetry({ api, repository, run, record, now = Date.now(), policy = DEFAULT_POLICY }) {
  const current = await currentCandidate(api, repository, run, now, policy);
  if (!current) return { state: 'superseded_or_not_retryable' };
  if (!validateRecord(record, current, repository, now, policy)) return { state: 'waiting', retryAt: record.retryAt };
  if ((await submissionState(api, repository, current)).length) return { state: 'observing_submission' };
  return { state: 'ready', run: current };
}

export async function submitRetry({ api, repository, run, record, journalRunId, now = Date.now(), policy = DEFAULT_POLICY }) {
  const current = await currentCandidate(api, repository, run, now, policy);
  if (!current || !validateRecord(record, current, repository, now, policy)) return { state: 'superseded_or_waiting' };
  const journals = await submissionState(api, repository, current);
  if (journals.length !== 1 || journals[0].expired || !same(journals[0].workflow_run?.id, journalRunId)) {
    throw new Error('Recovery requires its own durable submission journal before requesting a retry.');
  }
  // Exactly one POST. An exception remains journaled and is reconciled by
  // subsequent reads, never by another POST for the same original attempt.
  await api(`/repos/${repository}/actions/runs/${current.id}/rerun`, { method: 'POST' });
  return { state: 'requested', runId: current.id, runAttempt: current.run_attempt };
}

function save(path, data) { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, JSON.stringify(data)); }
function output(key, value) { if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `${key}=${value}\n`); }
function summary(message) { console.log(message); if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${message}\n`); }
async function main() {
  const policy = recoveryPolicy(process.env);
  const repository = process.env.GITHUB_REPOSITORY;
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository ?? '')) throw new Error('Invalid repository.');
  const root = '.pp-recovery';
  if (process.argv[2] === 'record') {
    const record = recoveryRecord(process.env);
    if (!numeric(record.runId) || !numeric(record.runAttempt) || !/^[a-f0-9]{40}$/.test(record.sha ?? '')) throw new Error('Invalid workflow identity.');
    save(`${root}/record/recovery.json`, record); output('safe', String(record.safeToRetry)); return;
  }
  const token = process.env.GH_TOKEN;
  if (!token) throw new Error('Recovery needs the repository workflow credential.');
  const api = async (path, options = {}) => {
    const response = await fetch(`https://api.github.com${path}`, { ...options, redirect: 'error', signal: AbortSignal.timeout(15_000),
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28' } });
    if (!response.ok) throw new Error(`GitHub recovery read or request refused (HTTP ${response.status}). No write is automatically replayed.`);
    return response.status === 204 || response.status === 201 ? {} : response.json();
  };
  if (process.argv[2] === 'inspect') {
    const run = await currentCandidate(api, repository, undefined, Date.now(), policy);
    if (!run) { summary('No newest, stopped approval wait is eligible for recovery.'); return; }
    const artifacts = await api(`/repos/${repository}/actions/runs/${run.id}/artifacts?per_page=100`);
    const matches = artifacts.artifacts?.filter(item => item.name === artifactName(run) && !item.expired);
    if (matches?.length !== 1) { summary('No matching recovery record. Inspect the failed deployment; no automatic retry was requested.'); return; }
    if ((await submissionState(api, repository, run)).length) {
      summary('A recovery submission is already recorded for this attempt. Observing GitHub; no second retry is sent. If no newer attempt appears, inspect the original recovery run.'); return;
    }
    save(`${root}/candidate.json`, run);
    output('run_id', String(run.id)); output('artifact_name', artifactName(run));
    return;
  }
  const run = JSON.parse(readFileSync(`${root}/candidate.json`, 'utf8'));
  const recordPath = `${root}/record/recovery.json`;
  if (!existsSync(recordPath) || readFileSync(recordPath).byteLength > 4096) throw new Error('Recovery record missing or oversized.');
  const record = JSON.parse(readFileSync(recordPath, 'utf8'));
  if (process.argv[2] === 'prepare') {
    const result = await prepareRetry({ api, repository, run, record, policy });
    summary(`Deployment recovery: ${result.state}${result.retryAt ? `; next check after ${result.retryAt}` : ''}.`);
    if (result.state === 'ready') {
      save(`${root}/submission/submission.json`, { repository, runId: run.id, runAttempt: run.run_attempt, sha: run.head_sha, coordinatorRunId: process.env.GITHUB_RUN_ID, createdAt: new Date().toISOString() });
      output('submit', 'true'); output('submission_name', submissionName(run));
    }
    return;
  }
  if (process.argv[2] !== 'submit') throw new Error('Unknown recovery command.');
  const result = await submitRetry({ api, repository, run, record, policy, journalRunId: process.env.GITHUB_RUN_ID });
  summary(`Deployment recovery: ${result.state}. The original workflow must verify every required approval again.`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
