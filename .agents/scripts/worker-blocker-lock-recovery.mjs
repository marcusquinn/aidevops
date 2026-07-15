// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { randomUUID } from "node:crypto";
import {
  linkSync,
  lstatSync,
  readFileSync,
  readdirSync,
  renameSync,
  unlinkSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";

export const LOCK_STALE_MS = 30_000;

const LOCK_RETRY_MS = 4;
const LOCK_RESTORE_RETRIES = 250;

function sleepSync(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

export function recoveryMarkersActive(lockPath) {
  const directory = dirname(lockPath);
  const prefix = `${basename(lockPath)}.quarantine-`;
  let active = false;
  try {
    for (const name of readdirSync(directory)) {
      if (!name.startsWith(prefix)) continue;
      const markerPath = join(directory, name);
      try {
        const markerStat = lstatSync(markerPath);
        if (markerStat.isSymbolicLink() || Date.now() - markerStat.mtimeMs > LOCK_STALE_MS) {
          unlinkSync(markerPath);
        } else {
          active = true;
        }
      } catch {
        // Another contender completed recovery first.
      }
    }
  } catch {
    return false;
  }
  return active;
}

function readStaleLockSnapshot(lockPath) {
  let snapshot = null;
  try {
    const stat = lstatSync(lockPath);
    if (!stat.isSymbolicLink() && Date.now() - stat.mtimeMs > LOCK_STALE_MS) {
      snapshot = { stat, token: readFileSync(lockPath, "utf8") };
    }
  } catch {
    // A missing or concurrently moved lock cannot be reclaimed by this attempt.
  }
  return snapshot;
}

function isExactStaleLock(movedStat, movedToken, observed) {
  const checks = [
    !movedStat.isSymbolicLink(),
    movedStat.dev === observed.stat.dev,
    movedStat.ino === observed.stat.ino,
    movedStat.mtimeMs === observed.stat.mtimeMs,
    movedToken === observed.token,
    Date.now() - movedStat.mtimeMs > LOCK_STALE_MS,
  ];
  return checks.every(Boolean);
}

function restoreQuarantinedLock(quarantinePath, lockPath) {
  for (let attempt = 0; attempt < LOCK_RESTORE_RETRIES; attempt++) {
    try {
      linkSync(quarantinePath, lockPath);
      unlinkSync(quarantinePath);
      return;
    } catch (error) {
      if (error?.code !== "EEXIST") return;
      sleepSync(LOCK_RETRY_MS);
    }
  }
}

export function quarantineStaleLock(lockPath) {
  const observed = readStaleLockSnapshot(lockPath);
  if (!observed) return false;

  const quarantinePath = `${lockPath}.quarantine-${randomUUID()}`;
  let reclaimed = false;
  try {
    renameSync(lockPath, quarantinePath);
    const movedStat = lstatSync(quarantinePath);
    const movedToken = readFileSync(quarantinePath, "utf8");
    if (isExactStaleLock(movedStat, movedToken, observed)) {
      unlinkSync(quarantinePath);
      reclaimed = true;
    } else if (movedStat.isSymbolicLink()) {
      unlinkSync(quarantinePath);
    } else {
      restoreQuarantinedLock(quarantinePath, lockPath);
    }
  } catch {
    // Another contender completed recovery first.
  }
  return reclaimed;
}
