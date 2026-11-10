// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const workflow = readFileSync(new URL('../../../.github/workflows/code-quality.yml', import.meta.url), 'utf8');
const selectors = [...workflow.matchAll(/^    runs-on: (.+)$/gm)].map((match) => match[1]);

test('Code Quality stays hosted regardless of event or CI_RUNNER configuration', () => {
  assert.equal(selectors.length, 12);
  for (const selector of selectors) {
    assert.ok(['ubuntu-latest', 'ubuntu-22.04', '${{ matrix.os }}'].includes(selector), selector);
  }
  assert.doesNotMatch(workflow, /vars\.CI_RUNNER|self-hosted/);
  assert.match(workflow, /name: ShellCheck \(\$\{\{ matrix\.os \}\}\)/);
  assert.match(workflow, /os: \[ubuntu-latest\]/);
  assert.match(workflow, /name: Model replay verifier boundary \(ubuntu-22\.04\)\n    runs-on: ubuntu-22\.04/);
});

// Execute the workflow's actual classification block, not a duplicated model.
// Redirect only the Actions output writes to stdout: Node's captured stdout may
// be a socket that cannot be reopened via /dev/stdout. No temp Git refs needed.
const scopeBlock = workflow
  .slice(workflow.indexOf("          printf 'Changed files:"), workflow.indexOf('  # Cross-platform shellcheck:'))
  .replaceAll('>> "$GITHUB_OUTPUT"', '>&1');
assert.ok(scopeBlock.includes('code_changed='));
for (const [label, files, shell, substantive] of [
  ['root docs', ['README.md', 'CHANGELOG.md'], false, false],
  ['nested docs', ['.agents/reference/ci-gate-policy.md', '.agents/scripts/README.md'], false, false],
  ['planning', ['TODO.md', 'todo/tasks/brief.json'], false, false],
  ['shell', ['.agents/scripts/example.sh'], true, true],
  ['workflow', ['.github/workflows/code-quality.yml'], true, true],
  ['Python', ['.agents/worker-lifecycle/example.py'], false, true],
  ['mixed docs and source', ['docs/guide.md', '.agents/scripts/example.sh'], true, true],
]) {
  test(`actual PR scope: ${label}`, () => {
    const result = spawnSync('bash', ['-euo', 'pipefail', '-c', scopeBlock], {
      encoding: 'utf8',
      env: { ...process.env, changed: files.join('\n') },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, new RegExp(`^shell=${shell}$`, 'm'));
    assert.match(result.stdout, new RegExp(`^substantive=${substantive}$`, 'm'));
  });
}
