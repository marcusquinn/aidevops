// Daemon lifecycle — per-tab CDP daemon process management.

import { existsSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import net from 'node:net';
import {
  DAEMON_CONNECT_DELAY_MS,
  DAEMON_CONNECT_RETRIES,
  IDLE_TIMEOUT_MS,
  IS_WINDOWS,
  PAGES_CACHE,
  cleanupStaleSocket,
  resolvePrefix,
  sleep,
  socketPath,
} from './constants.mjs';
import { CDPClient } from './cdp-client.mjs';
import { getWsUrl } from './connection.mjs';
import {
  browserVersionStr,
  clickStr,
  clickXyStr,
  evalRawStr,
  evalStr,
  formatPageList,
  getPages,
  htmlStr,
  loadAllStr,
  navStr,
  shotStr,
  snapshotStr,
  typeStr,
} from './commands.mjs';

// --- Daemon command registry ---

function buildDaemonCommands(cdp, sessionId, targetId) {
  return {
    list: () => getPages(cdp).then((pages) => formatPageList(pages)),
    list_raw: () => getPages(cdp).then((pages) => JSON.stringify(pages)),
    version: () => browserVersionStr(cdp),
    snap: () => snapshotStr(cdp, sessionId, true),
    snapshot: () => snapshotStr(cdp, sessionId, true),
    eval: (args) => evalStr(cdp, sessionId, args[0]),
    shot: (args) => shotStr(cdp, sessionId, args[0], targetId),
    screenshot: (args) => shotStr(cdp, sessionId, args[0], targetId),
    html: (args) => htmlStr(cdp, sessionId, args[0]),
    nav: (args) => navStr(cdp, sessionId, args[0]),
    navigate: (args) => navStr(cdp, sessionId, args[0]),
    click: (args) => clickStr(cdp, sessionId, args[0]),
    clickxy: (args) => clickXyStr(cdp, sessionId, args[0], args[1]),
    type: (args) => typeStr(cdp, sessionId, args[0]),
    loadall: (args) => loadAllStr(cdp, sessionId, args[0], args[1] ? Number.parseInt(args[1], 10) : 1500),
    evalraw: (args) => evalRawStr(cdp, sessionId, args[0], args[1]),
  };
}

async function dispatchDaemonCommand(commands, cmd, args) {
  if (cmd === 'stop') return { ok: true, result: '', stopAfter: true };

  const handler = commands[cmd];
  if (!handler) return { ok: false, error: `Unknown command: ${cmd}` };

  try {
    const result = await handler(args);
    return { ok: true, result: result || '' };
  } catch (error) {
    return { ok: false, error: error.message };
  }
}

// --- Daemon lifecycle helpers ---

async function connectDaemonCdp(targetId) {
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

  return { cdp, sessionId };
}

function createDaemonShutdown(socket, cdp, serverRef) {
  let alive = true;

  function shutdown() {
    if (!alive) return;
    alive = false;
    serverRef.server.close();
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

  return shutdown;
}

function wireDaemonEvents(cdp, targetId, sessionId, shutdown) {
  cdp.onEvent('Target.targetDestroyed', (params) => {
    if (params.targetId === targetId) shutdown();
  });
  cdp.onEvent('Target.detachedFromTarget', (params) => {
    if (params.sessionId === sessionId) shutdown();
  });
  cdp.onClose(() => shutdown());
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

function createIdleTimer(shutdown) {
  let idleTimer = setTimeout(shutdown, IDLE_TIMEOUT_MS);

  function resetIdle() {
    clearTimeout(idleTimer);
    idleTimer = setTimeout(shutdown, IDLE_TIMEOUT_MS);
  }

  return resetIdle;
}

function createDaemonServer(commands, resetIdle, shutdown) {
  return net.createServer((connection) => {
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

        resetIdle();
        dispatchDaemonCommand(commands, request.cmd, request.args).then((response) => {
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
}

export async function runDaemon(targetId) {
  const socket = socketPath(targetId);
  const { cdp, sessionId } = await connectDaemonCdp(targetId);

  const serverRef = { server: null };
  const shutdown = createDaemonShutdown(socket, cdp, serverRef);
  wireDaemonEvents(cdp, targetId, sessionId, shutdown);
  const resetIdle = createIdleTimer(shutdown);

  const commands = buildDaemonCommands(cdp, sessionId, targetId);
  const server = createDaemonServer(commands, resetIdle, shutdown);
  serverRef.server = server;

  server.on('error', (error) => {
    process.stderr.write(`Daemon server listen failed: ${error.message}\n`);
    process.exit(1);
  });

  cleanupStaleSocket(socket);
  server.listen(socket);
}

// --- Socket communication helpers ---

function connectToSocket(socket) {
  return new Promise((resolvePromise, rejectPromise) => {
    const connection = net.connect(socket);
    connection.on('connect', () => resolvePromise(connection));
    connection.on('error', rejectPromise);
  });
}

export async function getOrStartTabDaemon(targetId) {
  const socket = socketPath(targetId);
  try {
    return await connectToSocket(socket);
  } catch {
    // ignored
  }

  cleanupStaleSocket(socket);

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

export function sendCommand(connection, request) {
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

export async function stopDaemons(targetPrefix) {
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
      cleanupStaleSocket(socket);
    }
  }
}
