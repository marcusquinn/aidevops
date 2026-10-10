// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Strict parser for the small YAML subset used by canonical agent sources:
// nested maps of scalars only. Any unexpected syntax, unsafe key, or duplicate
// key makes the whole document unreadable so callers can fail closed.

const UNSAFE_FRONTMATTER_KEYS = new Set(["__proto__", "constructor", "prototype"]);

function parseFrontmatterScalar(value) {
  const booleans = { true: true, false: false };
  if (Object.hasOwn(booleans, value)) return booleans[value];
  return value.startsWith('"') ? JSON.parse(value) : value;
}

function parseFrontmatterEntry(line) {
  if (!line.trim() || line.trimStart().startsWith("#")) return null;
  const entry = line.match(/^( *)(?:"([^"]+)"|([A-Za-z0-9_.*-]+)):\s*(.*)$/);
  if (!entry || entry[1].length % 2 !== 0) throw new Error("Invalid agent frontmatter entry");
  return entry;
}

function assignFrontmatterEntry(stack, entry) {
  const indent = entry[1].length;
  while (stack.at(-1).indent >= indent) stack.pop();
  if (indent > stack.at(-1).indent + 2) throw new Error("Invalid agent frontmatter indentation");

  const key = entry[2] || entry[3];
  const parent = stack.at(-1).value;
  if (UNSAFE_FRONTMATTER_KEYS.has(key) || Object.hasOwn(parent, key)) {
    throw new Error("Unsafe or duplicate agent frontmatter key");
  }
  parent[key] = entry[4] ? parseFrontmatterScalar(entry[4]) : {};
  if (!entry[4]) stack.push({ indent, value: parent[key] });
}

/**
 * @param {string} source - Agent markdown with a leading `---` frontmatter block
 * @returns {{profile: object, prompt: string} | null} null when unreadable
 */
export function parseAgentFrontmatter(source) {
  try {
    const match = source.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
    if (!match) throw new Error("Agent frontmatter is missing");

    const profile = {};
    const stack = [{ indent: -1, value: profile }];
    match[1].split("\n")
      .map(parseFrontmatterEntry)
      .filter(Boolean)
      .forEach((entry) => assignFrontmatterEntry(stack, entry));
    return { profile, prompt: match[2].trim() };
  } catch {
    return null;
  }
}
