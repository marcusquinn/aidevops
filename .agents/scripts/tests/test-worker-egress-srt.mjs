// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';
import { ENV_ADDED, ENV_ALLOWLIST, providerHost, settings, tightenMacCommand, tightenMacProfile } from '../worker-egress-srt/backend.mjs';

const scripts = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const backend = path.join(scripts, 'worker-egress-srt/backend.mjs');
const policy = {
  schema: 'aidevops.worker-egress-policy.v1', default_tier: 5,
  default_action: 'deny', raw_ip_action: 'deny', private_network_action: 'deny', loopback_action: 'deny',
  rules: [{ match: 'exact', pattern: 'api.openai.com', action: 'allow', tier: 1 }],
};

test('only the exact provider policy is accepted; every relaxation fails closed', () => {
  assert.equal(providerHost(policy), 'api.openai.com');
  for (const key of ['default_action', 'raw_ip_action', 'private_network_action', 'loopback_action']) {
    assert.throws(() => providerHost({ ...policy, [key]: 'allow' }));
  }
  for (const host of ['127.0.0.1', '2130706433', 'localhost', '*.openai.com', 'x.local',
    'api.openai.com:80', 'api.openai.com.', 'user@api.openai.com', 'api.openai.com;false']) {
    assert.throws(() => providerHost({ ...policy, rules: [{ ...policy.rules[0], pattern: host }] }));
  }
  assert.throws(() => providerHost({ ...policy, rules: [...policy.rules, ...policy.rules] }));
});

test('SRT policy locks ports, private space, Unix sockets, nesting, and filesystem defaults', () => {
  const config = settings('api.openai.com', { read: ['/nix/store/example'], write: ['/owned'],
    tools: { bwrap: '/nix/store/bwrap/bin/bwrap', socat: '/nix/store/socat/bin/socat', rg: '/nix/store/rg/bin/rg' } });
  assert.deepEqual(config.network.allowedDomains, ['api.openai.com:443']);
  assert.equal(config.network.strictAllowlist, true);
  assert.ok(config.network.deniedResolvedAddresses.includes('fc00::/7'));
  assert.ok(config.network.deniedResolvedAddresses.includes('10.0.0.0/8'));
  assert.equal(config.network.allowAllUnixSockets, false);
  assert.equal(config.allowNestedUserNamespaces, false);
  assert.equal(config.allowAppleEvents, false);
  assert.deepEqual(config.filesystem.denyRead, ['/']);
  assert.equal(config.bwrapPath, '/nix/store/bwrap/bin/bwrap');
});

test('macOS DNS guard must recognize exactly one pinned Seatbelt invocation', () => {
  assert.match(tightenMacCommand("env /usr/bin/sandbox-exec -p 'PROFILE' /bin/sh -c true"), /seatbelt -p/);
  assert.throws(() => tightenMacCommand('unexpected-upstream-rendering'));
  assert.throws(() => tightenMacCommand('/usr/bin/sandbox-exec -p x /usr/bin/sandbox-exec -p y'));
  const profile = tightenMacProfile('(version 1)\n(deny default)\n(allow mach-lookup\n (global-name "com.apple.system.opendirectoryd.libinfo"))\n(allow process-exec)');
  assert.doesNotMatch(profile, /allow mach-lookup/);
  assert.match(profile, /allow process-exec/);
  assert.throws(() => tightenMacProfile('(version 1)\n(deny default)\n(allow mach-lookup (unknown-filter "new"))'));
});

// GH#38861: Homebrew binaries load dylibs through /opt/homebrew/opt/<keg>
// symlinks. The envelope realpaths every entry, so it must list each runtime
// keg's Cellar directory plus the real /opt/homebrew/opt directory (which
// discloses only installed keg names, a maintainer-accepted exposure).
function homebrewClosure(tools) {
  const cellar = /^(.*)\/Cellar\/([^/]+)\/[^/]+\//;
  const formulae = [...new Set(tools.map(t => t.match(cellar)?.[2]).filter(Boolean))];
  if (process.platform !== 'darwin' || formulae.length === 0) return [];
  const prefix = tools.find(t => cellar.test(t)).match(cellar)[1];
  const deps = spawnSync('brew', ['deps', '--installed', '--union', ...formulae], { encoding: 'utf8' });
  assert.equal(deps.status, 0, 'brew deps failed: ' + deps.stderr);
  const kegs = [...formulae, ...deps.stdout.split('\n').filter(Boolean)];
  return [path.join(prefix, 'opt'), ...kegs.map(k => fs.realpathSync(path.join(prefix, 'opt', k)))];
}

