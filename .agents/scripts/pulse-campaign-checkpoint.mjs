#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  chmodSync,
  linkSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { hostname } from "node:os";
import { isAbsolute, join, parse, resolve, sep } from "node:path";

const CHECKPOINT_LOCK_TIMEOUT_MS = 4_000;
const CHECKPOINT_LOCK_STALE_MS = 60_000;

function boundedTimeout(value) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) return CHECKPOINT_LOCK_TIMEOUT_MS;
  return Math.min(CHECKPOINT_LOCK_TIMEOUT_MS, Math.max(0, parsed));
}

function existingPathStats(filepath) {
  try {
    return lstatSync(filepath);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

function assertNoSymlinkComponents(filepath) {
  const absolutePath = resolve(filepath);
  const root = parse(absolutePath).root;
  let current = root;
  for (const component of absolutePath.slice(root.length).split(sep).filter(Boolean)) {
    current = join(current, component);
    const stats = existingPathStats(current);
    if (stats?.isSymbolicLink()) throw new TypeError("checkpoint path must not traverse symbolic links");
  }
}

function ensurePrivateCheckpointDirectory(directory) {
  assertNoSymlinkComponents(directory);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  assertNoSymlinkComponents(directory);
  const stats = lstatSync(directory);
  if (stats.isSymbolicLink()) throw new TypeError("checkpoint root must be a real directory");
  if (!stats.isDirectory()) throw new TypeError("checkpoint root must be a real directory");
  chmodSync(directory, 0o700);
  return { device: stats.dev, inode: stats.ino };
}

function validLockOwner(owner) {
  const checks = [
    typeof owner?.host === "string",
    Number.isSafeInteger(owner?.pid),
    owner?.pid >= 1,
    typeof owner?.processStartedAt === "string",
    typeof owner?.token === "string",
  ];
  return checks.every(Boolean);
}

function readCheckpointLock(lockPath) {
  try {
    const owner = JSON.parse(readFileSync(lockPath, "utf8"));
    return validLockOwner(owner) ? owner : null;
  } catch {
    return null;
  }
}

function processIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function processStartFingerprint(pid) {
  try {
    return execFileSync("ps", ["-p", String(pid), "-o", "lstart="], {
      encoding: "utf8",
      timeout: 1000,
    }).trim();
  } catch {
    return "";
  }
}

function lockOwnerIsActive(owner) {
  if (owner.host !== hostname()) return true;
  if (!processIsAlive(owner.pid)) return false;
  const currentFingerprint = processStartFingerprint(owner.pid);
  if (!owner.processStartedAt) return true;
  if (!currentFingerprint) return true;
  return owner.processStartedAt === currentFingerprint;
}

function assertDirectoryIdentity(directory, identity) {
  assertNoSymlinkComponents(directory);
  const current = lstatSync(directory);
  if (!current.isDirectory()) throw new TypeError("checkpoint directory identity changed");
  if (current.dev !== identity.device) throw new TypeError("checkpoint directory identity changed");
  if (current.ino !== identity.inode) throw new TypeError("checkpoint directory identity changed");
}

function createLockContext(filepath, timeoutMs) {
  const directory = resolve(filepath, "..");
  const directoryIdentity = ensurePrivateCheckpointDirectory(directory);
  return {
    deadline: Date.now() + boundedTimeout(timeoutMs),
    directory,
    directoryIdentity,
    lockPath: `${filepath}.lock`,
    owner: {
      host: hostname(),
      pid: process.pid,
      processStartedAt: processStartFingerprint(process.pid),
      token: randomUUID(),
    },
  };
}

function tryPublishLock(context) {
  const unpublishedPath = `${context.lockPath}.pending-${process.pid}-${randomUUID()}`;
  try {
    writeFileSync(unpublishedPath, `${JSON.stringify(context.owner)}\n`, {
      encoding: "utf8",
      mode: 0o600,
      flag: "wx",
    });
    assertDirectoryIdentity(context.directory, context.directoryIdentity);
    linkSync(unpublishedPath, context.lockPath);
    return { acquired: true };
  } catch (error) {
    return { acquired: false, error };
  } finally {
    rmSync(unpublishedPath, { force: true });
  }
}

function reclaimLock(lockPath) {
  const quarantinePath = `${lockPath}.stale-${process.pid}-${randomUUID()}`;
  try {
    renameSync(lockPath, quarantinePath);
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  rmSync(quarantinePath, { force: true });
}

function existingLockAction(context) {
  const stats = existingPathStats(context.lockPath);
  if (!stats) return "retry";
  if (stats.isSymbolicLink()) throw new TypeError("checkpoint lock path is unsafe");
  if (!stats.isFile()) throw new TypeError("checkpoint lock path is unsafe");
  if (Date.now() - stats.mtimeMs <= CHECKPOINT_LOCK_STALE_MS) return "wait";
  const owner = readCheckpointLock(context.lockPath);
  if (owner?.host && lockOwnerIsActive(owner)) return "wait";
  reclaimLock(context.lockPath);
  return "retry";
}

function acquireCheckpointLock(filepath, timeoutMs) {
  const context = createLockContext(filepath, timeoutMs);
  while (Date.now() <= context.deadline) {
    const publication = tryPublishLock(context);
    if (publication.acquired) return context;
    if (publication.error?.code !== "EEXIST") throw publication.error;
    if (existingLockAction(context) === "retry") continue;
    if (Date.now() >= context.deadline) break;
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25);
  }
  throw new Error("checkpoint lock timed out");
}

function releaseCheckpointLock(lock) {
  const owner = readCheckpointLock(lock.lockPath);
  if (owner?.pid !== lock.owner.pid) return;
  if (owner.token !== lock.owner.token) return;
  rmSync(lock.lockPath, { force: true });
}

export function campaignCheckpointPath(checkpointRoot, scopeKey) {
  if (typeof checkpointRoot !== "string") throw new TypeError("checkpoint root must be absolute");
  if (!isAbsolute(checkpointRoot)) throw new TypeError("checkpoint root must be absolute");
  if (typeof scopeKey !== "string") throw new TypeError("repository scope key is invalid");
  if (!/^[0-9a-f]{16}$/.test(scopeKey)) throw new TypeError("repository scope key is invalid");
  return join(checkpointRoot, `repo-${scopeKey}.json`);
}

export function withCheckpointLock(filepath, operation, timeoutMs) {
  const lock = acquireCheckpointLock(filepath, timeoutMs);
  try {
    assertDirectoryIdentity(lock.directory, lock.directoryIdentity);
    return operation(lock.directoryIdentity);
  } finally {
    releaseCheckpointLock(lock);
  }
}

export function writeCampaignCheckpointUnlocked(filepath, checkpoint, directoryIdentity) {
  const directory = resolve(filepath, "..");
  assertDirectoryIdentity(directory, directoryIdentity);
  const temporary = `${filepath}.tmp-${process.pid}-${randomUUID()}`;
  try {
    writeFileSync(temporary, `${JSON.stringify(checkpoint, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
      flag: "wx",
    });
    assertDirectoryIdentity(directory, directoryIdentity);
    renameSync(temporary, filepath);
    chmodSync(filepath, 0o600);
  } finally {
    rmSync(temporary, { force: true });
  }
  return filepath;
}

export function writeCampaignCheckpoint(filepath, checkpoint, options = {}) {
  return withCheckpointLock(
    filepath,
    (directoryIdentity) => writeCampaignCheckpointUnlocked(filepath, checkpoint, directoryIdentity),
    options.lockTimeoutMs,
  );
}
