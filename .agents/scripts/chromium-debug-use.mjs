#!/usr/bin/env node
// Adapted from the MIT-licensed pasky/chrome-cdp-skill project:
// https://github.com/pasky/chrome-cdp-skill
//
// Lightweight Chromium DevTools Protocol helper for aidevops.
// Uses raw CDP over WebSocket with Node 22+ built-in WebSocket support.

import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolve } from 'node:path';
import { spawn } from 'node:child_process';
import net from 'node:net';

const TIMEOUT_MS = 15000;
const NAVIGATION_TIMEOUT_MS = 30000;
const IDLE_TIMEOUT_MS = 20 * 60 * 1000;
const DAEMON_CONNECT_RETRIES = 20;
const DAEMON_CONNECT_DELAY_MS = 300;
const MIN_TARGET_PREFIX_LEN = 8;
const IS_WINDOWS = process.platform === 'win32';

if (!IS_WINDOWS) process.umask(0o077);

const RUNTIME_DIR = resolve(homedir(), '.aidevops', 'chromium-debug-use');
const CACHE_DIR = resolve(RUNTIME_DIR, 'runtime');
const PAGES_CACHE = resolve(CACHE_DIR, 'pages.json');

try {
  mkdirSync(CACHE_DIR, { recursive: true, mode: 0o700 });
} catch {
  // ignored
}

function socketPath(targetId) {
  if (IS_WINDOWS) {
    return `\\\\.\\pipe\\chromium-debug-use-${targetId}`;
  }
  return resolve(CACHE_DIR, `chromium-debug-use-${targetId}.sock`);
}

function sleep(ms) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, ms));
}

function normalizeBrowserUrl(raw) {
  if (!raw) return '';
  const trimmed = raw.endsWith('/') ? raw.slice(0, -1) : raw;
  return trimmed;
}

async function tryBrowserUrl(browserUrl) {
  const normalized = normalizeBrowserUrl(browserUrl);
  if (!normalized) return null;

  try {
    const versionUrl = new URL('/json/version', normalized);
    const response = await fetch(versionUrl);
    if (!response.ok) return null;
    const payload = await response.json();
    return payload.webSocketDebuggerUrl || null;
  } catch {
    return null;
  }
}

async function getWsUrl() {
  const explicitWsEndpoint = process.env.CHROMIUM_DEBUG_USE_WS_ENDPOINT || process.env.CDP_WS_ENDPOINT || '';
  if (explicitWsEndpoint) return explicitWsEndpoint;

  const browserUrlCandidates = [
    process.env.CHROMIUM_DEBUG_USE_BROWSER_URL || '',
    process.env.CDP_BROWSER_URL || '',
    'http://127.0.0.1:9222',
  ].filter(Boolean);

  for (const browserUrl of browserUrlCandidates) {
    const wsUrl = await tryBrowserUrl(browserUrl);
    if (wsUrl) return wsUrl;
  }

  const home = homedir();
  const macBrowsers = [
    'Google/Chrome',
    'Google/Chrome Beta',
    'Google/Chrome for Testing',
    'Chromium',
    'BraveSoftware/Brave-Browser',
    'Microsoft Edge',
    'Vivaldi',
    'Ungoogled Chromium',
  ];
  const linuxBrowsers = [
    'google-chrome',
    'google-chrome-beta',
    'chromium',
    'vivaldi',
    'vivaldi-snapshot',
    'BraveSoftware/Brave-Browser',
    'microsoft-edge',
    'ungoogled-chromium',
  ];
  const flatpakBrowsers = [
    ['org.chromium.Chromium', 'chromium'],
    ['com.google.Chrome', 'google-chrome'],
    ['com.brave.Browser', 'BraveSoftware/Brave-Browser'],
    ['com.microsoft.Edge', 'microsoft-edge'],
    ['com.vivaldi.Vivaldi', 'vivaldi'],
  ];

  const candidates = [
    process.env.CDP_PORT_FILE || '',
    ...macBrowsers.flatMap((browserName) => [
      resolve(home, 'Library/Application Support', browserName, 'DevToolsActivePort'),
      resolve(home, 'Library/Application Support', browserName, 'Default/DevToolsActivePort'),
    ]),
    ...linuxBrowsers.flatMap((browserName) => [
      resolve(home, '.config', browserName, 'DevToolsActivePort'),
      resolve(home, '.config', browserName, 'Default/DevToolsActivePort'),
    ]),
    ...flatpakBrowsers.flatMap(([appId, browserName]) => [
      resolve(home, '.var/app', appId, 'config', browserName, 'DevToolsActivePort'),
      resolve(home, '.var/app', appId, 'config', browserName, 'Default/DevToolsActivePort'),
    ]),
    ...(IS_WINDOWS
      ? ['Google/Chrome', 'BraveSoftware/Brave-Browser', 'Microsoft/Edge', 'Vivaldi', 'Chromium'].flatMap((browserName) => {
          const localAppData = process.env.LOCALAPPDATA || resolve(home, 'AppData', 'Local');
          return [
            resolve(localAppData, browserName, 'User Data/DevToolsActivePort'),
            resolve(localAppData, browserName, 'User Data/Default/DevToolsActivePort'),
          ];
        })
      : []),
  ].filter(Boolean);

  const portFile = candidates.find((candidate) => existsSync(candidate));
  if (!portFile) {
    throw new Error(
      'No Chromium debugging endpoint found. Launch a browser with --remote-debugging-port=9222 or set CHROMIUM_DEBUG_USE_BROWSER_URL.'
    );
  }

  const lines = readFileSync(portFile, 'utf8').trim().split('\n');
  if (lines.length < 2 || !lines[0] || !lines[1]) {
    throw new Error(`Invalid DevToolsActivePort file: ${portFile}`);
  }

  const host = process.env.CDP_HOST || '127.0.0.1';
  return `ws://${host}:${lines[0]}${lines[1]}`;
}

