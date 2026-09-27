// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  loadModelRouting,
  nextRoutingTier,
  routingProfile,
  routingTierForModel,
  selectConnectedRoutingCandidate,
} from "../model-routing.mjs";
import { withUnambiguousProviderFallbacks } from "../model-routing-reasoning.mjs";
import {
  applyAgentRoutingProfile,
  registerAgentRoutingIntent,
} from "../config-agent-profiles.mjs";
import { applyCompactionRouting } from "../config-hook.mjs";

test("a model serving several tiers resolves by observed variant", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-model-routing-"));
  const table = join(root, "table.json");
  try {
    writeFileSync(table, JSON.stringify({
      tiers: {
        standard: { models: ["vendor/shared"], reasoning: { vendor: "low" } },
        thinking: { models: ["vendor/shared"], reasoning: { vendor: "medium" } },
      },
      escalation_order: ["simple", "standard", "thinking"],
    }));
    const routing = loadModelRouting([table]);
    assert.equal(routingTierForModel(routing, "vendor/shared"), "standard");
    assert.equal(routingTierForModel(routing, "vendor/shared", "low"), "standard");
    assert.equal(routingTierForModel(routing, "vendor/shared", "medium"), "thinking");
    assert.equal(routingTierForModel(routing, "vendor/shared", "xhigh"), "standard");
    assert.equal(routingTierForModel(routing, "vendor/other", "medium"), "");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("partial higher-precedence routing tables inherit unspecified framework tiers", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-model-routing-"));
  const framework = join(root, "framework.json");
  const custom = join(root, "custom.json");
  try {
    writeFileSync(framework, JSON.stringify({
      tiers: {
        simple: { models: ["vendor/simple"], reasoning: { vendor: "low" } },
        standard: { models: ["vendor/standard"], reasoning: { vendor: "medium" } },
        thinking: { models: ["vendor/thinking"], reasoning: { vendor: "high" } },
      },
      escalation_order: ["simple", "standard", "thinking"],
    }));
    writeFileSync(custom, JSON.stringify({
      tiers: {
        standard: { models: ["custom/standard"], reasoning: { custom: "max" } },
      },
    }));

    const routing = loadModelRouting([custom, framework]);
    assert.deepEqual(routingProfile(routing, "simple"), {
      tier: "simple", model: "vendor/simple", variant: "low",
    });
    assert.deepEqual(routingProfile(routing, "standard"), {
      tier: "standard", model: "custom/standard", variant: "max",
    });
    assert.deepEqual(routingProfile(routing, "thinking"), {
      tier: "thinking", model: "vendor/thinking", variant: "high",
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("an explicit empty model list disables only that tier", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-model-routing-empty-"));
  const framework = join(root, "framework.json");
  const custom = join(root, "custom.json");
  try {
    writeFileSync(framework, JSON.stringify({ tiers: {
      simple: { models: ["vendor/simple"] },
      standard: { models: ["vendor/standard"] },
    } }));
    writeFileSync(custom, JSON.stringify({ tiers: { simple: { models: [] } } }));
    const routing = loadModelRouting([custom, framework]);
    assert.equal(routingProfile(routing, "simple").model, "");
    assert.equal(routingProfile(routing, "standard").model, "vendor/standard");
    assert.equal(nextRoutingTier(routing, "simple"), "standard");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("capability escalation skips an explicitly disabled tier", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-model-routing-skip-"));
  const framework = join(root, "framework.json");
  const custom = join(root, "custom.json");
  try {
    writeFileSync(framework, JSON.stringify({ tiers: {
      simple: { models: ["vendor/simple"] },
      standard: { models: ["vendor/standard"] },
      thinking: { models: ["vendor/thinking"] },
    } }));
    writeFileSync(custom, JSON.stringify({ tiers: { standard: { models: [] } } }));
    const routing = loadModelRouting([custom, framework]);
    assert.equal(nextRoutingTier(routing, "simple"), "thinking");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("an explicit empty reasoning value clears the framework variant", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-model-routing-variant-"));
  const framework = join(root, "framework.json");
  const custom = join(root, "custom.json");
  try {
    writeFileSync(framework, JSON.stringify({ tiers: {
      standard: {
        models: ["vendor/standard"],
        reasoning: { "vendor/standard": "high" },
      },
    } }));
    writeFileSync(custom, JSON.stringify({ tiers: {
      standard: { reasoning: { "vendor/standard": "" } },
    } }));
    const routing = loadModelRouting([custom, framework]);
    assert.equal(routingProfile(routing, "standard").variant, "");

    const routed = { model: "standard" };
    assert.equal(applyAgentRoutingProfile(routed, "standard", routing), true);
    assert.deepEqual(routed, {});

    const pinned = { model: "other/pinned", variant: "native" };
    assert.equal(applyAgentRoutingProfile(pinned, "standard", routing), false);
    assert.deepEqual(pinned, { model: "other/pinned", variant: "native" });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("connected provider state selects the first usable same-tier candidate", () => {
  const routing = {
    tiers: {
      simple: { models: [] },
      standard: { models: ["openai/primary", "anthropic/fallback"] },
      thinking: { models: [] },
    },
  };
  const providerState = {
    connected: ["anthropic"],
    all: [
      { id: "openai", models: { primary: { id: "primary" } } },
      { id: "anthropic", models: { fallback: { id: "fallback" } } },
    ],
  };

  assert.equal(
    selectConnectedRoutingCandidate(routing, "standard", providerState),
    "anthropic/fallback",
  );
});

test("conversation routing derives only unambiguous provider fallbacks", () => {
  assert.deepEqual(
    withUnambiguousProviderFallbacks({"openai/model-a": "high"}),
    {"openai/model-a": "high", openai: "high"},
  );
  const ambiguous = withUnambiguousProviderFallbacks({
    "openai/model-a": "high",
    "openai/model-b": "max",
  });
  assert.equal(Object.hasOwn(ambiguous, "openai"), false);
});

test("agent routing metadata defers tier selection while preserving explicit model pins", () => {
  const routing = {
    tiers: {
      simple: { models: [] },
      standard: { models: ["vendor/standard"] },
      thinking: { models: [] },
    },
  };
  const state = { tiers: new Map(), pinned: new Set() };
  const routed = { aidevops_model_tier: "standard" };
  assert.equal(registerAgentRoutingIntent(state, "general", routed, "simple", routing), true);
  assert.equal(state.tiers.get("general"), "standard");
  assert.deepEqual(routed, {});

  const pinned = { model: "other/pinned", aidevops_model_tier: "thinking" };
  assert.equal(registerAgentRoutingIntent(state, "custom", pinned, "standard", routing), false);
  assert.equal(state.pinned.has("custom"), true);
  assert.deepEqual(pinned, { model: "other/pinned" });
});

test("compaction uses the simple route only when its input budget fits the managed target", () => {
  const routing = { tiers: { simple: { models: ["openai/gpt-6-luna"], reasoning: { openai: "low" } } } };
  const config = { provider: { openai: { models: {
    "gpt-6-luna": { limit: { input: 260000, output: 128000, context: 388000 } },
  } } } };
  assert.equal(applyCompactionRouting(config, routing), true);
  assert.deepEqual(config.agent.compaction, { model: "openai/gpt-6-luna", variant: "low" });

  const tooSmall = { provider: { openai: { models: {
    "gpt-6-luna": { limit: { input: 239999 } },
  } } } };
  assert.equal(applyCompactionRouting(tooSmall, routing), false);
  assert.deepEqual(tooSmall.agent.compaction, {});
});

test("compaction preserves explicit user model and variant pins", () => {
  const routing = { tiers: { simple: { models: ["openai/gpt-6-luna"] } } };
  const config = { agent: { compaction: { model: "anthropic/pinned", variant: "high" } } };
  assert.equal(applyCompactionRouting(config, routing), false);
  assert.deepEqual(config.agent.compaction, { model: "anthropic/pinned", variant: "high" });
});
