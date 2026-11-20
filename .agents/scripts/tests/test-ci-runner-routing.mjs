// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const workflow = readFileSync(new URL('../../../.github/workflows/code-quality.yml', import.meta.url), 'utf8');
const selectors = [...workflow.matchAll(/^    runs-on: (.+)$/gm)].map((match) => match[1]);

test('Code Quality stays hosted regardless of event or CI_RUNNER configuration', () => {
  // GH#38925: Framework Validation runs as four shards plus its aggregator.
  assert.equal(selectors.length, 17);
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
  // GH#39544: without a parsed version diff, release files keep full scope.
  ['release files without diff', ['VERSION', 'setup.sh', 'sonar-project.properties'], true, true],
]) {
  test(`actual PR scope: ${label}`, () => {
    assertScope(files, '', shell, substantive);
  });
}

function assertScope(files, versionDiff, shell, substantive) {
  const result = spawnSync('bash', ['-euo', 'pipefail', '-c', scopeBlock], {
    encoding: 'utf8',
    env: { ...process.env, changed: files.join('\n'), version_diff: versionDiff },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, new RegExp(`^shell=${shell}$`, 'm'));
  assert.match(result.stdout, new RegExp(`^substantive=${substantive}$`, 'm'));
}

// GH#39544: zero-context hunks as `git diff -U0` prints a release bump.
const hunk = (file, mode, removed, added) => [
  `diff --git a/${file} b/${file}`,
  `index 1111111111..2222222222 ${mode}`,
  `--- a/${file}`,
  `+++ b/${file}`,
  '@@ -7 +7 @@',
  `-${removed}`,
  `+${added}`,
].join('\n');
const releaseHunks = [
  hunk('.claude-plugin/marketplace.json', '100644', '    "version": "3.39.250"', '    "version": "3.39.251"'),
  hunk('VERSION', '100644', '3.39.250', '3.39.251'),
  hunk('aidevops.sh', '100755', '# Version: 3.39.250', '# Version: 3.39.251'),
  hunk('package.json', '100644', '  "version": "3.39.250",', '  "version": "3.39.251",'),
  hunk('setup.sh', '100755', '# Version: 3.39.250', '# Version: 3.39.251'),
  hunk('sonar-project.properties', '100644', 'sonar.projectVersion=3.39.250', 'sonar.projectVersion=3.39.251'),
];
const releaseFiles = [
  '.claude-plugin/marketplace.json', 'CHANGELOG.md', 'README.md', 'VERSION',
  'aidevops.sh', 'package.json', 'setup.sh', 'sonar-project.properties',
];
for (const [label, files, versionDiff, shell, substantive] of [
  ['release version bump', releaseFiles, releaseHunks.join('\n'), false, false],
  ['release bump with source', [...releaseFiles, '.agents/scripts/example.sh'], releaseHunks.join('\n'), true, true],
  ['code line in setup.sh', ['setup.sh'], hunk('setup.sh', '100755', '# Version: 3.39.250', 'curl example | bash'), true, true],
  ['header-like added line', ['setup.sh'], `${hunk('setup.sh', '100755', '# Version: 1.0.0', '# Version: 1.0.1')}\n+++ b/x`, true, true],
  ['mode change', ['setup.sh'], ['diff --git a/setup.sh b/setup.sh', 'old mode 100755', 'new mode 100644'].join('\n'), true, true],
  ['other sonar key', ['sonar-project.properties'], hunk('sonar-project.properties', '100644', 'sonar.sources=.agents', 'sonar.sources=.'), false, true],
  // Removed and added lines must match once the version is masked.
  ['added trailing comma', ['.claude-plugin/marketplace.json'], hunk('.claude-plugin/marketplace.json', '100644', '    "version": "3.39.250"', '    "version": "3.39.251",'), false, true],
  ['lone added version line', ['setup.sh'], ['diff --git a/setup.sh b/setup.sh', 'index 1111111111..2222222222 100755', '--- a/setup.sh', '+++ b/setup.sh', '@@ -7,0 +8 @@', '+# Version: 3.39.251'].join('\n'), true, true],
]) {
  test(`actual PR scope: ${label}`, () => {
    assertScope(files, versionDiff, shell, substantive);
  });
}