test('real platform qualification (explicit opt-in, synthetic data, no provider contact)', {
  skip: process.env.AIDEVOPS_SRT_REAL_CHECK !== '1', timeout: 120000,
}, async () => {
  const temp = process.env.AIDEVOPS_TEMP_DIR || path.join(os.homedir(), '.aidevops/.agent-workspace/tmp');
  const root = fs.mkdtempSync(path.join(temp, 'srt-test-'));
  const output = path.join(root, 'output');
  fs.mkdirSync(output, { mode: 0o700 });
  const resolve = name => {
    for (const dir of process.env.PATH.split(path.delimiter)) {
      const candidate = path.join(dir, name);
      try { fs.accessSync(candidate, fs.constants.X_OK); return fs.realpathSync(candidate); } catch { /* keep looking */ }
    }
    throw new Error('missing tool: ' + name);
  };
  try {
    const tools = { shell: resolve('bash'), python: resolve('python3'), rg: resolve('rg'),
      coreutils: resolve('env'), procps: resolve('ps'), which: resolve('which') };
    if (process.platform === 'linux') {
      tools.bwrap = resolve('bwrap');
      tools.socat = process.env.AIDEVOPS_SRT_TEST_SOCAT || resolve('socat');
      tools.setsid = resolve('setsid');
    }
    const read = ['/usr', '/bin', '/lib', '/lib64', '/etc/ld.so.cache',
      ...(process.platform === 'darwin' ? ['/System/Library', '/Library/Apple/System/Library'] : []),
      path.join(scripts, 'worker-egress-srt/node_modules/@anthropic-ai/sandbox-runtime/vendor'),
      ...Object.values(tools)];
    // NixOS requires a reviewed executable closure, not the entire store.
    if (process.env.AIDEVOPS_SRT_TEST_READ) read.push(...JSON.parse(process.env.AIDEVOPS_SRT_TEST_READ));
    else read.push(...homebrewClosure(Object.values(tools)));
    const manifest = path.join(root, 'manifest.json');
    fs.writeFileSync(manifest, JSON.stringify({ schema: 'aidevops.srt-envelope.v1',
      cwd: output, read: read.filter(p => fs.existsSync(p)), write: [output], tools,
      timeoutSeconds: 3 }), { mode: 0o600 });
    const policyFile = path.join(root, 'policy.json');
    fs.writeFileSync(policyFile, JSON.stringify(policy), { mode: 0o600 });
    const invoke = args => spawnSync(process.execPath, [backend, ...args], {
      env: { ...process.env, AIDEVOPS_SRT_ENVELOPE: manifest }, encoding: 'utf8', timeout: 45000,
    });
    const probe = invoke(['probe', '--policy', policyFile]);
    if (process.platform === 'darwin' && process.arch !== 'arm64') {
      assert.equal(probe.status, 126);
      assert.equal(JSON.parse(probe.stdout).ready, false);
      assert.equal(JSON.parse(probe.stdout).reason, 'macos-x64-qualification-pending', probe.stderr);
      // This proves a deliberate qualification hold, not Intel Mac support.
      return;
    }
    assert.equal(probe.status, 0, probe.stdout + probe.stderr);
    const readiness = JSON.parse(probe.stdout);
    assert.equal(readiness.ready, true);
    assert.equal(readiness.qualification, 'synthetic-only');
    const run = invoke(['run', '--policy', policyFile, '--worker-id', 'synthetic-check', '--',
      tools.python, '-I', '-c', 'import sys; print(sys.argv[1])', 'a b;$(false)']);
    assert.equal(run.status, 0, run.stdout + run.stderr);
    assert.equal(run.stdout.trim(), 'a b;$(false)');
    // The supervisor exports framework constants; the workload must not see them.
    const envRun = invoke(['run', '--policy', policyFile, '--', tools.python, '-I', '-c',
      'import os,json; print(json.dumps(sorted(os.environ)))']);
    assert.equal(envRun.status, 0, envRun.stdout + envRun.stderr);
    const names = JSON.parse(envRun.stdout);
    const allowed = new Set([...ENV_ALLOWLIST, ...ENV_ADDED]);
    assert.deepEqual(names.filter(name => !allowed.has(name)), []);
    assert.ok(names.includes('PATH') && names.includes('HTTPS_PROXY'));
    const timed = invoke(['run', '--policy', policyFile, '--', tools.python,
      '-I', '-c', 'import time; time.sleep(120)']);
    assert.equal(timed.status, 124, timed.stdout + timed.stderr);
    // Cancellation after a detached synthetic child is running. The external
    // bounded-operation receipt separately records whether it drained leftovers;
    // this assertion alone proves exit handling, not absence of surviving PIDs.
    const cancellationRun = spawn(process.execPath, [backend, 'run', '--policy', policyFile,
      '--worker-id', 'synthetic-cancel', '--', tools.python, '-I', '-c',
      'import os,time; p=os.fork(); os.setsid() if p==0 else None; open("started-"+str(os.getpid()),"x").close(); time.sleep(120)'],
    { env: { ...process.env, AIDEVOPS_SRT_ENVELOPE: manifest }, stdio: 'ignore' });
    const exit = new Promise(resolve => cancellationRun.once('close', code => resolve(code)));
    const deadline = Date.now() + 15000;
    while (fs.readdirSync(output).filter(p => p.startsWith('started-')).length < 2 && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    const started = fs.readdirSync(output).filter(p => p.startsWith('started-')).length;
    await new Promise(resolve => setTimeout(resolve, 300));
    cancellationRun.kill('SIGTERM');
    const stopped = await Promise.race([exit, new Promise(resolve => {
      const timer = setTimeout(() => resolve('cleanup-timeout'), 10000); timer.unref();
    })]);
    assert.equal(started, 2, 'parent and detached child must run before cancellation');
    assert.notEqual(stopped, 'cleanup-timeout');
    assert.equal(stopped, 126);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
