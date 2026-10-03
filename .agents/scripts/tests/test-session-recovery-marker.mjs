// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import {
  createSessionRecoveryMarkerHandler,
  currentDirectorySequence,
  pathsReferenceSameFile,
  resolveSessionRecoveryMarker,
  writeSessionRecoveryMarker,
} from "../../plugins/opencode-aidevops/session-recovery-marker.mjs";

const root = mkdtempSync(join(tmpdir(), "aidevops-session-recovery-"));
const workDir = join(root, "work");
const directory = join(root, "repo");
const dataDir = join(workDir, "opencode-interactive", "project-repo-test");
const databaseDir = join(dataDir, "opencode");
const databasePath = join(databaseDir, "opencode.db");
const sessionID = "ses_0123456789AbCdEf";
mkdirSync(directory, { recursive: true });
mkdirSync(databaseDir, { recursive: true });

const sql = [
  "CREATE TABLE session (id text PRIMARY KEY, parent_id text, directory text NOT NULL);",
  `INSERT INTO session (id, parent_id, directory) VALUES ('${sessionID}', NULL, '${directory}');`,
].join(" ");
const sqlite = spawnSync("sqlite3", [databasePath, sql], { encoding: "utf8" });
assert.equal(sqlite.status, 0, sqlite.stderr);

assert.equal(
  currentDirectorySequence("/safe path"),
  "\u001B]1337;CurrentDir=/safe path\u0007",
  "Tabby CurrentDir sequence should carry the exact marker path",
);
assert.throws(() => currentDirectorySequence("/unsafe\npath"), /Invalid terminal recovery directory/);

const markerDirectory = writeSessionRecoveryMarker({ sessionID, directory, dataDir, workDir });
assert.deepEqual(resolveSessionRecoveryMarker({ cwd: markerDirectory, workDir }), {
  sessionID,
  directory: realpathSync(directory),
  dataDir: realpathSync(dataDir),
  markerDirectory: realpathSync(markerDirectory),
  runtime: "v1",
  ownerLive: true,
  foreignRuntime: false,
});
assert.equal(resolveSessionRecoveryMarker({ cwd: directory, workDir }), null);

const resolverPath = fileURLToPath(
  new URL("../../plugins/opencode-aidevops/session-recovery-marker.mjs", import.meta.url),
);
const linkedResolverPath = join(root, "session-recovery-marker.mjs");
symlinkSync(resolverPath, linkedResolverPath);
const resolvedCli = spawnSync(
  process.execPath,
  [linkedResolverPath, "resolve", "--cwd", markerDirectory, "--work-dir", workDir],
  { encoding: "utf8" },
);
assert.equal(resolvedCli.status, 3, resolvedCli.stderr);
assert.equal(
  resolvedCli.stdout,
  `${realpathSync(directory)}\t${realpathSync(dataDir)}\t${sessionID}\n`,
  "resolver CLI should execute when invoked through the deployed agents symlink",
);
const missingCli = spawnSync(
  process.execPath,
  [linkedResolverPath, "resolve", "--cwd", directory, "--work-dir", workDir],
  { encoding: "utf8" },
);
assert.equal(missingCli.status, 2, "resolver CLI should preserve the no-marker status through a symlink");

// V2 markers: one shared data home, sessions in session_v2 (GH#32700).
const v2DataDir = join(root, "v2-data");
const v2SessionID = "ses_V2SessionAbCdEf01";
mkdirSync(join(v2DataDir, "opencode"), { recursive: true });
const v2Sqlite = spawnSync(
  "sqlite3",
  [
    join(v2DataDir, "opencode", "opencode.db"),
    [
      "CREATE TABLE session_v2 (id text PRIMARY KEY, parent_id text, directory text NOT NULL);",
      `INSERT INTO session_v2 (id, parent_id, directory) VALUES ('${v2SessionID}', NULL, '${directory}');`,
    ].join(" "),
  ],
  { encoding: "utf8" },
);
assert.equal(v2Sqlite.status, 0, v2Sqlite.stderr);
const v2Marker = writeSessionRecoveryMarker({
  sessionID: v2SessionID,
  directory,
  dataDir: v2DataDir,
  workDir,
  runtime: "v2",
});
assert.equal(
  resolveSessionRecoveryMarker({ cwd: v2Marker, workDir, runtime: "v2", dataDir: v2DataDir }).ownerLive,
  true,
  "a V2 marker owned by this live process must report its owner as live",
);
assert.throws(
  () => resolveSessionRecoveryMarker({ cwd: v2Marker, workDir, runtime: "v2", dataDir: dataDir }),
  /not the OpenCode V2 data directory/,
  "a V2 marker must name the caller's V2 data home",
);
assert.equal(
  resolveSessionRecoveryMarker({ cwd: v2Marker, workDir }).foreignRuntime,
  true,
  "the V1 resolver must not resume a V2 session",
);
assert.equal(
  resolveSessionRecoveryMarker({ cwd: markerDirectory, workDir, runtime: "v2", dataDir: v2DataDir }).foreignRuntime,
  true,
  "the V2 resolver must not resume a V1 session",
);
const v2MarkerPath = join(v2Marker, "recovery.json");
const v2Payload = JSON.parse(readFileSync(v2MarkerPath, "utf8"));
writeFileSync(v2MarkerPath, `${JSON.stringify({ ...v2Payload, owner_start: "ps:dead owner" })}\n`, { mode: 0o600 });
const v2Cli = spawnSync(
  process.execPath,
  [resolverPath, "resolve", "--cwd", v2Marker, "--work-dir", workDir, "--runtime", "v2", "--data-dir", v2DataDir],
  { encoding: "utf8" },
);
assert.equal(v2Cli.status, 0, `a V2 marker with a dead owner is resumable: ${v2Cli.stderr}`);
assert.equal(v2Cli.stdout, `${realpathSync(directory)}\t${realpathSync(v2DataDir)}\t${v2SessionID}\n`);
const foreignCli = spawnSync(
  process.execPath,
  [resolverPath, "resolve", "--cwd", v2Marker, "--work-dir", workDir],
  { encoding: "utf8" },
);
assert.equal(foreignCli.status, 4, foreignCli.stderr);
assert.equal(foreignCli.stdout, `${realpathSync(directory)}\n`, "foreign markers expose only the project directory");

