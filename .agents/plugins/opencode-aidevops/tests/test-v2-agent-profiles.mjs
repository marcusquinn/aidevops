// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  loadV2PrimaryProfiles,
  registerV2ManagedDirectoryPermissions,
  registerV2PrimaryProfiles,
} from "../v2-agent-profiles.mjs";

function editor(initial = []) {
  const agents = new Map(initial.map((agent) => [agent.id, agent]));
  let selected;
  return {
    agents,
    get selected() { return selected; },
    get: (id) => agents.get(id),
    list: () => [...agents.values()],
    update(id, change) {
      if (!agents.has(id)) agents.set(id, { id, mode: "primary", hidden: false, permissions: [] });
      change(agents.get(id));
    },
    default(id) { selected = id; },
    remove(id) { agents.delete(id); },
  };
}

test("V2 and V1 derive all main agents from the same index and canonical prompt files", () => {
  const root = new URL("../../../", import.meta.url).pathname;
  const profiles = loadV2PrimaryProfiles(root);
  assert.equal(profiles.length, 16);
  const build = profiles.find((profile) => profile.name === "Build+");
  assert.equal(build.system, readFileSync(join(root, "build-plus.md"), "utf8").trim());
  const target = editor([{ id: "build", mode: "primary", permissions: [] }]);
  assert.equal(registerV2PrimaryProfiles(target, profiles), true);
  assert.equal(target.selected, "Build+");
  assert.equal(target.get("build"), undefined);
  assert.equal(target.get("Build+").mode, "primary");
  assert.equal(target.agents.size, 16);
  assert.equal(target.get("PR").system, readFileSync(join(root, "pr.md"), "utf8").trim());
});

test("V2 preserves operator agents and restrictive canonical tool rules", () => {
  const root = mkdtempSync(join(process.env.AIDEVOPS_TEMP_DIR || tmpdir(), "v2-primary-"));
  try {
    writeFileSync(join(root, "subagent-index.toon"),
      "<!--TOON:agents[2]{name,file,purpose,model_tier,triggers}:\nBuild+,build-plus.md,Build,thinking,code\nReview,review.md,Review,standard,review\n-->");
    writeFileSync(join(root, "build-plus.md"), "---\ndescription: Build\n---\nCanonical Build");
    writeFileSync(join(root, "review.md"), "---\ntools:\n  bash: false\n  write: false\n---\nCanonical Review");
    const profiles = loadV2PrimaryProfiles(root);
    const custom = { id: "Review", mode: "primary", hidden: false, system: "Operator Review", permissions: [] };
    const target = editor([{ id: "build", mode: "primary", permissions: [] }, custom]);
    assert.equal(registerV2PrimaryProfiles(target, profiles), true);
    assert.equal(target.get("Review"), custom);
    const clean = editor();
    registerV2PrimaryProfiles(clean, profiles);
    assert.deepEqual(clean.get("Review").permissions, [
      { action: "shell", resource: "*", effect: "deny" },
      { action: "bash", resource: "*", effect: "deny" },
      { action: "edit", resource: "*", effect: "deny" },
    ]);
    const invalid = profiles.filter(({ name }) => name !== "Build+");
    const fallback = editor([{ id: "build", mode: "primary", permissions: [] }]);
    assert.equal(registerV2PrimaryProfiles(fallback, invalid), false);
    assert.ok(fallback.get("build"));
    assert.equal(fallback.selected, undefined);
    writeFileSync(join(root, "review.md"), "---\ntools:\n  shell: maybe\n---\nUnsafe");
    assert.deepEqual(loadV2PrimaryProfiles(root), []);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("V2 agents receive V1 managed external-directory allows after existing rules (GH#35170)", () => {
  const deny = { action: "*", resource: "*", effect: "deny" };
  const target = editor([
    { id: "Build+", permissions: [] },
    { id: "explore", permissions: [deny] },
  ]);
  const home = join(tmpdir(), "v2-managed-home");
  const env = { AIDEVOPS_WORKTREE_BASE_DIR: "/srv/worktrees" };
  assert.equal(registerV2ManagedDirectoryPermissions(target, env, home), 2);
  for (const id of ["Build+", "explore"]) {
    const rules = target.get(id).permissions.filter((rule) => rule.action === "external_directory");
    const resources = rules.map((rule) => rule.resource);
    assert.ok(rules.every((rule) => rule.effect === "allow"));
    assert.ok(resources.includes(join(home, ".aidevops/**")));
    assert.ok(resources.includes("/srv/worktrees/**"));
    assert.ok(resources.every((resource) => !resource.startsWith("~")));
  }
  assert.deepEqual(target.get("explore").permissions[0], deny);
});
