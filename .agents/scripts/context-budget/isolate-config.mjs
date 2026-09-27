#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Write the isolated opencode.json for a context-budget probe: the user's config
// with every aidevops plugin entry replaced by the chosen plugin plus the capture
// plugin. The source file is only read. The copy is created exclusively (0600)
// and nothing from it is printed except the plugin count.
import { closeSync, openSync, readFileSync, writeSync } from "node:fs";

const args = process.argv.slice(2, 7);
const [source, target, key, pluginUrl, captureUrl] = args;
if (args.length !== 5 || args.some((value) => !value) || !["plugin", "plugins"].includes(key)) {
  console.error("Usage: isolate-config.mjs <source.json> <target.json> <plugin|plugins> <plugin-url> <capture-url>");
  process.exit(2);
}

let config;
try {
  config = JSON.parse(readFileSync(source, "utf8"));
} catch (error) {
  console.error(`Cannot read ${source} as plain JSON (${error.code ?? error.name}); JSONC configs are not supported.`);
  process.exit(1);
}

const entries = Array.isArray(config[key]) ? config[key] : [];
const kept = entries.filter((entry) => !(typeof entry === "string" && entry.includes("opencode-aidevops")));
config[key] = [...kept, pluginUrl, captureUrl];
const fd = openSync(target, "wx", 0o600);
try {
  writeSync(fd, `${JSON.stringify(config, null, 2)}\n`);
} finally {
  closeSync(fd);
}
console.log(`isolated config: ${config[key].length} plugin entries (${entries.length - kept.length} aidevops entry replaced)`);
