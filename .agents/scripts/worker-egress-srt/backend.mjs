#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
// Optional, synthetic qualification prototype for GH#35043; never auto-enabled.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
const version = '0.0.83';
const maximumBytes = 32768;
const cancellation = new AbortController();
const quote = value => "'" + String(value).replaceAll("'", "'\\''") + "'";
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const inside = (child, parent) => child === parent || child.startsWith(parent + path.sep);
class BackendError extends Error {}
function insist(condition, reason) { if (!condition) throw new BackendError(reason); }

const hostLabel = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const decimalOnly = /^\d+(?:\.\d+)*$/;
const reservedSuffix = /(?:^|\.)(?:localhost|local|internal|test|invalid)$/;

// One ordered rule per rejection, not a boolean chain and not a ladder of early
// returns: this decides the single hostname a worker may reach, so each clause
// has to stay individually readable and auditable. `every` short-circuits in
// order, so the type rule still runs before any string operation, and a hostname
// is accepted only if it survives every rule.
const providerHostRules = [
  host => typeof host === 'string',
  host => host.length > 0 && host.length <= 253,
  host => host === host.toLowerCase(),
  host => !net.isIP(host),
  // Refuse bare-decimal address forms such as 2130706433.
  host => !decimalOnly.test(host),
  host => !reservedSuffix.test(host),
  host => host.split('.').length >= 2,
  host => host.split('.').every(label => hostLabel.test(label)),
];

function isProviderHostname(host) {
  return providerHostRules.every(rule => rule(host));
}

export function providerHost(policy) {
  insist(policy?.schema === 'aidevops.worker-egress-policy.v1', 'policy-schema');
  for (const key of ['default_action', 'raw_ip_action', 'private_network_action', 'loopback_action']) {
    insist(policy[key] === 'deny', 'policy-must-deny');
  }
  insist(policy.default_tier === 5, 'provider-policy-only');
  insist(Array.isArray(policy.rules) && policy.rules.length === 1, 'provider-policy-only');
  const rule = policy.rules[0];
  insist(rule.match === 'exact', 'provider-rule');
  insist(['allow', 'allow-log'].includes(rule.action), 'provider-rule');
  insist([1, 2, 3].includes(rule.tier), 'provider-rule');
  const host = rule.pattern;
  insist(isProviderHostname(host), 'provider-host');
  return host;
}

function readJson(filename, privateFile = false) {
  insist(path.isAbsolute(filename), 'absolute-config-path-required');
  const fd = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const st = fs.fstatSync(fd);
    insist(st.isFile() && st.size <= maximumBytes, 'config-file-size-or-type');
    if (privateFile) insist(st.uid === process.getuid() && (st.mode & 0o077) === 0,
      'manifest-must-be-owned-private-file');
    const bytes = fs.readFileSync(fd);
    insist(bytes.length <= maximumBytes, 'config-file-size');
    return { bytes, data: JSON.parse(bytes.toString('utf8')) };
  } finally { fs.closeSync(fd); }
}

function executable(candidate) {
  insist(typeof candidate === 'string' && path.isAbsolute(candidate), 'absolute-tool-required');
  const real = fs.realpathSync(candidate);
  const st = fs.statSync(real);
  insist(st.isFile() && (st.mode & 0o111) !== 0 && (st.mode & 0o022) === 0, 'unsafe-tool');
  return real;
}