function resolvePrefix(prefix, candidates, noun = 'target', missingHint = '') {
  const upperPrefix = prefix.toUpperCase();
  const matches = candidates.filter((candidate) => candidate.toUpperCase().startsWith(upperPrefix));

  if (matches.length === 0) {
    const hint = missingHint ? ` ${missingHint}` : '';
    throw new Error(`No ${noun} matching prefix "${prefix}".${hint}`);
  }

  if (matches.length > 1) {
    throw new Error(`Ambiguous prefix "${prefix}" — matches ${matches.length} ${noun}s. Use more characters.`);
  }

  return matches[0];
}

function getDisplayPrefixLength(targetIds) {
  if (targetIds.length === 0) return MIN_TARGET_PREFIX_LEN;

  const maxLength = Math.max(...targetIds.map((targetId) => targetId.length));
  for (let length = MIN_TARGET_PREFIX_LEN; length <= maxLength; length += 1) {
    const prefixes = new Set(targetIds.map((targetId) => targetId.slice(0, length).toUpperCase()));
    if (prefixes.size === targetIds.length) return length;
  }

  return maxLength;
}

class CDPClient {
  #ws;
  #id = 0;
  #pending = new Map();
  #eventHandlers = new Map();
  #closeHandlers = [];

  async connect(wsUrl) {
    return new Promise((resolvePromise, rejectPromise) => {
      this.#ws = new WebSocket(wsUrl);

      this.#ws.onopen = () => resolvePromise();
      this.#ws.onerror = (event) => rejectPromise(new Error(`WebSocket error: ${event.message || event.type}`));
      this.#ws.onclose = () => {
        for (const handler of this.#closeHandlers) handler();
      };
      this.#ws.onmessage = (event) => {
        const message = JSON.parse(event.data);

        if (message.id && this.#pending.has(message.id)) {
          const { resolve, reject } = this.#pending.get(message.id);
          this.#pending.delete(message.id);
          if (message.error) reject(new Error(message.error.message));
          else resolve(message.result);
          return;
        }

        if (message.method && this.#eventHandlers.has(message.method)) {
          for (const handler of [...this.#eventHandlers.get(message.method)]) {
            handler(message.params || {}, message);
          }
        }
      };
    });
  }

