// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import assert from "node:assert/strict";
import test from "node:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { assertPrivateProcessingRead, loadPrivateProcessingPolicy, recordPrivateBlocker } from "../private-processing-policy.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../../..");
const SENTINEL = "synthetic-private-sentinel-34146";
function fixture(t) {
  const home = mkdtempSync(join(tmpdir(), "private-policy-"));
  t.after(() => rmSync(home, { recursive: true, force: true }));
  const configDir = join(home, ".config/aidevops");
  const protectedRoot = join(home, "classified");
  const publicRoot = join(home, "public");
  for (const dir of [configDir, protectedRoot, publicRoot]) mkdirSync(dir, { recursive: true });
  const file = join(configDir, "local-only-roots.json");
  const secret = join(protectedRoot, "synthetic.txt");
  writeFileSync(file, JSON.stringify({ roots: [protectedRoot] }), { mode: 0o600 });
  writeFileSync(secret, SENTINEL);
  writeFileSync(join(publicRoot, "plain.txt"), "public");
  return { home, file, secret, protectedRoot, publicRoot,
    classification: loadPrivateProcessingPolicy({ HOME: home }) };
}

test("operator classification is frozen; missing is no-op, malformed or insecure fails closed", (t) => {
  const f = fixture(t);
  assert.ok(Object.isFrozen(f.classification.roots));
  assert.equal(loadPrivateProcessingPolicy({ HOME: f.publicRoot }).invalid, false);
  chmodSync(f.file, 0o644);
  assert.equal(loadPrivateProcessingPolicy({ HOME: f.home }).invalid, true);
  chmodSync(f.file, 0o600);
  writeFileSync(f.file, "invalid");
  assert.equal(loadPrivateProcessingPolicy({ HOME: f.home }).invalid, true);
  assert.equal(f.classification.invalid, false, "snapshot cannot be changed by later writes");
});

test("unbound native and shell reads deny before execution; bound and public reads pass", (t) => {
  const f = fixture(t);
  const receipts = [];
  const check = (tool, args, bound = false) => assertPrivateProcessingRead({ tool, args,
    classification: f.classification, binding: { bound }, repositoryDir: f.publicRoot,
    sessionID: "ses_test", append: (event) => { receipts.push(event); return true; } });
  for (const tool of ["Read", "grep", "glob", "list"]) {
    assert.throws(() => check(tool, { path: f.secret }), /VAULT_POLICY_DENIED/);
    assert.doesNotThrow(() => check(tool, { path: f.secret }, true));
    assert.doesNotThrow(() => check(tool, { path: join(f.publicRoot, "plain.txt") }));
  }
  assert.throws(() => check("bash", { command: `cat '${f.secret}'` }), /protected_read/);
  assert.throws(() => check("aidevops_bounded_operation", { action: "start", command: ["cat", f.secret] }), /protected_read/);
  assert.doesNotThrow(() => check("bash", { command: "cat plain.txt" }));
  assert.doesNotThrow(() => check("bash", { command: `cat '${f.secret}'` }, true));
  assert.doesNotMatch(JSON.stringify(receipts), new RegExp(`${SENTINEL}|synthetic.txt|classified`));
});

test("aliases, ancestors, relative paths, option execution and quote concatenation fail closed", (t) => {
  const f = fixture(t);
  symlinkSync(f.protectedRoot, join(f.publicRoot, "alias"));
  const check = (tool, args) => assertPrivateProcessingRead({ tool, args, classification: f.classification,
    binding: { bound: false }, repositoryDir: f.publicRoot, append: () => true });
  for (const path of ["alias/synthetic.txt", "../classified/synthetic.txt", "../classified/..named", f.home]) {
    assert.throws(() => check("read", { path }), /protected_read/);
  }
  for (const command of ["cat '../class''ified/synthetic.txt'", "rg --pre=reader plain.txt",
    "cat $FILE", "python reader.py", "cat plain.txt | sh", "cat 'unterminated",
    "pwd\npython /public/reader.py", "pwd\r\npython /public/reader.py"]) {
    assert.throws(() => check("bash", { command }), /unclassifiable_shell_read/);
  }
  assert.throws(() => check("write", { filePath: "local-only-roots.json", cwd: dirname(f.file) }), /classification_mutation/);
  assert.throws(() => check("apply_patch", { cwd: dirname(f.file), patchText: "*** Begin Patch\n*** Delete File: local-only-roots.json\n*** End Patch" }), /classification_mutation/);
  assert.throws(() => check("read", { path: f.secret, append: () => { throw new Error(SENTINEL); } }), /VAULT_POLICY_DENIED/);
});

