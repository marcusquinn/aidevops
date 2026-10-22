// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
// Validation, manifest and Docker-home helpers for frontier-harness-run.mjs.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, symlinkSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { parseArgs } from "node:util";

const PROFILES = ["stock", "aidevops", "aidevops-native-compaction"];

export function parseRunOptions(argv) {
  const { values } = parseArgs({ args: argv, options: {
    task: { type: "string" }, out: { type: "string" },
    model: { type: "string", default: "gpt-6-astra" },
    profile: { type: "string", default: "stock" },
    "opencode-version": { type: "string", default: "1.18.29" },
    "install-only": { type: "boolean", default: false },
    "context-limit": { type: "string" }, "output-limit": { type: "string" },
  } });
  if (!PROFILES.includes(values.profile)) throw new Error("Unknown profile");
  if (!isAbsolute(values.task || "") || !isAbsolute(values.out || "")) {
    throw new Error("--task and --out must be absolute paths; --out must not exist");
  }
  if (!/^\d+\.\d+\.\d+$/.test(values["opencode-version"])) throw new Error("Pin an exact OpenCode release");
  const contextLimit = values["context-limit"] === undefined ? null : Number(values["context-limit"]);
  const outputLimit = values["output-limit"] === undefined ? null : Number(values["output-limit"]);
  validateLimits(contextLimit, outputLimit);
  return { values, contextLimit, outputLimit };
}

function validLimitPair(contextLimit, outputLimit) {
  if (!Number.isInteger(contextLimit) || !Number.isInteger(outputLimit)) return false;
  if (contextLimit < 4096 || contextLimit > 1000000) return false;
  return outputLimit >= 1024 && outputLimit < contextLimit;
}

function validateLimits(contextLimit, outputLimit) {
  if (contextLimit === null && outputLimit === null) return;
  if (!validLimitPair(contextLimit, outputLimit)) throw new Error("Provide valid paired context/output limits");
}

// Select once from the user's existing OAuth pool; never rotate after failure.
export function selectOAuthAccount(accounts, now = Date.now()) {
  return accounts
    .filter((a) => a.access && ["active", "idle"].includes(a.status)
      && a.expires > now + 1860000 && !(a.cooldownUntil > now))
    .sort((a, b) => new Date(b.lastUsed || 0) - new Date(a.lastUsed || 0))[0];
}

export function buildManifest({ values, commit, instruction, taskConfig, contextLimit, outputLimit }) {
  const sha256 = (data) => createHash("sha256").update(data).digest("hex");
  const version = values["opencode-version"];
  return {
    schema: 1, profile: values.profile, framework_commit: commit,
    opencode_version: version, harbor_version: "0.22.0",
    model: values.model, inference_route: "chatgpt-pro-oauth-local-relay",
    paid_api_fallback: false, leaderboard_comparable: false,
    task_instruction_sha256: sha256(instruction),
    task_config_sha256: sha256(taskConfig),
    max_requests: 64, concurrency: 1, retries: 0, install_only: values["install-only"],
    agent_setup_timeout_multiplier: 2,
    experimental_context_limit: contextLimit, experimental_output_reserve: outputLimit,
    calibration_contract: version === "1.18.29" ? "opencode-1.18.29-explicit-input-v1" : "unsupported-runtime",
    requested_model_limits: contextLimit === null ? null
      : { context: contextLimit, input: contextLimit - outputLimit, output: outputLimit },
    started_at: new Date().toISOString(),
  };
}

// Isolated runner HOME with only Docker compose/buildx CLI plugins linked in.
export function prepareRunnerHome(outDir) {
  const home = join(outDir, "runner-home");
  mkdirSync(home, { mode: 0o700 });
  const pluginDir = join(home, ".docker/cli-plugins");
  mkdirSync(pluginDir, { recursive: true, mode: 0o700 });
  const plugins = JSON.parse(execFileSync("docker", ["info", "--format", "{{json .ClientInfo.Plugins}}"], { encoding: "utf8" }));
  for (const plugin of plugins) {
    if (["compose", "buildx"].includes(plugin.Name) && isAbsolute(plugin.Path)) {
      symlinkSync(plugin.Path, join(pluginDir, `docker-${plugin.Name}`));
    }
  }
  return home;
}

export function localDockerHost() {
  const host = execFileSync("docker", ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], { encoding: "utf8" }).trim();
  if (!host.startsWith("unix://")) throw new Error("Only local Docker sockets are supported");
  return host;
}

export function buildHarborArgs({ values, contextLimit, outputLimit }) {
  const args = ["tool", "run", "--from", "harbor==0.22.0", "harbor", "run",
    "-p", values.task, "-a", "frontier_harness_agent:FrontierOpenCode",
    "-m", `openai/${values.model}`, "--ak", `profile=${values.profile}`,
    "--ak", `version=${values["opencode-version"]}`, "-n", "1", "-r", "0",
    "--agent-setup-timeout-multiplier", "2",
    "--jobs-dir", join(values.out, "jobs"), "--job-name", "pilot"];
  if (values["install-only"]) args.push("--install-only");
  if (contextLimit !== null) args.push("--ak", `context_limit=${contextLimit}`, "--ak", `output_limit=${outputLimit}`);
  return args;
}
