#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { execFileSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  readFileSync,
  statSync,
} from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";

import {
  campaignCheckpointPath,
  withCheckpointLock,
  writeCampaignCheckpoint,
  writeCampaignCheckpointUnlocked,
} from "./pulse-campaign-checkpoint.mjs";
import {
  configuredRunners,
  localRunner,
  peerRunners,
  runnerIdentity,
  validDeviceId,
} from "./pulse-campaign-runners.mjs";
import {
  CAMPAIGN_SCHEMA_VERSION,
  DEFAULT_CHECKPOINT_TTL_SECONDS,
  DEFAULT_HORIZON,
  planCampaign,
  REPOSITORY_SLUG,
  validPreviousCheckpoint,
} from "./pulse-campaign-planner.mjs";
import { canonicalTimestamp, compareAscii, hash } from "./pulse-campaign-values.mjs";

export { campaignCheckpointPath, writeCampaignCheckpoint };
export { CAMPAIGN_SCHEMA_VERSION, DEFAULT_CHECKPOINT_TTL_SECONDS, DEFAULT_HORIZON, planCampaign };
export { runnerIdentity };

const MAX_JSON_BYTES = 8 * 1024 * 1024;

function readJsonFile(filepath, fallback) {
  if (!filepath || !existsSync(filepath)) return fallback;
  if (statSync(filepath).size > MAX_JSON_BYTES) throw new TypeError(`JSON input exceeds ${MAX_JSON_BYTES} bytes`);
  const parsed = JSON.parse(readFileSync(filepath, "utf8"));
  return parsed;
}

export function repositoryScope(repositoryPath) {
  if (typeof repositoryPath !== "string" || !isAbsolute(repositoryPath)) throw new TypeError("repository path must be absolute");
  const gitRoot = execFileSync("git", ["-C", repositoryPath, "rev-parse", "--show-toplevel"], { encoding: "utf8", timeout: 5000 }).trim();
  const rawCommonDir = execFileSync("git", ["-C", repositoryPath, "rev-parse", "--git-common-dir"], { encoding: "utf8", timeout: 5000 }).trim();
  const commonDir = resolve(gitRoot, rawCommonDir);
  return { scopeKey: hash(commonDir, 16), commonDir };
}

function validateRepositoryBinding(reposState, repositorySlug, repositoryPath, expectedScope) {
  if (typeof repositorySlug !== "string" || !REPOSITORY_SLUG.test(repositorySlug)) throw new TypeError("repository slug is invalid");
  const repositories = Array.isArray(reposState?.initialized_repos) ? reposState.initialized_repos : [];
  const configured = repositories
    .filter((entry) => entry?.slug === repositorySlug && typeof entry?.path === "string" && isAbsolute(entry.path));
  if (configured.length === 0) throw new TypeError("repository slug is not bound to a configured path");
  const matches = configured.filter((entry) => {
    try {
      return repositoryScope(entry.path).scopeKey === expectedScope.scopeKey;
    } catch {
      return false;
    }
  });
  if (matches.length === 0) throw new TypeError(`repository slug does not match repository path: ${repositoryPath}`);
  if (matches.length > 1) throw new TypeError("repository slug has ambiguous configured paths");
  return matches[0];
}

function readPreviousCheckpoint(filepath) {
  if (!existsSync(filepath)) return null;
  const checkpointStats = lstatSync(filepath);
  if (checkpointStats.isSymbolicLink() || !checkpointStats.isFile()) throw new TypeError("checkpoint path is unsafe");
  try {
    return readJsonFile(filepath, null);
  } catch {
    return null;
  }
}

function sourceOrder(checkpoint) {
  const observedAt = canonicalTimestamp(checkpoint?.source?.observedAt, checkpoint?.generatedAt ?? "");
  return {
    observedAt,
    hash: typeof checkpoint?.source?.hash === "string" ? checkpoint.source.hash : "",
  };
}

function incomingSourcePrecedes(previous, incoming) {
  if (!validPreviousCheckpoint(previous, incoming.campaignId, incoming.repository.scopeKey)) return false;
  const previousOrder = sourceOrder(previous);
  const incomingOrder = sourceOrder(incoming);
  if (incomingOrder.observedAt !== previousOrder.observedAt) {
    return incomingOrder.observedAt < previousOrder.observedAt;
  }
  return incomingOrder.hash !== previousOrder.hash && compareAscii(incomingOrder.hash, previousOrder.hash) < 0;
}

