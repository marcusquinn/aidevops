// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// oauth-probe.mjs - RFC 9728 / 8414 / 7591 / 7636 discovery, registration and
// PKCE round trip against an app's OAuth-protected resource (for example MCP).
//
// Usage: node oauth-probe.mjs --base-url https://app.example.com
//          [--resource-path /mcp] --adapter adapter.mjs --scratch DIR [--resolve host=ip]
//
// Consent needs a signed-in browser: the adapter's login(page, 'admin') signs in
// and the loopback redirect is intercepted with context.route (no listener port).
// Tokens, codes and state values are never printed.

import { createHash, randomBytes } from 'node:crypto';
import {
  fail, failureCount, info, installErrorHandlers, launchProfile, loadAdapter, parseArgs, pass,
  profilePath, redact,
} from './lib.mjs';

installErrorHandlers();
const args = parseArgs(process.argv.slice(2));
const base = String(args['base-url'] || '').replace(/\/$/, '');
const rawPath = args['resource-path'] === true ? '/mcp' : args['resource-path'] || '/mcp';
const resourcePath = rawPath.startsWith('/') ? rawPath : `/${rawPath}`;
if (base && !/^https:\/\//i.test(base)) {
  console.log('FAIL: --base-url must be https://');
  process.exit(2);
}
const FETCH_TIMEOUT_MS = 30000;
const timedFetch = (url, init = {}) => fetch(url, { ...init, signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
const loopback = 'http://127.0.0.1:53682/callback';
const b64url = (buf) => buf.toString('base64url');

async function getJson(url, init) {
  const res = await timedFetch(url, init);
  let body = null;
  try { body = await res.json(); } catch { body = null; }
  return { res, body };
}

async function discover() {
  const prm = await getJson(`${base}/.well-known/oauth-protected-resource${resourcePath}`);
  if (prm.res.status === 200 && prm.body?.resource) pass('RFC 9728 protected-resource metadata');
  else fail(`RFC 9728 protected-resource metadata (HTTP ${prm.res.status})`);
  const asm = await getJson(`${base}/.well-known/oauth-authorization-server`);
  const meta = asm.body || {};
  if (asm.res.status === 200 && meta.authorization_endpoint && meta.token_endpoint) pass('RFC 8414 authorization-server metadata');
  else fail(`RFC 8414 authorization-server metadata (HTTP ${asm.res.status})`);
  if (Array.isArray(meta.code_challenge_methods_supported) && meta.code_challenge_methods_supported.includes('S256')) pass('S256 PKCE advertised');
  else fail('S256 PKCE not advertised');
  return meta;
}

async function checkUnauthenticated() {
  const res = await timedFetch(`${base}${resourcePath}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }),
  });
  const challenge = res.headers.get('www-authenticate') || '';
  if (res.status === 401 && /Bearer/i.test(challenge) && /resource_metadata=/.test(challenge)) pass('unauthenticated POST gives 401 with resource_metadata challenge');
  else fail(`unauthenticated POST expected 401 + Bearer resource_metadata (got ${res.status})`);
}

async function register(meta) {
  if (!meta.registration_endpoint) { fail('no registration_endpoint (RFC 7591)'); return null; }
  const { res, body } = await getJson(meta.registration_endpoint, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      client_name: 'cloudron-app-qa', redirect_uris: [loopback], token_endpoint_auth_method: 'none',
      grant_types: ['authorization_code'], response_types: ['code'],
    }),
  });
  if ((res.status === 200 || res.status === 201) && body?.client_id) { pass('RFC 7591 dynamic client registration (public client)'); return body.client_id; }
  fail(`RFC 7591 dynamic client registration (HTTP ${res.status})`);
  return null;
}

async function consent(meta, clientId, adapter, scratch) {
  const verifier = b64url(randomBytes(32));
  const challenge = b64url(createHash('sha256').update(verifier).digest());
  const state = b64url(randomBytes(16));
  const url = new URL(meta.authorization_endpoint);
  const params = {
    response_type: 'code', client_id: clientId, redirect_uri: loopback, code_challenge: challenge,
    code_challenge_method: 'S256', state, resource: `${base}${resourcePath}`,
  };
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const context = await launchProfile(profilePath(scratch, 'oauth'), { resolve: args.resolve });
  let code = null;
  try {
    await context.route(`${loopback.replace('/callback', '')}/**`, async (route) => {
      const u = new URL(route.request().url());
      if (u.searchParams.get('state') === state) code = u.searchParams.get('code');
      await route.fulfill({ status: 200, contentType: 'text/plain', body: 'ok' });
    });
    const page = await context.newPage();
    if (adapter?.login) await adapter.login(page, 'admin');
    await page.goto(url.toString());
    if (adapter?.consent) await adapter.consent(page);
    else await page.getByRole('button', { name: /allow|approve|authori[sz]e|consent/i }).first().click({ timeout: 30000 });
    for (let i = 0; i < 60 && !code; i += 1) await page.waitForTimeout(500);
  } finally {
    await context.close();
  }
  if (!code) { fail('consent did not return an authorization code via loopback redirect'); return null; }
  pass('consent returned authorization code (value withheld)');
  return { code, verifier };
}

async function exchange(meta, clientId, grant) {
  const form = new URLSearchParams({
    grant_type: 'authorization_code', code: grant.code, redirect_uri: loopback, client_id: clientId,
    code_verifier: grant.verifier, resource: `${base}${resourcePath}`,
  });
  const { res, body } = await getJson(meta.token_endpoint, {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: form,
  });
  if (res.status === 200 && body?.access_token) { pass('token exchange with PKCE verifier and resource'); return body.access_token; }
  fail(`token exchange (HTTP ${res.status})`);
  return null;
}

async function mcpCall(token, method, id, params = {}) {
  const res = await timedFetch(`${base}${resourcePath}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json', accept: 'application/json, text/event-stream',
      authorization: `Bearer ${token}`, 'MCP-Protocol-Version': '2025-06-18',
    },
    body: JSON.stringify({ jsonrpc: '2.0', id, method, params }),
  });
  return res;
}

async function mcpRoundTrip(token) {
  const init = await mcpCall(token, 'initialize', 1, {
    protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'cloudron-app-qa', version: '1' },
  });
  if (init.status === 200) pass('MCP initialize with bearer token'); else fail(`MCP initialize (HTTP ${init.status})`);
  const tools = await mcpCall(token, 'tools/list', 2);
  if (tools.status === 200) pass('MCP tools/list with bearer token'); else fail(`MCP tools/list (HTTP ${tools.status})`);
}

async function revoke(meta, clientId, token) {
  const endpoint = meta.revocation_endpoint || `${base}/oauth/revoke`;
  const res = await timedFetch(endpoint, {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ token, client_id: clientId }),
  });
  if (res.status === 200) pass('token revocation'); else fail(`token revocation (HTTP ${res.status})`);
  const after = await mcpCall(token, 'tools/list', 3);
  if (after.status === 401) pass('revoked token rejected with 401'); else fail(`revoked token expected 401 (got ${after.status})`);
}

async function main() {
  if (!base) { fail('--base-url is required'); process.exit(2); }
  const adapter = await loadAdapter(args.adapter);
  const scratch = String(args.scratch || '.');
  const meta = await discover();
  await checkUnauthenticated();
  const clientId = await register(meta);
  if (clientId && adapter?.login) {
    const grant = await consent(meta, clientId, adapter, scratch);
    const token = grant ? await exchange(meta, clientId, grant) : null;
    if (token) { await mcpRoundTrip(token); await revoke(meta, clientId, token); }
  } else if (clientId) {
    info('SKIP: consent/token round trip needs --adapter exporting login(page, role)');
  }
  info(`oauth-probe finished against ${redact(base)}`);
  process.exit(failureCount() > 0 ? 1 : 0);
}

main();
