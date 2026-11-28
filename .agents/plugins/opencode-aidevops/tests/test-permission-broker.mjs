// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { tmpdir } from "os";

import { createPermissionBroker, sanitizePermissionText } from "../permission-broker.mjs";
import { recordedDeviceTargets } from "../permission-broker-runtime-read.mjs";

test("worker runtime reads allow bounded plumbing but keep broad and proc requests gated", async (t) => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "aidevops-runtime-read-")));
  const previous = preserveWorkerEnvironment();
  t.after(() => { restoreWorkerEnvironment(previous); rmSync(root, { recursive: true, force: true }); });
  const requestFile = join(root, "request.json");
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  const temp = join(root, ".aidevops/.agent-workspace/tmp");
  mkdirSync(temp, { recursive: true });
  writeFileSync(join(temp, "output.txt"), "worker output");
  symlinkSync(root, join(temp, "escape"));
  const replies = [];
  const broker = createPermissionBroker({ isHeadless: () => true, home: root,
    blockerLogPath: join(root, "blockers.jsonl"),
    client: { postSessionIdPermissionsPermissionId: async (value) => replies.push(value) } });
  for (const [id, target, pattern, tool, allowed] of [
    ["null", "/dev/null", "/dev/*", "read", true],
    ["stdin", "/dev/stdin", "/dev/*", "read", true],
    ["stdout", "/dev/stdout", "/dev/*", "read", true],
    ["stderr", "/dev/stderr", "/dev/*", "read", true],
    ["fd", "/dev/fd/1", "/dev/fd/*", "read", true],
    ["urandom", "/dev/urandom", "/dev/*", "read", true],
    ["random", "/dev/random", "/dev/*", "read", true],
    ["temp", join(temp, "output.txt"), `${temp}/*`, "read", true],
    ["broad-dev", "", "/dev/*", "read", false],
    ["broad-home", join(temp, "output.txt"), `${root}/*`, "read", false],
    ["proc", "/proc/meminfo", "/proc/*", "read", false],
    ["proc-self", "/proc/self/status", "/proc/self/*", "read", false],
    ["write", "/dev/null", "/dev/*", "edit", false],
    ["write-random", "/dev/random", "/dev/*", "write", false],
    ["tty", "/dev/tty", "/dev/*", "read", false],
    ["block", "/dev/null/../sda", "/dev/*", "read", false],
    ["symlink", join(temp, "escape/request.json"), `${temp}/escape/*`, "read", false],
    ["secret", join(temp, ".env"), `${temp}/*`, "read", false],
  ]) {
    // GH#40455: hosts without /proc (macOS) reject the absent read before any
    // permission ask; that rejection is the gate there. Linux keeps the ask path.
    if (target.startsWith("/proc/") && !existsSync(target)) {
      assert.throws(() => broker.recordToolCall({ tool, callID: id }, { args: { filePath: target } }), /does not exist/, id);
      continue;
    }
    broker.recordToolCall({ tool, callID: id }, { args: { filePath: target } });
    const raw = { id, sessionID: "runtime", permission: "external_directory", patterns: [pattern], callID: id };
    const output = { status: "ask" };
    broker.permissionAsk(raw, output);
    assert.equal(output.status, allowed ? "allow" : "deny", id);
    await broker.handleEvent({ event: { type: "permission.asked", properties: raw } });
    assert.equal(replies.at(-1).body.response, allowed ? "once" : "reject", id);
    if (allowed) assert.equal(existsSync(requestFile), false, id);
  }
  const capture = JSON.parse(readFileSync(requestFile, "utf8"));
  assert.ok(capture.requests.some((request) => request.patterns.includes("/dev/*")));
});

