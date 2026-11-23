// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import dns from 'node:dns';
import net from 'node:net';
import { syncBuiltinESMExports } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { settings } from '../worker-egress-srt/backend.mjs';

const scripts = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

// GH#39361: synthetic, offline qualification of the host-side proxy. The SRT
// 0.0.83 manager exposes no resolver option, but its resolved-address guard
// resolves through `node:dns` `lookup`, read when the guard is built. The test
// swaps that function (then re-syncs the ESM binding) with a fixture mapping the
// allowed test name to chosen addresses, so no real DNS or /etc/hosts is used.
// Clients talk to the proxy ports directly from this process; no sandbox is
// needed, so this runs wherever SRT initializes.
const findTool = name => {
  for (const dir of (process.env.PATH || '').split(path.delimiter)) {
    try { fs.accessSync(path.join(dir, name), fs.constants.X_OK); return fs.realpathSync(path.join(dir, name)); } catch { /* next */ }
  }
  return null;
};
const proxyTools = { bwrap: findTool('bwrap'), socat: findTool('socat'), rg: findTool('rg') };
const srtInstalled = fs.existsSync(path.join(scripts,
  'worker-egress-srt/node_modules/@anthropic-ai/sandbox-runtime/dist/index.js'));
export const proxyReady = srtInstalled && (process.platform === 'darwin' ? Boolean(proxyTools.rg)
  : process.platform === 'linux' && Object.values(proxyTools).every(Boolean));
export const proxyHost = 'api.openai.com';
let proxyToken = '';

const parentProxyVars = ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy'];

export async function withProxy(records, extraAllowed, body) {
  const original = dns.lookup;
  // Keep the session offline: an inherited parent proxy would be dialled instead
  // of the fixture-controlled direct path.
  const savedEnv = Object.fromEntries(parentProxyVars.map(name => [name, process.env[name]]));
  for (const name of parentProxyVars) delete process.env[name];
  dns.lookup = (host, options, callback) => {
    const cb = typeof options === 'function' ? options : callback;
    const addresses = records[host];
    // IP literals need no resolver; every other name must have a synthetic record.
    if (net.isIP(host)) return original(host, options, callback);
    if (!addresses) return queueMicrotask(() => cb(Object.assign(new Error('no synthetic record for ' + host), { code: 'ENOTFOUND' })));
    const list = addresses.map(address => ({ address, family: net.isIP(address) }));
    return queueMicrotask(() => (options?.all ? cb(null, list) : cb(null, list[0].address, list[0].family)));
  };
  syncBuiltinESMExports();
  const { SandboxManager: manager } = await import(pathToFileURL(path.join(scripts,
    'worker-egress-srt/node_modules/@anthropic-ai/sandbox-runtime/dist/index.js')).href);
  const config = settings(proxyHost, { read: [], write: [], tools: proxyTools });
  config.network.allowedDomains.push(...extraAllowed);
  try {
    await manager.initialize(config, undefined, false);
    assert.ok(await manager.waitForNetworkInitialization(), 'proxy must start');
    proxyToken = manager.getProxyAuthToken();
    return await body({ http: manager.getProxyPort(), socks: manager.getSocksProxyPort() });
  } finally {
    await manager.reset();
    for (const [name, value] of Object.entries(savedEnv)) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
    dns.lookup = original;
    syncBuiltinESMExports();
  }
}

export function exchange(port, payload, until) {
  return new Promise(resolve => {
    const socket = net.connect(port, '127.0.0.1');
    let data = Buffer.alloc(0);
    const timer = setTimeout(() => { socket.destroy(); resolve(data); }, 3000);
    const finish = () => { clearTimeout(timer); socket.destroy(); resolve(data); };
    socket.on('data', chunk => { data = Buffer.concat([data, chunk]); if (until(data)) finish(); });
    socket.on('error', finish); socket.on('close', finish);
    socket.on('connect', () => {
      // The proxy requires its per-session credential, as the sandboxed client's
      // environment supplies it. Add it to the request line's headers.
      const write = socket.write.bind(socket);
      socket.write = chunk => (typeof chunk === 'string' && /^(GET|CONNECT) /.test(chunk)
        ? write(chunk.replace('\r\n', `\r\nProxy-Authorization: Basic ${Buffer.from('srt:' + proxyToken).toString('base64')}\r\n`))
        : write(chunk));
      payload(socket);
    });
  });
}

export const headDone = data => data.includes('\r\n\r\n');
export const statusOf = data => Number(data.toString().match(/^HTTP\/1\.[01] (\d+)/)?.[1] ?? 0);
export const connectStatus = async (port, authority) =>
  statusOf(await exchange(port, s => s.write(`CONNECT ${authority} HTTP/1.1\r\nHost: ${authority}\r\n\r\n`), headDone));

// Authenticated SOCKS5 CONNECT by domain name. Returns the reply code (0 =
// succeeded) or -1 when the proxy closed without a reply to the request.
export const socksReply = async (port, host, destination) => {
  const user = Buffer.from('srt');
  const pass = Buffer.from(proxyToken);
  const data = await exchange(port, s => {
    let stage = 0;
    s.on('data', () => {
      stage += 1;
      if (stage === 1) s.write(Buffer.concat([Buffer.from([1, user.length]), user, Buffer.from([pass.length]), pass]));
      else if (stage === 2) {
        s.write(Buffer.concat([Buffer.from([5, 1, 0, 3, host.length]), Buffer.from(host),
          Buffer.from([destination >> 8, destination & 255])]));
      }
    });
    s.write(Buffer.from([5, 1, 2]));
  }, d => d.length >= 2 + 2 + 4);
  return data.length >= 8 ? data[5] : -1;
};

export const deniedAddresses = {
  'RFC 1918 10/8': '10.1.2.3', 'RFC 1918 172.16/12': '172.16.5.5', 'RFC 1918 192.168/16': '192.168.1.1',
  'loopback 127/8': '127.0.0.1', 'loopback ::1': '::1', 'link-local 169.254/16': '169.254.169.254',
  'link-local fe80::/10': 'fe80::1', 'IPv4-mapped loopback': '::ffff:127.0.0.1',
  'IPv4-mapped RFC 1918': '::ffff:10.0.0.1', 'IPv4-mapped link-local': '::ffff:169.254.169.254',
  'CGNAT 100.64/10': '100.64.0.1', 'ULA fc00::/7': 'fd12:3456::1', unspecified: '0.0.0.0',
};
