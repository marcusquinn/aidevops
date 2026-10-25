// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Playwright MCP `--init-page` hook for AIDEVOPS_PLAYWRIGHT_HEADED=hidden
// (GH#35617). Not used by Playwriter, which is a separate tool.
//
// Keeps a real headed browser (no headless UA or rendering differences) but
// minimises every page window as soon as @playwright/mcp creates it. Rendering,
// screenshots, clicks and extra tabs keep working while minimised. Off-screen
// --window-position does not work on macOS: the window is clamped onto a
// display.
//
// macOS: launching the browser can take keyboard focus. When the frontmost app
// is this server's own browser child process, focus returns to the previously
// frontmost app via LaunchServices (`open -b`, no Accessibility permission).
// Any other frontmost app is left alone.
//
// The hook never throws: a failure leaves the window visible and the page
// usable instead of breaking the MCP tab.

"use strict";

const { spawnSync } = require("node:child_process");

const COMMAND_TIMEOUT_MS = 3000;

/**
 * Run a command and return trimmed stdout, or "" on any failure.
 * @param {string} command
 * @param {string[]} args
 * @returns {string}
 */
function run(command, args) {
  const result = spawnSync(command, args, { encoding: "utf8", timeout: COMMAND_TIMEOUT_MS });
  if (result.error || result.status !== 0) return "";
  return (result.stdout || "").trim();
}

/**
 * Read one lsappinfo field value for an application ASN.
 * @param {string} asn
 * @param {string} field
 * @returns {string}
 */
function appInfo(asn, field) {
  const match = run("lsappinfo", ["info", "-only", field, asn]).match(/=\s*"?([^"]*)"?\s*$/);
  return match ? match[1] : "";
}

/**
 * Return the parent PID of a process, or 0 when unknown.
 * @param {number} pid
 * @returns {number}
 */
function parentPid(pid) {
  return Number(run("ps", ["-o", "ppid=", "-p", String(pid)])) || 0;
}

/**
 * Hand focus back when this server's own browser took it (macOS only).
 */
function restoreFocusFromOwnBrowser() {
  if (process.platform !== "darwin") return;
  const front = run("lsappinfo", ["front"]);
  const frontPid = Number(appInfo(front, "pid"));
  if (!front || !frontPid || parentPid(frontPid) !== process.pid) return;

  const order = run("lsappinfo", ["visibleProcessList"]).match(/ASN:0x[0-9a-f]+-0x[0-9a-f]+/gi) || [];
  const previous = order.find((asn) => asn !== front);
  if (!previous) return;
  const previousBundle = appInfo(previous, "bundleid");
  // The same bundle as our browser (e.g. the user's everyday Brave) cannot be
  // addressed unambiguously through LaunchServices; leave focus unchanged.
  if (!previousBundle || previousBundle === appInfo(front, "bundleid")) return;
  run("open", ["-b", previousBundle]);
}

/**
 * Minimise the window that hosts this page through CDP.
 * @param {import("playwright-core").Page} page
 */
async function minimiseWindow(page) {
  const session = await page.context().newCDPSession(page);
  try {
    const { windowId } = await session.send("Browser.getWindowForTarget");
    await session.send("Browser.setWindowBounds", { windowId, bounds: { windowState: "minimized" } });
  } finally {
    await session.detach().catch(() => {});
  }
}

/**
 * @param {{ page: import("playwright-core").Page }} options
 */
async function initPage({ page }) {
  try {
    await minimiseWindow(page);
  } catch (error) {
    process.stderr.write(`aidevops headed-hidden: window not minimised: ${error && error.message}\n`);
  }
  try {
    restoreFocusFromOwnBrowser();
  } catch {
    // Focus restoration is best effort.
  }
}

module.exports = { default: initPage };
