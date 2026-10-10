// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { applyAgentMcpTools } from "../agent-mcp-tools.mjs";
import { registerOnDemandMcpAgents } from "../config-agent-profiles.mjs";
import { registerMcpServers } from "../mcp-registry.mjs";

const AGENTS_DIR = fileURLToPath(new URL("../../..", import.meta.url));
const LAUNCHER = join(AGENTS_DIR, "scripts", "seo-utils-mcp-launcher.sh");

function runLauncher(env) {
  return spawnSync("bash", [LAUNCHER], {
    encoding: "utf8",
    env: { PATH: process.env.PATH, HOME: process.env.HOME, ...env },
  });
}

function withStubApps(fn) {
  const dir = mkdtempSync(join(tmpdir(), "seo-utils-launcher-"));
  try {
    const current = join(dir, "current");
    const legacy = join(dir, "legacy");
    // The launcher detects support by the literal subcommand name in the binary.
    writeFileSync(current, "#!/usr/bin/env bash\n# mcp-stdio\nprintf 'args:%s\\n' \"$*\"\n");
    writeFileSync(legacy, "#!/usr/bin/env bash\nprintf 'started full backend\\n'\n");
    chmodSync(current, 0o755);
    chmodSync(legacy, 0o755);
    fn({ current, legacy, missing: join(dir, "missing") });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("SEO Utils registers as a disabled local MCP with a long tool timeout", () => {
  const config = { mcp: {}, tools: {} };
  registerMcpServers(config);

  assert.equal(config.mcp["seo-utils"].type, "local");
  assert.match(config.mcp["seo-utils"].command[0], /seo-utils-mcp-launcher\.sh$/);
  assert.equal(config.mcp["seo-utils"].enabled, false);
  assert.equal(config.mcp["seo-utils"].timeout, 900_000);
  assert.equal(config.tools["seo-utils_*"], false);
});

test("SEO Utils keeps a user-owned app entry but disconnects it", () => {
  const command = ["/Applications/SEO Utils.app/Contents/MacOS/SEO Utils", "mcp-stdio"];
  const config = {
    mcp: { "seo-utils": { type: "local", command, enabled: true, timeout: 900_000 } },
    tools: { "seo-utils_*": true },
  };
  registerMcpServers(config);

  assert.deepEqual(config.mcp["seo-utils"].command, command);
  assert.equal(config.mcp["seo-utils"].enabled, false);
  assert.equal(config.tools["seo-utils_*"], false);
});

test("only the bounded SEO Utils agent gets SEO Utils tools and spend guidance", () => {
  const config = { agent: { build: { tools: {} } } };
  registerOnDemandMcpAgents(config, AGENTS_DIR);
  applyAgentMcpTools(config);

  assert.equal(config.agent["seo-utils"].tools["seo-utils_*"], true);
  assert.equal(config.agent["seo-utils"].tools.aidevops_mcp, true);
  assert.equal(config.agent.build.tools["seo-utils_*"], undefined);
  assert.match(config.agent["seo-utils"].prompt, /lookup_action spends/);
  assert.match(config.agent["seo-utils"].prompt, /write_action creates, changes, deletes/);
});

test("launcher runs mcp-stdio only on builds that support it", () => {
  withStubApps(({ current, legacy, missing }) => {
    const ok = runLauncher({ SEO_UTILS_BIN: current });
    assert.equal(ok.status, 0);
    assert.equal(ok.stdout.trim(), "args:mcp-stdio");

    const dry = runLauncher({ SEO_UTILS_BIN: current, SEO_UTILS_MCP_LAUNCHER_DRY_RUN: "1" });
    assert.equal(dry.status, 0);
    assert.match(dry.stdout, /validated/);

    const old = runLauncher({ SEO_UTILS_BIN: legacy });
    assert.equal(old.status, 1);
    assert.equal(old.stdout, "");
    assert.match(old.stderr, /no mcp-stdio server/);

    const absent = runLauncher({ SEO_UTILS_BIN: missing });
    assert.equal(absent.status, 1);
    assert.match(absent.stderr, /not an executable file/);
  });
});
