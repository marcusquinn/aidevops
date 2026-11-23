// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { proxyReady, proxyHost, withProxy, exchange, headDone, statusOf, connectStatus, socksReply, deniedAddresses } from './worker-egress-srt-proxy-harness.mjs';
import { spawn, spawnSync } from 'node:child_process';
import { ENV_ADDED, ENV_ALLOWLIST, providerHost, settings, tightenLinuxArgs, tightenMacCommand, tightenMacProfile } from '../worker-egress-srt/backend.mjs';

const scripts = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const backend = path.join(scripts, 'worker-egress-srt/backend.mjs');
const policy = {
  schema: 'aidevops.worker-egress-policy.v1', default_tier: 5,
  default_action: 'deny', raw_ip_action: 'deny', private_network_action: 'deny', loopback_action: 'deny',
  rules: [{ match: 'exact', pattern: 'api.openai.com', action: 'allow', tier: 1 }],
};

test('only the exact provider policy is accepted; every relaxation fails closed', () => {
  assert.equal(providerHost(policy), 'api.openai.com');
  assert.equal(providerHost({ ...policy, rules: [{ ...policy.rules[0], pattern: 'api.example.com' }] }), 'api.example.com');
  for (const key of ['default_action', 'raw_ip_action', 'private_network_action', 'loopback_action']) {
    assert.throws(() => providerHost({ ...policy, [key]: 'allow' }));
  }
  for (const host of ['127.0.0.1', '2130706433', '0xc0.0.2.1', '0xc0000201', '0300.0.2.1', 'localhost', '*.openai.com', 'x.local',
    'api.openai.com:80', 'api.openai.com.', 'user@api.openai.com', 'api.openai.com;false']) {
    assert.throws(() => providerHost({ ...policy, rules: [{ ...policy.rules[0], pattern: host }] }), /provider-host/);
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
  for (const p of ['/tmp/claude', '/private/tmp/claude']) {
    assert.ok(profile.includes(`(deny file-read* file-write* (subpath "${p}"))`));
  }
  assert.throws(() => tightenMacProfile('(version 1)\n(deny default)\n(allow mach-lookup (unknown-filter "new"))'));
});

test('Linux temporary shadows follow all upstream mounts and preserve command argv', () => {
  const before = ['--new-session', '--bind', '/tmp/claude', '/tmp/claude', '--dev', '/dev'];
  const command = ['--', '/bin/bash', '-c', 'printf "%s" "a b;$(false)"'];
  const tightened = tightenLinuxArgs([...before, ...command]);
  assert.deepEqual(tightened.slice(0, before.length), before);
  assert.deepEqual(tightened.slice(-command.length), command);
  const shadows = tightened.slice(before.length, -command.length);
  for (const p of ['/tmp/claude', '/private/tmp/claude']) {
    if (fs.existsSync(p)) {
      assert.ok(shadows.some((value, index) => value === '--tmpfs' && shadows[index + 1] === fs.realpathSync(p)));
    } else assert.ok(!shadows.includes(p));
  }
  assert.throws(() => tightenLinuxArgs(['--args', '17', ...command]), /unexpected-bwrap-profile/);
  assert.throws(() => tightenLinuxArgs(before), /unexpected-bwrap-profile/);
});

test('Linux shadows canonical temporary aliases but never mounts an absent /private', t => {
  t.mock.method(fs, 'realpathSync', p => {
    if (p === '/tmp/claude') return '/owned/alias-target';
    throw Object.assign(new Error('synthetic absence'), { code: 'ENOENT' });
  });
  assert.deepEqual(tightenLinuxArgs(['--', '/bin/true']), [
    '--tmpfs', '/owned/alias-target', '--', '/bin/true',
  ]);
});

test('direct and absolute-symlink entrypoints execute while imports stay inert', () => {
  const temp = process.env.AIDEVOPS_TEMP_DIR || path.join(os.homedir(), '.aidevops/.agent-workspace/tmp');
  const root = fs.mkdtempSync(path.join(temp, 'srt-entry-'));
  try {
    const link = path.join(root, 'backend.mjs');
    fs.symlinkSync(backend, link);
    for (const entry of [backend, link]) {
      const result = spawnSync(process.execPath, [entry], { encoding: 'utf8' });
      assert.equal(result.status, 126);
      assert.equal(JSON.parse(result.stdout).ready, false);
    }
    const imported = spawnSync(process.execPath, ['--input-type=module', '-e',
      `await import(${JSON.stringify(pathToFileURL(backend).href)})`], { encoding: 'utf8' });
    assert.equal(imported.status, 0, imported.stderr);
    assert.equal(imported.stdout, '');
    assert.equal(imported.stderr, '');
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
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

function resolve(name) {
  for (const dir of process.env.PATH.split(path.delimiter)) {
    const candidate = path.join(dir, name);
    try { fs.accessSync(candidate, fs.constants.X_OK); return fs.realpathSync(candidate); } catch { /* keep looking */ }
  }
  throw new Error('missing tool: ' + name);
}

function removeEmptyTemp(directory) {
  try { fs.rmdirSync(directory); }
  catch (error) { if (error.code !== 'ENOTEMPTY') throw error; }
}

function checkTemporaryIsolation(invoke, policyFile, python, output) {
  // Unlisted synthetic HOST data at SRT's implicit write root must remain
  // unreadable and unchanged; writes to a private tmpfs shadow are harmless.
  const defaultTemp = '/tmp/claude';
  let madeDefaultTemp = false;
  try { fs.mkdirSync(defaultTemp, { mode: 0o700 }); madeDefaultTemp = true; }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  let hostRoot;
  try {
    hostRoot = fs.mkdtempSync(path.join(defaultTemp, 'aidevops-canary-'));
    const hostFile = path.join(hostRoot, 'host-only');
    fs.writeFileSync(hostFile, 'synthetic host marker', { mode: 0o600 });
    const isolated = invoke(['run', '--policy', policyFile, '--', python, '-I', '-c', String.raw`
import os, sys, tempfile
try:
    assert open(sys.argv[1]).read() != 'synthetic host marker', 'host temp data exposed'
except OSError:
    pass
try:
    with open(sys.argv[1], 'a') as f:
        f.write('escape')
except OSError:
    pass
assert os.environ['TMPDIR'] == sys.argv[2]
with tempfile.TemporaryFile() as f:
    f.write(b'private temporary output')
`, hostFile, output]);
    assert.equal(isolated.status, 0, isolated.stdout + isolated.stderr);
    assert.equal(fs.readFileSync(hostFile, 'utf8'), 'synthetic host marker');
  } finally {
    if (hostRoot) fs.rmSync(hostRoot, { recursive: true, force: true });
    if (madeDefaultTemp) removeEmptyTemp(defaultTemp);
  }
}

test('real platform qualification (explicit opt-in, synthetic data, no provider contact)', {
  skip: process.env.AIDEVOPS_SRT_REAL_CHECK !== '1', timeout: 120000,
}, async () => {
  const temp = process.env.AIDEVOPS_TEMP_DIR || path.join(os.homedir(), '.aidevops/.agent-workspace/tmp');
  const root = fs.mkdtempSync(path.join(temp, 'srt-test-'));
  const output = path.join(root, 'output');
  fs.mkdirSync(output, { mode: 0o700 });
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
    // GH#39362: every inherited send right named; the probe's host control
    // separately proves the attribution flags foreign (looked-up) rights.
    if (process.platform === 'darwin') assert.equal(readiness.checks['mach-send-rights-attributed'], true);
    const run = invoke(['run', '--policy', policyFile, '--worker-id', 'synthetic-check', '--',
      tools.python, '-I', '-c', 'import sys; print(sys.argv[1])', 'a b;$(false)']);
    assert.equal(run.status, 0, run.stdout + run.stderr);
    assert.equal(run.stdout.trim(), 'a b;$(false)');
    checkTemporaryIsolation(invoke, policyFile, tools.python, output);
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


test('policy denies loopback, link-local and unspecified explicitly, not only by SRT default', () => {
  const list = settings(proxyHost, { read: [], write: [], tools: {} }).network.deniedResolvedAddresses;
  for (const range of ['169.254.0.0/16', 'fe80::/10', '127.0.0.0/8', '::1', '0.0.0.0/8']) assert.ok(list.includes(range), range);
});

test('allowed name resolving to a denied address class is refused over CONNECT and SOCKS', {
  skip: !proxyReady, timeout: 120000,
}, async () => {
  const results = {};
  for (const [label, address] of Object.entries(deniedAddresses)) {
    await withProxy({ [proxyHost]: [address] }, [], async ports => {
      results[label] = { connect: await connectStatus(ports.http, proxyHost + ':443'),
        socks: await socksReply(ports.socks, proxyHost, 443) };
      assert.equal(results[label].connect, 403, `${label} CONNECT must be a policy refusal`);
      assert.equal(results[label].socks, 2, `${label} SOCKS must be a policy refusal`);
    });
  }
  console.log('GH39361 resolved-address results', JSON.stringify(results));
});

test('positive controls, redirect follow-up, non-443 ports and raw protocol behaviour', {
  skip: !proxyReady, timeout: 60000,
}, async () => {
  const echo = net.createServer(s => s.on('data', d => s.write(d)));
  const redirector = http.createServer((req, res) => {
    res.writeHead(302, { Location: `http://other.example.net:${echo.address().port}/` }); res.end();
  });
  await Promise.all([echo, redirector].map(s => new Promise(resolve => s.listen(0, '127.0.0.1', resolve))));
  const port = redirector.address().port;
  const echoPort = echo.address().port;
  try {
    // Only this variant carves the owned loopback listeners out of the guard
    // (literal:port allow entries), so it proves the fixture resolver and the
    // proxy dial path work. Production settings() never carries them.
    const carve = [port, echoPort].flatMap(p => [`${proxyHost}:${p}`, `127.0.0.1:${p}`]);
    await withProxy({ [proxyHost]: ['127.0.0.1'] }, carve, async ports => {
      const first = await exchange(ports.http, s => s.write(`GET http://${proxyHost}:${port}/ HTTP/1.1\r\nHost: ${proxyHost}:${port}\r\nConnection: close\r\n\r\n`), headDone);
      assert.equal(statusOf(first), 302, 'positive control: allowed name reaches the owned redirector');
      const location = new URL(first.toString().match(/^location: (.*)$/im)[1].trim());
      assert.equal(location.hostname, 'other.example.net');
      const follow = await exchange(ports.http, s => s.write(`GET ${location.href} HTTP/1.1\r\nHost: ${location.host}\r\nConnection: close\r\n\r\n`), headDone);
      assert.equal(statusOf(follow), 403, 'redirect follow-up to a different host is refused');
      const tunnel = await exchange(ports.http, s => {
        s.once('data', () => s.write('not-tls raw bytes'));
        s.write(`CONNECT ${proxyHost}:${echoPort} HTTP/1.1\r\nHost: ${proxyHost}:${echoPort}\r\n\r\n`);
      }, d => d.toString().includes('not-tls raw bytes'));
      assert.equal(statusOf(tunnel), 200, 'positive control: CONNECT tunnel to the owned echo listener');
      assert.match(tunnel.toString(), /not-tls raw bytes$/, 'recorded behaviour: non-TLS bytes are tunnelled opaquely once the authority is allowed');
      assert.equal(await socksReply(ports.socks, proxyHost, echoPort), 0, 'positive control: SOCKS to the owned echo listener');
    });
    // Production policy permits :443 only; the same name on any other port is refused.
    await withProxy({ [proxyHost]: ['127.0.0.1'] }, [], async ports => {
      for (const p of [80, 22, 25, 8443, port]) {
        assert.equal(await connectStatus(ports.http, `${proxyHost}:${p}`), 403, 'CONNECT :' + p);
        assert.equal(await socksReply(ports.socks, proxyHost, p), 2, 'SOCKS :' + p);
      }
      const plain = await exchange(ports.http, s => s.write(`GET http://${proxyHost}/ HTTP/1.1\r\nHost: ${proxyHost}\r\nConnection: close\r\n\r\n`), headDone);
      assert.equal(statusOf(plain), 403, 'plain HTTP to the allowed name on :80');
      assert.equal(await connectStatus(ports.http, 'other.example.net:443'), 403, 'different host on 443');
    });
  } finally {
    await Promise.all([echo, redirector].map(s => new Promise(resolve => s.close(resolve))));
  }
});