export function loadEnvelope(filename) {
  const { data, bytes } = readJson(filename, true);
  insist(data.schema === 'aidevops.srt-envelope.v1', 'envelope-schema');
  insist(Object.keys(data).every(key => ['schema', 'read', 'write', 'cwd', 'tools', 'timeoutSeconds'].includes(key)),
    'unknown-envelope-setting');
  const lists = {};
  for (const key of ['read', 'write']) {
    insist(Array.isArray(data[key]) && data[key].length <= 64, 'bounded-path-list-required');
    lists[key] = data[key].map(entry => {
      insist(typeof entry === 'string' && path.isAbsolute(entry) && !/[\x00-\x1f*?\[\]{}]/.test(entry),
        'literal-absolute-path-required');
      const real = fs.realpathSync(entry);
      insist(!['/', '/etc', '/home', '/Users', '/private', os.homedir()].includes(real), 'broad-root-denied');
      if (key === 'write') {
        const st = fs.statSync(real);
        insist(st.isDirectory() && st.uid === process.getuid() && (st.mode & 0o077) === 0,
          'write-root-must-be-owned-private-directory');
        insist(!inside(here, real) && !inside(fs.realpathSync(filename), real), 'writable-backend-or-manifest');
      }
      return real;
    });
  }
  insist(lists.write.length === 1, 'one-owned-output-root-required');
  insist(fs.readdirSync(lists.write[0]).length === 0, 'output-must-start-empty');
  insist(typeof data.cwd === 'string' && path.isAbsolute(data.cwd), 'absolute-cwd-required');
  const cwd = fs.realpathSync(data.cwd);
  insist(inside(cwd, lists.write[0]), 'cwd-must-be-owned-output');
  const tools = {};
  // `which` is mandatory because SRT resolves every dependency by spawning the
  // external which(1); cleanEnvironment() below builds PATH only from these
  // directories. On FHS distributions the tools share /usr/bin, which also
  // holds which(1), so the need is invisible; on NixOS each package has its own
  // bin directory and every SRT lookup fails with "<tool> not found".
  insist(data.tools && Object.keys(data.tools).every(key => ['shell', 'python', 'bwrap', 'socat', 'rg', 'coreutils', 'procps', 'setsid', 'which'].includes(key)),
    'unknown-tool');
  for (const key of ['shell', 'python', 'rg', 'coreutils', 'procps', 'which', ...(process.platform === 'linux' ? ['bwrap', 'socat', 'setsid'] : [])]) {
    tools[key] = executable(data.tools[key]);
    insist(!lists.write.some(root => inside(tools[key], root)), 'writable-tool');
  }
  insist(path.basename(tools.shell) === 'bash', 'bash-required');
  const timeoutSeconds = data.timeoutSeconds ?? 60;
  insist(Number.isInteger(timeoutSeconds) && timeoutSeconds >= 1 && timeoutSeconds <= 60, 'bounded-timeout-required');
  return { ...lists, cwd, tools, timeoutSeconds, sha256: digest(bytes) };
}

export function settings(host, envelope, bridgeSockets = []) {
  return {
    network: {
      allowedDomains: [host + ':443'], deniedDomains: [], strictAllowlist: true,
      // SRT does NOT deny all private-use addresses by default.
      deniedResolvedAddresses: ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16',
        '100.64.0.0/10', 'fc00::/7'],
      allowLocalBinding: false, allowUnixSockets: [], allowAllUnixSockets: false,
    },
    filesystem: {
      denyRead: ['/'],
      allowRead: [...envelope.read, ...envelope.write, ...bridgeSockets].map(p => ({ path: p, literal: true })),
      allowWrite: envelope.write.map(p => ({ path: p, literal: true })),
      denyWrite: [here],
    },
    bwrapPath: envelope.tools.bwrap, socatPath: envelope.tools.socat,
    ripgrep: { command: envelope.tools.rg },
    enableWeakerNestedSandbox: false, allowNestedUserNamespaces: false,
    enableWeakerNetworkIsolation: false, allowAppleEvents: false,
  };
}

