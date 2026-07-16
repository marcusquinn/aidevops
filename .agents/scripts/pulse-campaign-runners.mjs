// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "node:crypto";

export const LOGIN = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/;
export const DEVICE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

const MAX_RUNNERS = 128;
const MAX_RUNNER_CAPACITY = 16;
const RUNNER_PRIORITY = { "peer-observation": 1, "local-device": 2, "repository-config": 3 };

function isObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function clampInteger(value, minimum, maximum, fallback) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) return fallback;
  return Math.min(maximum, Math.max(minimum, parsed));
}

function compareAscii(left, right) {
  if (left < right) return -1;
  if (left > right) return 1;
  return 0;
}

function calculateFitness(metrics, action = "honour") {
  if (action === "ignore") return 0;
  if (Number.isFinite(Number(metrics?.fitness))) return clampInteger(metrics.fitness, 0, 100, 50);
  const merged = clampInteger(metrics?.worker_prs, 0, 1000, 0);
  const active = clampInteger(metrics?.active_claims, 0, 1000, 0);
  if (merged > 0) return Math.min(100, 60 + merged * 10);
  if (active >= 2) return 15;
  return 50;
}

export function runnerIdentity(login, deviceId) {
  if (typeof login !== "string" || !LOGIN.test(login)) throw new TypeError("runner login is invalid");
  if (typeof deviceId !== "string" || !DEVICE_ID.test(deviceId)) throw new TypeError("runner device_id is invalid");
  return `${login.toLowerCase()}:${deviceId}`;
}

function normalizeRunner(value, source, repositorySlug) {
  const login = value?.login;
  const deviceId = value?.device_id ?? value?.deviceId ?? "legacy";
  const checks = [
    isObject(value),
    typeof login === "string",
    LOGIN.test(login ?? ""),
    typeof deviceId === "string",
    DEVICE_ID.test(deviceId ?? ""),
  ];
  if (!checks.every(Boolean)) return null;
  if (value.repository && value.repository !== repositorySlug) return null;
  return {
    runnerKey: runnerIdentity(login, deviceId),
    login: login.toLowerCase(),
    deviceId,
    fitness: clampInteger(value.fitness ?? value.score, 0, 100, 50),
    capacity: clampInteger(value.capacity, 0, MAX_RUNNER_CAPACITY, 1),
    source,
  };
}

export function configuredRunners(repository, repositorySlug) {
  const runners = Array.isArray(repository?.pulse_campaign?.runners) ? repository.pulse_campaign.runners : [];
  return runners.map((runner) => normalizeRunner(runner, "repository-config", repositorySlug)).filter(Boolean);
}

export function peerRunners(peerState, repositorySlug) {
  if (!isObject(peerState)) return [];
  const runners = [];
  for (const [login, state] of Object.entries(peerState)) {
    if (!isObject(state)) continue;
    if (!LOGIN.test(login)) continue;
    const metrics = state.repositories?.[repositorySlug];
    const legacyRepos = Array.isArray(state.repos) ? state.repos : [];
    if (!isObject(metrics) && !legacyRepos.includes(repositorySlug)) continue;
    const runner = normalizeRunner({
      login,
      device_id: state.device_id ?? "legacy",
      fitness: calculateFitness(metrics, state.current_action),
      capacity: metrics?.capacity ?? 1,
    }, "peer-observation", repositorySlug);
    if (runner) runners.push(runner);
  }
  return runners;
}

export function localRunner({ selfLogin, deviceId }) {
  if (!selfLogin || !deviceId) return [];
  const runner = normalizeRunner({
    login: selfLogin,
    device_id: deviceId,
    fitness: 75,
    capacity: 1,
  }, "local-device", "");
  return runner ? [runner] : [];
}

export function mergeRunners(runners, repositorySlug = "") {
  const byKey = new Map();
  for (const value of runners) {
    const runner = normalizeRunner(value, value?.source ?? "campaign-input", repositorySlug);
    if (!runner) continue;
    const current = byKey.get(runner.runnerKey);
    const priority = RUNNER_PRIORITY[runner.source] ?? 0;
    const currentPriority = RUNNER_PRIORITY[current?.source] ?? 0;
    if (!current || priority >= currentPriority) byKey.set(runner.runnerKey, runner);
  }
  const retained = [...byKey.values()]
    .sort((left, right) =>
      (RUNNER_PRIORITY[right.source] ?? 0) - (RUNNER_PRIORITY[left.source] ?? 0) || compareAscii(left.runnerKey, right.runnerKey))
    .slice(0, MAX_RUNNERS);
  return retained.sort((left, right) =>
    right.fitness - left.fitness || right.capacity - left.capacity || compareAscii(left.runnerKey, right.runnerKey));
}

export function allocateLanes(frontier, runners, campaignId) {
  const tickets = [];
  for (const runner of runners) {
    if (runner.fitness <= 0 || runner.capacity <= 0) continue;
    const weight = Math.max(1, Math.ceil(runner.fitness / 25));
    for (let index = 0; index < runner.capacity * weight; index += 1) tickets.push(runner.runnerKey);
  }
  if (tickets.length === 0) return [];
  const assignments = new Map(runners.map((runner) => [runner.runnerKey, []]));
  frontier.forEach((issue, index) => assignments.get(tickets[index % tickets.length])?.push(issue.issueNumber));
  return runners
    .filter((runner) => assignments.get(runner.runnerKey)?.length > 0)
    .map((runner) => ({
      laneId: `lane-${createHash("sha256").update(`${campaignId}:${runner.runnerKey}`).digest("hex").slice(0, 16)}`,
      runnerKey: runner.runnerKey,
      issueNumbers: assignments.get(runner.runnerKey),
    }));
}
