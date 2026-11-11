// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// GH#33986: retain bounded CI hangs without weakening replay verification.
// Run: node .agents/scripts/tests/test-ci-workflow-timeouts.mjs

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import yaml from 'js-yaml';

const workflows = new URL('../../../.github/workflows/', import.meta.url);
const quality = yaml.load(readFileSync(new URL('code-quality.yml', workflows), 'utf8'));
const monitoring = yaml.load(readFileSync(new URL('code-review-monitoring.yml', workflows), 'utf8'));

const replayJob = quality.jobs['model-replay-linux'];
assert.equal(replayJob['timeout-minutes'], 20, 'Replay job must stop after 20 minutes');
assert.equal(replayJob['runs-on'], 'ubuntu-22.04', 'Keep the enforcing Bubblewrap runner');

const installStep = replayJob.steps.find(step => step.name === 'Install Bubblewrap');
assert.ok(installStep, 'Keep the Bubblewrap installation step');
assert.equal(installStep['timeout-minutes'], 8, 'Bubblewrap installation must stop after 8 minutes');
assert.match(
  installStep.run,
  /sudo timeout --kill-after=5s 60s apt-get install -y bubblewrap/,
  'Keep sandbox installation with a root-owned hard deadline',
);
assert.match(
  installStep.run,
  /sudo timeout --kill-after=5s 60s apt-get update -qq -o APT::Update::Error-Mode=any/,
  'Bound index refresh and reject incomplete updates before installation',
);
assert.match(installStep.run, /for attempt in 1 2 3; do/, 'Keep retries within the step budget');
assert.ok(3 * (65 + 65 + 5) < installStep['timeout-minutes'] * 60);
assert.match(
  installStep.run,
  /sudo sed -i '\/azure\[\.\]archive\[\.\]ubuntu\[\.\]com\/d' \/etc\/apt\/apt-mirrors\.txt/,
  'Use the runner-provided Ubuntu fallbacks instead of the failing Azure mirror',
);

const replayStep = replayJob.steps.find(step => step.name === 'Run model replay boundary suite');
assert.ok(replayStep, 'Keep the replay boundary suite step');
assert.equal(replayStep.run, 'node .agents/scripts/tests/test-model-replay-benchmark.mjs');

assert.equal(
  monitoring.jobs['code-review-monitoring']['timeout-minutes'],
  30,
  'Review monitoring must stop after 30 minutes',
);

console.log('PASS CI workflow timeout regression (20/8/30 minutes and replay boundary retained)');
