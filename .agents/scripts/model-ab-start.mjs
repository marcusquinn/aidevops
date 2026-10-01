// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { randomBytes } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { ALL_TIER_MODE, PROSPECTIVE_MODE, ROUTED_TIERS } from "./model-ab-enrollment.mjs";

const pulseLabel = "com.aidevops.aidevops-supervisor-pulse";
const configKey = "AIDEVOPS_MODEL_AB_CONFIG";
const HOUR_MS = 3600 * 1000;

function shippedRouting() {
  return JSON.parse(readFileSync(new URL("../configs/model-routing-table.json", import.meta.url), "utf8"));
}

// Provider-family arm from the shipped routing table: the first model of that
// provider in each tier, with the table's configured effort (if any).
function providerArm(routing, provider) {
  const tiers = {};
  for (const tier of ROUTED_TIERS) {
    const model = (routing?.tiers?.[tier]?.models || []).find((candidate) => candidate.startsWith(`${provider}/`));
    if (!model) throw new Error(`routing table has no ${provider} model for the ${tier} tier`);
    const variant = routing.tiers[tier].reasoning?.[model];
    tiers[tier] = variant ? { model, variant } : { model };
  }
  return { name: provider, tiers };
}

// Background work never runs below medium, so a sub-medium arm would be silently
// raised by the routing floor and mislabel the comparison (GH#32539, GH#33342).
const SUB_FLOOR_VARIANTS = new Set(["none", "minimal", "low"]);

export function rejectSubFloorArms(arms) {
  const routes = arms.flatMap((arm) => (arm?.tiers ? Object.values(arm.tiers) : [arm]));
  if (routes.some((route) => SUB_FLOOR_VARIANTS.has(route?.variant))) {
    throw new Error("model A/B arms must use medium or higher reasoning; the routing floor raises lower variants");
  }
  return arms;
}

export const START_PRESETS = {
  "standard-luna-terra": { prefix: "standard-ab", hours: 48, mode: PROSPECTIVE_MODE, arms: () => [
    { name: "luna-max", model: "openai/gpt-6-luna", variant: "max" },
    { name: "terra-medium", model: "openai/gpt-5.6-terra", variant: "medium" },
  ] },
  // A week: the 48-hour standard-only window enrolled only 2 issues (GH#32353).
  "openai-anthropic": { prefix: "provider-ab", hours: 168, mode: ALL_TIER_MODE, arms: (routing) => [
    providerArm(routing, "openai"), providerArm(routing, "anthropic"),
  ] },
};

export function parseStartOptions(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 2) {
    const [flag, value] = [args[index], args[index + 1]];
    if (!value || Object.hasOwn(options, flag.slice(2))) throw new Error(`invalid model A/B start option: ${flag}`);
    if (flag === "--preset" && Object.hasOwn(START_PRESETS, value)) options.preset = value;
    else if (flag === "--hours" && /^[1-9][0-9]{0,2}$/.test(value)) options.hours = Number(value);
    else throw new Error(`invalid model A/B start option: ${flag}`);
  }
  return options;
}

function regularOrAbsent(path) {
  if (!existsSync(path)) return;
  if (!lstatSync(path).isFile()) throw new Error("model A/B configuration path is not a regular file");
}

export function startProspectiveTrial(repo, {
  now = Date.now(), configRoot = join(homedir(), ".config", "aidevops"), validate,
  preset = "standard-luna-terra", hours, routing = shippedRouting(),
} = {}) {
  if (typeof validate !== "function") throw new Error("model A/B validation unavailable");
  const selected = START_PRESETS[preset];
  if (!selected) throw new Error(`unknown model A/B preset: ${preset}`);
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

  const id = `${selected.prefix}-${new Date(now).toISOString().replace(/[^0-9]/g, "")}`;
  const config = validate({
    id, repo, seed: randomBytes(12).toString("hex"),
    starts_at: new Date(now).toISOString(),
    ends_at: new Date(now + (hours || selected.hours) * HOUR_MS).toISOString(),
    enrollment: { mode: selected.mode },
    arms: rejectSubFloorArms(selected.arms(routing)),
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
