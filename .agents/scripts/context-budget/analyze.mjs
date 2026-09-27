#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Break a captured provider request body into context sections, skill catalogue,
// tools and OAuth wire-shape invariants, or compare two captures section by
// section. Output is character counts only: characters are not tokens, so use
// `context-budget-helper.sh tokens` for API-reported token evidence.
import { readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { pathToFileURL } from "node:url";

const BUILTIN_TOOLS = new Set([
  "Bash", "Read", "Edit", "Write", "Glob", "Grep", "WebFetch", "WebSearch", "Skill", "Task", "TodoWrite",
  "apply_patch", "question", "codesearch", "lsp", "list", "execute",
]);
const SKILL_BLOCK = /<(skill_list|available_skills)>[\s\S]*?<\/\1>/;
const MARKERS = [
  [/^You are powered by the model[^\n]*/gm, () => "runtime: model identity"],
  [/^Here is some useful information about the environment[^\n]*/gm, () => "runtime: environment"],
  [/^Instructions from: ([^\n]+)/gm, (match) => `instructions: ${tidyPath(match[1])}`],
  [/^Skills provide specialized instructions[^\n]*/gm, () => "skills: preamble"],
  [/^## Intent Tracing \(observability\)/gm, () => "plugin: intent tracing"],
  [/^## aidevops Quality Rules[^\n]*/gm, () => "plugin: quality rules"],
];

/** Stable, private-path-free labels: home becomes ~ and probe config homes one token. */
function tidyPath(path) {
  const home = homedir();
  const relative = home && path.startsWith(home) ? `~${path.slice(home.length)}` : path;
  return relative.replace(/[^\s/]*iso\.[A-Za-z0-9]{6}(?=\/)/g, "<isolated-config>");
}

function redact(text) {
  return String(text).replace(/cch=[^;\s]*/g, "cch=<redacted>");
}

function blockText(block) {
  if (typeof block === "string") return block;
  return typeof block?.text === "string" ? block.text : "";
}

function contentBlocks(content) {
  if (Array.isArray(content)) return content;
  return content == null ? [] : [{ type: "text", text: String(content) }];
}

/** Context sources in wire order: system blocks, then the first message's blocks. */
function contextSources(body) {
  const sources = [];
  const system = typeof body.system === "string" ? [body.system] : body.system ?? [];
  system.forEach((block, index) => sources.push({ source: `system[${index}]`, block }));
  if (typeof body.instructions === "string") sources.push({ source: "instructions", block: body.instructions });
  const first = body.messages?.[0] ?? body.input?.[0];
  contentBlocks(first?.content).forEach((block, index) => sources.push({ source: `messages[0][${index}]`, block }));
  return sources;
}

function markerCuts(text) {
  const cuts = [{ index: 0, label: "leading text" }];
  for (const [pattern, label] of MARKERS) {
    for (const match of text.matchAll(pattern)) cuts.push({ index: match.index, label: label(match) });
  }
  const skills = text.match(SKILL_BLOCK);
  if (skills) {
    cuts.push({ index: skills.index, label: "skills: catalogue" });
    const end = skills.index + skills[0].length;
    if (end < text.length) cuts.push({ index: end, label: "after skills: plugin additions" });
  }
  return cuts.sort((a, b) => a.index - b.index);
}

/** Split each context source at well-known markers; labels are unique for comparison. */
export function contextSections(body) {
  const sections = [];
  const seen = new Map();
  for (const { source, block } of contextSources(body)) {
    const text = blockText(block);
    const cuts = markerCuts(text).filter((cut, index, all) => index === all.length - 1 || cut.index !== all[index + 1].index);
    cuts.forEach((cut, index) => {
      const chars = (cuts[index + 1]?.index ?? text.length) - cut.index;
      if (chars === 0) return;
      const base = `${source} ${cut.label}`;
      const count = (seen.get(base) ?? 0) + 1;
      seen.set(base, count);
      sections.push({ label: count > 1 ? `${base} #${count}` : base, chars });
    });
  }
  return sections;
}

/** Summarise the skill catalogue: custom entries, compact wrapper list and total size. */
export function skillCatalogue(body) {
  const text = contextSources(body).map(({ block }) => blockText(block)).join("\n");
  const match = text.match(SKILL_BLOCK);
  if (!match) return null;
  const block = match[0];
  const entries = [...block.matchAll(/<skill>([\s\S]*?)<\/skill>/g)].map((entry) => ({
    name: entry[1].match(/<name>([^<]*)<\/name>/)?.[1] ?? "",
    chars: entry[0].length,
  }));
  const compact = block.match(/Generated aidevops workflow skills \((\d+)\)[\s\S]*$/);
  return {
    tag: match[1],
    chars: block.length,
    entries: entries.length,
    entryChars: entries.reduce((sum, entry) => sum + entry.chars, 0),
    generatedWrappers: compact ? Number(compact[1]) : entries.filter((entry) => entry.name.startsWith("aidevops-")).length,
    compactListChars: compact ? compact[0].length : 0,
    largestEntries: [...entries].sort((a, b) => b.chars - a.chars).slice(0, 5),
  };
}

export function toolSizes(body) {
  return (body.tools ?? []).map((tool) => {
    const name = tool.name ?? tool.function?.name ?? "";
    const description = tool.description ?? tool.function?.description ?? "";
    const schema = tool.input_schema ?? tool.parameters ?? tool.function?.parameters ?? {};
    return { name, description: description.length, schema: JSON.stringify(schema).length, total: JSON.stringify(tool).length };
  }).sort((a, b) => b.total - a.total);
}

/** Anthropic OAuth invariants that context work must preserve. */
export function wireShape(body) {
  const system = typeof body.system === "string" ? [body.system] : body.system ?? [];
  const tools = body.tools ?? [];
  const names = tools.map((tool) => tool.name ?? tool.function?.name ?? "");
  const schemaOf = (tool) => tool.input_schema ?? tool.parameters ?? tool.function?.parameters;
  return {
    model: body.model ?? null,
    maxTokens: body.max_tokens ?? body.max_output_tokens ?? null,
    thinking: body.thinking ?? body.reasoning ?? null,
    systemBlocks: system.length,
    systemPreview: system.map((block) => redact(blockText(block).slice(0, 60).replace(/\n/g, " "))),
    billingHeader: /x-anthropic-billing-header/.test(blockText(system[0])),
    identityBlock: blockText(system[1]).startsWith("You are Claude Code"),
    cacheControl: [...system, ...contentBlocks(body.messages?.[0]?.content)].map((block) => Boolean(block?.cache_control)),
    tools: tools.length,
    unprefixedTools: names.filter((name) => !BUILTIN_TOOLS.has(name) && !name.startsWith("mcp__")),
    intentTools: tools.filter((tool) => schemaOf(tool)?.properties?.agent__intent).length,
  };
}

export function analyzeBody(body, rawChars = JSON.stringify(body).length) {
  const sections = contextSections(body);
  const tools = toolSizes(body);
  return {
    bodyChars: rawChars,
    contextChars: sections.reduce((sum, section) => sum + section.chars, 0),
    toolChars: tools.reduce((sum, tool) => sum + tool.total, 0),
    sections,
    skills: skillCatalogue(body),
    tools,
    wire: wireShape(body),
  };
}

function loadReport(path) {
  const raw = readFileSync(path, "utf8");
  return analyzeBody(JSON.parse(raw), raw.length);
}

const row = (chars, label) => `${String(chars).padStart(8)}  ${label}`;
const signed = (value) => (value > 0 ? `+${value}` : String(value));

function printReport(path, report) {
  const lines = [`# ${tidyPath(path)}`, row(report.bodyChars, "request body chars"),
    row(report.contextChars, "context chars (system + first message)"), row(report.toolChars, `tool chars (${report.tools.length} tools)`),
    "", "## Context sections", ...report.sections.map((section) => row(section.chars, section.label))];
  if (report.skills) {
    const skills = report.skills;
    lines.push("", "## Skill catalogue", row(skills.chars, `<${skills.tag}> block`),
      row(skills.entryChars, `${skills.entries} listed entries`),
      row(skills.compactListChars, `compact generated-wrapper list (${skills.generatedWrappers} wrappers)`),
      ...skills.largestEntries.map((entry) => row(entry.chars, `entry ${entry.name}`)));
  }
  lines.push("", "## Tools (description / schema / total)",
    ...report.tools.map((tool) => row(tool.total, `${tool.name} (${tool.description} / ${tool.schema})`)),
    "", "## Wire shape", JSON.stringify(report.wire, null, 2),
    "", "Characters are not tokens: use `context-budget-helper.sh tokens` for API-reported evidence.");
  console.log(lines.join("\n"));
}

function deltaRows(before, after) {
  const labels = [...new Set([...before.keys(), ...after.keys()])];
  return labels.map((label) => {
    const a = before.get(label) ?? 0;
    const b = after.get(label) ?? 0;
    return { label, before: a, after: b, delta: b - a };
  }).filter((entry) => entry.delta !== 0);
}

export function compareReports(control, candidate) {
  const sectionsOf = (report) => new Map(report.sections.map((section) => [section.label, section.chars]));
  const toolsOf = (report) => new Map(report.tools.map((tool) => [tool.name, tool.total]));
  const wireChanges = Object.keys(control.wire)
    .filter((key) => key !== "systemPreview" && JSON.stringify(control.wire[key]) !== JSON.stringify(candidate.wire[key]))
    .map((key) => ({ key, control: control.wire[key], candidate: candidate.wire[key] }));
  return {
    totals: ["bodyChars", "contextChars", "toolChars"].map((key) => ({
      label: key, before: control[key], after: candidate[key], delta: candidate[key] - control[key],
    })),
    sections: deltaRows(sectionsOf(control), sectionsOf(candidate)),
    tools: deltaRows(toolsOf(control), toolsOf(candidate)),
    wireChanges,
  };
}

function printComparison(result) {
  const format = (entry) => `${String(entry.before).padStart(8)} ${String(entry.after).padStart(8)} ${signed(entry.delta).padStart(8)}  ${entry.label}`;
  const lines = ["## Totals (control candidate delta)", ...result.totals.map(format),
    "", "## Changed sections", ...(result.sections.length ? result.sections.map(format) : ["    none"]),
    "", "## Changed tools", ...(result.tools.length ? result.tools.map(format) : ["    none"]),
    "", "## Wire-shape changes", result.wireChanges.length ? JSON.stringify(result.wireChanges, null, 2) : "    none",
    "", "Characters are not tokens: use `context-budget-helper.sh tokens` for API-reported evidence."];
  console.log(lines.join("\n"));
}

function main(argv) {
  const [command, ...rest] = argv;
  const json = rest.includes("--json");
  const files = rest.filter((arg) => arg !== "--json");
  if (command === "analyze" && files.length === 1) {
    const report = loadReport(files[0]);
    if (json) console.log(JSON.stringify(report, null, 2));
    else printReport(files[0], report);
    return 0;
  }
  if (command === "compare" && files.length === 2) {
    const result = compareReports(loadReport(files[0]), loadReport(files[1]));
    if (json) console.log(JSON.stringify(result, null, 2));
    else printComparison(result);
    return 0;
  }
  console.error("Usage: analyze.mjs analyze <capture.json> [--json] | compare <control.json> <candidate.json> [--json]");
  return 2;
}

function invokedDirectly() {
  try {
    return import.meta.url === pathToFileURL(realpathSync(process.argv[1] ?? "")).href;
  } catch {
    return false;
  }
}

if (invokedDirectly()) process.exitCode = main(process.argv.slice(2));
