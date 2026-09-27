// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { readFileSync, realpathSync } from "node:fs";
import { join } from "node:path";

const SOURCE = /^([A-Za-z0-9 +.-]+),([a-z0-9-]+\.md),([^\n]*?),((?:simple|standard|thinking))(?:,|$)/;
const ACTIONS = { bash: "shell", task: "subagent", write: "edit", patch: "edit" };

function deniedTools(source) {
  const frontmatter = /^---\n([\s\S]*?)\n---/.exec(source)?.[1];
  if (!frontmatter) return null;
  const denied = [];
  let tools = false;
  for (const line of frontmatter.split("\n")) {
    if (line === "tools:") { tools = true; continue; }
    if (tools && !line.startsWith("  ")) tools = false;
    if (!tools) continue;
    const match = /^  ([a-z][a-z0-9_-]*): (true|false)$/.exec(line);
    if (!match) return null; // Never silently drop a restrictive tool rule.
    if (match[2] === "false") denied.push({
      action: ACTIONS[match[1]] || match[1], resource: "*", effect: "deny",
    });
  }
  return denied;
}

function primaryFromRow(root, row, names) {
  const match = SOURCE.exec(row.trim());
  if (!match || names.has(match[1])) return null;
  const [, name, file, description] = match;
  const path = join(root, file);
  if (realpathSync(path) !== path) return null;
  const system = readFileSync(path, "utf8").trim();
  const denied = deniedTools(system);
  return denied && system && description ? { name, description, system, denied } : null;
}

/** Derive V2 primaries from the same audited index and source files used by V1. */
export function loadV2PrimaryProfiles(agentsDir) {
  try {
    const root = realpathSync(agentsDir);
    const index = readFileSync(join(root, "subagent-index.toon"), "utf8");
    const block = /<!--TOON:agents\[\d+\]\{name,file,purpose,model_tier,triggers\}:\n([\s\S]*?)-->/.exec(index)?.[1];
    if (!block) return [];
    const entries = [];
    const names = new Set();
    for (const row of block.trim().split("\n")) {
      const profile = primaryFromRow(root, row, names);
      if (!profile) return [];
      entries.push(profile);
      names.add(profile.name);
    }
    return names.has("Build+") ? entries : [];
  } catch {
    return []; // No canonical source means keep the host Build fallback.
  }
}

export function registerV2PrimaryProfiles(editor, profiles) {
  if (!profiles.some((profile) => profile.name === "Build+")) return false;
  for (const profile of profiles) {
    if (editor.get(profile.name)) continue; // Operator/project profiles take precedence.
    editor.update(profile.name, (agent) => {
      agent.name = profile.name;
      agent.description = profile.description;
      agent.system = profile.system;
      agent.mode = "primary";
      agent.hidden = false;
      agent.permissions.push(...profile.denied);
    });
  }
  const primary = editor.get("Build+");
  if (!primary || primary.mode !== "primary" || primary.hidden) return false;
  editor.default("Build+");
  editor.remove("build");
  return true;
}
