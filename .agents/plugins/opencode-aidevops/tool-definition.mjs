// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// OpenCode owns packages/opencode/src/tool/bash.txt. Adapt only its known
// listing-only paragraph through the public tool.definition hook; do not
// replace the tool, its parameters, or any runtime permission enforcement.
import { GREP_PATH_DESCRIPTION_NOTE } from "./grep-path-guard.mjs";

export const LEGACY_PARENT_GUIDANCE = `1. Directory Verification:
   - If the command will create new directories or files, first use \`ls\` to verify the parent directory exists and is the correct location
   - For example, before running "mkdir foo/bar", first use \`ls foo\` to check that "foo" exists and is the intended parent directory`;

export const BOUNDED_PARENT_GUIDANCE = `1. Directory Verification:
   - Before creating files or directories, verify the exact intended parent path relative to the command's workdir (or use an absolute path).
   - When only existence and directory type are needed, use a bounded check such as \`test -d "foo"\` before \`mkdir "foo/bar"\`. Exit 0 confirms a directory; failure must stop creation. This does not enumerate children.
   - A successful check does not establish that an arbitrary existing directory is the correct parent: confirm the intended location from task context first. Quote paths, including paths with spaces.
   - When child names are materially needed, use an appropriately scoped directory listing or dedicated Read operation instead.
   - These checks do not grant filesystem access or replace pre-edit Git checks, destructive-operation confirmation, or other permission controls.`;

// GH#32622: remove only illustrative text captured from OpenCode 1.18.34.
// Keep the rules beside each example, including all safety/permission/Git text.
// Literal matches deliberately leave revised upstream paragraphs untouched.
export const BUILTIN_DESCRIPTION_TRIMS = Object.freeze({
  bash: Object.freeze([
    Object.freeze({
      original: `   - Examples of proper quoting:
     - mkdir "/Users/name/My Documents" (correct)
     - mkdir /Users/name/My Documents (incorrect - will fail)
     - python "/path/with spaces/script.py" (correct)
     - python /path/with spaces/script.py (incorrect - will fail)
`,
      replacement: "",
    }),
    Object.freeze({
      original: ` For instance, if one operation must complete before another starts (like mkdir before cp, Write before Bash for git operations, or git add before git commit), run these operations sequentially instead.`,
      replacement: ` For instance, if one operation must complete before another starts, run these operations sequentially instead.`,
    }),
    Object.freeze({
      original: `    <good-example>
    Use workdir="/foo/bar" with command: pytest tests
    </good-example>
    <bad-example>
    cd /foo/bar && pytest tests
    </bad-example>
`,
      replacement: "",
    }),
  ]),
  task: Object.freeze([
    Object.freeze({
      original: `6. Clearly tell the agent whether you expect it to write code or just to do research (search, file reads, web fetches, etc.), since it is not aware of the user's intent. Tell it how to verify its work if possible (e.g., relevant test commands).`,
      replacement: `6. Clearly tell the agent whether you expect it to write code or just to do research, since it is not aware of the user's intent. Tell it how to verify its work if possible.`,
    }),
  ]),
  todowrite: Object.freeze([
    Object.freeze({
      original: `## Examples

Use it:
- "Add a dark mode toggle and run the tests" -> multi-step feature + explicit verification
- "Rename getCwd -> getCurrentWorkingDirectory across the repo" -> grep reveals 15 occurrences in 8 files
- "Implement registration, catalog, cart, checkout" -> multiple complex features

Skip it:
- "How do I print Hello World in Python?" -> informational
- "Add a comment to calculateTotal" -> single edit
- "Run npm install and tell me what happened" -> one command

`,
      replacement: "",
    }),
  ]),
});

export async function adaptToolDefinition(input, output) {
  if (typeof output.description === "string") {
    const trims = Object.hasOwn(BUILTIN_DESCRIPTION_TRIMS, input.toolID)
      ? BUILTIN_DESCRIPTION_TRIMS[input.toolID] : [];
    for (const { original, replacement } of trims) {
      output.description = output.description.replaceAll(original, replacement);
    }
  }
  if (input.toolID === "grep" && typeof output.description === "string"
    && !output.description.includes(GREP_PATH_DESCRIPTION_NOTE)) {
    // GH#33061: pairs with the grep-path-guard rejection so callers learn the
    // contract before a file path is refused.
    output.description = `${output.description.trimEnd()}\n\n${GREP_PATH_DESCRIPTION_NOTE}`;
    return;
  }
  if (input.toolID === "bash" && typeof output.description === "string") {
    // Exact matching leaves future upstream revisions and other plugins' text
    // untouched rather than broadly deleting an unknown safety paragraph.
    output.description = output.description.replace(LEGACY_PARENT_GUIDANCE, BOUNDED_PARENT_GUIDANCE);
  }
  if (input.toolID !== "apply_patch") return;

  const parameters = output.parameters;
  if (!parameters || typeof parameters !== "object") return;
  parameters.properties ||= {};
  if (parameters.properties.workdir) return;
  parameters.properties.workdir = {
    type: "string",
    description: "Optional verified linked-worktree directory for applying the patch. Use absolute patch paths when targeting a different worktree.",
  };
}