  async send(method, params = {}, sessionId) {
    const id = this.#id + 1;
    this.#id = id;

    return new Promise((resolvePromise, rejectPromise) => {
      this.#pending.set(id, { resolve: resolvePromise, reject: rejectPromise });
      const message = { id, method, params };
      if (sessionId) message.sessionId = sessionId;
      this.#ws.send(JSON.stringify(message));

      setTimeout(() => {
        if (!this.#pending.has(id)) return;
        this.#pending.delete(id);
        rejectPromise(new Error(`Timeout: ${method}`));
      }, TIMEOUT_MS);
    });
  }

  onEvent(method, handler) {
    if (!this.#eventHandlers.has(method)) this.#eventHandlers.set(method, new Set());
    const handlers = this.#eventHandlers.get(method);
    handlers.add(handler);

    return () => {
      handlers.delete(handler);
      if (handlers.size === 0) this.#eventHandlers.delete(method);
    };
  }

  waitForEvent(method, timeoutMs = TIMEOUT_MS) {
    let settled = false;
    let unsubscribe;
    let timer;

    const promise = new Promise((resolvePromise, rejectPromise) => {
      unsubscribe = this.onEvent(method, (params) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        unsubscribe();
        resolvePromise(params);
      });

      timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        unsubscribe();
        rejectPromise(new Error(`Timeout waiting for event: ${method}`));
      }, timeoutMs);
    });

    return {
      promise,
      cancel() {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        unsubscribe?.();
      },
    };
  }

  onClose(handler) {
    this.#closeHandlers.push(handler);
  }

  close() {
    this.#ws.close();
  }
}

async function getPages(cdp) {
  const { targetInfos } = await cdp.send('Target.getTargets');
  return targetInfos.filter((targetInfo) => targetInfo.type === 'page' && !targetInfo.url.startsWith('chrome://'));
}

function formatPageList(pages) {
  const prefixLength = getDisplayPrefixLength(pages.map((page) => page.targetId));
  return pages
    .map((page) => {
      const id = page.targetId.slice(0, prefixLength).padEnd(prefixLength);
      const title = page.title.substring(0, 54).padEnd(54);
      return `${id}  ${title}  ${page.url}`;
    })
    .join('\n');
}

function shouldShowAxNode(node, compact = false) {
  const role = node.role?.value || '';
  const name = node.name?.value ?? '';
  const value = node.value?.value;
  if (compact && role === 'InlineTextBox') return false;
  return role !== 'none' && role !== 'generic' && !(name === '' && (value === '' || value == null));
}

function formatAxNode(node, depth) {
  const role = node.role?.value || '';
  const name = node.name?.value ?? '';
  const value = node.value?.value;
  const indent = '  '.repeat(Math.min(depth, 10));
  let line = `${indent}[${role}]`;
  if (name !== '') line += ` ${name}`;
  if (!(value === '' || value == null)) line += ` = ${JSON.stringify(value)}`;
  return line;
}

function orderedAxChildren(node, nodesById, childrenByParent) {
  const children = [];
  const seen = new Set();

  for (const childId of node.childIds || []) {
    const child = nodesById.get(childId);
    if (child && !seen.has(child.nodeId)) {
      seen.add(child.nodeId);
      children.push(child);
    }
  }

  for (const child of childrenByParent.get(node.nodeId) || []) {
    if (!seen.has(child.nodeId)) {
      seen.add(child.nodeId);
      children.push(child);
    }
  }

  return children;
}

async function snapshotStr(cdp, sessionId, compact = false) {
  const { nodes } = await cdp.send('Accessibility.getFullAXTree', {}, sessionId);
  const nodesById = new Map(nodes.map((node) => [node.nodeId, node]));
  const childrenByParent = new Map();

  for (const node of nodes) {
    if (!node.parentId) continue;
    if (!childrenByParent.has(node.parentId)) childrenByParent.set(node.parentId, []);
    childrenByParent.get(node.parentId).push(node);
  }

  const lines = [];
  const visited = new Set();

  function visit(node, depth) {
    if (!node || visited.has(node.nodeId)) return;
    visited.add(node.nodeId);
    if (shouldShowAxNode(node, compact)) lines.push(formatAxNode(node, depth));
    for (const child of orderedAxChildren(node, nodesById, childrenByParent)) {
      visit(child, depth + 1);
    }
  }

  const roots = nodes.filter((node) => !node.parentId || !nodesById.has(node.parentId));
  for (const root of roots) visit(root, 0);
  for (const node of nodes) visit(node, 0);

  return lines.join('\n');
}

