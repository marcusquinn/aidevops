// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import { test } from "node:test";
import assert from "node:assert/strict";
import { compactExactInstructionDocument, compactSkillCatalogue, compactSystemContext } from "../context-catalogue.mjs";
import { buildClaudeArgs } from "../claude-proxy-context.mjs";

function wrapper(name, description = `Run the aidevops ${name} workflow when explicitly requested.`) {
  return `<skill>\n<name>aidevops-${name}</name>\n<description>${description}</description>\n<location>/skills/aidevops-${name}/SKILL.md</location>\n</skill>`;
}

function v2Wrapper(name, id = `aidevops-${name}`) {
  return `  <skill>\n    <id>${id}</id>\n    <name>aidevops-${name}</name>\n    <description>Run the aidevops ${name} workflow when explicitly requested.</description>\n  </skill>`;
}

test("compact wrapper advertising retains every exact name, trigger and specialist instruction", () => {
  const names = ["full-loop", "seo", "report-token-use", "release", "review", "vault"];
  const custom = wrapper("custom", "Load when custom domain guidance is relevant. Never publish without consent.");
  const source = `unchanged prefix\n<available_skills>\n${names.map((name) => wrapper(name)).join("\n")}\n${custom}\n</available_skills>\nunchanged suffix`;
  const compact = compactSkillCatalogue(source);
  const advertised = compact.match(/all remain available:\n(.+)\n<\/available_skills>/)?.[1].split(", ");
  assert.deepEqual(advertised, names.map((name) => `aidevops-${name}`));
  assert.ok(!compact.includes("/skills/aidevops-seo/SKILL.md"), "wrapper locations are not advertised");
  assert.ok(compact.includes(custom));
  assert.match(compact, /Generated aidevops workflow skills \(6\)/);
  assert.match(compact, /ONLY when explicitly requested/);
  assert.match(compact, /skill tool using the exact skill name/);
  assert.ok(compact.startsWith("unchanged prefix\n"));
  assert.ok(compact.endsWith("\nunchanged suffix"));
  assert.ok(compact.length < source.length * 0.5);
  assert.equal(compactSkillCatalogue(compact), compact);
});

test("OpenCode 2 id/name wrapper entries compact and keep a differing id", () => {
  const custom = "  <skill>\n    <id>custom</id>\n    <name>custom</name>\n    <description>Custom trigger.</description>\n  </skill>";
  const source = `<available_skills>\n${v2Wrapper("seo")}\n${v2Wrapper("review", "global:aidevops-review")}\n${custom}\n</available_skills>`;
  const compact = compactSkillCatalogue(source);
  assert.match(compact, /all remain available:\naidevops-seo, aidevops-review \(id: global:aidevops-review\)\n/);
  assert.ok(compact.includes(custom));
  assert.ok(!compact.includes("<id>aidevops-seo</id>"));
});

test("unknown or enriched formats and isolated wrappers remain untouched", () => {
  const foreignLocation = wrapper("seo").replace("/skills/aidevops-seo/SKILL.md", "/skills/other/SKILL.md");
  for (const source of [wrapper("seo"), `<available_skills>${wrapper("seo")}</available_skills>`,
    `<available_skills>${wrapper("seo").replace("</skill>", "<extra>Keep me</extra></skill>")}</available_skills>`,
    `<available_skills>\n${foreignLocation}\n${foreignLocation}\n</available_skills>`]) {
    assert.equal(compactSkillCatalogue(source), source);
  }
});

test("deduplication preserves differing scope guidance and does not mutate source arrays", () => {
  const body = "All hard-won rules stay intact.\nNever omit verification.";
  const source = [`Instructions from: /global/AGENTS.md\n${body}`, `Instructions from: /repo/AGENTS.md\n${body}`,
    `Instructions from: /repo/nested/AGENTS.md\n${body}\nAn additional rule.`];
  const result = compactSystemContext(source);
  assert.equal(result[0], source[0]);
  assert.match(result[1], /byte-identical/);
  assert.match(result[1], /Apply those instructions here too/);
  assert.equal(result[2], source[2]);
  assert.equal(source[1], `Instructions from: /repo/AGENTS.md\n${body}`);
});

test("Claude proxy context compacts only its exact framework document", () => {
  const framework = "Keep safeguards intact.\nNever omit verification.";
  const agent = "Selected domain knowledge remains available.";
  const source = "/framework/agents/AGENTS.md";
  const document = `Instructions from: ${source}\n${framework}`;
  const exact = `${document}\n\nInstructions from: /repo/AGENTS.md\nRequest context.`;
  const result = [framework, agent, compactExactInstructionDocument(framework, source, exact)].join("\n\n");

  assert.equal(result.split(framework).length - 1, 1);
  assert.match(result, /already supplied by the Claude proxy/);
  assert.match(result, /Selected domain knowledge remains available/);
  assert.match(result, /Request context/);
  assert.equal(
    compactExactInstructionDocument(framework, source, exact),
    compactExactInstructionDocument(framework, source, exact),
  );
  for (const incoming of ["Request context.", `<framework>${framework}</framework>`,
    `${document}\nAn additional instruction.`, `Instructions from: /repo/AGENTS.md\n${framework}`]) {
    assert.equal(compactExactInstructionDocument(framework, source, incoming), incoming);
  }
});

test("Claude proxy builder retains the expected Claude argv shape", () => {
  const args = buildClaudeArgs({ model: "claude-sonnet-4-6", agentName: "legal", prompt: "Continue." }, "", false);

  assert.deepEqual(args.slice(0, 3), ["-p", "--model", "claude-sonnet-4-6"]);
  assert.ok(args.includes("--permission-mode"));
  assert.deepEqual(args.slice(-3), ["--output-format", "json", "Continue."]);
});
