// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { randomBytes } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const pulseLabel = "com.aidevops.aidevops-supervisor-pulse";
const configKey = "AIDEVOPS_MODEL_AB_CONFIG";

function regularOrAbsent(path) {
  if (!existsSync(path)) return;
  if (!lstatSync(path).isFile()) throw new Error("model A/B configuration path is not a regular file");
}

export function startProspectiveTrial(repo, {
  now = Date.now(), configRoot = join(homedir(), ".config", "aidevops"), validate,
} = {}) {
  if (typeof validate !== "function") throw new Error("model A/B validation unavailable");
  const overrides = join(configRoot, "plist-env-overrides.json");
  mkdirSync(configRoot, { recursive: true, mode: 0o700 });
  if (lstatSync(configRoot).isSymbolicLink()) throw new Error("model A/B config root is a symlink");
  regularOrAbsent(overrides);
  const existing = existsSync(overrides) ? JSON.parse(readFileSync(overrides, "utf8")) : {};
  if (!existing || typeof existing !== "object" || Array.isArray(existing)) {
    throw new Error("Pulse environment override must be a JSON object");
  }
  if (existing[pulseLabel]?.[configKey]) {
    throw new Error("Pulse already has a model A/B configuration; inspect it before starting another window");
  }

  const id = `standard-ab-${new Date(now).toISOString().replace(/[^0-9]/g, "")}`;
  const config = validate({
    id, repo, seed: randomBytes(12).toString("hex"),
    starts_at: new Date(now).toISOString(),
    ends_at: new Date(now + 48 * 3600 * 1000).toISOString(),
    enrollment: { mode: "new-standard-issues" },
    arms: [
      { name: "luna-max", model: "openai/gpt-6-luna", variant: "max" },
      { name: "terra-low", model: "openai/gpt-5.6-terra", variant: "low" },
    ],
  });
  const cohortDir = join(configRoot, "model-ab");
  mkdirSync(cohortDir, { recursive: true, mode: 0o700 });
  if (lstatSync(cohortDir).isSymbolicLink()) throw new Error("model A/B cohort directory is a symlink");
  const configPath = join(cohortDir, `${id}.json`);
  writeFileSync(configPath, `${JSON.stringify(config, null, 2)}\n`, { flag: "wx", mode: 0o600 });
  const next = { ...existing, [pulseLabel]: { ...existing[pulseLabel], [configKey]: configPath } };
  const temporary = `${overrides}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(next, null, 2)}\n`, { flag: "wx", mode: 0o600 });
  renameSync(temporary, overrides);
  return { experiment: id, config: configPath, starts_at: config.starts_at,
    ends_at: config.ends_at, activation: "pending-pulse-scheduler-reload" };
}