test("only bounded recorded bash device operations bypass their directory ask", async (t) => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "aidevops-runtime-shell-")));
  const previous = preserveWorkerEnvironment();
  t.after(() => { restoreWorkerEnvironment(previous); rmSync(root, { recursive: true, force: true }); });
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = join(root, "request.json");
  const broker = createPermissionBroker({ isHeadless: () => true, home: root,
    blockerLogPath: join(root, "blockers.jsonl") });
  for (const [command, permission, patterns, allowed] of [
    ["git status 2>/dev/null", "external_directory", ["/dev/*"], true],
    ["cat </dev/stdin", "external_directory", ["/dev/*"], true],
    ["git status 1>/dev/fd/1", "external_directory", ["/dev/fd/*"], false],
    ["git status --short 2>/dev/null | head -1", "external_directory", ["/dev/*"], true],
    ["true </dev/null", "external_directory", ["/dev/*"], true],
    ["</dev/null true", "external_directory", ["/dev/*"], true],
    ["git status >/dev/null 2>&1 && true", "external_directory", ["/dev/*"], true],
    ["true && git 2>/dev/null status", "external_directory", ["/dev/*"], true],
    ["head -c 16 /dev/urandom", "external_directory", ["/dev/*"], true],
    ["head -c 16 </dev/random", "external_directory", ["/dev/*"], true],
    ["cat </dev/urandom >/dev/null", "external_directory", ["/dev/*"], true],
    ["true >>/dev/null", "external_directory", ["/dev/*"], true],
    ["true 2>&1>/dev/null", "external_directory", ["/dev/*"], true],
    ["true >/dev/null >&1out", "external_directory", ["/dev/*"], false],
    ["true >/dev/null >&1.txt", "external_directory", ["/dev/*"], false],
    ["true >/dev/null 3>&1out", "external_directory", ["/dev/*"], false],
    ["true >/dev/urandom", "external_directory", ["/dev/*"], false],
    ["true >>/dev/random", "external_directory", ["/dev/*"], false],
    ["tee /dev/urandom", "external_directory", ["/dev/*"], false],
    ["cat </dev/tty", "external_directory", ["/dev/*"], false],
    ["true >/dev/stdout", "external_directory", ["/dev/*"], false],
    ["true >/dev/stderr", "external_directory", ["/dev/*"], false],
    ["cat </dev/sda", "external_directory", ["/dev/*"], false],
    ["true >/dev/null && cat /dev/sda", "external_directory", ["/dev/*"], false],
    ["true >/dev/null && tee /dev/random", "external_directory", ["/dev/*"], false],
    ["true >/dev/null &&", "external_directory", ["/dev/*"], false],
    ["true >/dev/null$(cat secret)", "external_directory", ["/dev/*"], false],
    ["cat << /dev/null", "external_directory", ["/dev/*"], false],
    ["cat >/dev/null\ntee /dev/random", "external_directory", ["/dev/*"], false],
    ["true >/dev/null\u000bextra", "external_directory", ["/dev/*"], false],
    ["true >/dev/null\u00a0extra", "external_directory", ["/dev/*"], false],
    ["head/dev/urandom", "external_directory", ["/dev/*"], false],
    ["true\t</dev/null", "external_directory", ["/dev/*"], true],
    ["cat /dev/sda 2>/dev/null", "external_directory", ["/dev/*"], false],
    ["git status 2>/dev/null; cat /dev/sda", "external_directory", ["/dev/*"], false],
    ["git status 2>/dev/null", "external_directory", ["/dev/*", `${root}/*`], false],
    ["git status 2>/dev/null", "bash", ["git *"], false],
    ["git status 2>$DEVICE", "external_directory", ["/dev/*"], false],
    ["ls /dev", "external_directory", ["/dev/*"], false],
  ]) {
    broker.recordToolCall({ tool: "bash", callID: "shell" }, { args: { command } });
    const output = { status: "ask" };
    broker.permissionAsk({ permission, patterns, callID: "shell" }, output);
    assert.equal(output.status, allowed ? "allow" : "deny", command);
  }
  const capture = JSON.parse(readFileSync(process.env.AIDEVOPS_PERMISSION_REQUEST_FILE, "utf8"));
  assert.ok(capture.requests.some((request) => request.concrete_device_targets.includes("/dev/tty")));
  assert.ok(capture.requests.some((request) => request.concrete_device_targets.includes("/dev/sda")));
  assert.ok(capture.requests.some((request) => request.concrete_device_targets.length === 0));
  assert.equal(JSON.stringify(capture).includes("cat secret"), false);
  assert.ok(capture.requests.every((request) => request.command === undefined));
  for (const command of ["cat /dev/sda${PARTITION}", "cat /dev/tty/../sda", "cat /other/dev/tty", "echo /dev/tty-value"]) {
    assert.deepEqual(recordedDeviceTargets({ tool: "bash", command }), [], command);
  }
  assert.deepEqual(recordedDeviceTargets({ tool: "bash", command: "cat /dev/tty 2>/dev/null" }), ["/dev/tty", "/dev/null"]);
});