// Reuse the framework's existing process-tree supervisor, including its timeout,
// detached-descendant snapshots and signal cleanup; don't invent another runner.
async function supervised(argv, envelope, scratch, timeout = 15) {
  const output = path.join(scratch, 'stdout');
  const error = path.join(scratch, 'stderr');
  const core = path.join(here, '..', 'sandbox-exec-helper.sh');
  cancellation.signal.throwIfAborted();
  const child = spawn(envelope.tools.python, ['-I', '-c',
    'import os,resource,sys; resource.setrlimit(resource.RLIMIT_FSIZE,(8388608,8388608)); os.execv(sys.argv[1],sys.argv[1:])',
    envelope.tools.shell, '-c',
    'source "$1"; shift; _sandbox_exec_with_pgkill "$@"',
    'srt-supervisor', core, String(timeout), output, error, ...argv],
  { cwd: envelope.cwd, env: process.env, stdio: ['ignore', 'ignore', 'ignore'] });
  const stop = () => child.kill('SIGTERM');
  cancellation.signal.addEventListener('abort', stop, { once: true });
  // The sourced core owns command timeouts and descendant cleanup. Keep the
  // event loop live: SRT's host HTTP/SOCKS proxies run in THIS Node process.
  const status = await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('close', code => resolve(code ?? 126));
  });
  cancellation.signal.removeEventListener('abort', stop);
  cancellation.signal.throwIfAborted();
  return {
    code: status,
    stdout: fs.existsSync(output) ? fs.readFileSync(output, 'utf8') : '',
    stderr: fs.existsSync(error) ? fs.readFileSync(error, 'utf8') : '',
  };
}

// Pin the upstream rendering contract. Modify argv via a receiver, not by parsing
// or reserializing the opaque SBPL profile; the host proxy stays outside Seatbelt.
export function tightenMacCommand(wrapped, node = process.execPath) {
  const marker = '/usr/bin/sandbox-exec -p ';
  insist(wrapped.split(marker).length === 2, 'unrecognized-seatbelt-command');
  return wrapped.replace(marker, `${quote(node)} ${quote(fileURLToPath(import.meta.url))} seatbelt -p `);
}

