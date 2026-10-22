// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

// Match the existing self-test bootstrap order for the common/browser cycle.
await import('../higgsfield/higgsfield-browser.mjs');
const image = await import('../higgsfield/higgsfield-image.mjs');
const options = await import('../higgsfield/higgsfield-image-options.mjs');
const { pipelineAssemble } = await import('../higgsfield/higgsfield-pipeline-assembly.mjs');

test('image option extraction preserves public re-export identity', () => {
  for (const name of ['configureImageOptions', 'setAspectRatio', 'setEnhanceToggle']) {
    assert.equal(typeof options[name], 'function');
    assert.equal(image[name], options[name]);
  }
});

test('empty image options and out-of-range batches do not access the page', async () => {
  await options.configureImageOptions(null, {});
  await options.configureImageOptions(null, { batch: 0 });
  await options.configureImageOptions(null, { batch: 5 });
});

test('assembly records an empty-clip failure without changing prior steps', () => {
  const previousStep = { step: 'video', success: false };
  const state = { steps: [previousStep] };
  pipelineAssemble({}, [], null, state);
  assert.deepEqual(state.steps, [
    previousStep,
    { step: 'assembly', success: false, reason: 'no valid clips' },
  ]);
});

test('single-scene assembly copies bytes and records the sanitized final path', (t) => {
  const parent = process.env.AIDEVOPS_TEMP_DIR
    || join(homedir(), '.aidevops', '.agent-workspace', 'tmp');
  const directory = mkdtempSync(join(parent, 'higgsfield-extraction-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const source = join(directory, 'scene.mp4');
  const finalPath = join(directory, 'example-title-final.mp4');
  const content = Buffer.from('single-scene copy requires no renderer');
  writeFileSync(source, content);
  const state = { steps: [] };

  pipelineAssemble({ title: 'Example Title' }, [source], directory, state);

  assert.deepEqual(readFileSync(finalPath), content);
  assert.deepEqual(readFileSync(source), content);
  assert.deepEqual(state.steps, [
    { step: 'assembly', success: true, method: 'copy', path: finalPath },
  ]);
});
