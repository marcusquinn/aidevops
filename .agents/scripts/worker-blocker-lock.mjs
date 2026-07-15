// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { randomUUID } from "node:crypto";
import {
  closeSync,
  existsSync,
  lstatSync,
  openSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";

import {
  LOCK_STALE_MS,
  quarantineStaleLock,
  recoveryMarkersActive,
} from "./worker-blocker-lock-recovery.mjs";

const LOCK_RETRIES = 25;
const LOCK_RETRY_MS = 4;

const LOCK_ACQUIRED = "acquired";
const LOCK_FAILED = "failed";
const LOCK_RETRY = "retry";

function sleepSync(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

function tryCreateOwnedLock(lockPath, token) {
  let descriptor;
  try {
    descriptor = openSync(lockPath, "wx", 0o600);
    writeFileSync(descriptor, token);
    return LOCK_ACQUIRED;
  } catch (error) {
    if (descriptor !== undefined) {
      try {
        unlinkSync(lockPath);
      } catch {
        // The incomplete lock remains stale and can be reclaimed.
      }
    }
    return error?.code === "EEXIST" ? "exists" : LOCK_FAILED;
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

export function releaseWorkerBlockerLock(lockPath, token) {
  try {
    if (readFileSync(lockPath, "utf8") !== token) return;
    unlinkSync(lockPath);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

function removeStalePrimaryLock(lockPath) {
  try {
    const lockStat = lstatSync(lockPath);
    if (lockStat.isSymbolicLink() || Date.now() - lockStat.mtimeMs <= LOCK_STALE_MS) return false;
    unlinkSync(lockPath);
    return true;
  } catch {
    return false;
  }
}

function finishInitialAcquisition(lockPath, reclaimPath, token) {
  let result = LOCK_ACQUIRED;
  if (existsSync(reclaimPath) || recoveryMarkersActive(reclaimPath)) {
    releaseWorkerBlockerLock(lockPath, token);
    sleepSync(LOCK_RETRY_MS);
    result = LOCK_RETRY;
  }
  return result;
}

function reclaimStaleLock(lockPath, reclaimPath, token) {
  const reclaimToken = randomUUID();
  let result = LOCK_RETRY;
  if (tryCreateOwnedLock(reclaimPath, reclaimToken) === LOCK_ACQUIRED) {
    if (recoveryMarkersActive(reclaimPath)) {
      releaseWorkerBlockerLock(reclaimPath, reclaimToken);
      sleepSync(LOCK_RETRY_MS);
    } else {
      try {
        removeStalePrimaryLock(lockPath);
        if (tryCreateOwnedLock(lockPath, token) === LOCK_ACQUIRED) result = LOCK_ACQUIRED;
      } finally {
        releaseWorkerBlockerLock(reclaimPath, reclaimToken);
      }
    }
  } else {
    sleepSync(LOCK_RETRY_MS);
  }
  return result;
}

function handleExistingLock(lockPath, reclaimPath, token) {
  const lockStat = lstatSync(lockPath);
  let result = LOCK_RETRY;
  if (lockStat.isSymbolicLink()) {
    result = LOCK_FAILED;
  } else if (Date.now() - lockStat.mtimeMs <= LOCK_STALE_MS) {
    sleepSync(LOCK_RETRY_MS);
  } else {
    result = reclaimStaleLock(lockPath, reclaimPath, token);
  }
  return result;
}

function tryAcquireLock(lockPath, reclaimPath, token) {
  let result = LOCK_RETRY;
  try {
    if (recoveryMarkersActive(reclaimPath)) {
      sleepSync(LOCK_RETRY_MS);
    } else if (existsSync(reclaimPath)) {
      quarantineStaleLock(reclaimPath);
      sleepSync(LOCK_RETRY_MS);
    } else {
      const initialResult = tryCreateOwnedLock(lockPath, token);
      if (initialResult === LOCK_ACQUIRED) {
        result = finishInitialAcquisition(lockPath, reclaimPath, token);
      } else if (initialResult === LOCK_FAILED) {
        result = LOCK_FAILED;
      } else {
        result = handleExistingLock(lockPath, reclaimPath, token);
      }
    }
  } catch (error) {
    if (error?.code !== "ENOENT") result = LOCK_FAILED;
    else sleepSync(LOCK_RETRY_MS);
  }
  return result;
}

export function acquireWorkerBlockerLock(lockPath) {
  const token = randomUUID();
  const reclaimPath = `${lockPath}.reclaim`;
  let acquiredToken = "";
  for (let attempt = 0; attempt < LOCK_RETRIES; attempt++) {
    const result = tryAcquireLock(lockPath, reclaimPath, token);
    if (result === LOCK_ACQUIRED) {
      acquiredToken = token;
      break;
    }
    if (result === LOCK_FAILED) break;
  }
  return acquiredToken;
}
