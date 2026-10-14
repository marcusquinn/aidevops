// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Stale owned-relay reconciliation for playwriter-authenticated-relay.mjs
// (GH#34615). The launcher passes the reviewed relay contract; nothing here
// stops a process without marker-protected state proving this launcher owns it.

import { spawnSync } from "node:child_process";
import { existsSync, lstatSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import {
  MARKER_NAME,
  POSIX_GROUPS,
  STATE_SCHEMA,
  processAlive,
  processGroupAlive,
  terminateProcessGroup,
} from "./playwriter-relay-lifecycle.mjs";

const LEGACY_STATE_SCHEMA = "aidevops-playwriter-relay/v1";
const SESSION_DIRECTORY = /^session-(\d+)-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;

export function inspectProcess(pid) {
  if (process.platform === "linux") return inspectLinuxProcess(pid);
  const result = spawnSync("ps", ["-ww", "-o", "pgid=", "-o", "lstart=", "-o", "command=", "-p", String(pid)], {
    encoding: "utf8",
    env: { ...process.env, LC_ALL: "C" },
    shell: false,
    timeout: 2_000,
  });
  const match = result.status === 0
    ? /^\s*(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+([^\n]+)$/.exec(result.stdout.trim()) : null;
  if (!match) return null;
  const startTime = match[2].replace(/\s+/g, " ");
  // ps cannot prove argv boundaries. Retain its legacy v1 compatibility path,
  // but never authorize a v2 guardian from this ambiguous rendering.
  return { groupId: Number(match[1]), legacyArgv: match[3].split(/\s+/), startTime };
}

function linuxIdentity(pid) {
  const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
  const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
  const boot = readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim();
  return { groupId: Number(fields[2]), startTime: `linux:${boot}:${fields[19]}` };
}

function inspectLinuxProcess(pid) {
  try {
    // Bind actual argv boundaries to one incarnation, rejecting PID reuse
    // during inspection. Both group and start tick come from the same stat.
    const before = linuxIdentity(pid);
    const argv = readFileSync(`/proc/${pid}/cmdline`, "utf8").split("\0");
    const after = linuxIdentity(pid);
    if (argv.pop() !== "" || before.startTime !== after.startTime
      || before.groupId !== after.groupId || !/^linux:[0-9a-f-]{36}:\d+$/.test(after.startTime)) return null;
    return { ...after, argv };
  } catch {
    return null;
  }
}

export function guardianStartTime(pid, contract, command) {
  const leader = inspectProcess(pid);
  const expected = [...contract.guardianArgv, ...command];
  const matches = leader?.groupId === pid
    && leader.argv?.length === expected.length
    && expected.every((part, index) => leader.argv[index] === part);
  return matches ? leader.startTime : null;
}

function isRegular(stats, kind) {
  return Boolean(stats?.[kind]()) && !stats.isSymbolicLink();
}

function parseSessionState(statePath, sessionPid) {
  try {
    const state = JSON.parse(readFileSync(statePath, "utf8"));
    const known = [STATE_SCHEMA, LEGACY_STATE_SCHEMA].includes(state?.schema);
    return known && state.supervisorPid === sessionPid ? state : null;
  } catch {
    return null;
  }
}

// A session with a marker but no state.json never recorded a relay; it holds
// nothing to stop once its supervisor is gone.
function readSessionState(directory, sessionPid) {
  const marker = lstatSync(join(directory, MARKER_NAME), { throwIfNoEntry: false });
  if (!isRegular(lstatSync(directory), "isDirectory") || !isRegular(marker, "isFile")) return null;
  const statePath = join(directory, "state.json");
  const stateStats = lstatSync(statePath, { throwIfNoEntry: false });
  if (!stateStats) return { supervisorPid: sessionPid, owned: false };
  return isRegular(stateStats, "isFile") ? parseSessionState(statePath, sessionPid) : null;
}

/**
 * Locate the process group of an owned relay whose supervisor is gone.
 * Returns null when nothing is left to stop and undefined when ownership
 * cannot be proven, in which case the relay and its state are left alone.
 */
function staleRelayGroup(state, contract, inspect) {
  const legacy = state.schema === LEGACY_STATE_SCHEMA;
  // v1 relays shared the supervisor's group; v2 relays lead a guardian group.
  const groupId = legacy ? state.supervisorPid : state.relayGroupId;
  const leaderPid = legacy ? state.relayPid : state.relayGroupId;
  const validIds = Number.isInteger(groupId) && Number.isInteger(leaderPid) && groupId > 1;
  const sameRelay = state.version === contract.version && state.port === contract.port;
  if (!validIds || !sameRelay) return undefined;
  if (!processGroupAlive(groupId)) return null;
  const leader = inspect(leaderPid);
  const matches = leader?.groupId === groupId
    && matchesRelayArgv(legacy ? leader.argv ?? leader.legacyArgv : leader.argv, contract, legacy)
    // Older v2 state has no process identity: preserve it as unproven.
    && (legacy || (typeof state.relayStartTime === "string"
      && state.relayStartTime === leader.startTime));
  return matches ? groupId : undefined;
}

function matchesRelayArgv(argv, contract, legacy) {
  if (!Array.isArray(argv)
    || (!legacy && !contract.guardianArgv.every((part, index) => argv[index] === part))) return false;
  if (legacy) {
    const tail = contract.legacyArgs;
    return argv.includes(contract.packageName)
      && tail.every((part, index) => argv[argv.length - tail.length + index] === part);
  }
  try {
    contract.validateCommand(argv.slice(contract.guardianArgv.length));
    return true;
  } catch {
    return false;
  }
}

async function reconcileSession(directory, sessionPid, contract, inspect) {
  const state = readSessionState(directory, sessionPid);
  if (!state || processAlive(state.supervisorPid)) return false;
  const groupId = state.owned ? staleRelayGroup(state, contract, inspect) : null;
  const stopped = groupId === null
    || (groupId !== undefined && await terminateProcessGroup(groupId));
  if (stopped) rmSync(directory, { recursive: true, force: true });
  return stopped;
}

/**
 * Stop relays the launcher started in an earlier session whose supervisor died
 * without cleanup, then remove that session's private state. A relay is
 * stopped only with marker-protected state, a dead supervisor, and a live
 * process group whose leader matches the reviewed relay command; a listener on
 * the relay port is never enough.
 * @param {{version: string, port: number, packageName: string,
 *   legacyArgs: string[], guardianArgv: string[], validateCommand: Function}} contract
 * @returns {Promise<string[]>} names of the session directories removed
 */
export async function reconcileOwnedRelays(parent, contract, { inspect = inspectProcess } = {}) {
  if (!POSIX_GROUPS || !existsSync(parent)) return [];
  const removed = [];
  for (const name of readdirSync(parent)) {
    const match = SESSION_DIRECTORY.exec(name);
    if (!match) continue;
    try {
      if (await reconcileSession(join(parent, name), Number(match[1]), contract, inspect)) {
        removed.push(name);
      }
    } catch {
      // One unreadable session must not block a new relay start.
    }
  }
  return removed;
}
