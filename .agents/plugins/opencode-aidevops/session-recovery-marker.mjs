// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import {
  chmodSync,
  closeSync,
  existsSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  writeFileSync,
  writeSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const SESSION_ID_RE = /^ses_[A-Za-z0-9]{6,128}$/;
const CONTROL_CHAR_RE = /[\u0000-\u001F\u007F]/;
const MARKER_BASENAME = "recovery.json";
const RUNTIMES = new Set(["v1", "v2"]);
// V1 isolates each project under opencode-interactive/*; V2 shares one data
// home whose sessions live in the session_v2 table.
const SESSION_TABLES = { v1: "session", v2: "session_v2" };
export const FOREIGN_RUNTIME_STATUS = 4;

function procStartToken(pid) {
  try {
    // Field 22 follows the command in parentheses; splitting the prefix is unsafe.
    const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
    const fields = stat.slice(stat.lastIndexOf(")") + 2).trim().split(/\s+/);
    return /^\d+$/.test(fields[19] || "") ? fields[19] : null;
  } catch {
    return null;
  }
}

// macOS has no /proc; `ps -o lstart=` gives a stable per-process start time,
// so a recycled PID never looks like the original live owner.
function psStartToken(pid) {
  const result = spawnSync("ps", ["-o", "lstart=", "-p", String(pid)], {
    encoding: "utf8",
    env: { ...process.env, LC_ALL: "C" },
    timeout: 2000,
  });
  const token = result.status === 0 ? result.stdout.trim().replace(/\s+/g, " ") : "";
  return token ? `ps:${token}` : null;
}

export function processStartToken(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return null;
  return procStartToken(pid) || psStartToken(pid);
}

function pathIsInside(parent, candidate) {
  const child = relative(parent, candidate);
  return child === "" || (!child.startsWith("..") && !isAbsolute(child));
}

function assertSafeText(value, label) {
  if (typeof value !== "string" || !value || CONTROL_CHAR_RE.test(value)) {
    throw new Error(`Invalid ${label}`);
  }
  return value;
}

function assertPrivateDirectory(path, uid) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== uid || (stat.mode & 0o077) !== 0) {
    throw new Error("Unsafe recovery marker directory");
  }
}

function assertPrivateFile(path, uid) {
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== uid || (stat.mode & 0o077) !== 0) {
    throw new Error("Unsafe recovery marker file");
  }
}

function ensurePrivateDirectory(path) {
  if (existsSync(path)) {
    const stat = lstatSync(path);
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid()) {
      throw new Error("Unsafe recovery marker directory");
    }
  } else {
    mkdirSync(path, { recursive: true, mode: 0o700 });
  }
  chmodSync(path, 0o700);
  assertPrivateDirectory(path, process.getuid());
}

export function recoveryRoot(workDir) {
  return join(workDir, "opencode-tabby-recovery");
}

export function currentDirectorySequence(directory) {
  const safeDirectory = assertSafeText(directory, "terminal recovery directory");
  return `\u001B]1337;CurrentDir=${safeDirectory}\u0007`;
}

export function writeCurrentDirectory(directory) {
  const sequence = currentDirectorySequence(directory);
  let ttyFd;
  try {
    ttyFd = openSync("/dev/tty", "w");
    writeSync(ttyFd, sequence);
    return true;
  } catch {
    return false;
  } finally {
    if (ttyFd !== undefined) {
      try {
        closeSync(ttyFd);
      } catch {
        // Tabby recovery synchronization is best-effort while OpenCode is live.
      }
    }
  }
}

