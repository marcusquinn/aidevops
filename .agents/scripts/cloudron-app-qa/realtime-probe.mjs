// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// realtime-probe.mjs - two-browser harness for WebSockets through Cloudron's
// proxy. Logs WebSocket open/close, measures send-to-visible latency and
// repeats after an idle wait to catch proxy idle timeouts.
//
// Usage: node realtime-probe.mjs --base-url URL --adapter adapter.mjs --scratch DIR
//          [--idle 330] [--resolve host=ip]
//
// Adapter interface (ES module):
//   export async function login(page, role)            // role: 'a' | 'b'
//   export async function realtime(pageA, pageB)       // returns { sent, seen } texts
//   export async function coedit(pageA, pageB)         // optional co-editing check
// realtime() must make pageA send a message and resolve once pageB shows it;
// the harness times the call.

import {
  fail, failureCount, info, installErrorHandlers, launchProfile, loadAdapter, parseArgs, pass, profilePath,
} from './lib.mjs';

installErrorHandlers();
const args = parseArgs(process.argv.slice(2));
const base = String(args['base-url'] || '');
const idleSeconds = Number(args.idle === undefined || args.idle === true ? 330 : args.idle);
if (!Number.isFinite(idleSeconds) || idleSeconds < 0) {
  fail('--idle must be a finite, non-negative number');
  process.exit(2);
}

function watchSockets(page, label) {
  page.on('websocket', (ws) => {
    info(`${label} websocket open`);
    ws.on('close', () => info(`${label} websocket close`));
  });
}

async function roundTrip(adapter, pageA, pageB, label) {
  const started = Date.now();
  try {
    await adapter.realtime(pageA, pageB);
    pass(`${label}: realtime delivery in ${Date.now() - started} ms`);
  } catch (error) {
    fail(`${label}: realtime delivery failed (${String(error?.message || error).split('\n')[0]})`);
  }
}

async function main() {
  const adapter = await loadAdapter(args.adapter);
  if (!base || !adapter?.login || !adapter?.realtime) {
    fail('--base-url and --adapter exporting login() and realtime() are required');
    process.exit(2);
  }
  const scratch = String(args.scratch || '.');
  const ctxA = await launchProfile(profilePath(scratch, 'a'), { resolve: args.resolve });
  const ctxB = await launchProfile(profilePath(scratch, 'b'), { resolve: args.resolve });
  try {
    const pageA = await ctxA.newPage();
    const pageB = await ctxB.newPage();
    watchSockets(pageA, 'A');
    watchSockets(pageB, 'B');
    await adapter.login(pageA, 'a');
    await adapter.login(pageB, 'b');
    await roundTrip(adapter, pageA, pageB, 'initial');
    if (adapter.coedit) {
      try { await adapter.coedit(pageA, pageB); pass('co-editing'); } catch { fail('co-editing'); }
    }
    info(`idling ${idleSeconds}s to catch proxy idle timeouts`);
    await pageA.waitForTimeout(idleSeconds * 1000);
    await roundTrip(adapter, pageA, pageB, 'after idle');
  } finally {
    await ctxA.close();
    await ctxB.close();
  }
  process.exit(failureCount() > 0 ? 1 : 0);
}

main();