async function evalStr(cdp, sessionId, expression) {
  await cdp.send('Runtime.enable', {}, sessionId);
  const result = await cdp.send(
    'Runtime.evaluate',
    { expression, returnByValue: true, awaitPromise: true },
    sessionId
  );

  if (result.exceptionDetails) {
    throw new Error(result.exceptionDetails.text || result.exceptionDetails.exception?.description || 'Runtime evaluation failed');
  }

  const value = result.result.value;
  if (typeof value === 'object') return JSON.stringify(value, null, 2);
  return String(value ?? '');
}

async function shotStr(cdp, sessionId, filePath, targetId) {
  let dpr = 1;
  try {
    const raw = await evalStr(cdp, sessionId, 'window.devicePixelRatio');
    const parsed = Number.parseFloat(raw);
    if (!Number.isNaN(parsed) && parsed > 0) dpr = parsed;
  } catch {
    // ignored
  }

  const { data } = await cdp.send('Page.captureScreenshot', { format: 'png' }, sessionId);
  const outputPath = filePath || resolve(CACHE_DIR, `screenshot-${(targetId || 'unknown').slice(0, 8)}.png`);
  writeFileSync(outputPath, Buffer.from(data, 'base64'));

  const lines = [outputPath];
  lines.push(`Screenshot saved. Device pixel ratio (DPR): ${dpr}`);
  lines.push('Coordinate mapping:');
  lines.push(`  Screenshot pixels -> CSS pixels (for CDP Input events): divide by ${dpr}`);
  lines.push(`  Example: screenshot (${Math.round(100 * dpr)}, ${Math.round(200 * dpr)}) -> CSS (100, 200)`);
  return lines.join('\n');
}

async function htmlStr(cdp, sessionId, selector) {
  const expression = selector
    ? `document.querySelector(${JSON.stringify(selector)})?.outerHTML || 'Element not found'`
    : 'document.documentElement.outerHTML';
  return evalStr(cdp, sessionId, expression);
}

async function waitForDocumentReady(cdp, sessionId, timeoutMs = NAVIGATION_TIMEOUT_MS) {
  const deadline = Date.now() + timeoutMs;
  let lastState = '';
  let lastError;

  while (Date.now() < deadline) {
    try {
      const state = await evalStr(cdp, sessionId, 'document.readyState');
      lastState = state;
      if (state === 'complete') return;
    } catch (error) {
      lastError = error;
    }
    await sleep(200);
  }

  if (lastState) throw new Error(`Timed out waiting for navigation to finish (last readyState: ${lastState})`);
  if (lastError) throw new Error(`Timed out waiting for navigation to finish (${lastError.message})`);
  throw new Error('Timed out waiting for navigation to finish');
}

async function navStr(cdp, sessionId, url) {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      throw new Error(`Only http/https URLs allowed, got: ${url}`);
    }
  } catch (error) {
    if (error.message.startsWith('Only')) throw error;
    throw new Error(`Invalid URL: ${url}`);
  }

  await cdp.send('Page.enable', {}, sessionId);
  const loadEvent = cdp.waitForEvent('Page.loadEventFired', NAVIGATION_TIMEOUT_MS);
  const result = await cdp.send('Page.navigate', { url }, sessionId);

  if (result.errorText) {
    loadEvent.cancel();
    throw new Error(result.errorText);
  }

  if (result.loaderId) {
    await loadEvent.promise;
  } else {
    loadEvent.cancel();
  }

  await waitForDocumentReady(cdp, sessionId, 5000);
  return `Navigated to ${url}`;
}

async function clickStr(cdp, sessionId, selector) {
  if (!selector) throw new Error('CSS selector required');

  const expression = `
    (() => {
      const el = document.querySelector(${JSON.stringify(selector)});
      if (!el) return { ok: false, error: 'Element not found: ' + ${JSON.stringify(selector)} };
      el.scrollIntoView({ block: 'center' });
      el.click();
      return { ok: true, tag: el.tagName, text: (el.textContent || '').trim().substring(0, 80) };
    })()
  `;

  const raw = await evalStr(cdp, sessionId, expression);
  const result = JSON.parse(raw);
  if (!result.ok) throw new Error(result.error);
  return `Clicked <${result.tag}> "${result.text}"`;
}

