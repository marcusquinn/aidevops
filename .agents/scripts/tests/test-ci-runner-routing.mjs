// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const workflow = readFileSync(new URL('../../../.github/workflows/code-quality.yml', import.meta.url), 'utf8');
const selectors = [...workflow.matchAll(/^    runs-on: (.+)$/gm)].map((match) => match[1]);
const guarded = selectors.filter((selector) => selector.startsWith('${{'));
const repository = 'marcusquinn/aidevops';
const pool = 'aidevops-public-ephemeral';

function context(eventName, { ref = 'refs/pull/1/merge', fork = false, fullName = repository } = {}) {
  return {
    github: {
      repository,
      event_name: eventName,
      ref,
      event: { pull_request: { head: { repo: { fork, full_name: fullName } } } },
    },
    vars: { CI_RUNNER: pool },
    matrix: { os: 'ubuntu-latest' },
  };
}

// These expressions use only the Actions/JavaScript common boolean subset.
// Use loose equality just as Actions does: missing/null fork metadata must
// not be accepted via Actions' null == false numeric coercion.
function selectRunner(selector, values) {
  const expression = selector.slice(3, -2);
  return runInNewContext(expression, { ...values, toJSON: (value) => JSON.stringify(value ?? null) }, { timeout: 100 });
}

test('every eligible Code Quality job is guarded; platform-specific verifier stays hosted', () => {
  assert.equal(selectors.length, 12);
  assert.equal(guarded.length, 11);
  assert.deepEqual(selectors.filter((selector) => !selector.startsWith('${{')), ['ubuntu-22.04']);
  assert.match(workflow, /name: ShellCheck \(\$\{\{ matrix\.os \}\}\)/);
  assert.match(workflow, /os: \[ubuntu-latest\]/);
});

for (const [index, selector] of guarded.entries()) {
  test(`runner selector ${index + 1}: trust boundary and hosted fallback`, () => {
    assert.equal(selectRunner(selector, context('push', { ref: 'refs/heads/main' })), pool);
    assert.equal(selectRunner(selector, context('pull_request')), pool);

    const denied = [
      context('push', { ref: 'refs/heads/develop' }),
      context('push', { ref: 'refs/tags/v1' }),
      context('pull_request', { fork: true, fullName: 'outside/fork' }),
      context('pull_request', { fork: true }),
      context('pull_request', { fullName: 'outside/fork' }),
      context('pull_request', { fork: null }),
      context('pull_request', { fork: 0 }),
      context('pull_request', { fork: '' }),
      context('pull_request', { fork: 'false' }),
      context('pull_request_target'),
      context('workflow_run'),
      context('workflow_dispatch'),
      context('schedule'),
      context('issues'),
      context('issue_comment'),
    ];
    // Destructuring defaults replace undefined; explicitly remove the property.
    const missingFork = context('pull_request');
    delete missingFork.github.event.pull_request.head.repo.fork;
    denied.push(missingFork);
    const missingName = context('pull_request');
    delete missingName.github.event.pull_request.head.repo.full_name;
    denied.push(missingName);
    for (const values of denied) {
      assert.equal(selectRunner(selector, values), 'ubuntu-latest', JSON.stringify(values.github));
    }

    const noPool = context('pull_request');
    noPool.vars.CI_RUNNER = '';
    assert.equal(selectRunner(selector, noPool), 'ubuntu-latest');
    const ordinaryPush = context('push', { ref: 'refs/heads/main' });
    ordinaryPush.github.event = {};
    assert.equal(selectRunner(selector, ordinaryPush), pool);
  });
}