test("runtime scratch exception rejects a symlinked root or managed ancestor", (t) => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "aidevops-runtime-root-")));
  const previous = preserveWorkerEnvironment();
  t.after(() => { restoreWorkerEnvironment(previous); rmSync(root, { recursive: true, force: true }); });
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = join(root, "request.json");
  const outside = join(root, "outside");
  mkdirSync(outside);
  writeFileSync(join(outside, "output.txt"), "outside");
  for (const ancestor of [false, true]) {
    const home = join(root, ancestor ? "ancestor-home" : "root-home");
    const workspace = join(home, ".aidevops/.agent-workspace");
    mkdirSync(ancestor ? home : workspace, { recursive: true });
    if (ancestor) {
      mkdirSync(join(outside, ".agent-workspace/tmp"), { recursive: true });
      writeFileSync(join(outside, ".agent-workspace/tmp/output.txt"), "outside");
      symlinkSync(outside, join(home, ".aidevops"));
    } else symlinkSync(outside, join(workspace, "tmp"));
    const target = join(workspace, "tmp/output.txt");
    const broker = createPermissionBroker({ isHeadless: () => true, home,
      blockerLogPath: join(root, "blockers.jsonl") });
    broker.recordToolCall({ tool: "read", callID: "linked" }, { args: { filePath: target } });
    const output = { status: "ask" };
    broker.permissionAsk({ permission: "external_directory", patterns: [`${dirname(target)}/*`], callID: "linked" }, output);
    assert.equal(output.status, "deny");
  }
});

test("missing exact external reads fail without a permission handoff; existing and sensitive paths retain gates", async (t) => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "aidevops-impossible-read-")));
  const previous = preserveWorkerEnvironment();
  t.after(() => { restoreWorkerEnvironment(previous); rmSync(root, { recursive: true, force: true }); });
  const home = join(root, "home");
  mkdirSync(home);
  const requestFile = join(root, "request.json");
  const blockerLog = join(root, "blockers.jsonl");
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  const replies = [];
  const broker = createPermissionBroker({
    client: { postSessionIdPermissionsPermissionId: async (value) => replies.push(value) },
    isHeadless: () => true, home, blockerLogPath: blockerLog,
  });
  const missing = join(root, "wrong/.aidevops/.agent-workspace/shot.png");
  assert.throws(() => broker.recordToolCall({ tool: "read", callID: "before" }, { args: { filePath: missing } }), /does not exist.*session output directory/);
  for (const tool of ["read", "glob", "grep", "list"]) {
    broker.recordToolCall({ tool, callID: tool }, { args: {} });
    const raw = { id: tool, sessionID: "missing", permission: "external_directory", patterns: [`${dirname(missing)}/*`], metadata: { filepath: missing }, tool: { callID: tool } };
    await broker.handleEvent({ event: { type: "permission.asked", properties: raw } });
    const output = { status: "ask" };
    broker.permissionAsk(raw, output);
    assert.equal(output.status, "deny");
    assert.match(output.message, /does not exist/);
  }
  assert.deepEqual(replies.map((reply) => reply.body.response), ["reject", "reject", "reject", "reject"]);
  assert.equal(existsSync(requestFile), false);
  assert.equal(existsSync(blockerLog), false);

  const existing = join(root, "existing.txt");
  writeFileSync(existing, "existing");
  const sensitive = join(root, ".ssh/missing-key");
  for (const [id, target] of [["existing", existing], ["sensitive", sensitive]]) {
    broker.recordToolCall({ tool: "read", callID: id }, { args: { filePath: target } });
    await broker.handleEvent({ event: { type: "permission.asked", properties: {
      id, sessionID: "gated", permission: "external_directory", patterns: [target], tool: { callID: id },
    } } });
  }
  const capture = JSON.parse(readFileSync(requestFile, "utf8"));
  assert.equal(capture.requests[0].risk.grantable, true);
  assert.equal(capture.requests[1].risk.grantable, false);
  assert.match(readFileSync(blockerLog, "utf8"), /permission_request_captured/);

  const managed = join(home, ".aidevops/.agent-workspace");
  mkdirSync(managed, { recursive: true });
  const alias = join(root, "alias");
  symlinkSync(join(home, ".aidevops"), alias, "dir");
  writeFileSync(join(home, "existing-through-traversal.txt"), "existing");
  const traversal = `${alias}/../existing-through-traversal.txt`;
  assert.equal(existsSync(traversal), true);
  assert.equal(existsSync(join(root, "existing-through-traversal.txt")), false);
  assert.doesNotThrow(() => broker.recordToolCall({ tool: "read", callID: "before-traversal" }, { args: { filePath: traversal } }));
  for (const [id, tool, target, patterns] of [
    ["managed", "read", join(managed, "missing.png"), [join(managed, "missing.png")]],
    ["symlink", "read", join(alias, ".agent-workspace/missing.png"), [join(alias, ".agent-workspace/missing.png")]],
    ["traversal", "read", traversal, [traversal]],
    ["mutation", "edit", missing, [missing]],
    ["unbounded", "read", missing, ["*"]],
    ["no-pattern", "read", missing, []],
  ]) {
    broker.recordToolCall({ tool, callID: id }, { args: {} });
    const output = { status: "ask" };
    broker.permissionAsk({ permission: "external_directory", patterns, metadata: { filepath: target }, callID: id }, output);
    assert.equal(output.status, "deny");
    assert.equal(output.message, undefined);
  }
  assert.equal(JSON.parse(readFileSync(requestFile, "utf8")).requests.length, 8);
});