function readDeviceId(filepath) {
  if (!filepath || !existsSync(filepath)) return "";
  const value = readFileSync(filepath, "utf8").trim();
  return validDeviceId(value) ? value : "";
}

function fileObservedAt(filepath) {
  if (!filepath || !existsSync(filepath)) return "";
  const observedEpoch = statSync(filepath).mtimeMs;
  return Number.isFinite(observedEpoch) ? new Date(observedEpoch).toISOString() : "";
}

function parseOptions(args) {
  const options = { write: true };
  const valueOptions = new Set([
    "--repo", "--repo-path", "--issues-file", "--ready-file", "--repos-file", "--peer-state-file",
    "--self-login", "--device-id-file", "--checkpoint-root", "--horizon", "--ttl", "--source-limit",
    "--source-succeeded", "--source-observed-at", "--now",
  ]);
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--no-write") {
      options.write = false;
      continue;
    }
    if (!valueOptions.has(argument) || index + 1 >= args.length) throw new TypeError(`unknown or incomplete option: ${argument}`);
    options[argument.slice(2).split("-").join("_")] = args[index + 1];
    index += 1;
  }
  return options;
}

function defaultCheckpointRoot(env = process.env) {
  const tempRoot = env.AIDEVOPS_TEMP_DIR || join(env.HOME || homedir(), ".aidevops", ".agent-workspace", "tmp");
  return resolve(tempRoot, "repository-campaigns");
}

export function run(args = process.argv.slice(2)) {
  const command = args[0] || "help";
  if (["help", "--help", "-h"].includes(command)) {
    process.stdout.write("Usage: pulse-campaign-coordinator.mjs plan --repo OWNER/REPO --repo-path PATH --issues-file FILE --ready-file FILE [options]\n");
    return 0;
  }
  if (command !== "plan") throw new TypeError(`unknown command: ${command}`);
  const options = parseOptions(args.slice(1));
  const repositorySlug = options.repo;
  const repositoryPath = options.repo_path;
  const repository = repositoryScope(repositoryPath);
  const { scopeKey } = repository;
  const reposState = readJsonFile(options.repos_file, {});
  const repositoryConfig = validateRepositoryBinding(reposState, repositorySlug, repositoryPath, repository);
  const checkpointRoot = resolve(options.checkpoint_root || defaultCheckpointRoot());
  const checkpointPath = campaignCheckpointPath(checkpointRoot, scopeKey);
  const peerState = readJsonFile(options.peer_state_file, {});
  const configured = configuredRunners(repositoryConfig, repositorySlug);
  const peers = peerRunners(peerState, repositorySlug);
  const local = localRunner({ selfLogin: options.self_login, deviceId: readDeviceId(options.device_id_file) });
  const campaignInput = {
    repositorySlug,
    scopeKey,
    issues: readJsonFile(options.issues_file, []),
    readyIssues: readJsonFile(options.ready_file, []),
    runners: [...peers, ...local, ...configured],
    horizon: Number(options.horizon ?? DEFAULT_HORIZON),
    ttlSeconds: Number(options.ttl ?? DEFAULT_CHECKPOINT_TTL_SECONDS),
    sourceLimit: Number(options.source_limit ?? 1000),
    sourceSucceeded: options.source_succeeded !== "0" && options.source_succeeded !== "false",
    sourceObservedAt: options.source_observed_at || fileObservedAt(options.issues_file),
    now: options.now,
  };
  let checkpoint;
  if (options.write) {
    checkpoint = withCheckpointLock(checkpointPath, (directoryIdentity) => {
      const previous = readPreviousCheckpoint(checkpointPath);
      const planned = planCampaign(campaignInput, previous);
      if (incomingSourcePrecedes(previous, planned)) return previous;
      writeCampaignCheckpointUnlocked(checkpointPath, planned, directoryIdentity);
      return planned;
    });
  } else {
    checkpoint = planCampaign(campaignInput, readPreviousCheckpoint(checkpointPath));
  }
  process.stdout.write(`${JSON.stringify({ ...checkpoint, checkpointPath })}\n`);
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    process.exitCode = run();
  } catch (error) {
    process.stderr.write(`pulse-campaign-coordinator: ${error.message}\n`);
    process.exitCode = 1;
  }
}
