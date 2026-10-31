// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFile, spawn } from "child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { processStartIdentity } from "./process-start-identity.mjs";

const execFileAsync = promisify(execFile);

/** Release fallback server ownership only at session deletion, never at idle. */
export async function releasePreEditSessionOwnership(input) {
  const event = input?.event;
  if (event?.type !== "session.deleted") return;
  const session = event.data?.sessionID
    || event.properties?.info?.id || event.properties?.sessionID;
  if (!/^ses_[A-Za-z0-9_-]+$/.test(session || "")) return;
  const identity = processStartIdentity(process.pid);
  if (!identity) throw new Error("Session ownership release lacks server generation proof");
  const database = process.env.WORKTREE_REGISTRY_DB || join(
    process.env.WORKTREE_REGISTRY_DIR || join(homedir(), ".aidevops", ".agent-workspace"),
    "worktree-registry.db",
  );
  // #aidevops:trust-boundary — the owner is this server, not a PID from the event.
  await execFileAsync("python3", [
    fileURLToPath(new URL("../../scripts/shared-worktree-registry-owner.py", import.meta.url)),
    "release-session", database, String(process.pid), session, identity,
  ], { timeout: 10000 });
}

/**
 * Run loop-mode checks in their own process group so a timeout cannot leave a
 * helper running long enough to create a worktree after the tool has returned.
 * @param {string} script
 * @param {string[]} args
 * @param {string} cwd
 * @param {number} timeoutMs
 * @param {object} [context] - OpenCode tool context
 * @returns {Promise<{code: number|null, stdout: string, stderr: string, timedOut: boolean, error?: Error}>}
 */
export function runPreEditCheck(script, args, cwd, timeoutMs, context) {
  return new Promise((resolve) => {
    const sessionID = String(context?.sessionID || "");
    // The plugin may run in a transport process. Keep the runtime identity
    // delivered by OpenCode's environment only with matching generation proof.
    // Liveness alone cannot distinguish a runtime from a reused PID.
    let ownerPID = String(process.pid);
    let ownerIdentity = processStartIdentity(process.pid);
    const inheritedPID = process.env.OPENCODE_PID || "";
    const inheritedIdentity = process.env.OPENCODE_PID_START_IDENTITY || "";
    if (sessionID === process.env.OPENCODE_SESSION_ID
      && /^[1-9][0-9]*$/.test(inheritedPID) && inheritedIdentity) {
      try {
        process.kill(Number(inheritedPID), 0);
        // #aidevops:trust-boundary — proof comes from the runtime environment,
        // never from tool arguments or a freshly sampled replacement process.
        if (processStartIdentity(Number(inheritedPID)) === inheritedIdentity) {
          ownerPID = inheritedPID;
          ownerIdentity = inheritedIdentity;
        }
      } catch {
        // Missing or inaccessible process evidence is not an owner override.
      }
    }
    const sessionEnv = /^ses_[A-Za-z0-9_-]+$/.test(sessionID)
      ? {
          OPENCODE: "1",
          OPENCODE_PID: ownerPID,
          OPENCODE_PID_START_IDENTITY: ownerIdentity,
          OPENCODE_SESSION_ID: sessionID,
          AIDEVOPS_OPENCODE_SESSION_ID: sessionID,
        }
      : {};
    const child = spawn("bash", [script, ...args], {
      cwd,
      detached: true,
      env: { ...process.env, ...sessionEnv },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let spawnError;

    child.stdout.setEncoding("utf-8");
    child.stderr.setEncoding("utf-8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => { spawnError = error; });

    const timer = setTimeout(() => {
      timedOut = true;
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch {
        child.kill("SIGKILL");
      }
    }, timeoutMs);

    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr, timedOut, error: spawnError });
    });
  });
}
