import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import assert from 'node:assert/strict';

const root = fileURLToPath(new URL('..', import.meta.url));
const script = join(root, 'scripts', 'run-claude.mjs');
const loader = join(root, 'tests', 'run-claude-loader.mjs');

function runClaude({ scenario = 'text', prompt = 'test prompt' } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'run-claude-'));
  const promptFile = join(dir, 'prompt.txt');
  const outputFile = join(dir, 'output.txt');
  writeFileSync(promptFile, prompt);
  const result = spawnSync(process.execPath, ['--experimental-loader', loader, script, promptFile], {
    env: { ...process.env, MOCK_CLAUDE_SCENARIO: scenario, CLAUDE_OUTPUT_FILE: outputFile },
    encoding: 'utf8',
  });
  return { ...result, output: readFileSync(outputFile, 'utf8') };
}

test('missing prompt-file argument prints usage and exits 1', () => {
  const result = spawnSync(process.execPath, [script], { encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Usage: run-claude\.mjs <prompt-file>/);
});

test('streams text deltas and writes accumulated output', () => {
  const result = runClaude();
  assert.equal(result.status, 0);
  assert.equal(result.stdout, 'hello world');
  assert.equal(result.output, 'hello world');
});

test('logs tool-use blocks while streaming output', () => {
  const result = runClaude({ scenario: 'tool' });
  assert.equal(result.status, 0);
  assert.match(result.stdout, /\n\[Bash\] \{\n  "command": "ls"\n\}/);
  assert.equal(result.output, 'hello world');
});

test('non-success result exits 1 and writes output', () => {
  const result = runClaude({ scenario: 'failure' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Agent ended with subtype: error/);
  assert.equal(result.output, 'hello world');
});

test('thrown query error exits 1 and still writes output', () => {
  const result = runClaude({ scenario: 'throw' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Error: mock failure/);
  assert.equal(result.output, '');
});
