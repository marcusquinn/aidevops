// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { spawn } from "node:child_process";

const MAX_READ_BYTES = 128 * 1024;

function captureBounded(current, chunk) {
  if (Buffer.byteLength(current) >= MAX_READ_BYTES) return current;
  const remaining = MAX_READ_BYTES - Buffer.byteLength(current);
  return current + Buffer.from(chunk).subarray(0, remaining).toString("utf8");
}

export function createOutputSandboxRecorder(helperPath, spawnImpl = spawn, timeoutMs = 5000) {
  const activeChildren = new Set();
  const recorder = (content, evidence = {}) => new Promise((resolve) => {
    const exitCode = Number.isInteger(evidence.exitCode) ? evidence.exitCode : 1;
    const child = spawnImpl("bash", [
      helperPath, "store", "--command", "bounded-interactive-operation",
      "--exit-code", String(exitCode), "--tag", "interactive-operation",
    ], { stdio: ["pipe", "pipe", "ignore"] });
    activeChildren.add(child);
    let stdout = "";
    let settled = false;
    const finish = (outputID = "") => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      activeChildren.delete(child);
      resolve(outputID);
    };
    const timer = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      finish();
    }, timeoutMs);
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk) => { stdout += chunk; });
    child.once("error", () => finish());
    child.once("close", (code) => {
      const match = code === 0 ? stdout.match(/^output_id:\s*(\S+)/m) : null;
      finish(match?.[1] || "");
    });
    child.stdin?.end(content);
  });
  recorder.dispose = () => {
    for (const child of activeChildren) {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }
    activeChildren.clear();
  };
  return recorder;
}

export function createOutputSandboxReader(helperPath, spawnImpl = spawn, timeoutMs = 5000) {
  const activeChildren = new Set();
  const reader = (outputID, { offset, limit }) => new Promise((resolve, reject) => {
    const child = spawnImpl("bash", [
      helperPath, "show", outputID, "--offset", String(offset), "--limit", String(limit),
    ], { stdio: ["ignore", "pipe", "pipe"] });
    activeChildren.add(child);
    let stdout = "";
    let stderr = "";
    let truncated = false;
    let settled = false;
    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      activeChildren.delete(child);
      if (error) reject(error);
      else resolve({ output: stdout, redacted: /redacted before storage/i.test(stderr), truncated });
    };
    const timer = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
      finish(new Error("stored output retrieval timed out"));
    }, timeoutMs);
    child.stdout?.on("data", (chunk) => {
      const next = captureBounded(stdout, chunk);
      if (Buffer.byteLength(next) < Buffer.byteLength(stdout) + Buffer.byteLength(chunk)) truncated = true;
      stdout = next;
    });
    child.stderr?.on("data", (chunk) => { stderr = captureBounded(stderr, chunk); });
    child.once("error", () => finish(new Error("stored output retrieval is unavailable")));
    child.once("close", (code) => {
      if (code !== 0) {
        finish(new Error(stderr.trim() || "stored output is unavailable"));
        return;
      }
      finish();
    });
  });
  reader.dispose = () => {
    for (const child of activeChildren) {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }
    activeChildren.clear();
  };
  return reader;
}
