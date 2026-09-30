// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// OpenCode's native grep treats `path` as the search root. For a regular file
// it searches the file's parent directory instead (upstream
// packages/opencode/src/tool/grep.ts: `cwd = Directory ? search : dirname`),
// so a single-file request silently returns sibling-file matches (GH#33061).
// Fail closed before the tool runs. Do not rewrite to dirname + include:
// include is a recursive glob, so same-named files in subdirectories leak.

import { statSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";

export const GREP_FILE_PATH_ERROR =
  "Grep `path` must be a directory; OpenCode searches a file's whole parent directory. "
  + "For one file use Read, or `rg -n -- <pattern> <file>` in Bash.";

export const GREP_PATH_DESCRIPTION_NOTE =
  "`path` must be a directory; regular-file paths are rejected because they would search the whole parent directory. "
  + "For one file, use Read or `rg -n -- <pattern> <file>`.";

export function checkGrepPathScope(tool, args, baseDir = process.cwd()) {
  if (tool !== "grep") return;
  const requested = args?.path;
  if (typeof requested !== "string" || requested.trim() === "") return;

  const candidate = isAbsolute(requested) ? requested : resolve(baseDir || process.cwd(), requested);
  let info;
  try {
    // statSync follows symlinks: a link to a file broadens the search too.
    info = statSync(candidate);
  } catch {
    return; // Missing or unreadable paths keep upstream error behaviour.
  }
  if (!info.isDirectory()) throw new Error(GREP_FILE_PATH_ERROR);
}
