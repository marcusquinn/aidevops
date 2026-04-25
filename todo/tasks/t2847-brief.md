---
mode: subagent
---

# t2847: LLM routing helper + audit log

## Pre-flight

- [x] Memory recall: `llm routing provider selection sensitivity` → no relevant lessons
- [x] Discovery: no existing centralised LLM router; existing scripts call providers directly (e.g. `ollama-helper.sh`, ad-hoc `Claude`/`claude` invocations)
- [x] File refs verified: `.agents/scripts/ollama-helper.sh`, `.agents/scripts/headless-runtime-helper.sh`, `prompts/build.txt` § "Secret-handling rules"
- [x] Tier: `tier:standard` — routing logic + audit log; new helper, depends on t2846 sensitivity tier output

## Origin

- Created: 2026-04-25
- Parent task: t2840 / GH#20892
- Phase: P0.5 (sensitivity + LLM routing layer)

## What

Centralise all LLM calls behind `llm-routing-helper.sh route --tier <sensitivity> --task <kind> ...` which selects a compliant provider per tier and **hard-fails** if no compliant provider is available. Existing one-off LLM invocations migrate to this layer over time; this task ships the layer itself + audit log + initial routing rules.

**Concrete deliverables:**

1. `llm-routing-helper.sh route --tier <tier> --task <kind> --prompt-file <path>` — selects provider, calls it, returns response
2. Routing policy in `_config/llm-routing.json` per sensitivity tier × task kind (classify, summarise, extract, draft, chase)
3. Provider abstraction: `ollama` (local, all tiers) | `anthropic` (cloud, public/internal/pii-with-redaction) | `openai` (cloud, same) — each behind a thin wrapper
4. **Hard-fail mode:** if `tier=privileged` and Ollama not running, EXIT 1 with "no compliant provider"; never silently fall back to cloud
5. Audit log at `_knowledge/index/llm-audit.log` (JSONL): timestamp, tier, task, provider, redaction-applied, prompt-sha256 (not raw prompt — too sensitive), response-sha256, tokens, cost
6. Cost tracking: aggregated per-day per-provider in `~/.aidevops/.agent-workspace/llm-costs.json`

## Why

Without centralised routing, every helper that calls an LLM has to re-implement provider selection + sensitivity check + audit log. Inconsistencies guarantee the privileged-leaks-to-cloud bug eventually. One central layer + hard-fail policy = privacy invariant enforceable.

Audit log without raw prompts/responses is intentional: storing raw privileged content in a log file defeats the point. Hash-only audit gives "this happened" provenance without leaking content.

## How (Approach)

1. **Routing policy spec** — `_config/llm-routing.json`:
   ```json
   {
     "tiers": {
       "public":     { "providers": ["any"], "default_provider": "anthropic" },
       "internal":   { "providers": ["cloud", "local"], "default_provider": "anthropic" },
       "pii":        { "providers": ["local", "cloud-with-redaction"], "default_provider": "ollama", "redaction_required_for_cloud": true },
       "sensitive":  { "providers": ["local"], "default_provider": "ollama" },
       "privileged": { "providers": ["local"], "default_provider": "ollama", "hard_fail_if_unavailable": true }
     },
     "providers": {
       "ollama":    { "kind": "local",  "command": "ollama-helper.sh chat", "models": ["llama3.1:70b", "mixtral"] },
       "anthropic": { "kind": "cloud",  "command": "claude --headless",     "vendor_dpa": true },
       "openai":    { "kind": "cloud",  "command": "openai-cli",            "vendor_dpa": true }
     }
   }
   ```
2. **Routing helper** — `scripts/llm-routing-helper.sh`:
   - `route --tier <t> --task <k> --prompt-file <p> [--max-tokens N] [--model <override>]`
     - Read policy, select provider; if `hard_fail_if_unavailable` and provider not running → exit 1
     - Apply redaction if `redaction_required_for_cloud` (delegate to `redaction-helper.sh`, stub for now)
     - Call provider, capture response, return on stdout
     - Append to audit log with hashed prompt+response
   - `audit-log <fields...>` — JSONL append
   - `costs [--since <date>] [--provider <p>]` — aggregate cost report
3. **Provider wrappers** — keep thin: each provider is just a shell function in `llm-routing-helper.sh` that knows how to invoke that provider with a prompt file and return the response. Ollama wrapper extends the existing `ollama-helper.sh chat` (P0.5c provides this).
4. **Redaction stub** — placeholder `redaction-helper.sh redact <input> <output>` that does nothing useful in MVP (just copies); leaves a TODO marker. Real redaction is post-MVP work, but the hook point exists from day 1.
5. **Hard-fail policy enforcement** — `tier=privileged` with no Ollama running gets exit 1 + clear error; no silent degradation. Verify with integration test that simulates Ollama-down state.
6. **Tests** — covers tier selection, hard-fail path, audit log correctness, cost aggregation, redaction hook firing for cloud+pii tier

### Files Scope

- NEW: `.agents/scripts/llm-routing-helper.sh`
- NEW: `.agents/scripts/redaction-helper.sh` (stub with TODO marker)
- NEW: `.agents/templates/llm-routing-config.json` (default `_config/llm-routing.json`)
- NEW: `.agents/tests/test-llm-routing.sh`
- EDIT: `.agents/aidevops/knowledge-plane.md` (LLM routing section)

## Acceptance Criteria

- [ ] `llm-routing-helper.sh route --tier public --task summarise` calls a cloud provider, returns response, appends audit log
- [ ] `llm-routing-helper.sh route --tier privileged --task draft` calls Ollama (P0.5c provides), returns response
- [ ] `llm-routing-helper.sh route --tier privileged --task draft` with Ollama stopped: exits 1 with "no compliant provider for tier=privileged"
- [ ] `llm-routing-helper.sh route --tier pii --task classify`: redaction-helper invoked before cloud call, audit log records `redaction_applied=true`
- [ ] Audit log at `_knowledge/index/llm-audit.log` records tier/task/provider/sha-prompt/sha-response/tokens/cost (NO raw prompts)
- [ ] `llm-routing-helper.sh costs --since 2026-04-01` produces a per-day per-provider cost report
- [ ] No existing helper has direct `claude`/`Claude`/`ollama` calls bypassing the router (CI lint check optional in MVP, document as follow-up)
- [ ] ShellCheck zero violations
- [ ] Tests pass: `bash .agents/tests/test-llm-routing.sh`
- [ ] Documentation: routing decision tree in `.agents/aidevops/knowledge-plane.md`

## Dependencies

- **Blocked by:** t2846 (P0.5a sensitivity tier on meta.json), t2848 (P0.5c Ollama substrate for local provider)
- **Blocks:** all P1, P4, P6 (any LLM call after this lands must route through this helper)

## Reference

- Parent brief: `todo/tasks/t2840-brief.md` § "Sensitivity tiers" + "Privileged/sensitive LLM routing"
- Existing local LLM substrate: `.agents/scripts/ollama-helper.sh`
- Existing headless invocation pattern: `.agents/scripts/headless-runtime-helper.sh`