export function tightenMacProfile(profile) {
  insist(profile.startsWith('(version 1)\n(deny default'), 'unexpected-seatbelt-profile');
  // Remove the pinned release's explicit Mach-service allows rather than
  // assuming a broad deny overrides more specific allows. Refuse unknown forms.
  const rule = /\(allow mach-lookup\s+(?:\(global-name(?:-prefix)? "(?:[^"\\]|\\.)*"\)\s*)+\)/g;
  let strict = profile.replace(rule, '');
  insist(!/\(allow\s+mach-lookup\b/.test(strict) && !/\(import\b/.test(strict), 'unknown-mach-rule');
  strict = strict.replace(/\(allow (?:user-preference-read|ipc-posix-shm|ipc-posix-sem)\)/g, '');
  return strict + '\n(deny mach-lookup)\n(deny mach-register)\n';
}

async function wrappedArgv(manager, argv, envelope) {
  // With a sealed filesystem there is no ambient /etc/hosts. Don't make clients
  // resolve SRT's "localhost" bridge name through an unavailable system resolver.
  const proxySetup = ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy']
    .map(key => `export ${key}="\${${key}/localhost:/127.0.0.1:}"; `).join('');
  const command = proxySetup + 'exec ' + argv.map(quote).join(' ');
  let wrapped = await manager.wrapWithSandbox(command, envelope.tools.shell);
  if (process.platform === 'darwin') wrapped = tightenMacCommand(wrapped);
  return [envelope.tools.shell, '-c', wrapped];
}

const canary = String.raw`
import ctypes, errno, json, os, socket, subprocess, sys, urllib.request, urllib.error
outside, approved_input, output, python, endpoints_json = sys.argv[1:]
endpoints = json.loads(endpoints_json)
checks = {}
try:
    open(outside).read()
    checks['host-read-denied'] = False
except (OSError, PermissionError):
    checks['host-read-denied'] = True
checks['approved-read'] = open(approved_input).read() == 'synthetic readonly'
for label, filename in [('input-write-denied', approved_input), ('host-write-shadow-or-denial', outside)]:
    try:
        with open(filename, 'a') as f:
            f.write('synthetic escape')
        # A denyRead region can be a private writable tmpfs shadow. The HOST
        # parent independently verifies that the real file stayed unchanged.
        checks[label] = filename == outside
    except OSError as e:
        checks[label] = e.errno in (errno.EACCES, errno.EPERM, errno.EROFS, errno.ENOENT)
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(outside + '.sock')
    checks['unix-denied'] = False
except OSError:
    checks['unix-denied'] = True
for family, address in [(socket.AF_INET, ('127.0.0.1', endpoints[0])), (socket.AF_INET6, ('::1', endpoints[1], 0, 0))]:
    s = socket.socket(family); s.settimeout(.3)
    try:
        s.connect(address); checks[str(family)] = False
    except OSError as e:
        checks[str(family)] = e.errno in (errno.ENETUNREACH, errno.EACCES, errno.EPERM, errno.ECONNREFUSED)
    finally:
        s.close()
if sys.platform == 'linux':
    try:
        socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        checks['unix-socket-creation-denied'] = False
    except OSError as e:
        checks['unix-socket-creation-denied'] = e.errno in (errno.EACCES, errno.EPERM)
    try:
        os.unshare(os.CLONE_NEWUSER); checks['nested-userns-denied'] = False
    except OSError as e:
        checks['nested-userns-denied'] = e.errno in (errno.ENOSPC, errno.EPERM)
else:
    lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    port = ctypes.c_uint.in_dll(lib, 'bootstrap_port').value
    for service in [b'com.apple.system.opendirectoryd.libinfo', b'com.apple.SecurityServer']:
        handle = ctypes.c_uint()
        rc = lib.bootstrap_look_up(port, service, ctypes.byref(handle))
        checks[service.decode()] = rc != 0
child = subprocess.run([python, '-I', '-c', 'import sys; sys.exit(0 if len(sys.argv)==2 and sys.argv[1]=="a b;$(false)" else 1)', 'a b;$(false)'], env=os.environ)
checks['descendant-and-argv'] = child.returncode == 0
try:
    urllib.request.urlopen('https://blocked.invalid/', timeout=2)
    checks['proxy-live-and-denying'] = False
except urllib.error.URLError as e:
    checks['proxy-live-and-denying'] = '403' in str(e.reason)
    if not checks['proxy-live-and-denying']:
        print('synthetic proxy error:', str(e.reason), file=sys.stderr)
result_file = os.path.join(output, os.path.basename(outside) + '-result')
with open(result_file, 'x') as f:
    f.write('synthetic')
os.unlink(result_file)
print(json.dumps(checks))
sys.exit(0 if all(checks.values()) else 1)
`;

async function qualify(manager, envelope, scratch) {
  const outside = path.join(scratch, 'host-canary');
  const input = path.join(scratch, 'approved-input');
  fs.writeFileSync(outside, 'synthetic only', { mode: 0o600 });
  fs.writeFileSync(input, 'synthetic readonly', { mode: 0o600 });
  const originalConfig = manager.getConfig();
  manager.updateConfig({ ...originalConfig, filesystem: { ...originalConfig.filesystem,
    allowRead: [...originalConfig.filesystem.allowRead, { path: input, literal: true }] } });
  const servers = [];
  try {
    const endpoints = [];
    // Ephemeral, owned local listeners only. Positive controls prevent absent
    // files, unavailable routes or absent IPv6 from masquerading as containment.
    for (const address of [{ host: '127.0.0.1', port: 0 }, { host: '::1', port: 0 }, outside + '.sock']) {
      const server = net.createServer(socket => socket.end());
      servers.push(server);
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(address, resolve); });
      const dest = typeof server.address() === 'string' ? server.address()
        : { host: server.address().address, port: server.address().port };
      await new Promise((resolve, reject) => {
        const socket = net.connect(dest, () => { socket.end(); resolve(); });
        socket.once('error', reject);
      });
      if (typeof dest !== 'string') endpoints.push(dest.port);
    }
    if (process.platform === 'darwin') {
      // Both services must be reachable OUTSIDE the sandbox, or the negative
      // bootstrap checks below would be meaningless.
      const control = spawnSync(envelope.tools.python, ['-I', '-c',
        'import ctypes,sys; l=ctypes.CDLL("/usr/lib/libSystem.B.dylib"); p=ctypes.c_uint.in_dll(l,"bootstrap_port").value; sys.exit(any(l.bootstrap_look_up(p,s,ctypes.byref(ctypes.c_uint())) != 0 for s in [b"com.apple.system.opendirectoryd.libinfo",b"com.apple.SecurityServer"]))']);
      insist(control.status === 0, 'mach-positive-control-unavailable');
    }
    const result = await supervised(await wrappedArgv(manager,
      [envelope.tools.python, '-I', '-c', canary, outside, input, envelope.write[0], envelope.tools.python,
        JSON.stringify(endpoints)], envelope), envelope, scratch);
    if (result.code !== 0) {
      let checks = {};
      try { checks = JSON.parse(result.stdout); } catch { /* no arbitrary output in diagnostics */ }
      console.error(JSON.stringify({ primitive_exit: result.code,
        failed_checks: Object.entries(checks).filter(([key, value]) => value === false && /^[a-z0-9-]+$/.test(key)).map(([key]) => key),
        exception: result.stderr.match(/\b([A-Za-z]+Error):/)?.[1] ?? null }));
    }
    insist(result.code === 0, 'primitive-check-failed');
    const checks = JSON.parse(result.stdout.trim());
    checks['host-file-unchanged'] = fs.readFileSync(outside, 'utf8') === 'synthetic only';
    checks['input-file-unchanged'] = fs.readFileSync(input, 'utf8') === 'synthetic readonly';
    insist(Object.keys(checks).length >= 8 && Object.values(checks).every(v => v === true), 'primitive-check-incomplete');
    return checks;
  } finally {
    manager.updateConfig(originalConfig);
    await Promise.all(servers.map(server => new Promise(resolve => server.close(resolve))));
  }
}

function cleanEnvironment(envelope, scratch) {
  // Capture operator settings BEFORE clearing; never inherit proxy chains,
  // credentials, NODE_OPTIONS, shell startup files or agent sockets into SRT.
  const search = [...new Set(Object.values(envelope.tools).map(t => path.dirname(t)))].join(path.delimiter);
  for (const key of Object.keys(process.env)) delete process.env[key];
  Object.assign(process.env, { PATH: search, HOME: envelope.cwd, TMPDIR: scratch, LANG: 'C.UTF-8' });
}

async function main(argv) {
  // Receiver invoked on the host, before the one and only sandbox_apply call.
  if (argv[0] === 'seatbelt') {
    insist(process.platform === 'darwin' && argv[1] === '-p' && argv.length >= 5, 'seatbelt-argv');
    const profile = tightenMacProfile(argv[2]);
    const child = spawnSync('/usr/bin/sandbox-exec', ['-p', profile, ...argv.slice(3)], { stdio: 'inherit' });
    return child.status ?? 126;
  }
  const action = argv.shift();
  insist(['probe', 'run'].includes(action), 'usage: probe|run --policy FILE [--worker-id ID] [-- COMMAND...]');
  insist(argv.shift() === '--policy', 'policy-argument-required');
  const policy = readJson(argv.shift());
  const host = providerHost(policy.data);
  if (argv[0] === '--worker-id') { argv.splice(0, 2); }
  if (action === 'run') insist(argv.shift() === '--' && argv.length > 0, 'command-required');
  else insist(argv.length === 0, 'unexpected-probe-arguments');
  insist(['linux', 'darwin'].includes(process.platform) && ['x64', 'arm64'].includes(process.arch), 'unsupported-platform');
  const envelope = loadEnvelope(process.env.AIDEVOPS_SRT_ENVELOPE || '');
  // No implicit FHS paths: NixOS supplies exact store paths including the
  // executable closure in read[], Ubuntu/macOS supply their native paths.
  const temp = process.env.AIDEVOPS_TEMP_DIR || path.join(os.homedir(), '.aidevops/.agent-workspace/tmp');
  insist(fs.statSync(temp).isDirectory(), 'temp-parent-required');
  const scratch = fs.mkdtempSync(path.join(temp, 'eg-'));
  fs.chmodSync(scratch, 0o700);
  let manager;
  try {
    cleanEnvironment(envelope, scratch);
    const installed = JSON.parse(fs.readFileSync(path.join(here,
      'node_modules/@anthropic-ai/sandbox-runtime/package.json'), 'utf8'));
    insist(installed.version === version, 'srt-version-mismatch');
    ({ SandboxManager: manager } = await import('@anthropic-ai/sandbox-runtime'));
    // Config before initialize sets explicit bwrap/socat locations for its own
    // dependency checks, rather than trusting caller PATH or weak SRT settings.
    manager.updateConfig(settings(host, envelope));
    const dependencies = await manager.checkDependenciesAsync({ command: envelope.tools.rg });
    insist(dependencies.errors.length === 0 && dependencies.warnings.length === 0, 'dependencies-not-ready');
    await manager.initialize(settings(host, envelope), undefined, false);
    insist(await manager.waitForNetworkInitialization(), 'proxy-not-ready');
    if (process.platform === 'linux') {
      // Only SRT's two owned bridge sockets are visible to its pre-seccomp
      // relays. Never expose the entire host scratch directory. The workload
      // cannot open AF_UNIX sockets after apply-seccomp.
      const sockets = [manager.getLinuxHttpSocketPath(), manager.getLinuxSocksSocketPath()];
      insist(sockets.every(p => typeof p === 'string'), 'bridge-sockets-not-ready');
      manager.updateConfig(settings(host, envelope, sockets));
    }
    const checks = await qualify(manager, envelope, scratch);
    if (process.platform === 'darwin') {
      // The legacy v1 caller ignores qualification fields. Do NOT let passing
      // these limited canaries turn an unreviewed DNS/inherited-Mach boundary
      // into an accepted backend. No environment-variable bypass is provided.
      console.error(JSON.stringify({ qualification: 'macos-incomplete', checks }));
      throw new BackendError('macos-dns-and-ipc-qualification-pending');
    }
    if (action === 'probe') {
      console.log(JSON.stringify({ schema: 'aidevops.worker-egress-backend.v1', ready: true,
        scope: 'process-tree', enforcement: 'equivalent', policy_sha256: digest(policy.bytes),
        backend_id: 'srt-0.0.83', cleanup: 'automatic',
        capabilities: ['direct-socket-deny', 'hostname-policy', 'private-network-deny', 'filesystem-allowlist'],
        envelope_sha256: envelope.sha256, platform: process.platform, architecture: process.arch, checks,
        qualification: 'synthetic-only', provider_connectivity: 'not-tested' }));
      return 0;
    }
    const result = await supervised(await wrappedArgv(manager, argv, envelope), envelope, scratch, envelope.timeoutSeconds);
    process.stdout.write(result.stdout);
    process.stderr.write(result.stderr);
    return result.code;
  } finally {
    try {
      if (manager) { try { manager.cleanupAfterCommand(); } finally { await manager.reset(); } }
    } finally { fs.rmSync(scratch, { recursive: true, force: true }); }
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
    process.on(signal, () => cancellation.abort());
  }
  main(process.argv.slice(2)).then(code => { process.exitCode = code; }).catch(error => {
    // Fixed errors only: never stringify an upstream message that may contain
    // request URLs, commands, credentials or filesystem contents.
    const known = error instanceof BackendError && error.message.match(/^[a-z][a-z0-9:-]*(?: [A-Z]+)?$/);
    console.log(JSON.stringify({ schema: 'aidevops.worker-egress-backend.v1', ready: false,
      reason: known ? error.message : 'backend-failed', backend_id: 'srt-0.0.83' }));
    process.exitCode = 126;
  });
}
