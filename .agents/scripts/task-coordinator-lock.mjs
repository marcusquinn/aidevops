// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
// Initialization lock ownership, stale-owner recovery and bounded acquisition.

import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

function processIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error.code === "ESRCH") return false;
    if (error.code === "EPERM") return true;
    throw error;
  }
}
function orphanedLockIsOldEnough(lock, orphanGrace) {
  try {
    return Date.now() - statSync(lock).mtimeMs >= orphanGrace;
  } catch (error) {
    if (error.code === "ENOENT") return false;
    throw error;
  }
}
function lockCanBeReclaimed(lock, orphanGrace) {
  try {
    const owner = JSON.parse(readFileSync(join(lock, "owner.json"), "utf8"));
    if (!owner || typeof owner.ownerToken !== "string" || !Number.isSafeInteger(Number(owner.pid)) || Number(owner.pid) < 1) throw new TypeError("malformed initialization lock owner");
    return !processIsAlive(Number(owner.pid));
  } catch (error) {
    if (error.code !== "ENOENT" && !(error instanceof SyntaxError) && !(error instanceof TypeError)) throw error;
    return orphanedLockIsOldEnough(lock, orphanGrace);
  }
}
function reclaimLock(lock) {
  const stale = `${lock}.stale-${randomUUID()}`;
  try {
    renameSync(lock, stale);
    rmSync(stale, { recursive: true, force: true });
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}
function acquireInitializationLock(lock, ownerToken) {
  const deadline = Date.now() + Number(process.env.AIDEVOPS_COORDINATOR_INIT_LOCK_TIMEOUT_MS || 30000);
  const orphanGrace = Number(process.env.AIDEVOPS_COORDINATOR_INIT_LOCK_ORPHAN_GRACE_MS || 1000);
  while (true) {
    try {
      mkdirSync(lock, { mode: 0o700 });
      writeFileSync(join(lock, "owner.json"), JSON.stringify({ ownerToken, pid: process.pid }), { mode: 0o600 });
      return;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      if (lockCanBeReclaimed(lock, orphanGrace)) reclaimLock(lock);
      if (Date.now() >= deadline) throw new Error("coordinator initialization lock timed out");
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25);
    }
  }
}
function releaseInitializationLock(lock, ownerToken) {
  try {
    const owner = JSON.parse(readFileSync(join(lock, "owner.json"), "utf8"));
    if (owner.ownerToken === ownerToken) rmSync(lock, { recursive: true, force: true });
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

export { acquireInitializationLock, releaseInitializationLock };
