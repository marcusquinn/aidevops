// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// Regression test for the "re-export only, used locally" class of bug.
// ---------------------------------------------------------------------------
// ES `export { X } from "./Y"` is a RE-EXPORT ONLY — it does NOT create a
// local binding for X inside the exporting module. If the module also
// *calls* X internally, it throws `ReferenceError: X is not defined` at
// call time (not at module load).
//
// This test statically scans plugin source files for re-exported
// identifiers that are also used in non-import/non-export positions and
// lack a corresponding local `import`. It would have caught both:
//   - quality-hooks.mjs: checkSignatureFooterGate (broke ALL Bash tool calls)
//   - google-proxy.mjs: discoverGoogleModels, persistGoogleProvider (latent)
//
//   node --test .agents/plugins/opencode-aidevops/tests/test-reexport-local-binding.mjs
// ---------------------------------------------------------------------------

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const pluginDir = resolve(__dirname, "..");

/**
 * Parse names out of a destructured list, stripping `as` aliases.
 * @param {string} block - Contents between `{` and `}`
 * @returns {string[]}
 */
function parseNames(block) {
  return block
    .split(",")
    .map((s) => s.trim().split(/\s+as\s+/)[0].trim())
    .filter(Boolean);
}

/**
 * Match all `^import/export { … } from "…"` blocks of a given kind and
 * accumulate the destructured identifiers plus the byte ranges they occupy.
 * @param {string} src
 * @param {RegExp} re
 * @param {Set<string>} identifiersOut
 * @param {Array<[number, number]>} rangesOut
 */
function collectDestructuredFromBlocks(src, re, identifiersOut, rangesOut) {
  for (const m of src.matchAll(re)) {
    parseNames(m[1]).forEach((id) => identifiersOut.add(id));
    rangesOut.push([m.index, m.index + m[0].length]);
  }
}

/**
 * True if `pos` falls inside any of the recorded import/export block ranges.
 * @param {number} pos
 * @param {Array<[number, number]>} ranges
 */
function positionIsInsideBlock(pos, ranges) {
  return ranges.some(([start, end]) => pos >= start && pos < end);
}

/**
 * True if the line containing byte offset `pos` begins with a comment marker
 * (`//` or `*`). Cheap line-scoped check to skip prose mentions.
 * @param {string} src
 * @param {number} pos
 */
function positionIsOnCommentLine(src, pos) {
  const lineStart = src.lastIndexOf("\n", pos) + 1;
  const lineEnd = src.indexOf("\n", pos);
  const line = src.slice(lineStart, lineEnd === -1 ? src.length : lineEnd);
  return /^\s*(\/\/|\*)/.test(line);
}

/**
 * True if `id` appears in `src` outside any of the given import/export block
 * ranges and outside any comment line.
 * @param {string} src
 * @param {string} id
 * @param {Array<[number, number]>} blockRanges
 */
function identifierHasLocalUse(src, id, blockRanges) {
  const idRe = new RegExp(`\\b${id}\\b`, "g");
  for (const m of src.matchAll(idRe)) {
    if (positionIsInsideBlock(m.index, blockRanges)) continue;
    if (positionIsOnCommentLine(src, m.index)) continue;
    return true;
  }
  return false;
}

/**
 * Return identifiers that are re-exported via `export { … } from "./mod"`
 * but are also used in non-import/non-export positions in the same file
 * without a corresponding `import { … }` declaration.
 *
 * Implementation note: matches against byte-offset ranges rather than line
 * scope so that multi-line `export { A, B, C } from "./mod"` blocks — whose
 * identifier continuation lines contain only destructured names — don't
 * look like "local uses" of A, B, or C.
 *
 * @param {string} filePath
 * @returns {string[]}
 */
function findReExportLocalUseViolations(filePath) {
  const src = readFileSync(filePath, "utf8");

  const reExportRe = /^export\s*\{([^}]+)\}\s*from\s*["'][^"']+["'];?\s*$/gm;
  const importRe = /^import\s*\{([^}]+)\}\s*from\s*["'][^"']+["'];?\s*$/gm;

  const reExported = new Set();
  const imported = new Set();
  const blockRanges = [];

  collectDestructuredFromBlocks(src, reExportRe, reExported, blockRanges);
  if (reExported.size === 0) return [];
  collectDestructuredFromBlocks(src, importRe, imported, blockRanges);

  return [...reExported].filter(
    (id) => !imported.has(id) && identifierHasLocalUse(src, id, blockRanges),
  );
}

// Auto-discover all plugin .mjs files except the entry point (index.mjs).
// Rationale: hardcoded lists silently miss new files that ship with the
// re-export-only-used-locally bug pattern. t2697 closes that gap by scanning
// the plugin directory on every test run. `index.mjs` is excluded because it
// is a pure re-export barrel — the pattern this test flags is legitimate there.
const CANDIDATES = readdirSync(pluginDir)
  .filter((name) => name.endsWith(".mjs") && name !== "index.mjs")
  .sort();

for (const name of CANDIDATES) {
  test(`${name}: re-exported identifiers used locally are also imported`, () => {
    const violations = findReExportLocalUseViolations(resolve(pluginDir, name));
    assert.deepEqual(
      violations,
      [],
      `Identifier(s) are re-exported via \`export { … } from "./Y"\` and used locally in ${name} without a matching \`import\`. This causes ReferenceError at call time. Add them to an \`import { … } from "./Y"\` statement.`,
    );
  });
}
