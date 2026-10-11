// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Resolve trust-sensitive executables through PATH without trusting
// caller-owned files: accept the first PATH entry whose real executable and
// real directory chains are root-controlled. No distro-specific roots, so the
// same rule covers macOS, FHS Linux and store-symlinked layouts.
// Python counterpart: trusted_executable.py.

import {lstatSync, readlinkSync, realpathSync, statSync} from "node:fs";
import {delimiter, isAbsolute, parse} from "node:path";

// Owned by root and not group/other writable (sticky directories allowed).
function rootControlled(path, directory) {
  try {
    const metadata = statSync(path);
    if (metadata.uid !== 0) return false;
    if ((metadata.mode & 0o022) === 0) return true;
    return directory && (metadata.mode & 0o1000) !== 0;
  } catch {
    return false;
  }
}

function trustedChain(path) {
  let current = path;
  if (!rootControlled(current, statSync(current).isDirectory())) return false;
  while (current !== parse(current).root) {
    current = parse(current).dir;
    if (!rootControlled(current, true)) return false;
  }
  return true;
}

function trustedSymlinkChain(path, hops = 0) {
  if (hops >= 40) return false;
  const parts = path.split("/").filter(Boolean);
  let prefix = "/";
  for (let index = 0; index < parts.length; index++) {
    prefix = `${prefix === "/" ? "" : prefix}/${parts[index]}`;
    const metadata = lstatSync(prefix);
    if (metadata.isSymbolicLink()) {
      if (metadata.uid !== 0 || !trustedChain(parse(prefix).dir)) return false;
      const target = readlinkSync(prefix);
      const next = isAbsolute(target) ? target : `${parse(prefix).dir}/${target}`;
      const remaining = parts.slice(index + 1).join("/");
      return trustedSymlinkChain(remaining ? `${next}/${remaining}` : next, hops + 1);
    }
  }
  return trustedChain(path);
}

function trustedCandidate(candidate, directory) {
  const metadata = statSync(candidate);
  if (!metadata.isFile() || (metadata.mode & 0o111) === 0) return false;
  const real = realpathSync(candidate);
  const realDirectory = realpathSync(directory);
  // Sticky directories are allowed only as ancestors, not PATH leaves.
  if (!rootControlled(parse(real).dir, false) || !rootControlled(realDirectory, false)) return false;
  return trustedSymlinkChain(candidate) && trustedChain(real) && trustedChain(realDirectory);
}

// Returns the trusted path, or a non-existent sentinel so callers fail closed.
export function resolveTrustedExecutable(name, searchPath = `${process.env.PATH || ""}${delimiter}/bin${delimiter}/usr/bin`) {
  if (!/^[A-Za-z0-9_.+-]+$/.test(name) || name === "." || name === "..") return `/nonexistent/aidevops-untrusted-tool`;
  for (const directory of searchPath.split(delimiter)) {
    if (!isAbsolute(directory)) continue;
    // Do not collapse symlink/.. components before filesystem resolution.
    const candidate = `${directory.replace(/\/+$/, "")}/${name}`;
    try {
      if (trustedCandidate(candidate, directory)) return candidate;
    } catch {
      continue;
    }
  }
  return `/nonexistent/aidevops-untrusted-${name}`;
}
