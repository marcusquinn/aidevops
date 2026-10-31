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
function combinations(...dimensions) {
  return dimensions.reduce((rows, values) => rows.flatMap((row) =>
    values.map((value) => [...row, value])), [[]]);
}

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

test("local-provider override (GH#35723) is refused to write, patch and shell tools, even when absent", (t) => {
  const f = fixture(t);
  const providers = join(dirname(f.file), "local-ai-providers.conf");
  assert.equal(f.classification.providersFile, providers);
  for (const bound of [false, true]) {
    const check = (tool, args) => assertPrivateProcessingRead({ tool, args, classification: f.classification,
      binding: { bound }, repositoryDir: f.publicRoot, append: () => true });
    assert.throws(() => check("write", { filePath: providers }), /classification_mutation/);
    assert.throws(() => check("edit", { filePath: "local-ai-providers.conf", cwd: dirname(providers) }), /classification_mutation/);
    assert.throws(() => check("apply_patch", { cwd: dirname(providers),
      patchText: "*** Begin Patch\n*** Add File: local-ai-providers.conf\n+openai\n*** End Patch" }), /classification_mutation/);
    assert.throws(() => check("bash", { command: `printf openai > '${providers}'` }), /classification_mutation/);
    assert.throws(() => check("aidevops_bounded_operation", { action: "start", command: ["cp", "x", providers] }), /classification_mutation/);
    assert.doesNotThrow(() => check("write", { filePath: join(f.publicRoot, "local-ai-providers.conf") }));
  }
  const xdg = join(f.home, "xdg");
  assert.equal(loadPrivateProcessingPolicy({ HOME: f.home, XDG_CONFIG_HOME: xdg }).providersFile,
    join(xdg, "aidevops/local-ai-providers.conf"));
});

test("shell config operands resolve relative and symlink aliases before policy exemptions", (t) => {
  const f = fixture(t);
  const configDir = dirname(f.file);
  symlinkSync(configDir, join(f.publicRoot, "config-alias"));
  // Keep file/existence order so absent overrides are checked before creation.
  for (const [file, exists, bound, roots] of combinations(
    [f.file, f.classification.providersFile], [false, true],
    [false, true], [f.classification.roots, []],
  )) {
    const name = file.slice(configDir.length + 1);
    // Canonical resolution must work both before and after the override exists.
    if (exists) writeFileSync(file, "synthetic config", { mode: 0o600 });
    const check = (tool, args) => assertPrivateProcessingRead({ tool, args,
      classification: { ...f.classification, roots }, binding: { bound },
      repositoryDir: f.publicRoot, append: () => true });
    for (const command of [`cat ${name}`, `cat './${name}'`, ["cat", name]]) {
      const tool = Array.isArray(command) ? "aidevops_bounded_operation" : "bash";
      assert.throws(() => check(tool, { command, action: "start", workdir: configDir }), /classification_mutation/);
    }
    assert.throws(() => check("bash", { command: `cat config-alias/${name}` }), /classification_mutation/);
    assert.throws(() => check("bash", { command: `cat ../.config/aidevops/${name}` }), /classification_mutation/);
    for (const operand of [`config-alias/../aidevops/${name}`, `${f.publicRoot}/config-alias/../aidevops/${name}`]) {
      assert.throws(() => check("bash", { command: `cat ${operand}` }), /classification_mutation/);
      assert.throws(() => check("aidevops_bounded_operation", {
        action: "start", command: ["cat", operand],
      }), /classification_mutation/);
    }
    for (const command of [`cat ${name}; true`, `cat config-alias/${name} | wc`]) {
      assert.throws(() => check("bash", { command, workdir: configDir }), /unclassifiable_shell_read/);
    }
    for (const [shell, option] of combinations(
      ["sh", "/bin/bash", "dash", "ash", "zsh", "ksh", "mksh", "fish", "csh", "tcsh"], ["-c", "-lc"],
    )) {
      const script = `cat ../.config/aidevops/${name}`;
      assert.throws(() => check("bash", { command: `${shell} ${option} '${script}'` }), /unclassifiable_shell_read/);
      assert.throws(() => check("aidevops_bounded_operation", {
        action: "start", command: [shell, option, script],
      }), /unclassifiable_shell_read/);
    }
    assert.doesNotThrow(() => check("bash", { command: `cat ${name}` }), "same basename outside config remains allowed");
    assert.doesNotThrow(() => check("bash", { command: "cat ../public/plain.txt" }), "ordinary parent traversal remains allowed");
  }
});

test("interpreter scripts naming operator config fail closed before bound-session and empty-roots exemptions", (t) => {
  const f = fixture(t);
  for (const [bound, roots, name, [shell, option]] of combinations(
    [false, true], [f.classification.roots, []],
    ["local-only-roots.json", "local-ai-providers.conf"],
    [["sh", "-c"], ["/bin/bash", "-lc"], ["dash", "-ec"], ["fish", "--command"]],
  )) {
    const script = `cat ../.config/aidevops/${name}`;
    const check = (tool, command) => assertPrivateProcessingRead({
      tool, args: { action: "start", command }, repositoryDir: f.publicRoot,
      classification: { ...f.classification, roots }, binding: { bound }, append: () => true,
    });
    assert.throws(() => check("bash", `${shell} ${option} '${script}'`), /unclassifiable_shell_read/);
    assert.throws(() => check("aidevops_bounded_operation", [shell, option, script]), /unclassifiable_shell_read/);
  }
});

test("GH#36017: ordinary compound commands and scripts pass outside classified unbound sessions", (t) => {
  const f = fixture(t);
  for (const [bound, roots] of [[true, f.classification.roots], [true, []], [false, []]]) {
    const check = (tool, command) => assertPrivateProcessingRead({
      tool, args: { action: "start", command }, repositoryDir: f.publicRoot,
      classification: { ...f.classification, roots }, binding: { bound }, append: () => true,
    });
    for (const command of ["git status && git log -1 | head -5", "rg foo $DIR", "ls *.md; true",
      "sh -c 'git status'", "pwd\ngit status"]) {
      assert.doesNotThrow(() => check("bash", command), command);
    }
    assert.doesNotThrow(() => check("aidevops_bounded_operation", ["bash", "-lc", "pnpm test"]));
    // Differently-cased config names stay denied in opaque text.
    assert.throws(() => check("bash", "cat LOCAL-ONLY-ROOTS.JSON | wc"), /unclassifiable_shell_read/);
  }
  // Classified unbound sessions keep the strict literal-reader path.
  const strict = (command) => assertPrivateProcessingRead({ tool: "bash", args: { command },
    repositoryDir: f.publicRoot, classification: f.classification, binding: { bound: false }, append: () => true });
  assert.throws(() => strict("git status && git log -1 | head -5"), /unclassifiable_shell_read/);
  assert.throws(() => strict("sh -c 'git status'"), /unclassifiable_shell_read/);
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
