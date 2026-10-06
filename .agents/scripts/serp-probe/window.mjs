// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// macOS window control for serp-captcha-probe.mjs --hidden. Hiding the app
// (like Cmd-H) returns focus to the previous app, and pages still report
// visibilityState "visible" with animation frames running (verified
// 2026-10-05), so behaviour matches headed.

import { execFileSync } from 'node:child_process';

function macApp(pid, action) {
  const call = { hide: 'a.hide', show: '(a.unhide, a.activateWithOptions(0))', hidden: 'a.hidden' }[action];
  try {
    return execFileSync('osascript', ['-l', 'JavaScript', '-e',
      `ObjC.import('AppKit'); var a = $.NSRunningApplication.runningApplicationWithProcessIdentifier(${Number(pid)}); a.isNil() ? 'none' : String(${call})`],
    { encoding: 'utf8', timeout: 10_000 }).trim();
  } catch {
    return 'error';
  }
}

// The browser is a direct child of this Node process with a macOS app identity.
function findBrowserPid() {
  let children = [];
  try {
    children = execFileSync('pgrep', ['-P', String(process.pid)], { encoding: 'utf8' }).trim().split('\n').filter(Boolean);
  } catch {
    return null;
  }
  return children.find((pid) => !['none', 'error'].includes(macApp(pid, 'hidden'))) || null;
}

async function hideBrowser(pid) {
  for (let i = 0; i < 40; i += 1) {
    if (macApp(pid, 'hidden') === 'true') return true;
    macApp(pid, 'hide');
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  return false;
}

// Sets report.window and returns controls; showForHuman/rehide are no-ops
// unless --hidden succeeded.
export async function setupWindow(options, report, log) {
  report.window = options.headless ? 'headless' : 'visible';
  const browserPid = options.hidden ? findBrowserPid() : null;
  if (options.hidden) {
    report.window = browserPid && await hideBrowser(browserPid) ? 'hidden' : 'visible';
    if (report.window !== 'hidden') log('Could not hide the browser window; continuing visible');
  }
  const hidden = report.window === 'hidden';
  return {
    showForHuman: () => { if (hidden) macApp(browserPid, 'show'); },
    rehide: async () => { if (hidden) await hideBrowser(browserPid); },
  };
}
