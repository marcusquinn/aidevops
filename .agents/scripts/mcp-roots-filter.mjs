#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// MCP stdio roots filter (GH#35159). @playwright/mcp resolves the `filename`
// argument of native tools (screenshot, snapshot, pdf, ...) against the MCP
// client's first root, which OpenCode sets to the project directory (often a
// canonical checkout). Removing the `roots` client capability makes the server
// fall back to process.cwd(), which the launcher sets to a private artifact dir.
//
// Usage: node mcp-roots-filter.mjs -- <server command...>
// Client->server: strips params.capabilities.roots from `initialize` and drops
// `notifications/roots/list_changed`. Server->client: passed through, except
// `roots/list` requests, which are answered with an empty list.

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

/**
 * Filter one client->server JSON-RPC line.
 * @param {string} line
 * @returns {string|null} line to forward, or null to drop
 */
export function filterClientLine(line) {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return line;
  }
  if (!message || typeof message !== "object" || Array.isArray(message)) return line;
  if (message.method === "notifications/roots/list_changed") return null;
  if (message.method === "initialize" && message.params?.capabilities?.roots !== undefined) {
    delete message.params.capabilities.roots;
    return JSON.stringify(message);
  }
  return line;
}

function main() {
  const separator = process.argv.indexOf("--");
  const command = separator === -1 ? process.argv.slice(2) : process.argv.slice(separator + 1);
  if (command.length === 0) {
    process.stderr.write("mcp-roots-filter: missing server command\n");
    process.exit(2);
  }
  const child = spawn(command[0], command.slice(1), {
    stdio: ["pipe", "pipe", "inherit"],
  });
  child.on("error", (error) => {
    process.stderr.write(`mcp-roots-filter: cannot start server: ${error.message}\n`);
    process.exit(127);
  });

  const clientLines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  clientLines.on("line", (line) => {
    const forwarded = filterClientLine(line);
    if (forwarded !== null && child.stdin.writable) child.stdin.write(`${forwarded}\n`);
  });
  clientLines.on("close", () => child.stdin.end());
  child.stdin.on("error", () => {});

  const serverLines = createInterface({ input: child.stdout, crlfDelay: Infinity });
  serverLines.on("line", (line) => {
    try {
      const message = JSON.parse(line);
      if (message?.method === "roots/list" && message.id !== undefined) {
        child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: message.id, result: { roots: [] } })}\n`);
        return;
      }
    } catch {
      // not JSON: pass through unchanged
    }
    process.stdout.write(`${line}\n`);
  });

  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(signal, () => child.kill(signal));
  }
  let exitCode = 0;
  serverLines.on("close", () => process.exit(exitCode));
  child.on("exit", (code, signal) => {
    exitCode = signal ? 143 : (code ?? 0);
    setTimeout(() => process.exit(exitCode), 2000).unref();
  });
}

if (process.argv[1]?.endsWith("mcp-roots-filter.mjs")) {
  main();
}
