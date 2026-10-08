// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Resolve trust-sensitive executables through PATH without trusting
// caller-owned files: accept the first PATH entry whose real executable and
// real directory chains are root-controlled. No distro-specific roots, so the
// same rule covers macOS, FHS Linux and store-symlinked layouts.
// Python counterpart: trusted_executable.py.

import {realpathSync, statSync} from "node:fs";
import {delimiter, isAbsolute, join, parse, resolve} from "node:path";

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
    current = resolve(current, "..");
    if (!rootControlled(current, true)) return false;
  }
  return true;
}

// Returns the trusted path, or a non-existent sentinel so callers fail closed.
export function resolveTrustedExecutable(name, searchPath = process.env.PATH || "") {
  for (const directory of searchPath.split(delimiter)) {
    if (!isAbsolute(directory)) continue;
    const candidate = join(directory, name);
    try {
      const metadata = statSync(candidate);
      if (!metadata.isFile() || (metadata.mode & 0o111) === 0) continue;
      if (trustedChain(realpathSync(candidate)) && trustedChain(realpathSync(directory))) {
        return candidate;
      }
    } catch {
      continue;
    }
  }
  return `/nonexistent/aidevops-untrusted-${name}`;
}
