/**
 * Bridge spawn / transport utilities for cursor/proxy.js.
 * Extracted to keep per-file complexity below the threshold.
 */

import { resolve as pathResolve } from "node:path";

export const CURSOR_API_URL = process.env.CURSOR_API_URL ?? "https://api2.cursor.sh";
export const CONNECT_END_STREAM_FLAG = 0b00000010;
export const BRIDGE_PATH = pathResolve(import.meta.dir, "h2-bridge.mjs");

// Tool name alias map (t1553)
export const TOOL_NAME_ALIASES = new Map([
  ["runcommand", "bash"], ["executecommand", "bash"], ["runterminalcommand", "bash"],
  ["terminalcommand", "bash"], ["shellcommand", "bash"], ["shell", "bash"],
  ["terminal", "bash"], ["bashcommand", "bash"], ["runbash", "bash"],
  ["executebash", "bash"],
  ["readfile", "read"], ["getfile", "read"], ["filecontent", "read"],
  ["readfilecontent", "read"],
  ["writefile", "write"], ["createfile", "write"], ["savefile", "write"],
  ["editfile", "edit"], ["modifyfile", "edit"], ["updatefile", "edit"],
  ["replaceinfile", "edit"],
  ["searchcontent", "grep"], ["searchcode", "grep"], ["findcontent", "grep"],
  ["grepfiles", "grep"], ["searchfiles", "grep"],
  ["findfiles", "glob"], ["globfiles", "glob"], ["fileglob", "glob"],
  ["matchfiles", "glob"],
  ["listdirectory", "ls"], ["listfiles", "ls"], ["listdir", "ls"],
  ["readdir", "ls"],
]);

/** Resolve a tool name through the alias map. */
export function resolveToolAlias(name) {
  if (!name) return name;
  const lower = name.toLowerCase().replace(/[_\-\s]/g, "");
  return TOOL_NAME_ALIASES.get(lower) || name;
}

/** Length-prefix a message: [4-byte BE length][payload] */
export function lpEncode(data) {
  const buf = Buffer.alloc(4 + data.length);
  buf.writeUInt32BE(data.length, 0);
  buf.set(data, 4);
  return buf;
}

/** Connect protocol frame: [1-byte flags][4-byte BE length][payload] */
export function frameConnectMessage(data, flags = 0) {
  const frame = Buffer.alloc(5 + data.length);
  frame[0] = flags;
  frame.writeUInt32BE(data.length, 1);
  frame.set(data, 5);
  return frame;
}

/** Read length-prefixed frames from the bridge stdout and dispatch to callbacks. */
export async function readBridgeOutput(proc, cbs) {
  const reader = proc.stdout.getReader();
  let pending = Buffer.alloc(0);
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      pending = Buffer.concat([pending, Buffer.from(value)]);
      while (pending.length >= 4) {
        const len = pending.readUInt32BE(0);
        if (pending.length < 4 + len) break;
        const payload = pending.subarray(4, 4 + len);
        pending = pending.subarray(4 + len);
        cbs.data?.(Buffer.from(payload));
      }
    }
  } catch {
    // Stream ended
  }
}

/** Spawn an h2-bridge child process and return a bridge handle. */
export function spawnBridge(options) {
  const proc = Bun.spawn(["node", BRIDGE_PATH], {
    stdin: "pipe", stdout: "pipe", stderr: "ignore",
  });
  const config = JSON.stringify({
    accessToken: options.accessToken,
    url: options.url ?? CURSOR_API_URL,
    path: options.rpcPath,
  });
  proc.stdin.write(lpEncode(new TextEncoder().encode(config)));
  const cbs = { data: null, close: null };
  let exited = false;
  let exitCode = 1;
  (async () => {
    await readBridgeOutput(proc, cbs);
    const code = await proc.exited ?? 1;
    exited = true;
    exitCode = code;
    cbs.close?.(code);
  })();
  return {
    proc,
    get alive() { return !exited; },
    write(data) { try { proc.stdin.write(lpEncode(data)); } catch { } },
    end() { try { proc.stdin.write(lpEncode(new Uint8Array(0))); proc.stdin.end(); } catch { } },
    onData(cb) { cbs.data = cb; },
    onClose(cb) {
      if (exited) { queueMicrotask(() => cb(exitCode)); }
      else { cbs.close = cb; }
    },
  };
}

/** Execute a single unary RPC over the bridge and return the response bytes. */
export async function callCursorUnaryRpc(options) {
  const bridge = spawnBridge({ accessToken: options.accessToken, rpcPath: options.rpcPath, url: options.url });
  const chunks = [];
  const { promise, resolve } = Promise.withResolvers();
  let timedOut = false;
  const timeoutMs = options.timeoutMs ?? 5_000;
  const timeout = timeoutMs > 0
    ? setTimeout(() => { timedOut = true; try { bridge.proc.kill(); } catch { } }, timeoutMs)
    : undefined;
  bridge.onData((chunk) => { chunks.push(Buffer.from(chunk)); });
  bridge.onClose((exitCode) => {
    if (timeout) clearTimeout(timeout);
    resolve({ body: Buffer.concat(chunks), exitCode, timedOut });
  });
  bridge.write(frameConnectMessage(options.requestBody));
  bridge.end();
  return promise;
}
