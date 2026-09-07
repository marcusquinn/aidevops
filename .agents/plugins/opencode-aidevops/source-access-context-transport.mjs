// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { randomBytes } from "node:crypto";
import { chmodSync, lstatSync, mkdirSync, unlinkSync } from "node:fs";
import { createServer } from "node:net";
import { dirname, isAbsolute, join } from "node:path";

const MAX_QUERY_BYTES = 8192;

export function isUnprivilegedSourceRuntime() {
  return typeof process.getuid === "function" && typeof process.geteuid === "function"
    && process.getuid() > 0 && process.geteuid() === process.getuid();
}

function privateSocketDirectory(directory, privateLeaf = true) {
  if (!isAbsolute(directory) || !isUnprivilegedSourceRuntime()) return false;
  let current = directory;
  while (true) {
    const metadata = lstatSync(current);
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) return false;
    if (![0, process.getuid()].includes(metadata.uid) || (metadata.mode & 0o022)) return false;
    if (privateLeaf && current === directory
      && (metadata.uid !== process.getuid() || (metadata.mode & 0o077))) {
      return false;
    }
    const parent = dirname(current);
    if (parent === current) return true;
    current = parent;
  }
}

/** Create only the reserved leaf under an existing, safe workspace temp root. */
export function prepareSourceContextDirectory(parent) {
  if (!privateSocketDirectory(parent, false)) throw new Error("unsafe source context parent");
  const directory = join(parent, "source-context");
  try {
    mkdirSync(directory, { mode: 0o700 });
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
  }
  if (!privateSocketDirectory(directory)) throw new Error("unsafe source context directory");
  return directory;
}

function readContextChunk(connection, respond, state, request, chunk) {
  if (request.started) return connection.destroy();
  request.input = Buffer.concat([request.input, chunk]);
  if (request.input.length > MAX_QUERY_BYTES) return connection.destroy();
  if (!request.input.includes(10)) return;
  request.started = true;
  let query;
  try {
    query = JSON.parse(request.input.toString("utf8"));
  } catch {
    connection.destroy();
    return;
  }
  if (state.pending >= 8) return connection.destroy();
  state.pending++;
  Promise.resolve().then(() => respond(query, request.controller.signal)).then((reply) => {
    if (!connection.destroyed) connection.end(`${JSON.stringify(reply)}\n`);
  }).catch(() => {
    // Never forward SDK errors, titles, messages, credentials or source bytes.
    if (!connection.destroyed) connection.end('{"error":"context unavailable"}\n');
  }).finally(() => {
    state.pending--;
  });
}

function acceptContextQuery(connection, respond, state) {
  const { connections } = state;
  if (connections.size >= 8 || state.pending >= 8) return connection.destroy();
  connections.add(connection);
  const request = { controller: new AbortController(), input: Buffer.alloc(0), started: false };
  const deadline = setTimeout(() => connection.destroy(), 5000);
  deadline.unref();
  connection.on("error", () => connection.destroy());
  connection.once("close", () => {
    clearTimeout(deadline);
    request.controller.abort();
    connections.delete(connection);
  });
  connection.on("data", (chunk) => readContextChunk(connection, respond, state, request, chunk));
}

/** Opt-in transport primitive; importing this module starts no listener. */
export async function listenSourceContext({ directory, respond }) {
  if (typeof respond !== "function" || !privateSocketDirectory(directory)) {
    throw new Error("source context requires an existing private user directory");
  }
  const socketPath = join(directory, `${process.pid}-${randomBytes(8).toString("hex")}.sock`);
  if (Buffer.byteLength(socketPath) >= 104) throw new Error("source context socket path is too long");
  const state = { connections: new Set(), pending: 0 };
  const server = createServer((connection) => acceptContextQuery(connection, respond, state));
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  let identity;
  try {
    chmodSync(socketPath, 0o600);
    identity = lstatSync(socketPath);
  } catch {
    server.close();
    throw new Error("source context listener setup failed");
  }
  server.unref();
  let closed = false;
  return {
    socketPath,
    close() {
      if (closed) return;
      closed = true;
      for (const connection of state.connections) connection.destroy();
      server.close();
      try {
        const current = lstatSync(socketPath);
        if (current.isSocket() && current.dev === identity.dev && current.ino === identity.ino) {
          unlinkSync(socketPath);
        }
      } catch {
        // Node also cleans up its reserved endpoint; tolerate its prior removal.
      }
    },
  };
}