export function writeSessionRecoveryMarker({ sessionID, directory, dataDir, workDir, runtime = "v1" }) {
  if (!SESSION_ID_RE.test(sessionID)) throw new Error("Invalid OpenCode session ID");
  if (!RUNTIMES.has(runtime)) throw new Error("Invalid OpenCode runtime");
  assertSafeText(directory, "session directory");
  assertSafeText(dataDir, "OpenCode data directory");
  assertSafeText(workDir, "aidevops work directory");
  if (!isAbsolute(directory) || !isAbsolute(dataDir) || !isAbsolute(workDir)) {
    throw new Error("Recovery marker paths must be absolute");
  }

  const canonicalDirectory = realpathSync(directory);
  const canonicalDataDir = realpathSync(dataDir);
  const root = recoveryRoot(resolve(workDir));
  const markerDirectory = join(root, sessionID);
  ensurePrivateDirectory(root);
  ensurePrivateDirectory(markerDirectory);

  const markerPath = join(markerDirectory, MARKER_BASENAME);
  const temporaryPath = join(markerDirectory, `.recovery.${process.pid}.${Date.now()}.tmp`);
  const payload = `${JSON.stringify({
    // Schema 1 predates runtimes and stays V1-only so older resolvers keep
    // rejecting V2 markers instead of misreading them.
    schema_version: runtime === "v2" ? 2 : 1,
    ...(runtime === "v2" ? { runtime } : {}),
    session_id: sessionID,
    directory: canonicalDirectory,
    data_dir: canonicalDataDir,
    owner_pid: process.pid,
    owner_start: processStartToken(process.pid),
  })}\n`;

  try {
    writeFileSync(temporaryPath, payload, { encoding: "utf8", flag: "wx", mode: 0o600 });
    renameSync(temporaryPath, markerPath);
    chmodSync(markerPath, 0o600);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
  assertPrivateFile(markerPath, process.getuid());
  return markerDirectory;
}

function querySessionDirectory(databasePath, sessionID, runtime) {
  // The table name is a fixed constant and sessionID matched SESSION_ID_RE.
  const table = SESSION_TABLES[runtime];
  const sql = `SELECT directory FROM ${table} WHERE id='${sessionID}' AND parent_id IS NULL LIMIT 2;`;
  const result = spawnSync("sqlite3", ["-readonly", databasePath, sql], {
    encoding: "utf8",
    timeout: 5000,
  });
  if (result.error || result.status !== 0) throw new Error("Could not validate OpenCode recovery database");
  const rows = result.stdout.trimEnd().split("\n").filter(Boolean);
  if (rows.length !== 1) throw new Error("OpenCode recovery session was not found");
  return rows[0];
}

function canonicalMarkerDirectory(cwd, workDir, uid) {
  const root = recoveryRoot(resolve(workDir));
  if (!existsSync(root)) return null;
  if (lstatSync(root).isSymbolicLink()) throw new Error("Invalid recovery marker root");
  const canonicalRoot = realpathSync(root);
  const canonicalCwd = realpathSync(cwd);
  if (!pathIsInside(canonicalRoot, canonicalCwd)) return null;

  if (lstatSync(cwd).isSymbolicLink()) throw new Error("Invalid recovery marker location");
  assertPrivateDirectory(canonicalRoot, uid);
  assertPrivateDirectory(canonicalCwd, uid);
  if (dirname(canonicalCwd) !== canonicalRoot) throw new Error("Invalid recovery marker location");
  return canonicalCwd;
}

function readRecoveryMarker(canonicalCwd, uid) {
  const markerPath = join(canonicalCwd, MARKER_BASENAME);
  assertPrivateFile(markerPath, uid);
  const marker = JSON.parse(readFileSync(markerPath, "utf8"));
  const isV1 = marker.schema_version === 1 && marker.runtime === undefined;
  const isV2 = marker.schema_version === 2 && marker.runtime === "v2";
  if (!(isV1 || isV2) || !SESSION_ID_RE.test(marker.session_id)) {
    throw new Error("Invalid recovery marker schema");
  }
  if (basename(canonicalCwd) !== marker.session_id) throw new Error("Recovery marker session mismatch");
  return { ...marker, runtime: isV2 ? "v2" : "v1" };
}

function canonicalRecoveryDataDir(dataDir, workDir, uid) {
  const dataDirStat = lstatSync(dataDir);
  if (!dataDirStat.isDirectory() || dataDirStat.isSymbolicLink() || dataDirStat.uid !== uid) {
    throw new Error("Unsafe OpenCode recovery data directory");
  }
  const canonicalDataDir = realpathSync(dataDir);
  const isolatedRootPath = join(resolve(workDir), "opencode-interactive");
  const isolatedRootStat = lstatSync(isolatedRootPath);
  if (!isolatedRootStat.isDirectory() || isolatedRootStat.isSymbolicLink() || isolatedRootStat.uid !== uid) {
    throw new Error("Unsafe OpenCode isolated storage root");
  }
  const isolatedRoot = realpathSync(isolatedRootPath);
  if (!pathIsInside(isolatedRoot, canonicalDataDir) || canonicalDataDir === isolatedRoot) {
    throw new Error("Recovery marker data directory is outside isolated storage");
  }
  return canonicalDataDir;
}

// V2 has one shared data home, so the marker must name exactly the data home
// the caller's V2 shim is using; anything else fails closed.
function canonicalV2DataDir(dataDir, expectedDataDir, uid) {
  if (!expectedDataDir || !isAbsolute(assertSafeText(expectedDataDir, "OpenCode V2 data directory"))) {
    throw new Error("OpenCode V2 recovery requires an absolute V2 data directory");
  }
  for (const path of [dataDir, expectedDataDir]) {
    const stat = lstatSync(path);
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== uid) {
      throw new Error("Unsafe OpenCode recovery data directory");
    }
  }
  const canonicalDataDir = realpathSync(dataDir);
  if (canonicalDataDir !== realpathSync(expectedDataDir)) {
    throw new Error("Recovery marker data directory is not the OpenCode V2 data directory");
  }
  return canonicalDataDir;
}

