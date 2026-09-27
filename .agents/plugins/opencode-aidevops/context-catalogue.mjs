// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Generated command-skill wrapper entry. OpenCode 1 lists name/description/
// location; OpenCode 2 lists id/name/description. The location, when present,
// must be the wrapper's own SKILL.md so custom skills are never factored.
const GENERATED_WRAPPER_ENTRY = new RegExp(
  "^\\s*(?:<id>([^<>\\n]+)<\\/id>\\s*)?" +
  "<name>(aidevops-([a-z0-9-]+))<\\/name>\\s*" +
  "<description>Run the aidevops \\3 workflow when explicitly requested\\.<\\/description>\\s*" +
  "(?:<location>[^<>\\n]+\\/\\2\\/SKILL\\.md<\\/location>\\s*)?$",
);

/**
 * Compact advertising, never skill content, permissions, or invocation.
 * Generated wrappers share one trigger and resolve by exact name through the
 * skill tool, so only their names (plus a differing OpenCode 2 id) are listed.
 * Every generated name is `aidevops-<suffix>`, so the shared prefix is stated
 * once with a complete example instead of being repeated for each wrapper.
 */
export function compactSkillCatalogue(text) {
  return text.replace(/<available_skills>([\s\S]*?)<\/available_skills>/g, (block, body) => {
    const wrappers = [];
    const retained = body.replace(/[ \t]*<skill>([\s\S]*?)<\/skill>\n?/g, (entry, fields) => {
      // Fail open for custom descriptions, additional fields, or changed formats.
      const match = fields.match(GENERATED_WRAPPER_ENTRY);
      if (!match) return entry;
      const [, id, name, suffix] = match;
      wrappers.push({ name, listed: id && id !== name ? `${suffix} (id: ${id})` : suffix });
      return "";
    });
    if (wrappers.length < 2) return block;
    return `<available_skills>${retained.trimEnd()}\n\n` +
      `Generated aidevops workflow skills (${wrappers.length}) share one trigger: run the named aidevops workflow ONLY when explicitly requested. ` +
      "Load the full instructions with the skill tool using the exact skill name `aidevops-<listed name>` " +
      `(for example \`${wrappers[0].name}\`); all remain available:\n` +
      wrappers.map((wrapper) => wrapper.listed).join(", ") + "\n</available_skills>";
  });
}

/** Pointer used when an instruction body is byte-identical to one already loaded. */
export function duplicateInstructionReference(source, previous) {
  return `Instructions from: ${source}\nThe complete instruction body is byte-identical to the already loaded instructions from: ${previous}. Apply those instructions here too.`;
}

/** Only exact, separately supplied instruction bodies may be shared. No history rewriting. */
export function compactSystemContext(system) {
  const instructions = new Map();
  return system.map((text) => {
    if (typeof text !== "string") return text;
    const match = text.match(/^Instructions from: ([^\n]+)\n([\s\S]+)$/);
    if (match) {
      const [, source, body] = match;
      const previous = instructions.get(body);
      if (previous) return duplicateInstructionReference(source, previous);
      instructions.set(body, source);
    }
    return compactSkillCatalogue(text);
  });
}

/** Replace only a byte-identical canonical instruction document with its source. */
export function compactExactInstructionDocument(body, source, text) {
  const incoming = typeof text === "string" ? text : "";
  if (!body || !source) return incoming;

  const document = `Instructions from: ${source}\n${body}`;
  const reference = `Instructions from: ${source}\nThe complete instruction body is already supplied by the Claude proxy.`;
  const escapedDocument = document.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return incoming.replace(
    new RegExp(`(^|\\n\\n)${escapedDocument}(?=\\n\\nInstructions from:|$)`, "g"),
    `$1${reference}`,
  );
}
