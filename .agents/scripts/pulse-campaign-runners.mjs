// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { createHash } from "node:crypto";

const MAX_RUNNERS = 128;
const MAX_RUNNER_CAPACITY = 16;
const RUNNER_PRIORITY = { "peer-observation": 1, "local-device": 2, "repository-config": 3 };
const ASCII_ALPHANUMERIC = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
const ASCII_ALPHANUMERIC_CHARACTERS = new Set(ASCII_ALPHANUMERIC);
const LOGIN_CHARACTERS = new Set(`${ASCII_ALPHANUMERIC}-`);
const DEVICE_ID_CHARACTERS = new Set(`${ASCII_ALPHANUMERIC}._-`);

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

function validIdentifier(value, maximumLength, allowedCharacters) {
  return typeof value === "string"
    && value.length >= 1
    && value.length <= maximumLength
    && ASCII_ALPHANUMERIC_CHARACTERS.has(value[0])
    && [...value].every((character) => allowedCharacters.has(character));
}

export function validRunnerLogin(value) {
  return validIdentifier(value, 39, LOGIN_CHARACTERS);
}

export function validDeviceId(value) {
  return validIdentifier(value, 64, DEVICE_ID_CHARACTERS);
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
  if (!validRunnerLogin(login)) throw new TypeError("runner login is invalid");
  if (!validDeviceId(deviceId)) throw new TypeError("runner device_id is invalid");
  return `${login.toLowerCase()}:${deviceId}`;
}

function normalizedRunnerIdentity(value) {
  if (!isObject(value)) return null;
  const login = value?.login;
  const deviceId = value?.device_id ?? value?.deviceId ?? "legacy";
  if (!validRunnerLogin(login) || !validDeviceId(deviceId)) return null;
  return { deviceId, login };
}

function normalizeRunner(value, source, repositorySlug) {
  const identity = normalizedRunnerIdentity(value);
  if (!identity) return null;
  if (value.repository && value.repository !== repositorySlug) return null;
  return {
    runnerKey: runnerIdentity(identity.login, identity.deviceId),
    login: identity.login.toLowerCase(),
    deviceId: identity.deviceId,
    fitness: clampInteger(value.fitness ?? value.score, 0, 100, 50),
    capacity: clampInteger(value.capacity, 0, MAX_RUNNER_CAPACITY, 1),
    source,
  };
}

export function configuredRunners(repository, repositorySlug) {
  const runners = Array.isArray(repository?.pulse_campaign?.runners) ? repository.pulse_campaign.runners : [];
  return runners.map((runner) => normalizeRunner(runner, "repository-config", repositorySlug)).filter(Boolean);
}

function runnerFromPeer(login, state, repositorySlug) {
  if (!validRunnerLogin(login) || !isObject(state)) return null;
  const metrics = state.repositories?.[repositorySlug];
  const legacyRepos = Array.isArray(state.repos) ? state.repos : [];
  if (!isObject(metrics) && !legacyRepos.includes(repositorySlug)) return null;
  return normalizeRunner({
    login,
    device_id: state.device_id ?? "legacy",
    fitness: calculateFitness(metrics, state.current_action),
    capacity: metrics?.capacity ?? 1,
  }, "peer-observation", repositorySlug);
}

export function peerRunners(peerState, repositorySlug) {
  if (!isObject(peerState)) return [];
  return Object.entries(peerState)
    .map(([login, state]) => runnerFromPeer(login, state, repositorySlug))
    .filter(Boolean);
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

function preferredRunner(current, candidate) {
  if (!current) return candidate;
  const priority = RUNNER_PRIORITY[candidate.source] ?? 0;
  const currentPriority = RUNNER_PRIORITY[current.source] ?? 0;
  return priority >= currentPriority ? candidate : current;
}

function runnerIndex(runners, repositorySlug) {
  const byKey = new Map();
  for (const value of runners) {
    const runner = normalizeRunner(value, value?.source ?? "campaign-input", repositorySlug);
    if (!runner) continue;
    byKey.set(runner.runnerKey, preferredRunner(byKey.get(runner.runnerKey), runner));
  }
  return byKey;
}

function runnerPriorityOrder(left, right) {
  return (RUNNER_PRIORITY[right.source] ?? 0) - (RUNNER_PRIORITY[left.source] ?? 0)
    || compareAscii(left.runnerKey, right.runnerKey);
}

function runnerFitnessOrder(left, right) {
  return right.fitness - left.fitness
    || right.capacity - left.capacity
    || compareAscii(left.runnerKey, right.runnerKey);
}

export function mergeRunners(runners, repositorySlug = "") {
  const retained = [...runnerIndex(runners, repositorySlug).values()]
    .sort(runnerPriorityOrder)
    .slice(0, MAX_RUNNERS);
  return retained.sort(runnerFitnessOrder);
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
  frontier.forEach((issue, index) => {
    assignments.get(tickets[index % tickets.length])?.push(issue.issueNumber);
  });
  return runners
    .filter((runner) => assignments.get(runner.runnerKey)?.length > 0)
    .map((runner) => ({
      laneId: `lane-${createHash("sha256").update(`${campaignId}:${runner.runnerKey}`).digest("hex").slice(0, 16)}`,
      runnerKey: runner.runnerKey,
      issueNumbers: assignments.get(runner.runnerKey),
    }));
}
