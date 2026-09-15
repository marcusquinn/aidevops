// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  mkdirSync, readFileSync, rmdirSync, statSync, unlinkSync, writeFileSync,
} from "fs";
import { randomUUID } from "crypto";
import { homedir } from "os";
import { dirname, join } from "path";
import { OAUTH_CALLBACK_PORT, OAUTH_CALLBACK_TIMEOUT_MS } from "./oauth-pool-constants.mjs";

const LOCK_POLL_MS = 250;
const LOCK_LEASE_GRACE_MS = 30_000;

function callbackLockDir() {
  return process.env.AIDEVOPS_OPENCODE_OAUTH_LOCK_DIR
    || join(homedir(), ".aidevops", ".agent-workspace", "locks", `opencode-oauth-${OAUTH_CALLBACK_PORT}.lock`);
}

function callbackLockLeaseMs() {
  const configured = Number.parseInt(process.env.AIDEVOPS_OPENCODE_OAUTH_LOCK_LEASE_MS || "", 10);
  return Number.isFinite(configured) && configured > 0
    ? configured
    : OAUTH_CALLBACK_TIMEOUT_MS + LOCK_LEASE_GRACE_MS;
}

function removeStaleCallbackLock(lockDir) {
  const ownerPath = join(lockDir, "pid");
  let ageMs = 0;
  try { ageMs = Date.now() - statSync(lockDir).mtimeMs; }
  catch { return true; }
  if (ageMs < callbackLockLeaseMs()) return false;

  let observedOwner = "";
  try { observedOwner = readFileSync(ownerPath, "utf8"); }
  catch { /* incomplete or abandoned lock */ }
  let currentOwner = "";
  try { currentOwner = readFileSync(ownerPath, "utf8"); }
  catch { /* incomplete or abandoned lock */ }
  if (currentOwner !== observedOwner) return false;

  try { unlinkSync(ownerPath); } catch { /* absent owner file */ }
  try { rmdirSync(lockDir); return true; }
  catch { return false; }
}

function callbackLockRelease(lockDir, ownerPath, owner) {
  let released = false;
  return () => {
    if (released) return;
    released = true;
    let currentOwner = "";
    try { currentOwner = readFileSync(ownerPath, "utf8").trim(); }
    catch { /* lock already cleaned */ }
    if (currentOwner !== owner) return;
    try { unlinkSync(ownerPath); } catch { /* ignore */ }
    try { rmdirSync(lockDir); } catch { /* ignore */ }
  };
}

function createCallbackLock(lockDir, ownerPath) {
  mkdirSync(lockDir, { mode: 0o700 });
  const owner = JSON.stringify({ pid: process.pid, token: randomUUID() });
  try { writeFileSync(ownerPath, `${owner}\n`, { mode: 0o600, flag: "wx" }); }
  catch (error) {
    try { rmdirSync(lockDir); } catch { /* ignore */ }
    throw error;
  }
  return callbackLockRelease(lockDir, ownerPath, owner);
}

function handleCallbackLockCollision(error, lockDir, announcedWait) {
  if (error?.code !== "EEXIST") throw error;
  if (removeStaleCallbackLock(lockDir)) return { retry: true, announcedWait };
  if (!announcedWait) {
    console.error("[aidevops] OAuth pool: waiting for another interactive login to finish");
  }
  return { retry: false, announcedWait: true };
}

export async function acquireCallbackLock(cancelled) {
  const lockDir = callbackLockDir();
  const ownerPath = join(lockDir, "pid");
  mkdirSync(dirname(lockDir), { recursive: true, mode: 0o700 });
  let announcedWait = false;

  while (!cancelled()) {
    try {
      return createCallbackLock(lockDir, ownerPath);
    } catch (error) {
      const collision = handleCallbackLockCollision(error, lockDir, announcedWait);
      announcedWait = collision.announcedWait;
      if (collision.retry) continue;
      await new Promise((resolve) => setTimeout(resolve, LOCK_POLL_MS));
    }
  }
  return null;
}
