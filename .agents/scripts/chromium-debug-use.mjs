#!/usr/bin/env node
// Adapted from the MIT-licensed pasky/chrome-cdp-skill project:
// https://github.com/pasky/chrome-cdp-skill
//
// Lightweight Chromium DevTools Protocol helper for aidevops.
// Uses raw CDP over WebSocket with Node 22+ built-in WebSocket support.

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { PAGES_CACHE, resolvePrefix } from './chromium-debug-use-lib/constants.mjs';
import { CDPClient } from './chromium-debug-use-lib/cdp-client.mjs';
import { getWsUrl } from './chromium-debug-use-lib/connection.mjs';
import { browserVersionStr, formatPageList, getPages } from './chromium-debug-use-lib/commands.mjs';
import { getOrStartTabDaemon, runDaemon, sendCommand, stopDaemons } from './chromium-debug-use-lib/daemon.mjs';

const USAGE = `chromium-debug-use - lightweight Chromium DevTools Protocol CLI

Usage: chromium-debug-use <command> [args]

  version                           Show connected browser version info
  list                              List open pages (shows unique target prefixes)
  open [url]                        Open a new tab (default: about:blank)
  snap  <target>                    Accessibility tree snapshot
  eval  <target> <expr>             Evaluate a JavaScript expression
  shot  <target> [file]             Save a viewport screenshot
  html  <target> [selector]         Get HTML (full page or CSS selector)
  nav   <target> <url>              Navigate to URL and wait for load completion
  click   <target> <selector>       Click an element by CSS selector
  clickxy <target> <x> <y>          Click at CSS pixel coordinates
  type    <target> <text>           Type text at current focus via Input.insertText
  loadall <target> <selector> [ms]  Repeatedly click a selector until it disappears
  evalraw <target> <method> [json]  Send a raw CDP command and print JSON result
  stop  [target]                    Stop daemon(s)

<target> is a unique targetId prefix from "list". If a prefix is ambiguous,
use more characters.

Environment:
  CHROMIUM_DEBUG_USE_BROWSER_URL    Browser debugging base URL (default fallback: http://127.0.0.1:9222)
  CHROMIUM_DEBUG_USE_WS_ENDPOINT    Explicit browser WebSocket endpoint
`;

const PAGE_COMMANDS = new Set([
  'snap', 'snapshot', 'eval', 'shot', 'screenshot',
  'html', 'nav', 'navigate', 'click', 'clickxy',
  'type', 'loadall', 'evalraw',
]);

// --- Command handlers ---

async function runVersionCommand() {
  const cdp = new CDPClient();
  await cdp.connect(await getWsUrl());
  console.log(await browserVersionStr(cdp));
  cdp.close();
}

async function runListCommand() {
  const cdp = new CDPClient();
  await cdp.connect(await getWsUrl());
  const pages = await getPages(cdp);
  cdp.close();
  writeFileSync(PAGES_CACHE, JSON.stringify(pages), { mode: 0o600 });
  console.log(formatPageList(pages));
  setTimeout(() => process.exit(0), 100);
}

async function runOpenCommand(args) {
  const url = args[0] || 'about:blank';
  const cdp = new CDPClient();
  await cdp.connect(await getWsUrl());
  const { targetId } = await cdp.send('Target.createTarget', { url });
  const pages = await getPages(cdp);
  if (!pages.some((page) => page.targetId === targetId)) {
    pages.push({ targetId, title: url, url });
  }
  cdp.close();
  writeFileSync(PAGES_CACHE, JSON.stringify(pages), { mode: 0o600 });
  console.log(`Opened new tab: ${targetId.slice(0, 8)}  ${url}`);
  console.log('Note: this tab may prompt once for debugging approval on first access.');
}

function normalizePageArgs(command, commandArgs) {
  const normalized = [...commandArgs];

  if (command === 'eval') {
    const expression = normalized.join(' ');
    if (!expression) {
      console.error('Error: expression required');
      process.exit(1);
    }
    normalized[0] = expression;
  } else if (command === 'type') {
    const text = normalized.join(' ');
    if (!text) {
      console.error('Error: text required');
      process.exit(1);
    }
    normalized[0] = text;
  } else if (command === 'evalraw') {
    if (!normalized[0]) {
      console.error('Error: CDP method required');
      process.exit(1);
    }
    if (normalized.length > 2) {
      normalized[1] = normalized.slice(1).join(' ');
    }
  }

  if ((command === 'nav' || command === 'navigate') && !normalized[0]) {
    console.error('Error: URL required');
    process.exit(1);
  }

  return normalized;
}

async function runPageCommand(command, args) {
  const targetPrefix = args[0];
  if (!targetPrefix) {
    console.error('Error: target ID required. Run "list" first.');
    process.exit(1);
  }

  if (!existsSync(PAGES_CACHE)) {
    console.error('No page list cached. Run "list" first.');
    process.exit(1);
  }

  const pages = JSON.parse(readFileSync(PAGES_CACHE, 'utf8'));
  const targetId = resolvePrefix(targetPrefix, pages.map((page) => page.targetId), 'target', 'Run "list".');
  const connection = await getOrStartTabDaemon(targetId);

  const commandArgs = normalizePageArgs(command, args.slice(1));
  const response = await sendCommand(connection, { cmd: command, args: commandArgs });

  if (response.ok) {
    if (response.result) console.log(response.result);
    return;
  }

  console.error('Error:', response.error);
  process.exit(1);
}

// --- Main dispatch ---

const MAIN_COMMANDS = {
  _daemon: (args) => runDaemon(args[0]),
  version: () => runVersionCommand(),
  list: () => runListCommand(),
  ls: () => runListCommand(),
  open: (args) => runOpenCommand(args),
  stop: (args) => stopDaemons(args[0]),
};

function isHelpRequest(command) {
  return !command || command === 'help' || command === '--help' || command === '-h';
}

async function main() {
  const [command, ...args] = process.argv.slice(2);

  if (isHelpRequest(command)) {
    console.log(USAGE);
    process.exit(0);
  }

  const directHandler = MAIN_COMMANDS[command];
  if (directHandler) return directHandler(args);

  if (!PAGE_COMMANDS.has(command)) {
    console.error(`Unknown command: ${command}\n`);
    console.log(USAGE);
    process.exit(1);
  }

  return runPageCommand(command, args);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