async function clickXyStr(cdp, sessionId, x, y) {
  const cssX = Number.parseFloat(x);
  const cssY = Number.parseFloat(y);
  if (Number.isNaN(cssX) || Number.isNaN(cssY)) {
    throw new Error('x and y must be numbers (CSS pixels)');
  }

  const base = { x: cssX, y: cssY, button: 'left', clickCount: 1, modifiers: 0 };
  await cdp.send('Input.dispatchMouseEvent', { ...base, type: 'mouseMoved' }, sessionId);
  await cdp.send('Input.dispatchMouseEvent', { ...base, type: 'mousePressed' }, sessionId);
  await sleep(50);
  await cdp.send('Input.dispatchMouseEvent', { ...base, type: 'mouseReleased' }, sessionId);
  return `Clicked at CSS (${cssX}, ${cssY})`;
}

async function typeStr(cdp, sessionId, text) {
  if (text == null || text === '') throw new Error('text required');
  await cdp.send('Input.insertText', { text }, sessionId);
  return `Typed ${text.length} characters`;
}

async function loadAllStr(cdp, sessionId, selector, intervalMs = 1500) {
  if (!selector) throw new Error('CSS selector required');

  let clicks = 0;
  const deadline = Date.now() + 5 * 60 * 1000;
  while (Date.now() < deadline) {
    const exists = await evalStr(cdp, sessionId, `!!document.querySelector(${JSON.stringify(selector)})`);
    if (exists !== 'true') break;

    const clicked = await evalStr(
      cdp,
      sessionId,
      `(() => {
        const el = document.querySelector(${JSON.stringify(selector)});
        if (!el) return false;
        el.scrollIntoView({ block: 'center' });
        el.click();
        return true;
      })()`
    );

    if (clicked !== 'true') break;
    clicks += 1;
    await sleep(intervalMs);
  }

  return `Clicked "${selector}" ${clicks} time(s) until it disappeared`;
}

async function evalRawStr(cdp, sessionId, method, paramsJson) {
  if (!method) throw new Error('CDP method required (e.g. "DOM.getDocument")');

  let params = {};
  if (paramsJson) {
    try {
      params = JSON.parse(paramsJson);
    } catch {
      throw new Error(`Invalid JSON params: ${paramsJson}`);
    }
  }

  const result = await cdp.send(method, params, sessionId);
  return JSON.stringify(result, null, 2);
}

async function browserVersionStr(cdp) {
  const version = await cdp.send('Browser.getVersion');
  return JSON.stringify(
    {
      product: version.product,
      protocolVersion: version.protocolVersion,
      revision: version.revision,
      userAgent: version.userAgent,
      jsVersion: version.jsVersion,
    },
    null,
    2
  );
}

