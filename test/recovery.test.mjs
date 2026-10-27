import { test } from 'node:test';
import assert from 'node:assert/strict';
import { recoveryPolicy, recoveryRecord, validateRecord, prepareRetry, submitRetry, submissionName } from '../scripts/deployment-recovery.mjs';
const now = Date.parse('2026-10-27T16:00:00Z');
const repository = 'example/client';
const sha = 'a'.repeat(40);
const policy = recoveryPolicy({ PP_RECOVERY_WORKFLOW_PATH: '.github/workflows/deploy.yml', PP_RECOVERY_JOB: 'Deploy production',
  PP_RECOVERY_GATES: '["Verify permission"]', PP_RECOVERY_EFFECTS: '["Submit deployment"]' });
const run = { id: 41, run_attempt: 1, path: policy.workflow, head_branch: 'main', head_repository: { full_name: repository },
  head_sha: sha, created_at: new Date(now - 3_600_000).toISOString(), event: 'push', status: 'completed', conclusion: 'failure' };
const record = { ...recoveryRecord({ GITHUB_REPOSITORY: repository, GITHUB_SHA: sha, GITHUB_RUN_ID: '41', GITHUB_RUN_ATTEMPT: '1',
  PP_RECOVERY_SAFE: 'true', PP_RECOVERY_REASON: 'provider_unavailable', PP_RECOVERY_WORKFLOW_REF: 'example/client/.github/workflows/deploy.yml@refs/heads/main' }, now - 600_000) };
function fixture() {
  const state = { run: { ...run }, journals: [], submitted: 0, missingExecutionStep: false };
  const api = async (path, options = {}) => {
    if (options.method === 'POST') { state.submitted++; return {}; }
    if (path.includes('/actions/workflows/')) return { workflow_runs: [state.run] };
    if (path.includes('/git/ref/')) return { object: { sha } };
    if (path.includes('/jobs?')) return { total_count: 1, jobs: [{ name: policy.job, status: 'completed', conclusion: 'failure',
      steps: [{ name: 'Verify permission', conclusion: 'failure' }, ...(state.missingExecutionStep ? [] : [{ name: 'Submit deployment', conclusion: 'skipped' }])] }] };
    if (path.includes('/actions/artifacts?')) return { total_count: state.journals.length, artifacts: state.journals };
    return state.run;
  };
  return { state, api };
}
test('resumes a customer workflow through its exact declared gate after a stopped wait', async () => {
  const { state, api } = fixture();
  assert.equal((await prepareRetry({ api, repository, policy, run, record, now })).state, 'ready');
  state.journals = [{ name: submissionName(run), expired: false, workflow_run: { id: 90 } }];
  assert.equal((await submitRetry({ api, repository, policy, run, record, now, journalRunId: 90 })).state, 'requested');
  assert.equal(state.submitted, 1);
});
test('never accepts a missing execution step or another attempt', async () => {
  const { state, api } = fixture(); state.missingExecutionStep = true;
  assert.equal((await prepareRetry({ api, repository, policy, run, record, now })).state, 'superseded_or_not_retryable');
  assert.equal(state.submitted, 0);
  assert.throws(() => validateRecord({ ...record, runAttempt: 2 }, run, repository, now, policy));
});
test('an existing submission is observed without replay after process restart', async () => {
  const { state, api } = fixture(); state.journals = [{ name: submissionName(run), expired: false, workflow_run: { id: 90 } }];
  assert.equal((await prepareRetry({ api, repository, policy, run, record, now })).state, 'observing_submission');
  await assert.rejects(submitRetry({ api, repository, policy, run, record, now, journalRunId: 91 }));
  assert.equal(state.submitted, 0);
});
test('requires an explicit, bounded deployment contract', () => {
  assert.throws(() => recoveryPolicy({ PP_RECOVERY_WORKFLOW_PATH: '../other.yml' }));
  assert.throws(() => recoveryPolicy({ PP_RECOVERY_EFFECTS: '[]' }));
  assert.throws(() => recoveryPolicy({ PP_RECOVERY_GATES: '["same","same"]' }));
  assert.throws(() => recoveryPolicy({ PP_RECOVERY_WORKFLOW_REF: 'attacker/file' }));
});