const WORKER_ENV_KEYS = [
  "AIDEVOPS_PERMISSION_REQUEST_FILE",
  "WORKER_ISSUE_NUMBER",
  "WORKER_REPO_SLUG",
  "WORKER_SESSION_KEY",
];

function preserveWorkerEnvironment() {
  return Object.fromEntries(WORKER_ENV_KEYS.map((key) => [key, process.env[key]]));
}

function restoreWorkerEnvironment(previous) {
  for (const key of WORKER_ENV_KEYS) {
    if (previous[key] === undefined) delete process.env[key];
    else process.env[key] = previous[key];
  }
}

function toolOutputPermissionEvent({ id, callID, outputDir, outputPath }) {
  return { event: { type: "permission.asked", properties: {
    id,
    sessionID: "session-output",
    permission: "external_directory",
    patterns: [`${outputDir}/*`],
    metadata: { filepath: outputPath, parentDir: outputDir },
    tool: { callID, messageID: `message-${id}` },
  } } };
}

test("headless workers auto-approve only regular OpenCode tool-output reads", async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "aidevops-permission-broker-")));
  const dataHome = join(root, "xdg-data");
  const outputDir = join(dataHome, "opencode", "tool-output");
  const outputPath = join(outputDir, "tool_01TESTOUTPUT");
  const requestFile = join(root, "request.json");
  const blockerLog = join(root, "blockers.jsonl");
  const previous = preserveWorkerEnvironment();
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  mkdirSync(outputDir, { recursive: true });
  writeFileSync(outputPath, "bounded output\n");
  const replies = [];
  const broker = createPermissionBroker({
    client: { postSessionIdPermissionsPermissionId: async (value) => replies.push(value) },
    isHeadless: () => true,
    home: root,
    dataHome,
    blockerLogPath: blockerLog,
  });
  broker.recordToolCall({ tool: "read", callID: "call-output" }, { args: {} });

  await broker.handleEvent(toolOutputPermissionEvent({
    id: "permission-output",
    callID: "call-output",
    outputDir,
    outputPath,
  }));

  assert.equal(replies[0].body.response, "once");
  assert.equal(existsSync(requestFile), false);
  assert.equal(existsSync(blockerLog), false);

  broker.recordToolCall({ tool: "read", callID: "call-output-legacy" }, { args: {} });
  const legacyOutput = { status: "ask" };
  await broker.permissionAsk({
    id: "permission-output-legacy",
    type: "external_directory",
    pattern: `${outputDir}/*`,
    callID: "call-output-legacy",
    metadata: { filepath: outputPath, parentDir: outputDir },
  }, legacyOutput);
  assert.equal(legacyOutput.status, "allow");
  restoreWorkerEnvironment(previous);
  rmSync(root, { recursive: true, force: true });
});