const pluginIndexUrl = new URL("../../plugins/opencode-aidevops/index.mjs", import.meta.url).href;
const subcommandImport = spawnSync(
  process.execPath,
  [
    "--input-type=module",
    "--eval",
    `process.argv[1] = "run"; await import(${JSON.stringify(pluginIndexUrl)});`,
  ],
  { encoding: "utf8" },
);
assert.equal(
  subcommandImport.status,
  0,
  `plugin import should ignore non-path CLI subcommands: ${subcommandImport.stderr}`,
);
const bunVirtualPath = "/$bunfs/root/src/index.js";
assert.equal(
  pathsReferenceSameFile(bunVirtualPath, resolverPath, (candidate) => {
    if (candidate === bunVirtualPath) {
      const error = new Error(`ENOENT: no such file or directory, lstat '${candidate}'`);
      error.code = "ENOENT";
      throw error;
    }
    return realpathSync(candidate);
  }),
  false,
  "Bun virtual argv paths must not break plugin module evaluation when canonicalization fails",
);

const emitted = [];
const handler = createSessionRecoveryMarkerHandler({
  directory,
  dataDir,
  workDir,
  isEnabled: () => true,
  writeMarker: (marker) => {
    emitted.push(marker);
    return markerDirectory;
  },
  writeDirectory: (path) => emitted.push(path),
});
await handler({ event: { type: "session.created", properties: { info: { id: sessionID } } } });
await handler({ event: { type: "session.updated", properties: { info: { id: sessionID } } } });
await handler({
  event: {
    type: "session.created",
    properties: { info: { id: "ses_AnotherSession123", parentID: sessionID } },
  },
});
assert.equal(emitted.length, 2, "root session marker should be emitted exactly once");
assert.equal(emitted[0].sessionID, sessionID);
assert.equal(emitted[1], markerDirectory);

chmodSync(join(markerDirectory, "recovery.json"), 0o644);
assert.throws(
  () => resolveSessionRecoveryMarker({ cwd: markerDirectory, workDir }),
  /Unsafe recovery marker file/,
);
chmodSync(join(markerDirectory, "recovery.json"), 0o600);

const linkedMarker = join(workDir, "opencode-tabby-recovery", "ses_LinkedMarker123");
symlinkSync(markerDirectory, linkedMarker);
assert.throws(
  () => resolveSessionRecoveryMarker({ cwd: linkedMarker, workDir }),
  /Invalid recovery marker location|session mismatch/,
);

const linkedWorkDir = join(root, "linked-work");
mkdirSync(linkedWorkDir);
symlinkSync(join(workDir, "opencode-tabby-recovery"), join(linkedWorkDir, "opencode-tabby-recovery"));
assert.throws(
  () => resolveSessionRecoveryMarker({ cwd: markerDirectory, workDir: linkedWorkDir }),
  /Invalid recovery marker root/,
);

writeFileSync(
  join(markerDirectory, "recovery.json"),
  `${JSON.stringify({
    schema_version: 1,
    session_id: sessionID,
    directory: join(root, "other-repo"),
    data_dir: dataDir,
  })}\n`,
  { mode: 0o600 },
);
assert.throws(
  () => resolveSessionRecoveryMarker({ cwd: markerDirectory, workDir }),
  /ENOENT|does not match/,
);

console.log("All session recovery marker tests passed");
