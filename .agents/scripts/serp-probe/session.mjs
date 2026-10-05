// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Run setup for serp-captcha-probe.mjs: egress proxy, private run directory
// and report, and the persistent browser profile.

import { chmodSync, mkdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

import { loadPlaywright, resolvePlaywrightBrowserExecutable } from '../playwright-runtime.mjs';
import { SCHEMA } from './options.mjs';

const WORKSPACE = process.env.AIDEVOPS_SERP_PROBE_DIR?.trim()
  || join(homedir(), '.aidevops', '.agent-workspace', 'serp-probe');

const tildePath = (path) => path.replace(homedir(), '~');

export function proxyFromEnv() {
  const raw = process.env.SERP_PROBE_PROXY?.trim();
  if (!raw) return undefined;
  const url = new URL(raw);
  return {
    server: `${url.protocol}//${url.host}`,
    username: url.username ? decodeURIComponent(url.username) : undefined,
    password: url.password ? decodeURIComponent(url.password) : undefined,
  };
}

export function createRun(options, proxy) {
  const runId = new Date().toISOString().replace(/[:.]/g, '-');
  const runDir = join(WORKSPACE, 'runs', runId);
  mkdirSync(runDir, { recursive: true, mode: 0o700 });
  for (const dir of [WORKSPACE, join(WORKSPACE, 'runs'), runDir]) chmodSync(dir, 0o700);
  const report = {
    schema: SCHEMA,
    run_id: runId,
    engine: options.engine,
    gl: options.gl,
    hl: options.hl,
    headless: options.headless,
    egress: proxy ? 'proxy' : 'direct',
    profile: options.freshProfile ? 'fresh' : 'persistent',
    pacing_seconds: { min: options.minDelay, max: options.maxDelay },
    on_captcha: options.onCaptcha,
    started_at: new Date().toISOString(),
    ended_at: null,
    planned: options.keywords.length,
    attempted: 0,
    succeeded: 0,
    first_block: null,
    blocks: [],
    stop_reason: 'completed',
    queries: [],
    run_dir: tildePath(runDir),
  };
  const save = () => {
    report.ended_at = new Date().toISOString();
    writeFileSync(join(runDir, 'report.json'), `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
  };
  return { runDir, report, save };
}

export async function launchBrowser(options, runDir, proxy) {
  const runtime = await loadPlaywright();
  const executablePath = resolvePlaywrightBrowserExecutable(runtime) || undefined;
  const profileDir = options.freshProfile ? join(runDir, 'profile') : join(WORKSPACE, `profile-${options.engine}`);
  mkdirSync(profileDir, { recursive: true, mode: 0o700 });
  chmodSync(profileDir, 0o700);
  const context = await runtime.chromium.launchPersistentContext(profileDir, {
    headless: options.headless,
    executablePath,
    proxy,
    locale: options.locale,
    timezoneId: options.timezone,
    viewport: null,
    // Present as an ordinary browser: without these, navigator.webdriver is true
    // and Google serves /sorry/ on the first query (observed 2026-10-05).
    ignoreDefaultArgs: ['--enable-automation'],
    args: ['--disable-blink-features=AutomationControlled'],
  });
  return { context, browser: executablePath?.includes('Brave') ? 'brave' : 'chromium' };
}