test("receipt failure cannot obscure a denial or import ambient metadata", () => {
  let captured;
  recordPrivateBlocker("bad-session", "protected_read", "read", (event) => { captured = event; return true; });
  assert.equal(captured.session_key, "ses_unknown");
  assert.equal(captured.repo_slug, "none");
  assert.equal(captured.request_id, "none");
  assert.equal(recordPrivateBlocker("ses_test", "protected_read", "read", () => { throw new Error(SENTINEL); }), false);
  assert.throws(() => assertPrivateProcessingRead({ tool: "read", args: { path: "/classified/file" },
    classification: { file: "/operator/config", roots: ["/classified"] }, binding: { bound: false },
    append: () => { throw new Error(SENTINEL); } }), /VAULT_POLICY_DENIED.*receipt unavailable/);
});

test("real plugin factory: Read, Grep and Bash deny before synthetic content reaches the caller", (t) => {
  const f = fixture(t);
  const plugin = pathToFileURL(join(ROOT, ".agents/plugins/opencode-aidevops/index.mjs")).href;
  const script = `
    const [url, root, secret, plain, bound] = process.argv.slice(1);
    const fs = await import('node:fs');
    const { AidevopsPlugin } = await import(url);
    const hooks = await AidevopsPlugin({ directory: root, client: {} });
    process.env.AIDEVOPS_RUNTIME_POLICY = bound === 'yes' ? '' : 'local-only';
    const results = [];
    for (const tool of ['read', 'grep', 'bash']) {
      const args = tool === 'bash' ? { command: 'cat ' + secret, workdir: plain }
        : tool === 'read' ? { filePath: secret } : { path: secret, pattern: 'synthetic' };
      try {
        await hooks['tool.execute.before']({ tool, sessionID: 'ses_synthetic', callID: tool }, { args });
        results.push({ tool, content: fs.readFileSync(secret, 'utf8') });
      } catch (error) { results.push({ tool, denial: error.message }); }
    }
    process.stdout.write(JSON.stringify(results)); process.exit(0);`;
  for (const bound of [false, true]) {
    const result = spawnSync(process.execPath, ["--input-type=module", "-e", script, plugin, ROOT, f.secret, f.publicRoot, bound ? "yes" : "no"], {
      cwd: ROOT, encoding: "utf8", timeout: 60000,
      env: { PATH: process.env.PATH, HOME: f.home, AIDEVOPS_HEADLESS: "1", AIDEVOPS_RUNTIME_POLICY: bound ? "local-only" : "" },
    });
    assert.equal(result.status, 0, result.stderr);
    const results = JSON.parse(result.stdout);
    if (!bound) {
      for (const entry of results) assert.match(entry.denial, /VAULT_POLICY_DENIED/);
      assert.doesNotMatch(result.stdout, new RegExp(`${SENTINEL}|synthetic.txt`));
    } else {
      // The existing Grep file-path gate remains independent of transfer policy.
      assert.equal(results[0].content, SENTINEL);
      // Bash cat may still be refused by the existing dedicated-file-tool gate.
      assert.doesNotMatch(results[2].denial || "", /VAULT_POLICY_DENIED/);
    }
  }
  const log = readFileSync(join(f.home, ".aidevops/.agent-workspace/private-processing-blockers.jsonl"), "utf8");
  assert.doesNotMatch(log, new RegExp(`${SENTINEL}|synthetic.txt|classified`));
});
