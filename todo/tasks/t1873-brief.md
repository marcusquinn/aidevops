---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1873: Add Ollama as opt-in local model backend with Gemma 4 documentation

## Origin

- **Created:** 2026-04-03
- **Session:** opencode:interactive
- **Created by:** marcusquinn (human, interactive)
- **Conversation context:** External contributor (johnwaldo) opened GH#16810 requesting first-class Ollama support. Maintainer reviewed, scoped down to opt-in alternative (not default). User decided haiku should remain preferred over local unless explicitly configured. Gemma 4 release identified as the catalyst — its 26B MoE model is competitive with mid-tier API models on coding benchmarks.

## What

Add Ollama as a supported (but not recommended) local model backend alongside the existing llama.cpp infrastructure. Users who already have Ollama installed get integration without switching tools. Haiku remains the default — local models are opt-in only. Document Gemma 4 26B MoE as the recommended model for users who choose local inference.

Deliverables:
1. Ollama provider entry in model-routing-table.json
2. Ollama probe (with `num_ctx` validation) in model-availability-helper.sh
3. Thin `ollama-helper.sh` wrapper script
4. Updated local-models.md with Ollama section and Gemma 4 guidance
5. Updated model-routing.md mentioning Ollama as alternative
6. Test coverage for local tier and Ollama probe

## Why

- Gemma 4 26B MoE (77.1% LiveCodeBench, 3.8B active params, 256K context) makes local inference genuinely viable for coding tasks
- Ollama is the simplest path to run local models (`brew install ollama && ollama pull gemma4:26b`)
- Multiple users likely to request this — better to have documented support than ad-hoc workarounds
- Zero marginal cost for users willing to trade some quality for free inference

## How (Approach)

### t1873.1 — model-routing-table.json: Add Ollama provider

File: `.agents/configs/model-routing-table.json`

**Changes:**
- Line 6: Keep `local` tier as-is — do NOT add `local/ollama` to the tier models array. The `local` tier is opt-in and `llama.cpp` is recommended. Ollama is a provider-level alternative, not a tier-level addition.
- Lines 17-24: Add `ollama` as a new provider entry after `local`:

```json
"ollama": {
  "endpoint": "http://localhost:11434/v1/chat/completions",
  "key_env": null,
  "probe_path": "/api/tags",
  "probe_timeout_seconds": 3,
  "min_context_length": 16384,
  "_comment": "Ollama local inference. Probe uses /api/tags (native API) not /v1/models. Requires num_ctx >= 16384 in Modelfile for agentic use. See local-models.md."
}
```

Note: Ollama's native health probe is `/api/tags` (returns running models), not `/v1/models` (OpenAI compat layer). The `/api/tags` endpoint is more reliable for detecting whether Ollama is actually running.

**Testing:** `jq . .agents/configs/model-routing-table.json` validates JSON. Manual review for correctness.

### t1873.2 — model-availability-helper.sh: Add local/Ollama probe with num_ctx validation

File: `.agents/scripts/model-availability-helper.sh`

**Changes:**

1. `get_provider_endpoint()` (line 67-79): Add `local` and `ollama` cases:
   ```bash
   local) echo "http://localhost:8080/v1/models" ;;
   ollama) echo "http://localhost:11434/api/tags" ;;
   ```

2. `get_provider_key_vars()` (line 83-96): Add cases returning empty (no key needed):
   ```bash
   local) echo "" ;;
   ollama) echo "" ;;
   ```

3. `is_known_provider()` (line 99-105): Add `local | ollama` to the case:
   ```bash
   anthropic | openai | google | openrouter | groq | deepseek | local | ollama) return 0 ;;
   ```

4. `get_tier_models()` (line 112-128): Leave line 116 unchanged. The local tier already falls back to haiku — that's correct since haiku is preferred unless user explicitly opts in.

5. `check_model_available()` (line 795-878): Add a local/ollama-specific path before the generic provider probe. When `provider` is `local` or `ollama`, skip the cloud probe path and instead:
   - For `local`: curl `http://localhost:8080/v1/models` with 3s timeout
   - For `ollama`: curl `http://localhost:11434/api/tags` with 3s timeout, then validate `num_ctx` via `http://localhost:11434/api/show` for the target model

