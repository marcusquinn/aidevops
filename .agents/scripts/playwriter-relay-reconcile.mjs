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

function inspectProcess(pid) {
  const result = spawnSync("ps", ["-o", "pgid=", "-o", "command=", "-p", String(pid)], {
    encoding: "utf8",
    shell: false,
    timeout: 2_000,
  });
  const match = result.status === 0 ? /^\s*(\d+)\s+([\s\S]+)$/.exec(result.stdout.trim()) : null;
  return match ? { groupId: Number(match[1]), command: match[2] } : null;
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
  const shape = legacy ? contract.legacyShape : contract.guardianShape;
  const matches = leader?.groupId === groupId
    && leader.command.includes(contract.packageName)
    && leader.command.includes(shape);
  return matches ? groupId : undefined;
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
 *   legacyShape: string, guardianShape: string}} contract
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