function validateRecoveryDatabase(canonicalDataDir, sessionID, canonicalDirectory, uid, runtime) {
  const databasePath = join(canonicalDataDir, "opencode", "opencode.db");
  const databaseStat = lstatSync(databasePath);
  if (!databaseStat.isFile() || databaseStat.isSymbolicLink() || databaseStat.uid !== uid) {
    throw new Error("Unsafe OpenCode recovery database");
  }
  const databaseDirectory = querySessionDirectory(databasePath, sessionID, runtime);
  if (realpathSync(databaseDirectory) !== canonicalDirectory) {
    throw new Error("Recovery marker directory does not match the OpenCode session");
  }
}

function markerOwnerLive(marker) {
  const validOwnerPid = Number.isSafeInteger(marker.owner_pid) && marker.owner_pid > 0;
  const validOwnerStart = typeof marker.owner_start === "string" && marker.owner_start.length > 0;
  return validOwnerPid && validOwnerStart && processStartToken(marker.owner_pid) === marker.owner_start;
}

// `runtime` names the caller. A marker from the other runtime yields only its
// project directory (`foreignRuntime`) so the caller can leave the marker
// directory without resuming a session it cannot open.
export function resolveSessionRecoveryMarker({ cwd, workDir, runtime = "v1", dataDir: expectedDataDir = "" }) {
  assertSafeText(cwd, "recovered working directory");
  assertSafeText(workDir, "aidevops work directory");
  if (!isAbsolute(cwd) || !isAbsolute(workDir)) throw new Error("Recovery paths must be absolute");
  if (!RUNTIMES.has(runtime)) throw new Error("Invalid OpenCode runtime");

  const uid = process.getuid();
  const canonicalCwd = canonicalMarkerDirectory(cwd, workDir, uid);
  if (!canonicalCwd) return null;
  const marker = readRecoveryMarker(canonicalCwd, uid);
  const directory = assertSafeText(marker.directory, "marker session directory");
  const dataDir = assertSafeText(marker.data_dir, "marker OpenCode data directory");
  if (!isAbsolute(directory) || !isAbsolute(dataDir)) throw new Error("Recovery marker paths must be absolute");
  const canonicalDirectory = realpathSync(directory);
  const base = { sessionID: marker.session_id, directory: canonicalDirectory, markerDirectory: canonicalCwd, runtime: marker.runtime };
  if (marker.runtime !== runtime) {
    return { ...base, dataDir: "", ownerLive: false, foreignRuntime: true };
  }

  const canonicalDataDir = runtime === "v2"
    ? canonicalV2DataDir(dataDir, expectedDataDir, uid)
    : canonicalRecoveryDataDir(dataDir, workDir, uid);
  validateRecoveryDatabase(canonicalDataDir, marker.session_id, canonicalDirectory, uid, runtime);

  return { ...base, dataDir: canonicalDataDir, ownerLive: markerOwnerLive(marker), foreignRuntime: false };
}

