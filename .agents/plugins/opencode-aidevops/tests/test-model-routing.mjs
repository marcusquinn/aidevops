// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  candidateRateLimitedUntil,
  loadModelRouting,
  mergeModelRouting,
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
import { applyCompactionEffort } from "../compaction-effort.mjs";
import {
  applyCompactionRouting,
  createCompactionCredentialCheck,
  createCompactionResidencyWarning,
  rerouteCompactionAfterRejection,
} from "../compaction-routing.mjs";
import { authSignatureFromHeaders, clearModelUnavailable, isModelUnavailable, markModelUnavailable } from "../model-unavailability.mjs";
import { poolRateLimitedUntil, rateLimitedProviders } from "../provider-rate-limits.mjs";

test("ChatGPT OAuth restrictions survive overlays and do not restrict API keys", () => {
  const shipped = loadModelRouting([new URL("../../../configs/model-routing-table.json", import.meta.url)]);
  const routing = mergeModelRouting(shipped, { tiers: { standard: { models: [
    "openai/gpt-6.1-sol", "anthropic/claude-sonnet-5-5",
  ] } } });
  const providerState = { connected: ["openai", "anthropic"], all: [
    { id: "openai", models: { "gpt-6.1-sol": { id: "gpt-6.1-sol" } } },
    { id: "anthropic", models: { "claude-sonnet-5-5": { id: "claude-sonnet-5-5" } } },
  ] };
  assert.ok(routing.chatgptOAuthUnsupported.includes("gpt-6-astra"));
  assert.equal(selectConnectedRoutingCandidate(routing, "standard", providerState, undefined,
    { openAIAuthType: "oauth" }), "anthropic/claude-sonnet-5-5");
  assert.equal(selectConnectedRoutingCandidate(routing, "standard", providerState, undefined,
    { openAIAuthType: "api" }), "openai/gpt-6.1-sol");
  const openAIOnly = { ...providerState, connected: ["openai"] };
  assert.equal(selectConnectedRoutingCandidate(routing, "standard", openAIOnly, undefined,
    { openAIAuthType: "oauth" }), "");
  const overridden = mergeModelRouting(routing, { chatgpt_oauth_restrictions: { openai_unsupported: [] } });
  assert.equal(selectConnectedRoutingCandidate(overridden, "standard", openAIOnly, undefined,
    { openAIAuthType: "oauth" }), "openai/gpt-6.1-sol");
});