test("headless workers auto-allow read-only toolchain roots but never writes or credential files", async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "aidevops-permission-broker-")));
  const requestFile = join(root, "request.json");
  const blockerLog = join(root, "blockers.jsonl");
  const previous = preserveWorkerEnvironment();
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  const replies = [];
  const broker = createPermissionBroker({
    client: { postSessionIdPermissionsPermissionId: async (value) => replies.push(value) },
    isHeadless: () => true,
    home: root,
    dataHome: join(root, "xdg-data"),
    blockerLogPath: blockerLog,
  });
  const ask = (id, tool, patterns) => {
    broker.recordToolCall({ tool, callID: id }, { args: {} });
    return broker.handleEvent({ event: { type: "permission.asked", properties: {
      id, sessionID: "session-nvm", permission: "external_directory", patterns, tool: { callID: id },
    } } });
  };

  await ask("nvm-read", "read", [`${root}/.nvm/versions/*`]);
  assert.equal(replies.at(-1).body.response, "once");
  assert.equal(existsSync(requestFile), false);
  assert.match(readFileSync(blockerLog, "utf8"), /permission_read_only_root_allowed/);

  await ask("local-bin-read", "read", [`${root}/.local/bin/*`]);
  assert.equal(replies.at(-1).body.response, "once");
  assert.equal(existsSync(requestFile), false);
  assert.doesNotMatch(readFileSync(blockerLog, "utf8"), /permission_request_captured|permission_required/);

  broker.recordToolCall({ tool: "read", callID: "local-bin-legacy" }, { args: {} });
  const localBinOutput = { status: "ask" };
  broker.permissionAsk({ type: "external_directory", pattern: `${root}/.local/bin/*`, callID: "local-bin-legacy" }, localBinOutput);
  assert.equal(localBinOutput.status, "allow");
  assert.equal(existsSync(requestFile), false);

  for (const tool of ["write", "edit", "bash"]) {
    await ask(`local-bin-${tool}`, tool, [`${root}/.local/bin/*`]);
    assert.equal(replies.at(-1).body.response, "reject");
  }
  for (const [id, pattern] of [
    ["credential", `${root}/.local/bin/.env`],
    ["escape", `${root}/.local/bin/../share/*`],
    ["prefix", `${root}/.local/bin-other/*`],
    ["mixed", `${root}/outside/*`],
  ]) {
    await ask(`local-bin-${id}`, "read", [`${root}/.local/bin/*`, pattern]);
    assert.equal(replies.at(-1).body.response, "reject");
  }

  broker.recordToolCall({ tool: "read", callID: "local-bin-auth" }, { args: { filePath: `${root}/.local/bin/auth.json` } });
  await broker.handleEvent({ event: { type: "permission.asked", properties: {
    id: "local-bin-auth", sessionID: "session-nvm", permission: "external_directory",
    patterns: [`${root}/.local/bin/*`], tool: { callID: "local-bin-auth" },
  } } });
  assert.equal(replies.at(-1).body.response, "reject");
  assert.match(readFileSync(requestFile, "utf8"), /"grantable": false/);

  mkdirSync(join(root, "outside-secret"), { recursive: true });
  mkdirSync(join(root, ".local"), { recursive: true });
  symlinkSync(join(root, "outside-secret"), join(root, ".local", "bin"));
  await ask("local-bin-symlink", "read", [`${root}/.local/bin/*`]);
  assert.equal(replies.at(-1).body.response, "reject");

  mkdirSync(join(root, ".ssh"), { recursive: true });
  writeFileSync(join(root, ".ssh", "id_rsa"), "x");
  symlinkSync(join(root, ".ssh", "id_rsa"), join(root, "outside-secret", "link"));
  rmSync(requestFile, { force: true });
  await ask("local-bin-ssh-link", "read", [`${root}/.local/bin/link`]);
  assert.equal(replies.at(-1).body.response, "reject");
  assert.match(readFileSync(requestFile, "utf8"), /"grantable": false/);
  assert.doesNotMatch(readFileSync(requestFile, "utf8"), /"grantable": true/);

  await ask("nvm-write", "write", [`${root}/.nvm/*`]);
  assert.equal(replies.at(-1).body.response, "reject");
  assert.equal(existsSync(requestFile), true);

  await ask("nvm-npmrc", "read", [`${root}/.nvm/versions/node/v20/etc/npmrc`]);
  assert.equal(replies.at(-1).body.response, "reject");
  assert.match(readFileSync(requestFile, "utf8"), /"grantable": false/);

  await ask("nvm-escape", "read", [`${root}/.nvm/../.ssh/*`]);
  assert.equal(replies.at(-1).body.response, "reject");
  restoreWorkerEnvironment(previous);
  rmSync(root, { recursive: true, force: true });
});

