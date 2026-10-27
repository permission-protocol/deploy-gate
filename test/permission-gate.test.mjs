import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
const repoRoot = fileURLToPath(new URL('../', import.meta.url));
const published = '214e1de8d966e1b757b172f6d0fae41620307e15';
const workflow = readFileSync(join(repoRoot, '.github/workflows/deploy-gate.yml'), 'utf8').replaceAll('\r\n', '\n');
const marker = "          python3 - <<'PY'\n";
const bootstrap = workflow.split(marker)[1]?.split('          PY')[0]?.split('\n').map(line => line.startsWith('          ') ? line.slice(10) : line).join('\n');
const release = execFileSync('git', ['show', `${published}:action.yml`], { cwd: repoRoot });
function normalize(bytes) {
  const root = mkdtempSync(join(tmpdir(), 'pp-trusted-gate-'));
  try {
    mkdirSync(join(root, '.pp-gate-client')); const path = join(root, '.pp-gate-client/action.yml'); writeFileSync(path, bytes);
    const result = spawnSync(process.platform === 'win32' ? 'python' : 'python3', ['-c', bootstrap], { cwd: root, encoding: 'utf8' });
    return { ...result, normalized: readFileSync(path, 'utf8') };
  } finally { rmSync(root, { recursive: true, force: true }); }
}
test('a long composite shell step has no GitHub expressions to exceed the parser limit', () => {
  const source = readFileSync(join(repoRoot, 'action.yml'), 'utf8');
  const script = source.split('      run: |')[1].split('\n    - ')[0];
  assert.ok(script.length <= 21_000 || !script.includes('$' + '{{'), 'large shell bodies cannot be compiled as inline expressions');
  assert.match(source, /PP_REPOSITORY: \$\{\{ github\.repository \}\}/);
  assert.match(source, /GH_TOKEN: \$\{\{ github\.token \}\}/);
});
test('the approval job uses immutable released code and still requires the same PP gate', () => {
  assert.ok(workflow.includes(`ref: ${published}`));
  assert.match(workflow, /repository: permission-protocol\/deploy-gate/);
  assert.match(workflow, /persist-credentials: false/);
  assert.match(workflow, /uses: \.\/\.pp-gate-client/);
  assert.match(workflow, /fail-on-missing: 'true'/);
  assert.match(workflow, /fail-mode: 'closed'/);
  assert.match(workflow, /capability: 'deploy:main'/);
  assert.match(workflow, /ready_for_review/);
  assert.ok(!workflow.includes('uses: ./\n'), 'candidate Action must not bootstrap its own approval');
});
test('published code normalization changes only six equivalent shell env interpolations', () => {
  assert.ok(bootstrap); assert.equal(createHash('sha256').update(release).digest('hex'), 'fb245151187c4e7cdc4e42607f4e1ee52ef6da81e8d060020456be8dfd310e6d');
  const result = normalize(release); assert.equal(result.status, 0, result.stderr);
  const source = release.toString('utf8'); const at = source.indexOf('      run: |\n') + '      run: |\n'.length;
  const expected = source.slice(0, at) + source.slice(at).replaceAll('$' + '{{ github.repository }}', '${PP_REPOSITORY}').replaceAll('$' + '{{ github.token }}', '${GH_TOKEN}');
  assert.equal(result.normalized.replaceAll('\r\n', '\n'), expected);
});
test('a changed published client is refused before normalization', () => {
  const changed = Buffer.concat([release, Buffer.from('\n# altered\n')]); const result = normalize(changed);
  assert.notEqual(result.status, 0); assert.match(result.stderr, /identity could not be established/);
  assert.equal(result.normalized, changed.toString('utf8'));
});
