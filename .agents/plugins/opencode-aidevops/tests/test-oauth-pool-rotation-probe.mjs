// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync,
  statSync, symlinkSync, writeFileSync, existsSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const plugin = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const scripts = resolve(plugin, "../../scripts");
const moduleNames = ["provider-auth.mjs", "provider-auth-pool.mjs", "provider-auth-pool-recovery.mjs"];

function fixture(t) {
  const temp = process.env.AIDEVOPS_TEMP_DIR || join(homedir(), ".aidevops/.agent-workspace/tmp");
  mkdirSync(temp, { recursive: true });
  const root = mkdtempSync(join(temp, "rotation-probe-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const installed = join(root, "installed");
  const runtime = join(root, "runtime-bundle");
  mkdirSync(join(installed, "scripts"), { recursive: true });
  mkdirSync(join(installed, "plugins"));
  mkdirSync(runtime);
  // Only this controlled fixture copies sources to induce dependency mismatches.
  // The production probe always reads the actual sibling installation.
  for (const name of moduleNames) copyFileSync(join(plugin, name), join(runtime, name));
  symlinkSync(runtime, join(installed, "plugins/opencode-aidevops"), "dir");
  for (const name of ["oauth-pool-rotation-probe.mjs", "oauth-pool-helper.sh", "oauth-pool-add.sh", "oauth-pool-manage.sh", "oauth-pool-diagnose.sh"]) {
    copyFileSync(join(scripts, name), join(installed, "scripts", name));
  }
  const home = join(root, "home");
  mkdirSync(join(home, ".aidevops"), { recursive: true });
  mkdirSync(join(home, ".local/share/opencode"), { recursive: true });
  const pool = join(home, ".aidevops/oauth-pool.json");
  const auth = join(home, ".local/share/opencode/auth.json");
  for (const path of [pool, auth]) writeFileSync(path, "dummy sentinel, never credentials", { mode: 0o600 });
  const marker = join(root, "unexpected-side-effect");
  // A real storage import, NODE_OPTIONS preload, or Claude version subprocess
  // would leave this marker. None is permitted on the offline shell path.
  const trap = `import { writeFileSync } from 'node:fs'; writeFileSync(${JSON.stringify(marker)}, 'unexpected'); throw Error('trap');`;
  writeFileSync(join(runtime, "oauth-pool.mjs"), trap);
  writeFileSync(join(runtime, "provider-auth-request.mjs"), trap);
  const preload = join(root, "preload.mjs");
  writeFileSync(preload, trap);
  const bin = join(root, "bin");
  mkdirSync(bin);
  writeFileSync(join(bin, "claude"), `#!/bin/sh\ntouch '${marker}'\nexit 1\n`, { mode: 0o700 });
  return {
    root, runtime, pool, auth, marker, preload,
    script: join(installed, "scripts/oauth-pool-rotation-probe.mjs"),
    shell: join(installed, "scripts/oauth-pool-helper.sh"),
    env: {
      PATH: `${bin}:${process.env.PATH}`, HOME: home,
      XDG_DATA_HOME: join(home, ".local/share"), AIDEVOPS_OAUTH_POOL_FILE: pool,
    },
  };
}

function snapshot(path) {
  const contents = readFileSync(path, "utf8");
  const { mode, size, mtimeMs, ctimeMs, atimeMs } = statSync(path);
  return { contents, mode, size, mtimeMs, ctimeMs, atimeMs };
}

function run(f, args = ["probe-rotation", "anthropic"]) {
  return spawnSync("bash", [f.shell, ...args], {
    env: { ...f.env, NODE_OPTIONS: `--import=${f.preload}` },
    encoding: "utf8", timeout: 15000,
  });
}

test("offline shell command passes through symlink deployment and preserves sentinel stores", t => {
  const f = fixture(t);
  const before = [snapshot(f.pool), snapshot(f.auth)];
  const result = run(f);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.match(result.stdout, /OFFLINE \/ SIMULATED/);
  assert.match(result.stdout, /not live end-to-end failover/);
  assert.equal(result.stdout.match(/^PASS .*:/gm)?.length, 18);
  assert.match(result.stdout, /PASS overall/);
  // Check metadata before reading again, so the assertion itself cannot hide access.
  for (const [index, path] of [f.pool, f.auth].entries()) {
    const { mode, size, mtimeMs, ctimeMs, atimeMs } = statSync(path);
    assert.deepEqual({ mode, size, mtimeMs, ctimeMs, atimeMs }, {
      mode: before[index].mode, size: before[index].size, mtimeMs: before[index].mtimeMs,
      ctimeMs: before[index].ctimeMs, atimeMs: before[index].atimeMs,
    });
    assert.equal(readFileSync(path, "utf8"), before[index].contents);
  }
  assert.equal(existsSync(f.marker), false);
});

test("malformed and unsupported provider inputs fail without side effects", t => {
  const f = fixture(t);
  for (const args of [["probe-rotation"], ["probe-rotation", "openai"], ["probe-rotation", "anthropic", "extra"]]) {
    const result = run(f, args);
    assert.equal(result.status, 1, result.stderr);
    assert.match(result.stderr, /Usage:/);
  }
  assert.equal(existsSync(f.marker), false);
});

test("unexpected dependency specifiers fail closed before evaluation", t => {
  const f = fixture(t);
  const path = join(f.runtime, "provider-auth.mjs");
  const source = readFileSync(path, "utf8");
  for (const specifier of ["./oauth-pool-storage.mjs", "node:fs", "./nested/oauth-pool.mjs"]) {
    writeFileSync(path, `import ${JSON.stringify(specifier)};\n${source}`);
    const result = run(f);
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.doesNotMatch(result.stdout, /PASS overall/);
    assert.equal(existsSync(f.marker), false);
  }
});

test("dynamic import, missing module and outbound source symlink fail closed", t => {
  const f = fixture(t);
  const path = join(f.runtime, "provider-auth.mjs");
  const source = readFileSync(path, "utf8");
  writeFileSync(path, `await import('node:fs');\n${source}`);
  assert.equal(run(f).status, 1);
  rmSync(path);
  assert.equal(run(f).status, 1);
  symlinkSync(join(f.runtime, "oauth-pool.mjs"), path);
  // Same-directory trap still cannot import fs.
  assert.equal(run(f).status, 1);
  rmSync(path);
  symlinkSync(f.preload, path);
  assert.equal(run(f).status, 1);
  assert.equal(existsSync(f.marker), false);
});

test("unsupported VM API and stalled provider produce nonzero, bounded failures", t => {
  const f = fixture(t);
  const unsupported = spawnSync(process.execPath, [f.script, "--isolated", f.runtime], {
    env: {}, encoding: "utf8", timeout: 15000,
  });
  assert.equal(unsupported.status, 1);
  assert.match(unsupported.stderr, /Unsupported Node/);
  const path = join(f.runtime, "provider-auth.mjs");
  writeFileSync(path, `while (true) {}\n${readFileSync(path, "utf8")}`);
  const stalled = run(f);
  assert.equal(stalled.status, 1, stalled.stderr);
  assert.equal(stalled.error, undefined);
  assert.equal(existsSync(f.marker), false);
});
