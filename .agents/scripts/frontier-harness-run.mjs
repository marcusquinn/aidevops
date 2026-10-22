#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { spawn, execFileSync } from "node:child_process";
import { closeSync, mkdirSync, openSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { getAccounts } from "../plugins/opencode-aidevops/oauth-pool-storage.mjs";
import { createRelay } from "./frontier-harness-oauth-relay.mjs";
import {
  buildHarborArgs, buildManifest, localDockerHost, parseRunOptions, prepareRunnerHome, selectOAuthAccount,
} from "./frontier-harness-run-support.mjs";

const scripts = dirname(fileURLToPath(import.meta.url));
const repo = resolve(scripts, "../..");

async function main() {
  const { values, contextLimit, outputLimit } = parseRunOptions(process.argv.slice(2));
  const instruction = readFileSync(join(values.task, "instruction.md"));
  const taskConfig = readFileSync(join(values.task, "task.toml"));
  if (!statSync(dirname(values.out)).isDirectory()) throw new Error("Output parent must exist");
  const git = (...args) => execFileSync("git", ["-C", repo, ...args], { encoding: "utf8" }).trim();
  if (git("status", "--porcelain")) throw new Error("Commit the integration before freezing a trial");
  const commit = git("rev-parse", "HEAD");
  // Select once from the user's existing OAuth pool; never read API-key env vars
  // and never rotate accounts after a failure. OAuth secrets remain host-only.
  const account = selectOAuthAccount(getAccounts("openai"));
  if (!account && !values["install-only"]) throw new Error("No fresh OpenAI OAuth account; no API fallback permitted");
  mkdirSync(values.out, { mode: 0o700 });
  const archive = join(values.out, "framework.tar");
  execFileSync("git", ["-C", repo, "archive", "--format=tar", "-o", archive, commit, ".agents"]);
  const manifest = buildManifest({ values, commit, instruction, taskConfig, contextLimit, outputLimit });
  const save = () => writeFileSync(join(values.out, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
  save();
  let relay;
  let log;
  let child;
  const stop = () => { manifest.interrupted = true; relay?.close(); child?.kill("SIGTERM"); };
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  try {
    // Install-only receives an inert placeholder, never a live inference capability.
    relay = values["install-only"]
      ? { port: 9, key: "0".repeat(64), stats: () => ({ requests: 0 }), close: () => {} }
      : await createRelay({ model: values.model, account });
    log = openSync(join(values.out, "runner.log"), "wx", 0o600);
    // Explicit allowlist, not a copy of process.env: no real provider key, OAuth
    // token, global OpenCode config or host auth store reaches Harbor's agent.
    const env = {};
    for (const name of ["PATH", "TMPDIR"]) {
      if (process.env[name]) env[name] = process.env[name];
    }
    const home = prepareRunnerHome(values.out);
    const dockerHost = localDockerHost();
    Object.assign(env, {
      HOME: home, XDG_CONFIG_HOME: join(home, ".config"), XDG_DATA_HOME: join(home, ".local/share"),
      XDG_CACHE_HOME: join(home, ".cache"), DOCKER_HOST: dockerHost,
      UV_CACHE_DIR: execFileSync("uv", ["cache", "dir"], { encoding: "utf8" }).trim(),
      PYTHONPATH: scripts, AIDEVOPS_EVAL_ARCHIVE: archive,
      AIDEVOPS_EVAL_RELAY_URL: `http://host.docker.internal:${relay.port}/v1`,
      AIDEVOPS_EVAL_RELAY_KEY: relay.key, OPENAI_API_KEY: relay.key,
    });
    const args = buildHarborArgs({ values, contextLimit, outputLimit });
    child = spawn("uv", args, { cwd: repo, env, stdio: ["ignore", log, log] });
    const code = await new Promise((resolvePromise, reject) => {
      child.once("error", reject);
      child.once("exit", (status) => resolvePromise(status ?? 1));
    });
    manifest.runner_exit_code = code;
    const result = JSON.parse(readFileSync(join(values.out, "jobs/pilot/result.json"), "utf8"));
    manifest.completed_trials = result.stats?.n_completed_trials ?? null;
    manifest.errored_trials = result.stats?.n_errored_trials ?? null;
    const valid = code === 0 && manifest.completed_trials === 1 && manifest.errored_trials === 0;
    manifest.status = valid ? "runner_finished" : "runner_failed";
    console.log(JSON.stringify({ runner_exit_code: code, requests: relay.stats().requests,
      profile: values.profile, note: "Read the verifier result; runner exit zero is not a task pass" }));
    process.exitCode = valid ? 0 : 1;
  } catch {
    manifest.status = "infrastructure_error";
    process.exitCode = 1;
    console.error("Pilot infrastructure error; inspect private runner.log");
  } finally {
    manifest.relay = relay?.stats() ?? null;
    manifest.finished_at = new Date().toISOString();
    if (manifest.interrupted) manifest.status = "interrupted";
    save();
    relay?.close();
    if (log !== undefined) closeSync(log);
    process.removeListener("SIGINT", stop);
    process.removeListener("SIGTERM", stop);
  }
}

main().catch(() => {
  // Provider/child exceptions can include credential-bearing headers or config.
  console.error("Frontier pilot failed; inspect private local artifacts (never publish raw logs)");
  process.exitCode = 1;
});
