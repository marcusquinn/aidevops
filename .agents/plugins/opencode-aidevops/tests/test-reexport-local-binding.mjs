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
import { readFileSync } from "node:fs";
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

  // Collect re-exports + occupied byte ranges in one pass.
  const reExported = new Set();
  const blockRanges = [];
  for (const m of src.matchAll(reExportRe)) {
    parseNames(m[1]).forEach((id) => reExported.add(id));
    blockRanges.push([m.index, m.index + m[0].length]);
  }
  if (reExported.size === 0) return [];

  const imported = new Set();
  for (const m of src.matchAll(importRe)) {
    parseNames(m[1]).forEach((id) => imported.add(id));
    blockRanges.push([m.index, m.index + m[0].length]);
  }

  const isInsideImportExportBlock = (pos) =>
    blockRanges.some(([start, end]) => pos >= start && pos < end);

  const violations = [];
  for (const id of reExported) {
    if (imported.has(id)) continue;
    const idRe = new RegExp(`\\b${id}\\b`, "g");
    let usedLocally = false;
    for (const m of src.matchAll(idRe)) {
      if (isInsideImportExportBlock(m.index)) continue;
      // Skip comment lines: the most common false positive is a // or *
      // that references the identifier in prose. Cheap line-scoped check.
      const lineStart = src.lastIndexOf("\n", m.index) + 1;
      const lineEnd = src.indexOf("\n", m.index);
      const line = src.slice(lineStart, lineEnd === -1 ? src.length : lineEnd);
      if (/^\s*(\/\/|\*)/.test(line)) continue;
      usedLocally = true;
      break;
    }
    if (usedLocally) violations.push(id);
  }
  return violations;
}

// Files known to use the re-export pattern — extend when new ones land.
const CANDIDATES = [
  "quality-hooks.mjs",
  "google-proxy.mjs",
  "oauth-pool.mjs",
  "agent-loader.mjs",
];

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