async function runDaemon(targetId) {
  const socket = socketPath(targetId);
  const cdp = new CDPClient();

  try {
    await cdp.connect(await getWsUrl());
  } catch (error) {
    process.stderr.write(`Daemon: cannot connect to Chromium: ${error.message}\n`);
    process.exit(1);
  }

  let sessionId;
  try {
    const result = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
    sessionId = result.sessionId;
  } catch (error) {
    process.stderr.write(`Daemon: attach failed: ${error.message}\n`);
    cdp.close();
    process.exit(1);
  }

  let server;
  let alive = true;

  function shutdown() {
    if (!alive) return;
    alive = false;
    server.close();
    if (!IS_WINDOWS) {
      try {
        unlinkSync(socket);
      } catch {
        // ignored
      }
    }
    cdp.close();
    process.exit(0);
  }

  cdp.onEvent('Target.targetDestroyed', (params) => {
    if (params.targetId === targetId) shutdown();
  });
  cdp.onEvent('Target.detachedFromTarget', (params) => {
    if (params.sessionId === sessionId) shutdown();
  });
  cdp.onClose(() => shutdown());
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);

  let idleTimer = setTimeout(shutdown, IDLE_TIMEOUT_MS);
  function resetIdle() {
    clearTimeout(idleTimer);
    idleTimer = setTimeout(shutdown, IDLE_TIMEOUT_MS);
  }

  async function handleCommand({ cmd, args }) {
    resetIdle();
    try {
      let result = '';
      switch (cmd) {
        case 'list': {
          const pages = await getPages(cdp);
          result = formatPageList(pages);
          break;
        }
        case 'list_raw': {
          const pages = await getPages(cdp);
          result = JSON.stringify(pages);
          break;
        }
        case 'version':
          result = await browserVersionStr(cdp);
          break;
        case 'snap':
        case 'snapshot':
          result = await snapshotStr(cdp, sessionId, true);
          break;
        case 'eval':
          result = await evalStr(cdp, sessionId, args[0]);
          break;
        case 'shot':
        case 'screenshot':
          result = await shotStr(cdp, sessionId, args[0], targetId);
          break;
        case 'html':
          result = await htmlStr(cdp, sessionId, args[0]);
          break;
        case 'nav':
        case 'navigate':
          result = await navStr(cdp, sessionId, args[0]);
          break;
        case 'click':
          result = await clickStr(cdp, sessionId, args[0]);
          break;
        case 'clickxy':
          result = await clickXyStr(cdp, sessionId, args[0], args[1]);
          break;
        case 'type':
          result = await typeStr(cdp, sessionId, args[0]);
          break;
        case 'loadall':
          result = await loadAllStr(cdp, sessionId, args[0], args[1] ? Number.parseInt(args[1], 10) : 1500);
          break;
        case 'evalraw':
          result = await evalRawStr(cdp, sessionId, args[0], args[1]);
          break;
        case 'stop':
          return { ok: true, result: '', stopAfter: true };
        default:
          return { ok: false, error: `Unknown command: ${cmd}` };
      }

      return { ok: true, result: result || '' };
    } catch (error) {
      return { ok: false, error: error.message };
    }
  }

  server = net.createServer((connection) => {
    let buffer = '';

    connection.on('data', (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split('\n');
      buffer = lines.pop();

      for (const line of lines) {
        if (!line.trim()) continue;

        let request;
        try {
          request = JSON.parse(line);
        } catch {
          connection.write(`${JSON.stringify({ ok: false, error: 'Invalid JSON request', id: null })}\n`);
          continue;
        }

        handleCommand(request).then((response) => {
          const payload = `${JSON.stringify({ ...response, id: request.id })}\n`;
          if (response.stopAfter) {
            connection.end(payload, shutdown);
          } else {
            connection.write(payload);
          }
        });
      }
    });
  });

  server.on('error', (error) => {
    process.stderr.write(`Daemon server listen failed: ${error.message}\n`);
    process.exit(1);
  });

  if (!IS_WINDOWS) {
    try {
      unlinkSync(socket);
    } catch {
      // ignored
    }
  }

  server.listen(socket);
}

function connectToSocket(socket) {
  return new Promise((resolvePromise, rejectPromise) => {
    const connection = net.connect(socket);
    connection.on('connect', () => resolvePromise(connection));
    connection.on('error', rejectPromise);
  });
}

async function getOrStartTabDaemon(targetId) {
  const socket = socketPath(targetId);
  try {
    return await connectToSocket(socket);
  } catch {
    // ignored
  }

  if (!IS_WINDOWS) {
    try {
      unlinkSync(socket);
    } catch {
      // ignored
    }
  }

  const child = spawn(process.execPath, [process.argv[1], '_daemon', targetId], {
    detached: true,
    stdio: 'ignore',
  });
  child.unref();

  for (let index = 0; index < DAEMON_CONNECT_RETRIES; index += 1) {
    await sleep(DAEMON_CONNECT_DELAY_MS);
    try {
      return await connectToSocket(socket);
    } catch {
      // ignored
    }
  }

  throw new Error('Daemon failed to start — confirm the browser approved debugging access and the endpoint is reachable.');
}