6. New function `_probe_ollama_context_length()`:
   ```bash
   _probe_ollama_context_length() {
       local model_name="$1"
       local min_ctx="${2:-16384}"
       # POST to /api/show with model name, parse num_ctx from modelinfo
       local response
       response=$(curl -sf --max-time 5 -X POST \
           "http://localhost:11434/api/show" \
           -d "{\"name\":\"$model_name\"}" 2>/dev/null) || return 1
       local num_ctx
       num_ctx=$(printf '%s' "$response" | python3 -c "
   import sys, json
   data = json.load(sys.stdin)
   params = data.get('parameters', '')
   for line in params.split('\n'):
       if 'num_ctx' in line:
           print(line.split()[-1])
           sys.exit(0)
   # Default Ollama context if not set
   print('2048')
   " 2>/dev/null) || { echo "2048"; return 1; }
       if [[ "$num_ctx" -lt "$min_ctx" ]]; then
           print_warning "Ollama model $model_name has num_ctx=$num_ctx (minimum: $min_ctx)"
           print_warning "Set num_ctx in Modelfile or run: ollama run $model_name /set parameter num_ctx $min_ctx"
           return 1
       fi
       return 0
   }
   ```

**Testing:** Run `bash tests/test-model-availability.sh` — should pass existing tests plus new local tier tests. Mock-test Ollama probe by checking function existence and argument parsing (no live Ollama needed in CI).

### t1873.3 — ollama-helper.sh: Thin wrapper for Ollama lifecycle

File: `.agents/scripts/ollama-helper.sh` (NEW — ~200 lines)

**Subcommands:**
- `status` — Check if Ollama daemon is running (`curl -sf http://localhost:11434/api/tags`), list loaded models
- `serve` — Start Ollama daemon (`ollama serve` backgrounded), wait for health
- `stop` — Stop Ollama daemon (`pkill -f "ollama serve"` or `launchctl` if installed as service)
- `models` — List available models (`ollama list`)
- `pull <model>` — Pull a model (`ollama pull <model>`), validate context length after pull
- `recommend` — Print recommended models for agentic use (Gemma 4 26B, Qwen 3, Llama 4 Scout)
- `validate <model>` — Check model exists and has sufficient context length

**Pattern to follow:** Same CLI structure as `local-model-helper.sh` (line 2587-2617 `main()` dispatcher) but much thinner — Ollama already has its own CLI, so this is mostly wrapping + validation.

**Key design decisions:**
- NOT a replacement for `local-model-helper.sh` — that stays llama.cpp-only
- Detect if `ollama` binary exists in PATH; fail gracefully with install instructions if not
- Validate `num_ctx` on `pull` and `status` — warn if below 16384
- ShellCheck clean, bash 3.2 compatible, `local var="$1"` pattern, explicit returns

**Testing:** `shellcheck .agents/scripts/ollama-helper.sh` zero violations. Test `status` subcommand returns 1 when Ollama not running (safe to run in CI). Add `tests/test-ollama-helper.sh` with unit tests for argument parsing and mock responses.

### t1873.4 — headless-runtime-helper.sh: Add ollama case to provider_auth_available

File: `.agents/scripts/headless-runtime-helper.sh`

**Changes:**
- `provider_auth_available()` (line 699-738): Add `ollama` alongside the existing `local` case:
  ```bash
  local | ollama)
      # Local providers need no auth
      return 0
      ;;
  ```

This is a one-line change. The existing `local)` case on line 729 just needs `ollama` added to the pattern.

**Testing:** Run `bash tests/test-headless-runtime-helper.sh` — existing tests should pass. No new tests needed for this trivial change (covered by the wildcard `*` case that already returns 0).

### t1873.5 — local-models.md: Add Ollama section with Gemma 4 guidance

File: `.agents/tools/local-models/local-models.md`

**Changes:**

1. Update description frontmatter (line 2) to mention Ollama:
   ```
   description: Local AI model inference via llama.cpp (recommended) and Ollama (alternative) - setup, models, usage tracking
   ```

2. Update Quick Reference (lines 20-28) to add Ollama:
   ```markdown
   - **Recommended runtime**: llama.cpp (MIT, fastest, no daemon, localhost only)
   - **Alternative runtime**: Ollama (simpler setup, daemon-based, see security notes)
   - **Recommended model**: Gemma 4 26B MoE (77.1% LiveCodeBench, 3.8B active, 256K context)
   ```

3. Update comparison table (lines 33-38) to add "Supported in aidevops?" row:
   ```
   | aidevops support | Recommended | Supported (opt-in) | Not integrated |
   ```