function eventSessionInfo(event) {
  return event?.properties?.info || event?.properties?.session || null;
}

function eventSessionID(event, info) {
  return String(info?.id || info?.sessionID || event?.properties?.sessionID || "");
}

export function createSessionRecoveryMarkerHandler({
  directory,
  dataDir,
  workDir,
  isEnabled = () => process.env.AIDEVOPS_TABBY_SESSION_RECOVERY === "1",
  writeMarker = writeSessionRecoveryMarker,
  writeDirectory = writeCurrentDirectory,
}) {
  const emitted = new Set();
  return async ({ event } = {}) => {
    if (!isEnabled() || !event || !["session.created", "session.updated"].includes(event.type)) return;
    const info = eventSessionInfo(event);
    if (info?.parentID) return;
    const sessionID = eventSessionID(event, info);
    if (!SESSION_ID_RE.test(sessionID) || emitted.has(sessionID)) return;
    const markerDirectory = writeMarker({ sessionID, directory, dataDir, workDir });
    writeDirectory(markerDirectory);
    emitted.add(sessionID);
  };
}

function parseCliArgs(argv) {
  const parsed = parseArgs({
    args: argv,
    options: {
      cwd: { type: "string" },
      "work-dir": { type: "string" },
      runtime: { type: "string" },
      "data-dir": { type: "string" },
    },
    strict: true,
  });
  return {
    cwd: parsed.values.cwd || "",
    workDir: parsed.values["work-dir"] || "",
    runtime: parsed.values.runtime || "v1",
    dataDir: parsed.values["data-dir"] || "",
  };
}

// Exit status: 0 resumable, 3 owner still live (open the directory only),
// 4 marker from another runtime (stdout is the directory only), 2 no marker.
function runCli(argv) {
  const [command, ...options] = argv;
  if (command !== "resolve") throw new Error("Expected recovery resolver command");
  const parsed = parseCliArgs(options);
  const workDir = parsed.workDir || join(homedir(), ".aidevops", ".agent-workspace", "work");
  const result = resolveSessionRecoveryMarker({
    cwd: parsed.cwd,
    workDir,
    runtime: parsed.runtime,
    dataDir: parsed.dataDir,
  });
  if (!result) return 2;
  if (result.foreignRuntime) {
    process.stdout.write(`${result.directory}\n`);
    return FOREIGN_RUNTIME_STATUS;
  }
  process.stdout.write(`${result.directory}\t${result.dataDir}\t${result.sessionID}\n`);
  return result.ownerLive ? 3 : 0;
}

export function pathsReferenceSameFile(candidatePath, expectedPath, canonicalize = realpathSync) {
  if (!candidatePath || !expectedPath) return false;
  try {
    return canonicalize(candidatePath) === canonicalize(expectedPath);
  } catch {
    return false;
  }
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
const modulePath = fileURLToPath(import.meta.url);
if (pathsReferenceSameFile(invokedPath, modulePath)) {
  try {
    process.exitCode = runCli(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`Session recovery marker rejected: ${error.message}\n`);
    process.exitCode = 1;
  }
}