test("tool-output read approval failure falls back to capture and rejection", async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "aidevops-permission-broker-")));
  const dataHome = join(root, "xdg-data");
  const outputDir = join(dataHome, "opencode", "tool-output");
  const outputPath = join(outputDir, "tool_01FAILEDAPPROVAL");
  const requestFile = join(root, "request.json");
  const blockerLog = join(root, "blockers.jsonl");
  const previous = preserveWorkerEnvironment();
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  mkdirSync(outputDir, { recursive: true });
  writeFileSync(outputPath, "bounded output\n");
  const replies = [];
  const broker = createPermissionBroker({
    client: { postSessionIdPermissionsPermissionId: async (value) => {
      replies.push(value);
      if (value.body.response === "once") return { error: { message: "approval failed" }, response: { ok: false } };
      return { data: {}, response: { ok: true } };
    } },
    isHeadless: () => true,
    home: root,
    dataHome,
    blockerLogPath: blockerLog,
  });
  broker.recordToolCall({ tool: "read", callID: "call-output-failed" }, { args: {} });

  await broker.handleEvent(toolOutputPermissionEvent({
    id: "permission-output-failed",
    callID: "call-output-failed",
    outputDir,
    outputPath,
  }));

  assert.deepEqual(replies.map((reply) => reply.body.response), ["once", "reject"]);
  assert.equal(JSON.parse(readFileSync(requestFile, "utf8")).requests[0].tool, "read");
  assert.equal(JSON.parse(readFileSync(blockerLog, "utf8")).reason, "permission_required");
  restoreWorkerEnvironment(previous);
  rmSync(root, { recursive: true, force: true });
});

test("tool-output exception rejects mutation tools and symlink escapes", async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "aidevops-permission-broker-")));
  const physicalDataHome = join(root, "physical-xdg-data");
  const dataHome = join(root, "linked-xdg-data");
  const physicalOutputDir = join(physicalDataHome, "opencode", "tool-output");
  const outputDir = join(dataHome, "opencode", "tool-output");
  const outsidePath = join(root, "outside.txt");
  const linkedOutput = join(outputDir, "tool_01LINKEDOUTPUT");
  const regularOutput = join(outputDir, "tool_01REGULAROUTPUT");
  const requestFile = join(root, "request.json");
  const previous = preserveWorkerEnvironment();
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  mkdirSync(physicalOutputDir, { recursive: true });
  symlinkSync(physicalDataHome, dataHome, "dir");
  writeFileSync(outsidePath, "outside\n");
  writeFileSync(regularOutput, "regular\n");
  symlinkSync(outsidePath, linkedOutput);
  const replies = [];
  const broker = createPermissionBroker({
    client: { postSessionIdPermissionsPermissionId: async (value) => replies.push(value) },
    isHeadless: () => true,
    home: root,
    dataHome,
    blockerLogPath: join(root, "blockers.jsonl"),
  });
  broker.recordToolCall({ tool: "edit", callID: "call-edit" }, { args: {} });
  broker.recordToolCall({ tool: "read", callID: "call-symlink" }, { args: {} });
  broker.recordToolCall({ tool: "read", callID: "call-symlink-directory" }, { args: {} });

  for (const [id, callID, outputPath] of [
    ["permission-edit", "call-edit", regularOutput],
    ["permission-symlink", "call-symlink", linkedOutput],
    ["permission-symlink-directory", "call-symlink-directory", regularOutput],
  ]) {
    await broker.handleEvent(toolOutputPermissionEvent({
      id,
      callID,
      outputDir,
      outputPath,
    }));
  }

  assert.deepEqual(replies.map((reply) => reply.body.response), ["reject", "reject", "reject"]);
  const capture = JSON.parse(readFileSync(requestFile, "utf8"));
  assert.deepEqual(capture.requests.map((request) => request.tool), ["edit", "read"]);
  restoreWorkerEnvironment(previous);
  rmSync(root, { recursive: true, force: true });
});

test("headless permission event is sanitized, persisted, and rejected", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-permission-broker-"));
  const requestFile = join(root, "request.json");
  const blockerLog = join(root, "blockers.jsonl");
  const previous = preserveWorkerEnvironment();
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  process.env.WORKER_ISSUE_NUMBER = "123";
  process.env.WORKER_REPO_SLUG = "owner/repo";
  process.env.WORKER_SESSION_KEY = "issue-123";
  const replies = [];
  const broker = createPermissionBroker({
    client: { postSessionIdPermissionsPermissionId: async (value) => replies.push(value) },
    isHeadless: () => true,
    home: "/Users/example",
    blockerLogPath: blockerLog,
  });
  broker.recordToolCall(
    { tool: "read", callID: "call-1" },
    { args: { agent__intent: "Reading SDK declarations token=secret-value" } },
  );
  await broker.handleEvent({ event: { type: "permission.asked", properties: {
    id: "permission-1",
    sessionID: "session-1",
    permission: "external_directory",
    patterns: ["/Users/example/.cache/opencode/node_modules/@opencode-ai/sdk/**"],
    tool: { callID: "call-1", messageID: "message-1" },
  } } });
  const capture = JSON.parse(readFileSync(requestFile, "utf8"));
  assert.equal(capture.issue, "123");
  assert.equal(capture.requests[0].tool, "read");
  assert.match(capture.requests[0].patterns[0], /^~\//);
  assert.doesNotMatch(capture.requests[0].intent, /secret-value/);
  assert.equal(replies[0].body.response, "reject");
  const blocker = JSON.parse(readFileSync(blockerLog, "utf8").trim());
  assert.equal(blocker.reason, "permission_required");
  assert.equal(blocker.blocking, true);
  assert.equal(blocker.issue_number, 123);
  assert.equal(blocker.repo_slug, "owner/repo");
  assert.equal(blocker.session_key, "issue-123");
  assert.doesNotMatch(blocker.detail, /secret-value/);
  restoreWorkerEnvironment(previous);
  rmSync(root, { recursive: true, force: true });
});

