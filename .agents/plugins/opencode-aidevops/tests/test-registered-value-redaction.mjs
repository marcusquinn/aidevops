// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
//
// GH#32362 regression tests: exact registered secret values injected into a
// provider command line must be redacted from process-list tool output before
// persistence and model delivery. Synthetic markers only.
//
//   node --test .agents/plugins/opencode-aidevops/tests/test-registered-value-redaction.mjs

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, describe, test } from "node:test";
import { fileURLToPath } from "node:url";

import { BoundedInteractiveOperationManager } from "../bounded-interactive-operation.mjs";
import { createQualityHooks } from "../quality-hooks.mjs";
import { createSecretValueRedactor, SECRET_VALUE_REDACTION_TOKEN } from "../registered-value-redaction.mjs";

const TOKEN = SECRET_VALUE_REDACTION_TOKEN;
const REGISTRY_HELPER = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "scripts", "redaction-digest-registry.py");
const roots = [];

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

function marker(label) {
  return `synthetic${label}${randomBytes(10).toString("hex")}`;
}

function fixture({ credentials = {}, registered = [], env = {} } = {}) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "aidevops-registered-secret-")));
  roots.push(root);
  const configDir = join(root, "config");
  const registryDir = join(root, "registry");
  mkdirSync(configDir, { recursive: true, mode: 0o700 });
  const lines = Object.entries(credentials).map(([name, value]) => `export ${name}="${value}"`);
  if (lines.length > 0) writeFileSync(join(configDir, "credentials.sh"), `${lines.join("\n")}\n`, { mode: 0o600 });
  if (registered.length > 0) {
    const records = registered.map((value, index) => `SYNTHETIC_INJECTED_${index}=${value}\0`).join("");
    execFileSync("python3", [REGISTRY_HELPER, "register"], {
      input: records,
      env: { ...process.env, AIDEVOPS_SECRET_REDACTION_DIR: registryDir },
    });
  }
  const redactor = createSecretValueRedactor({ home: root, configDir, registryDir, env });
  return { root, redactor };
}

async function afterHook(redactor, root, output, tool = "bash") {
  const hooks = createQualityHooks({ scriptsDir: root, logsDir: root, secretRedactor: redactor });
  await hooks.toolExecuteAfter({ tool, callID: "" }, output);
  return output;
}

async function processListing(args) {
  const child = spawn(process.execPath, ["-e", "setTimeout(() => {}, 10000)", "--", ...args], { stdio: "ignore" });
  await new Promise((resolve, reject) => {
    child.once("spawn", resolve);
    child.once("error", reject);
  });
  try {
    return execFileSync("ps", ["-ax", "-o", "pid=,etime=,command="], { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  } finally {
    child.kill("SIGKILL");
  }
}

describe("registered secret value redaction (GH#32362)", () => {
  test("process listing redacts a credential-file value inside a provider command line", async () => {
    const secret = marker("Cred");
    const ordinary = marker("Ordinary");
    const { root, redactor } = fixture({ credentials: { SYNTHETIC_PROVIDER_AUTH: secret } });
    const raw = await processListing([`--provider-auth=${secret}`, "--ordinary-flag", ordinary]);
    assert.ok(raw.includes(secret), "reproducer: raw process listing exposes the argv value");

    const output = await afterHook(redactor, root, {
      output: raw,
      title: `ps -ax -o pid=,etime=,command= # ${secret}`,
      metadata: { output: raw.slice(0, 30000), description: "list processes" },
    });
    for (const text of [output.output, output.title, output.metadata.output]) {
      assert.equal(text.includes(secret), false);
    }
    assert.ok(output.output.includes(`--provider-auth=${TOKEN}`));
    assert.ok(output.output.includes(`--ordinary-flag ${ordinary}`), "ordinary argv stays readable");
  });

  test("process listing redacts a digest-registered value without plaintext knowledge", async () => {
    const secret = `${marker("Inject")}-._~=`;
    const { root, redactor } = fixture({ registered: [secret] });
    const raw = await processListing(["--api", `https://user:${secret}@example.invalid/v1`, "--key", secret]);
    assert.ok(raw.includes(secret));

    const output = await afterHook(redactor, root, { output: raw, title: "", metadata: {} });
    assert.equal(output.output.includes(secret), false);
    assert.ok(output.output.includes(`https://user:${TOKEN}@example.invalid/v1`));
    assert.ok(output.output.includes(`--key ${TOKEN}`));
  });

  test("environment values under registered or sensitive names are redacted", () => {
    const registeredName = marker("Env");
    const sensitive = marker("Sensitive");
    const unrelated = marker("Unrelated");
    const { redactor } = fixture({
      credentials: { SYNTHETIC_ENV_BACKED: "placeholder-not-used-here" },
      env: { SYNTHETIC_ENV_BACKED: registeredName, SYNTHETIC_API_TOKEN: sensitive, SYNTHETIC_HOME_DIR: unrelated },
    });
    const { text, count } = redactor.redactText(`a ${registeredName} b ${sensitive} c ${unrelated}`);
    assert.equal(text, `a ${TOKEN} b ${TOKEN} c ${unrelated}`);
    assert.equal(count, 2);
  });

  test("longer secret sharing a registered prefix is redacted whole (plaintext and digest)", () => {
    const short = marker("Prefix");
    const long = `${short}-longer-tail`;
    const plain = fixture({ credentials: { SYNTHETIC_SHORT: short, SYNTHETIC_LONG: long } });
    assert.equal(plain.redactor.redactText(`x ${long} y ${short} z`).text, `x ${TOKEN} y ${TOKEN} z`);

    const digest = fixture({ registered: [short, long] });
    assert.equal(digest.redactor.redactText(`x --a=${long} y --b=${short} z`).text, `x --a=${TOKEN} y --b=${TOKEN} z`);
  });

  test("short and placeholder values never redact ordinary output", () => {
    const { redactor } = fixture({ credentials: { SYNTHETIC_SHORT: "true", SYNTHETIC_EMPTY: "", SYNTHETIC_NONE: "none" } });
    const text = "ok true none status 1234";
    assert.deepEqual(redactor.redactText(text), { text, count: 0 });
  });

  test("bounded operation redacts a value split across output chunks before storage", async () => {
    const secret = marker("Chunk");
    const { root, redactor } = fixture({ registered: [secret] });
    const recorded = [];
    const manager = new BoundedInteractiveOperationManager({
      projectRoot: root,
      killGraceMs: 10,
      secretRedactor: redactor,
      recordOutput: async (content) => {
        recorded.push(String(content));
        return "out_fixture";
      },
    });
    try {
      const half = Math.floor(secret.length / 2);
      const script = `process.stdout.write(${JSON.stringify(`provider --auth ${secret.slice(0, half)}`)});`
        + `setTimeout(() => { process.stdout.write(${JSON.stringify(`${secret.slice(half)} ready\n`)}); process.exit(0); }, 60);`;
      await manager.start({ command: [process.execPath, "-e", script], cwd: root, budgetMs: 5000 }, { sessionID: "ses_fixture" });
      const deadline = Date.now() + 5000;
      while (recorded.length === 0 && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
      assert.equal(recorded.length, 1);
      assert.equal(recorded[0], `provider --auth ${TOKEN} ready\n`);
    } finally {
      manager.dispose();
    }
  });
});
