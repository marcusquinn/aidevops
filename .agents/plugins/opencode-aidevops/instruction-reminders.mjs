// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { readFileSync } from "node:fs";
import { duplicateInstructionReference } from "./context-catalogue.mjs";

// OpenCode 1's Read tool appends a <system-reminder> containing each nearby
// AGENTS.md that is not already a system instruction *by path*. A repository
// copy of the framework guide (for example `.agents/AGENTS.md` in the aidevops
// repo) is byte-identical to the loaded `~/.aidevops/agents/AGENTS.md`, so the
// same ~24K characters were stored again in the conversation (GH#32444).
//
// Only an exact `Instructions from: <path>\n<file body>` document whose body is
// byte-identical to an instruction file already in this session's system prompt
// becomes a pointer. The rewrite happens once in tool.execute.after, before the
// tool result is stored, so later requests replay identical bytes and the prompt
// cache prefix stays stable. Differing, unreadable or unmatched content is kept.
//
// OpenCode 2 loads nearby instructions as a separate synthetic message instead
// of Read output, so this compactor is a no-op there (no `metadata.loaded`).

const MAX_SESSIONS = 200;
const INSTRUCTION_HEADER = /(?:^|\n)Instructions from: ([^\n]+)\n/g;

function readText(path, readFile) {
  try {
    return readFile(path);
  } catch {
    return null;
  }
}

/** Collect `Instructions from:` sources from separate or joined system strings. */
export function extractInstructionSources(system) {
  const sources = new Set();
  for (const text of Array.isArray(system) ? system : []) {
    if (typeof text !== "string") continue;
    for (const match of text.matchAll(INSTRUCTION_HEADER)) sources.add(match[1]);
  }
  return sources;
}

/**
 * @param {{ readFile?: (path: string) => string }} [options]
 */
export function createInstructionReminderCompactor(options = {}) {
  const readFile = options.readFile ?? ((path) => readFileSync(path, "utf8"));
  const sessions = new Map();

  function rememberSystem(sessionID, system) {
    if (!sessionID) return;
    const sources = extractInstructionSources(system);
    if (sources.size === 0) return;
    sessions.delete(sessionID);
    sessions.set(sessionID, sources);
    while (sessions.size > MAX_SESSIONS) sessions.delete(sessions.keys().next().value);
  }

  function findLoadedCopy(sources, path, body) {
    for (const source of sources) {
      if (source !== path && readText(source, readFile) === body) return source;
    }
    return null;
  }

  /** @returns {number} count of reminder documents replaced by pointers */
  function compactReadOutput(input, output) {
    if (input?.tool !== "read" || typeof output?.output !== "string") return 0;
    const loaded = output.metadata?.loaded;
    if (!Array.isArray(loaded) || loaded.length === 0) return 0;
    const sources = sessions.get(input.sessionID);
    if (!sources) return 0;
    let replaced = 0;
    for (const path of loaded) {
      if (typeof path !== "string") continue;
      const body = readText(path, readFile);
      if (!body) continue;
      const document = `Instructions from: ${path}\n${body}`;
      if (!output.output.includes(document)) continue;
      const loadedCopy = findLoadedCopy(sources, path, body);
      if (!loadedCopy) continue;
      output.output = output.output.replace(document, () => duplicateInstructionReference(path, loadedCopy));
      replaced += 1;
    }
    return replaced;
  }

  return { rememberSystem, compactReadOutput };
}