test("blocker events retain identity from an existing permission capture", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-permission-broker-"));
  const requestFile = join(root, "request.json");
  const blockerLog = join(root, "blockers.jsonl");
  const previous = preserveWorkerEnvironment();
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  delete process.env.WORKER_ISSUE_NUMBER;
  delete process.env.WORKER_REPO_SLUG;
  delete process.env.WORKER_SESSION_KEY;
  writeFileSync(requestFile, `${JSON.stringify({
    schema: "aidevops-permission-capture/v1",
    issue: "321",
    repo: "owner/repo",
    worker_session: "issue-321",
    requests: [],
  })}\n`);
  const broker = createPermissionBroker({
    client: {},
    isHeadless: () => true,
    home: "/Users/example",
    blockerLogPath: blockerLog,
  });
  await broker.permissionAsk({
    id: "permission-existing-capture",
    type: "external_directory",
    pattern: "/Users/example/.cache/opencode/tool/**",
  }, { status: "ask" });
  const blocker = JSON.parse(readFileSync(blockerLog, "utf8").trim());
  assert.equal(blocker.issue_number, 321);
  assert.equal(blocker.repo_slug, "owner/repo");
  assert.equal(blocker.session_key, "issue-321");
  restoreWorkerEnvironment(previous);
  rmSync(root, { recursive: true, force: true });
});

test("sensitive locations are non-grantable", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-permission-broker-"));
  const requestFile = join(root, "request.json");
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  const blockerLog = join(root, "blockers.jsonl");
  const broker = createPermissionBroker({ client: {}, isHeadless: () => true, home: "/Users/example", blockerLogPath: blockerLog });
  const output = { status: "ask" };
  await broker.permissionAsk({
    id: "permission-2",
    type: "external_directory",
    pattern: "/Users/example/.ssh/**",
  }, output);
  const capture = JSON.parse(readFileSync(requestFile, "utf8"));
  assert.equal(output.status, "deny");
  assert.equal(capture.requests[0].risk.grantable, false);
  assert.equal(JSON.parse(readFileSync(blockerLog, "utf8").trim()).reason, "permission_non_grantable");
  rmSync(root, { recursive: true, force: true });
  delete process.env.AIDEVOPS_PERMISSION_REQUEST_FILE;
});

test("requests without an exact pattern are non-grantable", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-permission-broker-"));
  const requestFile = join(root, "request.json");
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  const broker = createPermissionBroker({ client: {}, isHeadless: () => true, home: "/Users/example", blockerLogPath: join(root, "blockers.jsonl") });
  const output = { status: "ask" };
  await broker.permissionAsk({ id: "permission-3", type: "bash", patterns: [] }, output);
  const capture = JSON.parse(readFileSync(requestFile, "utf8"));
  assert.equal(capture.requests[0].risk.grantable, false);
  assert.match(capture.requests[0].risk.reason, /exact permission pattern/);
  rmSync(root, { recursive: true, force: true });
  delete process.env.AIDEVOPS_PERMISSION_REQUEST_FILE;
});

test("action-only permissions are non-grantable", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-permission-broker-"));
  const requestFile = join(root, "request.json");
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  const broker = createPermissionBroker({ client: {}, isHeadless: () => true, home: "/Users/example", blockerLogPath: join(root, "blockers.jsonl") });
  await broker.permissionAsk({ id: "permission-4", type: "webfetch", patterns: ["example.invalid"] }, { status: "ask" });
  const capture = JSON.parse(readFileSync(requestFile, "utf8"));
  assert.equal(capture.requests[0].risk.grantable, false);
  assert.match(capture.requests[0].risk.reason, /exact OpenCode pattern rule/);
  rmSync(root, { recursive: true, force: true });
  delete process.env.AIDEVOPS_PERMISSION_REQUEST_FILE;
});

