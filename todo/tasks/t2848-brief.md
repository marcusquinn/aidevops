---
mode: subagent
---

# t2848: Ollama integration + local LLM substrate

## Pre-flight

- [x] Memory recall: `ollama local llm chat completion` → existing `ollama-helper.sh` covers status/serve/stop/models/pull/recommend/validate
- [x] Discovery: `ollama-helper.sh` is production-quality; missing pieces are `chat` subcommand + integration with new routing layer
- [x] File refs verified: `.agents/scripts/ollama-helper.sh` (existing, ~production-quality)
- [x] Tier: `tier:standard` — extends existing helper with `chat`/`embed` subcommands and harness for routing-layer integration

## Origin

- Created: 2026-04-25
- Parent task: t2840 / GH#20892
- Phase: P0.5 (sensitivity + LLM routing layer)

## What

Extend `ollama-helper.sh` with `chat`, `embed`, and `health` subcommands so the new LLM routing layer (t2847) can use Ollama as the local-LLM provider for `pii`, `sensitive`, and `privileged` tiers. Ship a recommended local-model bundle (one fast 7B model + one larger reasoning model) with auto-pull on first use.

**Concrete deliverables:**

1. `ollama-helper.sh chat --model <name> --prompt-file <path> [--max-tokens N] [--temperature T]` — invokes a local model, returns completion on stdout
2. `ollama-helper.sh embed --model <name> --text-file <path>` — returns vector embeddings (used post-MVP by P1c PageIndex if it adds vector RAG)
3. `ollama-helper.sh health` — exit 0 if Ollama running and at least one usable model installed; exit 1 otherwise (used by routing layer hard-fail)
4. Recommended bundle (existing `recommend` subcommand): document official `aidevops/llm-bundle-default` set in `~/.aidevops/configs/ollama-bundle.json` — auto-pull on first call to `chat` if missing
5. Auto-start: `chat`/`embed` invocations check `health` first; if not running, attempt `serve` and wait up to 30s; fail with clear error if still not up
6. Privacy verifier: `ollama-helper.sh privacy-check` — confirms no telemetry, no remote model registry calls during chat (assertion via process inspection / network sniff stub)

## Why

The routing layer (t2847) is meaningless without a working local provider for sensitive/privileged tiers. The existing `ollama-helper.sh` covers infrastructure (start/stop/pull) but not invocation. This task closes the gap so privileged content has a real on-host LLM target.

Auto-start matters because users will forget to `ollama serve` and the framework should "just work" for first-time use without exposing privileged content as a casualty of friction.

The privacy verifier is paranoia-plus-evidence: hard claims like "Ollama runs entirely offline" need a verifiable check, not a vibe.

## How (Approach)

1. **Extend `ollama-helper.sh` with three subcommands:**
   - `chat`: validates model exists (auto-pull if missing), reads prompt file, calls `ollama run <model> < prompt-file`, captures output (with timeout), returns completion. Honour `--max-tokens` (passes to model parameters), `--temperature`.
   - `embed`: similar pattern, calls `ollama embed`, returns JSON array of floats.
   - `health`: `ollama list` (succeeds → daemon up), check at least one model installed.
2. **Auto-start logic** — function `_ensure_running()`:
   - `health` check; if down, log "starting ollama"; call existing `serve` subcommand; poll `health` every 1s for 30s; on timeout, exit 2 with explanatory message.
3. **Recommended bundle config** — `~/.aidevops/configs/ollama-bundle.json`:
   ```json
   {
     "fast":      { "model": "llama3.1:8b",  "purpose": "classify, short-form summary" },
     "reasoning": { "model": "llama3.1:70b", "purpose": "drafts, structured extraction, long-form" },
     "embed":     { "model": "nomic-embed-text", "purpose": "vector embeddings" }
   }
   ```
   On first `chat` call, ensure all three pulled (or warn user with disk-space estimate).
4. **Privacy check** — `privacy-check` subcommand:
   - Spawn `ollama run` on a known fixed prompt with a network-monitor wrapper (e.g. `lsof -i` on the ollama process, or a stub that asserts the process has no outbound TCP except to localhost ollama daemon)
   - Document in helper's `--help` output that this is a best-effort check, not a guarantee
5. **Integrate with routing layer** — t2847's `provider.ollama.command` config points to `ollama-helper.sh chat`; routing layer calls it with prompt file + tier-derived model selection
6. **Tests** — covers chat with valid model, chat with missing model (auto-pull), health up/down, auto-start success/timeout, privacy check passes on canonical setup

### Files Scope

- EDIT: `.agents/scripts/ollama-helper.sh` (add `chat`, `embed`, `health`, `privacy-check` subcommands)
- NEW: `.agents/templates/ollama-bundle.json` (default recommended-bundle config)
- NEW: `.agents/tests/test-ollama-helper.sh` (extends any existing tests, covers new subcommands)
- EDIT: `.agents/aidevops/knowledge-plane.md` (Ollama integration section + privacy guarantee)
- EDIT: `.agents/scripts/setup.sh` (optional: prompt to install Ollama if `knowledge` plane enabled)

## Acceptance Criteria

- [ ] `ollama-helper.sh chat --model llama3.1:8b --prompt-file /tmp/test.txt` returns a completion on stdout (Ollama running)
- [ ] `ollama-helper.sh chat --model nonexistent:1b --prompt-file ...` auto-pulls (or fails clearly if model not in registry)
- [ ] `ollama-helper.sh health` exit 0 with daemon up + at least one model; exit 1 with daemon down
- [ ] Auto-start: `chat` with daemon stopped attempts `serve` automatically (verifiable in tests with mock)
- [ ] `ollama-helper.sh privacy-check` documents what it verifies in --help; passes on a canonical setup
- [ ] Recommended bundle pulls fast/reasoning/embed models on first use, with disk-space warning
- [ ] Routing layer (t2847) integration: `llm-routing-helper.sh route --tier privileged ...` successfully calls Ollama via `chat`
- [ ] ShellCheck zero violations
- [ ] Tests pass: `bash .agents/tests/test-ollama-helper.sh`
- [ ] Documentation: Ollama setup + privacy section in `.agents/aidevops/knowledge-plane.md`

## Dependencies

- **Blocked by:** none — substrate work, can run in parallel with t2846
- **Blocks:** t2847 (P0.5b LLM routing depends on functional local provider)
- **Soft-blocks:** t2856 (P6a case draft uses local LLM for privileged drafts), t2849-t2850 (P1 enrichment may use local LLM for ambiguous cases)

## Reference

- Parent brief: `todo/tasks/t2840-brief.md` § "Sensitivity tiers" → "privileged: Local LLM only"
- Existing helper: `.agents/scripts/ollama-helper.sh` (read fully before extending — already production-quality)
- Ollama upstream docs: assume `ollama` CLI present; setup hint in `setup.sh`