function sendCommand(connection, request) {
  return new Promise((resolvePromise, rejectPromise) => {
    let buffer = '';
    let settled = false;

    const cleanup = () => {
      connection.off('data', onData);
      connection.off('error', onError);
      connection.off('end', onEnd);
      connection.off('close', onClose);
    };

    const onData = (chunk) => {
      buffer += chunk.toString();
      const newlineIndex = buffer.indexOf('\n');
      if (newlineIndex === -1) return;
      settled = true;
      cleanup();
      resolvePromise(JSON.parse(buffer.slice(0, newlineIndex)));
      connection.end();
    };

    const onError = (error) => {
      if (settled) return;
      settled = true;
      cleanup();
      rejectPromise(error);
    };

    const onEnd = () => {
      if (settled) return;
      settled = true;
      cleanup();
      rejectPromise(new Error('Connection closed before response'));
    };

    const onClose = () => {
      if (settled) return;
      settled = true;
      cleanup();
      rejectPromise(new Error('Connection closed before response'));
    };

    connection.on('data', onData);
    connection.on('error', onError);
    connection.on('end', onEnd);
    connection.on('close', onClose);
    request.id = 1;
    connection.write(`${JSON.stringify(request)}\n`);
  });
}

async function stopDaemons(targetPrefix) {
  if (!existsSync(PAGES_CACHE)) return;

  const pages = JSON.parse(readFileSync(PAGES_CACHE, 'utf8'));
  const targets = targetPrefix
    ? [resolvePrefix(targetPrefix, pages.map((page) => page.targetId), 'target')]
    : pages.map((page) => page.targetId);

  for (const targetId of targets) {
    const socket = socketPath(targetId);
    try {
      const connection = await connectToSocket(socket);
      await sendCommand(connection, { cmd: 'stop' });
    } catch {
      if (!IS_WINDOWS) {
        try {
          unlinkSync(socket);
        } catch {
          // ignored
        }
      }
    }
  }
}

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
  'snap',
  'snapshot',
  'eval',
  'shot',
  'screenshot',
  'html',
  'nav',
  'navigate',
  'click',
  'clickxy',
  'type',
  'loadall',
  'evalraw',
]);

async function main() {
  const [command, ...args] = process.argv.slice(2);

  if (command === '_daemon') {
    await runDaemon(args[0]);
    return;
  }

  if (!command || command === 'help' || command === '--help' || command === '-h') {
    console.log(USAGE);
    process.exit(0);
  }

  if (command === 'version') {
    const cdp = new CDPClient();
    await cdp.connect(await getWsUrl());
    console.log(await browserVersionStr(cdp));
    cdp.close();
    return;
  }

  if (command === 'list' || command === 'ls') {
    const cdp = new CDPClient();
    await cdp.connect(await getWsUrl());
    const pages = await getPages(cdp);
    cdp.close();
    writeFileSync(PAGES_CACHE, JSON.stringify(pages), { mode: 0o600 });
    console.log(formatPageList(pages));
    setTimeout(() => process.exit(0), 100);
    return;
  }

  if (command === 'open') {
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
    return;
  }

  if (command === 'stop') {
    await stopDaemons(args[0]);
    return;
  }

  if (!PAGE_COMMANDS.has(command)) {
    console.error(`Unknown command: ${command}\n`);
    console.log(USAGE);
    process.exit(1);
  }

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

  const commandArgs = args.slice(1);
  if (command === 'eval') {
    const expression = commandArgs.join(' ');
    if (!expression) {
      console.error('Error: expression required');
      process.exit(1);
    }
    commandArgs[0] = expression;
  } else if (command === 'type') {
    const text = commandArgs.join(' ');
    if (!text) {
      console.error('Error: text required');
      process.exit(1);
    }
    commandArgs[0] = text;
  } else if (command === 'evalraw') {
    if (!commandArgs[0]) {
      console.error('Error: CDP method required');
      process.exit(1);
    }
    if (commandArgs.length > 2) {
      commandArgs[1] = commandArgs.slice(1).join(' ');
    }
  }

  if ((command === 'nav' || command === 'navigate') && !commandArgs[0]) {
    console.error('Error: URL required');
    process.exit(1);
  }

  const response = await sendCommand(connection, { cmd: command, args: commandArgs });
  if (response.ok) {
    if (response.result) console.log(response.result);
    return;
  }

  console.error('Error:', response.error);
  process.exit(1);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