test("doom_loop passes only designed bounded-operation polls (GH#39048)", async (t) => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-permission-broker-"));
  const previous = preserveWorkerEnvironment();
  t.after(() => { restoreWorkerEnvironment(previous); rmSync(root, { recursive: true, force: true }); });
  const requestFile = join(root, "request.json");
  const blockerLog = join(root, "blockers.jsonl");
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = requestFile;
  const replies = [];
  const broker = createPermissionBroker({
    client: { postSessionIdPermissionsPermissionId: async (value) => replies.push(value) },
    isHeadless: () => true, home: root, blockerLogPath: blockerLog,
  });
  const doomLoop = (id, tool, input) => ({
    id, sessionID: "worker", permission: "doom_loop", patterns: [tool], always: [tool], metadata: { tool, input },
  });
  const poll = { action: "status", operation_id: "op_1", wait_seconds: 60 };

  for (const [id, input] of [["status", poll], ["output", { action: "output", operation_id: "op_1" }]]) {
    await broker.handleEvent({ event: { type: "permission.asked", properties: doomLoop(id, "aidevops_bounded_operation", input) } });
    const output = { status: "ask" };
    broker.permissionAsk(doomLoop(`${id}-hook`, "aidevops_bounded_operation", input), output);
    assert.equal(output.status, "allow");
  }
  const legacy = { status: "ask" };
  broker.permissionAsk({ id: "legacy", type: "doom_loop", pattern: "aidevops_bounded_operation", metadata: { input: poll } }, legacy);
  assert.equal(legacy.status, "allow");
  assert.deepEqual(replies.map((reply) => reply.body.response), ["once", "once"]);
  assert.equal(existsSync(requestFile), false);
  const allowed = readFileSync(blockerLog, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  assert.ok(allowed.every((event) => event.event === "permission_designed_poll_allowed" && event.blocking === false));

  for (const [id, tool, input] of [
    ["start", "aidevops_bounded_operation", { action: "start", command: ["true"] }],
    ["cancel", "aidevops_bounded_operation", { action: "cancel", operation_id: "op_1" }],
    ["bash", "bash", { command: "sleep 60" }],
  ]) {
    await broker.handleEvent({ event: { type: "permission.asked", properties: doomLoop(id, tool, input) } });
    const output = { status: "ask" };
    broker.permissionAsk(doomLoop(`${id}-hook`, tool, input), output);
    assert.equal(output.status, "deny");
  }
  assert.deepEqual(replies.slice(2).map((reply) => reply.body.response), ["reject", "reject", "reject"]);
  // start/cancel share one stable request ID (same permission, pattern, tool).
  const capture = JSON.parse(readFileSync(requestFile, "utf8"));
  assert.deepEqual(capture.requests.map((request) => request.tool).sort(), ["aidevops_bounded_operation", "bash"]);
  assert.ok(capture.requests.every((request) => request.permission === "doom_loop" && request.risk.grantable === false));

  const interactive = createPermissionBroker({ client: {}, isHeadless: () => false, home: root, blockerLogPath: blockerLog });
  const untouched = { status: "ask" };
  interactive.permissionAsk(doomLoop("interactive", "aidevops_bounded_operation", poll), untouched);
  assert.equal(untouched.status, "ask");
});

test("capture write failure still denies the permission without crashing", async () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-permission-broker-"));
  const blocker = join(root, "not-a-directory");
  writeFileSync(blocker, "block");
  process.env.AIDEVOPS_PERMISSION_REQUEST_FILE = join(blocker, "request.json");
  const blockerLog = join(root, "blockers.jsonl");
  const broker = createPermissionBroker({ client: {}, isHeadless: () => true, home: "/Users/example", blockerLogPath: blockerLog });
  const output = { status: "ask" };
  await broker.permissionAsk({ id: "permission-5", type: "bash", patterns: ["git status"] }, output);
  assert.equal(output.status, "deny");
  assert.equal(JSON.parse(readFileSync(blockerLog, "utf8").trim()).reason, "capture_file_write_failed");
  rmSync(root, { recursive: true, force: true });
  delete process.env.AIDEVOPS_PERMISSION_REQUEST_FILE;
});

test("sanitizer normalizes home and redacts credential-like values", () => {
  const value = sanitizePermissionText("/Users/example/file token=abc123", { home: "/Users/example" });
  assert.equal(value, "~/file token=[REDACTED]");
});
