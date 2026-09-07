// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { closeSync, constants, fstatSync, lstatSync, openSync, readSync, realpathSync } from "node:fs";
import { dirname, isAbsolute, join, parse, relative, resolve, sep } from "node:path";
import { sourceAccessGit } from "./source-access-git.mjs";

export const MAX_SOURCE_BYTES = 10 * 1024 * 1024;

function requireValidFile(condition) {
  if (!condition) throw new Error("source-access file is invalid");
}

export function hasSymlinkComponent(filePath) {
  const absolute = resolve(filePath);
  const root = parse(absolute).root;
  let current = root;
  for (const part of absolute.slice(root.length).split(sep).filter(Boolean)) {
    current = join(current, part);
    try {
      if (lstatSync(current).isSymbolicLink()) return true;
    } catch {
      return false;
    }
  }
  return false;
}

export function trackedFileIdentity(filePath, git, run = execFileSync) {
  try {
    const gitRoot = realpathSync(String(sourceAccessGit(git,
      ["-C", dirname(filePath), "rev-parse", "--show-toplevel"], {
        encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 15000,
      }, run)).trim());
    const relativePath = relative(gitRoot, filePath);
    if (!relativePath || relativePath.startsWith(`..${sep}`) || isAbsolute(relativePath)) return false;
    sourceAccessGit(git, ["-C", gitRoot, "ls-files", "--error-unmatch", "--", relativePath], {
      encoding: "utf8", stdio: ["ignore", "ignore", "ignore"], timeout: 15000,
    }, run);
    return { repoRoot: gitRoot, relativePath };
  } catch {
    return false;
  }
}

export function isGitTrackedFile(filePath, git, run = execFileSync) {
  return Boolean(trackedFileIdentity(filePath, git, run));
}

function readStableSource(filePath) {
  const descriptor = openSync(filePath, constants.O_RDONLY | (constants.O_NOFOLLOW || 0) | (constants.O_NONBLOCK || 0));
  try {
    const opened = fstatSync(descriptor, { bigint: true });
    requireValidFile(opened.isFile() && opened.nlink === 1n && opened.size <= BigInt(MAX_SOURCE_BYTES));
    const buffer = Buffer.alloc(Number(opened.size) + 1);
    let used = 0;
    while (used < buffer.length) {
      const count = readSync(descriptor, buffer, used, buffer.length - used, null);
      if (count === 0) break;
      used += count;
    }
    const current = lstatSync(filePath, { bigint: true });
    const final = fstatSync(descriptor, { bigint: true });
    requireValidFile(used <= MAX_SOURCE_BYTES && current.isFile() && !current.isSymbolicLink());
    requireValidFile(current.dev === opened.dev && current.ino === opened.ino);
    requireValidFile(["dev", "ino", "uid", "mode", "nlink", "size", "mtimeNs", "ctimeNs"]
      .every((key) => final[key] === opened[key]));
    return { content: buffer.subarray(0, used), fileIdentity: { device: String(opened.dev), inode: String(opened.ino) } };
  } finally {
    closeSync(descriptor);
  }
}

export function sourceDigestMatches(filePath, expectedDigest) {
  try {
    return createHash("sha256").update(readStableSource(filePath).content).digest("hex") === expectedDigest;
  } catch {
    return false;
  }
}

export function trustedSourceSnapshot(filePath, git = "/usr/bin/git", run = execFileSync) {
  let result = false;
  try {
    requireValidFile(isAbsolute(filePath));
    requireValidFile(!hasSymlinkComponent(filePath));
    const canonicalPath = realpathSync(filePath);
    requireValidFile(canonicalPath === resolve(filePath));
    const { content, fileIdentity } = readStableSource(canonicalPath);
    const identity = trackedFileIdentity(canonicalPath, git, run);
    requireValidFile(identity);
    result = { canonicalPath, content, fileIdentity,
      contentSha256: createHash("sha256").update(content).digest("hex"), ...identity };
  } catch {
    result = false;
  }
  return result;
}