test("a model serving several tiers resolves by observed variant", () => {
  const root = mkdtempSync(join(tmpdir(), "aidevops-model-routing-"));
  const table = join(root, "table.json");
  try {
    writeFileSync(table, JSON.stringify({
      tiers: {
        standard: { models: ["vendor/shared"], reasoning: { vendor: "low" } },
        thinking: { models: ["vendor/shared"], reasoning: { vendor: "high" } },
      },
      escalation_order: ["simple", "standard", "thinking"],
    }));
    const routing = loadModelRouting([table]);
    assert.equal(routingTierForModel(routing, "vendor/shared"), "standard");
    assert.equal(routingTierForModel(routing, "vendor/shared", "low"), "standard");
    assert.equal(routingTierForModel(routing, "vendor/shared", "medium"), "standard");
    assert.equal(routingTierForModel(routing, "vendor/shared", "high"), "thinking");
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
      tier: "simple", model: "vendor/simple", variant: "medium",
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

test("routing skips a model rejected for the active auth signature", () => {
  const routing = {
    tiers: {
      simple: { models: [] },
      standard: { models: ["openai/rejected", "openai/next"] },
      thinking: { models: [] },
    },
  };
  const providerState = {
    connected: ["openai"],
    all: [{ id: "openai", models: { rejected: { id: "rejected" }, next: { id: "next" } } }],
  };
  const signature = authSignatureFromHeaders(new Headers({ authorization: "Bearer synthetic", "chatgpt-account-id": "acct" }));
  const now = Date.now();
  markModelUnavailable("openai/rejected", signature, { ttlMs: 100, now });
  const otherSignature = authSignatureFromHeaders(new Headers({ authorization: "Bearer other", "chatgpt-account-id": "other" }));
  assert.equal(isModelUnavailable("openai/rejected"), false);
  assert.equal(selectConnectedRoutingCandidate(routing, "standard", providerState, undefined, { authSignature: otherSignature }), "openai/rejected");
  assert.equal(isModelUnavailable("openai/rejected", signature, now + 99), true);
  assert.equal(isModelUnavailable("openai/rejected", signature, now + 100), false);
  markModelUnavailable("openai/rejected", signature, { ttlMs: 100, now });
  assert.equal(
    selectConnectedRoutingCandidate(routing, "standard", providerState, undefined, { authSignature: signature }),
    "openai/next",
  );
  clearModelUnavailable("openai/rejected", signature);
  assert.equal(
    selectConnectedRoutingCandidate(routing, "standard", providerState, undefined, { authSignature: signature }),
    "openai/rejected",
  );
});

test("routing skips exhausted provider pools until reset (GH#37649)", () => {
  const routing = { tiers: { standard: { models: ["anthropic/sonnet", "openai/sol"] } } };
  const providerState = { connected: ["anthropic", "openai"], all: [
    { id: "anthropic", models: { sonnet: { id: "sonnet" } } },
    { id: "openai", models: { sol: { id: "sol" } } },
  ] };
  const select = (availability) => selectConnectedRoutingCandidate(routing, "standard", providerState, undefined, availability);
  const now = Date.now();

  assert.equal(select({ rateLimitedProviders: { anthropic: now + 60_000 } }), "openai/sol");
  assert.equal(select({ rateLimitedProviders: { anthropic: now - 1 } }), "anthropic/sonnet", "expired reset recovers");
  assert.equal(select({ rateLimitedProviders: { anthropic: now + 60_000, openai: now + 60_000 } }), "");
  assert.equal(candidateRateLimitedUntil("anthropic/sonnet", { rateLimitedProviders: { anthropic: now + 60_000 } }, now), now + 60_000);
  assert.equal(candidateRateLimitedUntil("openai/sol", { rateLimitedProviders: { anthropic: now + 60_000 } }, now), 0);
});

test("a provider pool is rate limited only when no account can serve and OAuth is active (GH#37649)", () => {
  const now = Date.now();
  const limited = (cooldownUntil) => ({ status: "rate-limited", cooldownUntil });
  assert.equal(poolRateLimitedUntil([], now), 0);
  assert.equal(poolRateLimitedUntil([limited(now + 5_000), { status: "active", cooldownUntil: null }], now), 0);
  assert.equal(poolRateLimitedUntil([limited(now + 5_000), limited(now + 2_000)], now), now + 2_000);
  assert.equal(poolRateLimitedUntil([limited(now + 5_000), { status: "auth-error", cooldownUntil: now + 9_000 }], now), now + 5_000);
  assert.equal(poolRateLimitedUntil([limited(now - 1)], now), 0, "expired cooldowns are routable");
  assert.equal(poolRateLimitedUntil([limited(now - 1), limited(now + 5_000)], now), 0, "one recovered account keeps the provider routable");
  assert.equal(poolRateLimitedUntil([{ status: "auth-error", cooldownUntil: now + 5_000 }], now), 0, "auth failures are a different class");

  const accounts = () => [limited(now + 5_000)];
  assert.deepEqual(rateLimitedProviders({
    now,
    readAuth: (provider) => (provider === "anthropic" ? { type: "oauth" } : { type: "api" }),
    readAccounts: accounts,
  }), { anthropic: now + 5_000 }, "API-key providers do not use the pool");
  assert.deepEqual(rateLimitedProviders({
    now,
    readAuth: () => ({ type: "oauth" }),
    readAccounts: () => { throw new Error("unreadable pool"); },
  }), {}, "an unreadable pool never blocks routing");
});

test("config-only providers without credentials are not routable (GH#35762)", () => {
  const routing = {
    tiers: {
      simple: { models: [] },
      standard: { models: ["openai/primary", "anthropic/fallback"] },
      thinking: { models: [] },
    },
  };
  const models = (id) => ({ [id]: { id } });
  const anthropic = { id: "anthropic", source: "config", key: "set", options: {}, models: models("fallback") };
  const state = (openai) => ({ connected: ["openai", "anthropic"], all: [openai, anthropic] });
  const configOnly = { id: "openai", source: "config", env: ["OPENAI_API_KEY"], options: {}, models: models("primary") };

  assert.equal(selectConnectedRoutingCandidate(routing, "standard", state(configOnly)), "anthropic/fallback");
  for (const credentialed of [
    { ...configOnly, key: "env-key" },
    { ...configOnly, options: { apiKey: "opencode-oauth-dummy-key" } },
    { ...configOnly, options: { baseURL: "http://127.0.0.1:11434/v1" } },
    { ...configOnly, source: "env" },
  ]) {
    assert.equal(selectConnectedRoutingCandidate(routing, "standard", state(credentialed)), "openai/primary");
  }
  assert.equal(
    selectConnectedRoutingCandidate(routing, "standard", { connected: ["openai"], all: [configOnly] }),
    "",
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

const credentialed = () => true;

test("compaction uses the simple route only when its input budget fits the managed target", () => {
  const routing = { tiers: { simple: { models: ["openai/gpt-6-luna"], reasoning: { openai: "low" } } } };
  const config = { provider: { openai: { models: {
    "gpt-6-luna": { limit: { input: 260000, output: 128000, context: 388000 } },
  } } } };
  assert.equal(applyCompactionRouting(config, routing, { hasCredentials: credentialed }), true);
  assert.deepEqual(config.agent.compaction, { model: "openai/gpt-6-luna", variant: "high" });

  const tooSmall = { provider: { openai: { models: {
    "gpt-6-luna": { limit: { input: 239999 } },
  } } } };
  assert.equal(applyCompactionRouting(tooSmall, routing, { hasCredentials: credentialed }), false);
  assert.deepEqual(tooSmall.agent.compaction, {});
});

test("compaction skips a too-small first simple candidate for the next that fits (GH#32934)", () => {
  const routing = { tiers: { simple: {
    models: ["anthropic/claude-haiku-4-5", "openai/gpt-6-luna"],
    reasoning: { "anthropic/claude-haiku-4-5": "high", "openai/gpt-6-luna": "medium" },
  } } };
  const config = { provider: {
    anthropic: { models: { "claude-haiku-4-5": { limit: { context: 200000, output: 32000 } } } },
    openai: { models: { "gpt-6-luna": { limit: { input: 260000, output: 128000, context: 388000 } } } },
  } };
  assert.equal(applyCompactionRouting(config, routing, { hasCredentials: credentialed }), true);
  assert.equal(config.agent.compaction.model, "openai/gpt-6-luna");
});

test("compaction without OpenAI credentials falls back to catalog Haiku 5.5, then the parent (GH#36169)", () => {
  const routing = { compactionReasoning: "xhigh", tiers: { simple: {
    models: ["openai/gpt-6-luna", "anthropic/claude-haiku-5-5"],
  } } };
  // The plugin always writes OpenAI limits; Haiku 5.5 exists only in the catalog.
  const config = () => ({ provider: { openai: { models: { "gpt-6-luna": { limit: { input: 260000 } } } } } });
  const env = {};
  const anthropicOnly = config();
  const check = createCompactionCredentialCheck(anthropicOnly, { env, authProviders: new Set(["anthropic"]), localProviders: [] });
  assert.equal(applyCompactionRouting(anthropicOnly, routing, { hasCredentials: check }), true);
  assert.deepEqual(anthropicOnly.agent.compaction, { model: "anthropic/claude-haiku-5-5", variant: "xhigh" });

  const none = config();
  const noCredentials = createCompactionCredentialCheck(none, { env, authProviders: new Set(), localProviders: [] });
  assert.equal(applyCompactionRouting(none, routing, { hasCredentials: noCredentials }), false);
  assert.deepEqual(none.agent.compaction, {});

  const keyed = config();
  const envCheck = createCompactionCredentialCheck(keyed, { env: { OPENAI_API_KEY: "x" }, authProviders: new Set(), localProviders: [] });
  assert.equal(applyCompactionRouting(keyed, routing, { hasCredentials: envCheck }), true);
  assert.equal(keyed.agent.compaction.model, "openai/gpt-6-luna");

  const disabled = { ...config(), disabled_providers: ["openai"] };
  const disabledCheck = createCompactionCredentialCheck(disabled, { env, authProviders: new Set(["openai", "anthropic"]), localProviders: [] });
  assert.equal(applyCompactionRouting(disabled, routing, { hasCredentials: disabledCheck }), true);
  assert.equal(disabled.agent.compaction.model, "anthropic/claude-haiku-5-5");
});

test("compaction credential check trusts local providers and credential options", () => {
  const config = { provider: { custom: { options: { baseURL: "http://localhost:1/v1" } }, bare: {} } };
  const check = createCompactionCredentialCheck(config, { env: {}, authProviders: new Set(), localProviders: ["ollama"] });
  assert.equal(check("ollama"), true);
  assert.equal(check("custom"), true);
  assert.equal(check("bare"), false);
  assert.equal(check("openai"), false);
});

test("compaction effort is fixed both ways from the model's own variants (GH#36169)", () => {
  const routing = { compactionReasoning: "high", tiers: { simple: { models: ["openai/gpt-6-luna"] } } };
  const lunaVariants = Object.fromEntries(["none", "low", "medium", "high", "xhigh"]
    .map((effort) => [effort, { reasoningEffort: effort, reasoningSummary: "auto" }]));
  const luna = { providerID: "openai", id: "gpt-6-luna", variants: lunaVariants };
  const logs = [];
  const log = (level, message) => logs.push(`${level} ${message}`);

  const low = { options: { reasoningEffort: "low" } };
  assert.deepEqual(applyCompactionEffort({ agent: "compaction", model: luna }, low, routing, { env: {}, log }), { from: "low", to: "high" });
  assert.deepEqual(low.options, { reasoningEffort: "high", reasoningSummary: "auto" });
  assert.deepEqual(logs, ["INFO [compaction] effort low -> high (gpt-6-luna)"]);

  // An Opus parent's `max` has no Luna variant, so OpenCode sent no effort at all.
  const absent = { options: {} };
  assert.deepEqual(applyCompactionEffort({ agent: "compaction", model: luna }, absent, routing, { env: {} }), { from: "default", to: "high" });

  const maxed = { options: { reasoningEffort: "xhigh" } };
  applyCompactionEffort({ agent: "compaction", model: luna }, maxed, { ...routing, compactionReasoning: "max" }, { env: {} });
  assert.equal(maxed.options.reasoningEffort, "xhigh", "max falls back to Luna's highest catalogued variant");

  const opusVariants = { high: { thinking: { type: "adaptive" }, effort: "high" }, max: { thinking: { type: "adaptive" }, effort: "max" } };
  const opus = { providerID: "anthropic", id: "claude-opus-5-5", variants: opusVariants };
  const opusMax = { options: { thinking: { type: "adaptive", display: "summarized" }, effort: "max" } };
  applyCompactionEffort({ agent: "compaction", model: opus }, opusMax, routing, { env: {} });
  assert.deepEqual(opusMax.options, { thinking: { type: "adaptive", display: "summarized" }, effort: "high" });

  const primary = { options: { effort: "max" } };
  assert.equal(applyCompactionEffort({ agent: "build-plus", model: opus }, primary, routing, { env: {} }), null);
  assert.equal(primary.options.effort, "max");

  const envTarget = { options: { reasoningEffort: "high" } };
  applyCompactionEffort({ agent: "compaction", model: luna }, envTarget, routing, { env: { AIDEVOPS_COMPACTION_EFFORT: "xhigh" } });
  assert.equal(envTarget.options.reasoningEffort, "xhigh");
  const capped = { options: { reasoningEffort: "high" } };
  applyCompactionEffort({ agent: "compaction", model: luna }, capped, routing, { env: { AIDEVOPS_COMPACTION_EFFORT: "xhigh", AIDEVOPS_COMPACTION_MAX_EFFORT: "medium" } });
  assert.equal(capped.options.reasoningEffort, "medium");

  // No variant catalogue: existing keys are only clamped down.
  const uncatalogued = { providerID: "vendor", id: "model" };
  const nested = { options: { reasoning: { effort: "max" } } };
  applyCompactionEffort({ agent: "compaction", model: uncatalogued }, nested, routing, { env: {} });
  assert.equal(nested.options.reasoning.effort, "high");
  const lowNested = { options: { reasoning: { effort: "low" } } };
  assert.equal(applyCompactionEffort({ agent: "compaction", model: uncatalogued }, lowNested, routing, { env: {} }), null);
});

test("compaction routing keeps local sessions local (GH#35893)", () => {
  const routing = { tiers: { simple: {
    models: ["openai/gpt-6-luna", "ollama/qwen-big"],
    reasoning: { "openai/gpt-6-luna": "medium" },
  } } };
  const provider = () => ({
    openai: { models: { "gpt-6-luna": { limit: { input: 260000 } } } },
    ollama: { models: { "qwen-big": { limit: { input: 262144 } } } },
  });
  const bound = { bound: true, localProviders: ["ollama"] };

  const opts = (extra) => ({ hasCredentials: credentialed, ...extra });
  const boundLocal = { provider: provider() };
  assert.equal(applyCompactionRouting(boundLocal, routing, opts({ policy: bound })), true);
  assert.equal(boundLocal.agent.compaction.model, "ollama/qwen-big");

  const boundCloudOnly = { provider: { openai: provider().openai } };
  const cloudRouting = { tiers: { simple: { models: ["openai/gpt-6-luna"] } } };
  assert.equal(applyCompactionRouting(boundCloudOnly, cloudRouting, opts({ policy: bound })), false);
  assert.deepEqual(boundCloudOnly.agent.compaction, {});

  const unbound = { bound: false, localProviders: [] };
  const localDefault = { model: "ollama/qwen-big", provider: provider() };
  assert.equal(applyCompactionRouting(localDefault, routing, opts({ policy: unbound, localProviders: ["ollama"] })), true);
  assert.equal(localDefault.agent.compaction.model, "ollama/qwen-big");

  let reads = 0;
  const cloudDefault = { model: "anthropic/claude-opus-5-5", provider: provider() };
  const thunk = () => { reads += 1; return ["ollama"]; };
  assert.equal(applyCompactionRouting(cloudDefault, routing, opts({ policy: unbound, localProviders: thunk })), true);
  assert.deepEqual(cloudDefault.agent.compaction, { model: "openai/gpt-6-luna", variant: "high" });
  assert.equal(reads, 1);

  const noDefault = { provider: provider() };
  assert.equal(applyCompactionRouting(noDefault, routing, opts({ policy: unbound, localProviders: () => assert.fail("not read") })), true);
  assert.equal(noDefault.agent.compaction.model, "openai/gpt-6-luna");
});

test("compaction residency warning fires once for a local parent on a cloud route (GH#35893)", () => {
  const logs = [];
  const warn = createCompactionResidencyWarning({ localProviders: ["ollama"], log: (level, msg) => logs.push(`${level} ${msg}`) });
  const luna = { agent: "compaction", model: { providerID: "openai", id: "gpt-6-luna" } };
  assert.equal(warn({ agent: "build-plus", model: luna.model }, "ollama/qwen"), false);
  assert.equal(warn(luna, "anthropic/claude-opus-5-5"), false);
  assert.equal(warn({ agent: "compaction", model: { providerID: "ollama", id: "qwen" } }, "ollama/qwen"), false);
  assert.equal(warn(luna, ""), false);
  assert.equal(warn(luna, "ollama/qwen"), true);
  assert.equal(warn(luna, "ollama/qwen"), false);
  assert.equal(logs.length, 1);
  assert.match(logs[0], /^WARN \[compaction\] local provider "ollama" session compacted on non-local provider "openai"/);
});

test("compaction preserves explicit user model and variant pins", () => {
  const routing = { tiers: { simple: { models: ["openai/gpt-6-luna"] } } };
  const config = { agent: { compaction: { model: "anthropic/pinned", variant: "high" } } };
  assert.equal(applyCompactionRouting(config, routing), false);
  assert.deepEqual(config.agent.compaction, { model: "anthropic/pinned", variant: "high" });
});

test("compaction skips a model rejected for the current auth and re-routes live (t18957)", () => {
  // Unique model ID: re-routing tracks every auto-routed config in the process.
  const routing = { tiers: { simple: { models: ["openai/gpt-t18957-a", "anthropic/claude-haiku-5-5"] } } };
  const config = { provider: { openai: { models: { "gpt-t18957-a": { limit: { input: 260000 } } } } } };
  const rejected = new Set();
  const opts = { policy: null, localProviders: [], hasCredentials: () => true, isUnavailable: (m) => rejected.has(m) };
  assert.equal(applyCompactionRouting(config, routing, opts), true);
  assert.equal(config.agent.compaction.model, "openai/gpt-t18957-a");
  rejected.add("openai/gpt-t18957-a");
  assert.equal(rerouteCompactionAfterRejection("openai/other"), 0);
  assert.equal(rerouteCompactionAfterRejection("openai/gpt-t18957-a"), 1);
  assert.equal(config.agent.compaction.model, "anthropic/claude-haiku-5-5");
  const fresh = { provider: config.provider };
  assert.equal(applyCompactionRouting(fresh, routing, opts), true);
  assert.equal(fresh.agent.compaction.model, "anthropic/claude-haiku-5-5");
});

test("compaction re-route never overrides pins and keeps the route without an alternative (t18957)", () => {
  const routing = { tiers: { simple: { models: ["openai/gpt-t18957-b"] } } };
  const pinned = { agent: { compaction: { model: "openai/gpt-t18957-b" } } };
  assert.equal(applyCompactionRouting(pinned, routing, { isUnavailable: () => true }), false);
  assert.equal(rerouteCompactionAfterRejection("openai/gpt-t18957-b"), 0);
  assert.equal(pinned.agent.compaction.model, "openai/gpt-t18957-b");
  const config = { provider: { openai: { models: { "gpt-t18957-b": { limit: { input: 260000 } } } } } };
  let down = false;
  const opts = { policy: null, localProviders: [], hasCredentials: () => true, isUnavailable: () => down };
  assert.equal(applyCompactionRouting(config, routing, opts), true);
  down = true;
  assert.equal(rerouteCompactionAfterRejection("openai/gpt-t18957-b"), 0);
  assert.equal(config.agent.compaction.model, "openai/gpt-t18957-b");
});