4. Add new section after the comparison table: "## Alternative: Ollama"
   - When to use Ollama: already installed, Docker deployments, want simplest setup
   - When to use llama.cpp: performance-sensitive, security-sensitive, no daemon
   - Setup: `brew install ollama && ollama serve && ollama pull gemma4:26b`
   - Critical: Context length configuration (Ollama defaults to 2048, need 16384+ for agentic)
   - Modelfile example setting `num_ctx 32768`
   - Security warnings: daemon listens on port, bind to localhost only, firewall recommendations

5. Add new section: "## Recommended Local Models (2026)"
   - Gemma 4 26B MoE: best coding performance per active parameter. 77.1% LiveCodeBench, 82.6% MMLU Pro, 256K context. Only 3.8B active params = fast inference. 18GB on Ollama, needs 24GB VRAM.
   - Gemma 4 E4B: laptop-friendly. 52% LiveCodeBench, 128K context, 9.6GB. Good for simple tasks.
   - Gemma 4 31B Dense: highest quality but needs more compute. 80% LiveCodeBench, 20GB.
   - Brief mention of Qwen 3, Llama 4 Scout as alternatives without deep benchmarking.

**Testing:** `markdownlint-cli2 .agents/tools/local-models/local-models.md` clean. Manual review for accuracy.

### t1873.6 — model-routing.md: Update local tier description

File: `.agents/tools/context/model-routing.md`

**Changes:**
- Line 30: Update local tier table row to mention Ollama:
  ```
  | local | llama.cpp or Ollama (user models) | Privacy/offline, bulk, experimentation; opt-in only |
  ```
- Lines 40-41: Update local fallback logic to clarify opt-in:
  ```
  Local is opt-in only. Default dispatch uses haiku. Users who explicitly configure local tier: llama.cpp → Ollama → haiku.
  ```
- Lines 55-64: Update fallback routing table entry.

**Testing:** `markdownlint-cli2 .agents/tools/context/model-routing.md` clean.

### t1873.7 — Tests: Add local tier and Ollama coverage

File: `tests/test-model-availability.sh`

**Changes:**
- Section 3 (line 158): Add `local` to the tier resolution loop
- Section 4 (line 207): Add `local` and `ollama` to the provider check loop
- New section: "Local Provider Probes" — test that:
  - `is_known_provider local` returns 0
  - `is_known_provider ollama` returns 0
  - `get_provider_endpoint local` returns localhost:8080 URL
  - `get_provider_endpoint ollama` returns localhost:11434 URL
  - `get_provider_key_vars local` returns empty
  - `get_provider_key_vars ollama` returns empty
  - `check local` with no server running returns non-zero (graceful failure)
  - `check ollama` with no server running returns non-zero (graceful failure)

File: `tests/test-ollama-helper.sh` (NEW — ~100 lines)

**Tests:**
- Script exists and is executable
- `shellcheck` passes
- `status` returns non-zero when Ollama not running (safe for CI)
- `recommend` outputs model names
- Unknown subcommand returns non-zero
- `--help` works

**Testing:** `bash tests/test-model-availability.sh` and `bash tests/test-ollama-helper.sh` both pass.

## Acceptance Criteria

- [ ] `ollama` provider appears in `model-routing-table.json` with correct endpoint and probe path
  ```yaml
  verify:
    method: codebase
    pattern: '"ollama".*endpoint.*11434'
    path: ".agents/configs/model-routing-table.json"
  ```
- [ ] `model-availability-helper.sh` recognizes `local` and `ollama` as known providers
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/model-availability-helper.sh check ollama --quiet 2>&1; [[ $? -le 3 ]]"
  ```
- [ ] `num_ctx` validation function exists in model-availability-helper.sh
  ```yaml
  verify:
    method: codebase
    pattern: "_probe_ollama_context_length"
    path: ".agents/scripts/model-availability-helper.sh"
  ```
- [ ] `ollama-helper.sh` exists with status/serve/stop/models/pull/recommend subcommands
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/ollama-helper.sh --help 2>&1 | grep -q 'status'"
  ```
- [ ] `local-models.md` documents Ollama as alternative with security caveats and Gemma 4 recommendations
  ```yaml
  verify:
    method: codebase
    pattern: "Alternative.*Ollama"
    path: ".agents/tools/local-models/local-models.md"
  ```
