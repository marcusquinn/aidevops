// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
// Run: node --test .agents/scripts/tests/test-higgsfield-common.mjs

import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import * as cli from '../higgsfield/higgsfield-cli.mjs';
import * as filesystem from '../higgsfield/higgsfield-filesystem.mjs';

test('CLI parsing retains aliases, integer values and compound/boolean flags', () => {
  const originalArgv = process.argv;
  try {
    process.argv = ['node', 'higgsfield', 'image', '-p', 'test prompt',
      '-b', '3', '--api-only', '--no-sound', '--enhance', '--unknown'];
    assert.deepEqual(cli.parseArgs(), {
      command: 'image',
      options: {
        prompt: 'test prompt', batch: 3, useApi: true, apiOnly: true,
        sound: false, enhance: true,
      },
    });
  } finally {
    process.argv = originalArgv;
  }
});

test('filesystem helpers preserve selection by extension, timestamp and name', () => {
  const root = mkdtempSync(join(tmpdir(), 'higgsfield-common-'));
  try {
    const dir = join(root, 'nested', 'assets');
    assert.equal(filesystem.ensureDir(dir), dir);
    assert.equal(filesystem.ensureDir(dir), dir);
    for (const [name, time] of [['scene-old.png', 1000], ['scene-new.JPG', 2000],
      ['other.webp', 3000], ['ignored.txt', 4000]]) {
      const path = join(dir, name);
      writeFileSync(path, name);
      utimesSync(path, time, time);
    }
    assert.equal(filesystem.findNewestFile(dir), join(dir, 'other.webp'));
    assert.equal(filesystem.findNewestFileMatching(dir, ['png', '.jpg'], 'scene'),
      join(dir, 'scene-new.JPG'));
    assert.equal(filesystem.findNewestFileMatching(dir, ['png'], 'absent'), null);
    assert.equal(filesystem.findNewestFile(join(root, 'missing')), null);
    assert.equal(filesystem.sanitizePathSegment('/folder/test file.png'), 'test-file.png');
    assert.equal(filesystem.sanitizePathSegment('!!!', 'fallback'), 'fallback');
    assert.equal(filesystem.safeJoin('/base/', '\\nested\\', '/file.png'),
      '/base/nested/file.png');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