- [ ] Gemma 4 26B MoE documented with benchmarks (LiveCodeBench 77.1%, 3.8B active params)
  ```yaml
  verify:
    method: codebase
    pattern: "77\\.1%.*LiveCodeBench"
    path: ".agents/tools/local-models/local-models.md"
  ```
- [ ] Haiku remains default — local tier does NOT auto-resolve before haiku
  ```yaml
  verify:
    method: codebase
    pattern: 'local\) echo "local/llama.cpp\|anthropic/claude-haiku'
    path: ".agents/scripts/model-availability-helper.sh"
  ```
- [ ] `headless-runtime-helper.sh` handles `ollama` provider auth (no-op, like local)
  ```yaml
  verify:
    method: codebase
    pattern: "local.*ollama"
    path: ".agents/scripts/headless-runtime-helper.sh"
  ```
- [ ] All existing tests pass (`bash tests/test-model-availability.sh`)
  ```yaml
  verify:
    method: bash
    run: "bash tests/test-model-availability.sh 2>&1 | tail -1 | grep -q 'FAIL: 0'"
  ```
- [ ] ShellCheck clean on all modified/new scripts
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/ollama-helper.sh .agents/scripts/model-availability-helper.sh"
  ```
- [ ] Lint clean on all modified markdown
  ```yaml
  verify:
    method: bash
    run: "markdownlint-cli2 .agents/tools/local-models/local-models.md .agents/tools/context/model-routing.md"
  ```

## Context & Decisions

- **Why Ollama as opt-in, not default:** Haiku is proven, cheap ($0.25/MTok), and reliable. Local models trade quality for cost savings. Users who want local should explicitly choose it.
- **Why llama.cpp recommended over Ollama:** Deliberate architectural decision from t1338. Security (no daemon, no CVEs, localhost-only), performance (20-70% faster), and smaller attack surface.
- **Why Gemma 4 26B MoE highlighted:** 77.1% LiveCodeBench (vs Gemma 3 27B's 29.1%) with only 3.8B active params. Best coding-per-FLOP for local inference in 2026. Native function-calling support makes it viable for agentic work.
- **Fallback order kept simple:** `local/llama.cpp|anthropic/claude-haiku-4-5` unchanged. Not adding `local/ollama` to the tier fallback chain — Ollama is a provider-level alternative to llama.cpp, not a separate tier entry.
- **`num_ctx` validation:** Ollama defaults to 2048 tokens regardless of model capability. Agentic tool schemas consume 4-8K tokens alone. Without validation, users get silent garbage output. This is the single most important quality-of-life improvement in this task.
- **No changes to fallback-chain-config.json.txt:** The fallback chain is Anthropic-only for worker dispatch by design. Local models are for interactive/explicit use.

## Relevant Files

- `.agents/configs/model-routing-table.json` — provider registry, add ollama entry
- `.agents/scripts/model-availability-helper.sh:67-105` — provider functions to extend
- `.agents/scripts/model-availability-helper.sh:112-128` — tier models (leave unchanged)
- `.agents/scripts/model-availability-helper.sh:795-878` — check_model_available, add local/ollama path
- `.agents/scripts/headless-runtime-helper.sh:699-738` — provider_auth_available, add ollama
- `.agents/scripts/local-model-helper.sh` — existing llama.cpp helper (reference, don't modify)
- `.agents/tools/local-models/local-models.md` — docs to extend
- `.agents/tools/context/model-routing.md` — routing docs to update
- `tests/test-model-availability.sh:155-217` — test sections to extend
- `.agents/configs/fallback-chain-config.json.txt` — NOT modified (by design)

## Dependencies

- **Blocked by:** Nothing
- **Blocks:** GH#16810 (external issue)
- **External:** None (Ollama is user-installed, not a build dependency)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Already done in this session |
| t1873.1 routing table | 15m | JSON edit, trivial |
| t1873.2 availability helper | 1.5h | Probe functions + num_ctx validation |
| t1873.3 ollama-helper.sh | 1.5h | New script, thin wrapper |
| t1873.4 headless runtime | 10m | One-line change |
| t1873.5 local-models.md | 45m | Ollama section + Gemma 4 docs |
| t1873.6 model-routing.md | 15m | Minor doc updates |
| t1873.7 tests | 45m | Test additions + new test file |
| **Total** | **~5h** | (ai:4h test:45m read:15m) |
