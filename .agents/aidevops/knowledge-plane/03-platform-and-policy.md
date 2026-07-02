# Knowledge Plane — Platform Abstraction and Policy

Parent index: `../knowledge-plane.md`.

## Platform Abstraction (t2843)

All operations that interact with a remote platform (create issues, comment,
create PRs) are routed through `platform-helper.sh` — a thin abstraction layer
that dispatches to `gh` (GitHub), `glab` (GitLab), `tea` (Gitea), or a local
no-op logger.

Platform detection order:

1. `repos.json` `"platform"` field for the repo path (explicit override)
2. `repos.json` `"local_only": true` → `local`
3. Remote URL of `origin` (github.com → `github`, gitlab.com → `gitlab`, etc.)
4. No remote found → `local`

### Available Functions

| Function | Description |
|----------|-------------|
| `platform_detect <repo_path>` | Prints `github\|gitea\|gitlab\|local` |
| `platform_create_issue <slug> <title> <body_file> <labels>` | Creates an issue |
| `platform_get_issue <slug> <num>` | Returns issue as JSON |
| `platform_comment_issue <slug> <num> <body_file>` | Posts a comment |
| `platform_create_pr <slug> <title> <body_file> <base> <head>` | Creates a PR |

### Platform Status

| Platform | Status |
|----------|--------|
| `github` | Fully implemented via `gh` CLI |
| `gitea` | P9 stub — exits 1 with "adapter not implemented" |
| `gitlab` | P9 stub — exits 1 with "adapter not implemented" |
| `local` | No-op — operations logged to `~/.aidevops/logs/platform-local-ops.log` |

### Usage

```bash
# Source and use directly
source ~/.aidevops/agents/scripts/platform-helper.sh

platform=$(platform_detect /path/to/repo)
echo "Platform: $platform"

# CLI invocation
platform-helper.sh detect /path/to/repo
platform-helper.sh create-issue owner/repo "Title" /tmp/body.md "label1,label2"
platform-helper.sh get-issue owner/repo 123
platform-helper.sh comment-issue owner/repo 123 /tmp/comment.md
platform-helper.sh create-pr owner/repo "Title" /tmp/body.md main feature/branch
```

The helper: `.agents/scripts/platform-helper.sh`.

---

## Sensitivity Classification (t2846)

Every ingested source is automatically stamped with a sensitivity tier. Detection runs
entirely offline — no cloud calls, no network.

### Tiers

| Tier | Redact | LLM Policy | Retention | Description |
|------|--------|------------|-----------|-------------|
| `public` | No | Any | 10 yr | Public-facing content |
| `internal` | No | Cloud OK | 7 yr | Internal business docs |
| `pii` | Yes | Local or redacted cloud | 7 yr | Personal data |
| `sensitive` | Yes | Local only | 7 yr | Board, strategy, HR |
| `privileged` | Yes | Local hard-fail | 10 yr | Attorney-client, regulatory |

Tier precedence (highest wins): `privileged > sensitive > pii > internal > public`

### Detection Pipeline

1. **Regex/pattern**: NI numbers, IBAN, payment cards, email addresses, postcodes → `pii`
2. **Path heuristics**: `legal/`, `privileged/`, `board-minutes/`, `strategy/` → tier per config
3. **Maintainer override**: `--sensitivity <tier>` on `knowledge add` or `sensitivity override` subcommand
4. **Precautionary upgrade** (P0.5c pending): ambiguous content defaults to `internal` until
   local-LLM (Ollama, P0.5c) ships. After P0.5c, routes via `llm-routing-helper.sh`.

### Configuration

Default patterns and heuristics: `.agents/templates/sensitivity-config.json`

Deployed at: `_knowledge/_config/sensitivity.json`

To customise per-repo: edit `_knowledge/_config/sensitivity.json` after provisioning.

### Audit Log

Every classification is recorded at `_knowledge/index/sensitivity-audit.log` (JSONL):

```json
{"ts":"2026-04-27T10:00:00Z","source_id":"my-doc","tier":"pii","evidence":"regex:uk_ni","actor":"sensitivity-detector"}
```

### Override CLI

```bash
# Manual correction with audit trail
knowledge-helper.sh sensitivity override <source-id> internal --reason "False positive NI match"

# View current tier + recent audit entries
knowledge-helper.sh sensitivity show <source-id>
```

### meta.json Fields

| Field | Description |
|-------|-------------|
| `sensitivity` | Current tier (`public`\|`internal`\|`pii`\|`sensitive`\|`privileged`) |
| `sensitivity_override` | Manually set tier (detector respects this on re-classify) |
| `sensitivity_override_reason` | Free-text reason for the override |

---

## LLM Routing

All LLM calls in the framework are centralised behind `llm-routing-helper.sh`. Direct invocations of `claude`, `ollama`, or any other LLM CLI are prohibited in new helpers — route through this layer instead.

### Sensitivity Tiers

Every LLM call is assigned a sensitivity tier that controls which providers are allowed:

| Tier | Allowed providers | Default | Notes |
|------|-------------------|---------|-------|
| `public` | any | anthropic | No restrictions |
| `internal` | cloud or local | anthropic | Normal framework data |
| `pii` | local preferred; cloud with redaction | ollama | Redaction applied before cloud calls |
| `sensitive` | local only | ollama | No cloud fallback |
| `privileged` | local only | ollama | Hard-fail if Ollama is not running |

**Hard-fail rule:** when `tier=privileged` and no local provider is available, `llm-routing-helper.sh` exits 1 with "no compliant provider for tier=privileged". There is no silent fallback to cloud.

### Routing Decision Tree

```text
route --tier <t> --prompt-file <p>
  │
  ├─ tier = public/internal?
  │     └─ use default_provider from config (anthropic)
  │
  ├─ tier = pii?
  │     ├─ Ollama running? → use Ollama (no redaction needed)
  │     └─ cloud provider? → call redaction-helper.sh first, then cloud
  │
  ├─ tier = sensitive?
  │     ├─ Ollama running? → use Ollama
  │     └─ Ollama down? → exit 1 (no cloud fallback)
  │
  └─ tier = privileged?
        ├─ Ollama running? → use Ollama
        └─ Ollama down? → EXIT 1 (hard-fail, policy enforced)
```

### Audit Log

Every LLM call appends a JSONL record to `_knowledge/index/llm-audit.log`:

```json
{
  "timestamp": "2026-04-27T12:00:00Z",
  "tier": "public",
  "task": "summarise",
  "provider": "anthropic",
  "redaction_applied": false,
  "prompt_sha256": "<sha256 of prompt — not raw content>",
  "response_sha256": "<sha256 of response — not raw content>",
  "tokens": 512,
  "cost": "0"
}
```

Raw prompts and responses are **never** stored in the audit log. Only SHA-256 hashes are recorded, providing provenance ("this call happened") without leaking content.

### Cost Tracking

Per-day per-provider costs are accumulated at `~/.aidevops/.agent-workspace/llm-costs.json`:

```bash
llm-routing-helper.sh costs --since 2026-04-01
llm-routing-helper.sh costs --provider ollama
```

### Configuration

Policy lives in `_config/llm-routing.json` (copy from `.agents/templates/llm-routing-config.json` on init). Key fields:

- `tiers.<name>.hard_fail_if_unavailable` — if true, exit 1 instead of falling back
- `tiers.<name>.redaction_required_for_cloud` — if true, call `redaction-helper.sh` before any cloud call
- `providers.<name>.kind` — `"local"` or `"cloud"`

### Redaction

`redaction-helper.sh redact <input> <output>` is called automatically for `pii` tier cloud calls. The MVP implementation is a pass-through stub — it copies the file unchanged and logs a warning. Real PII entity recognition is tracked as a post-MVP TODO in `redaction-helper.sh`.

### Usage

```bash
# Public tier — uses anthropic by default
llm-routing-helper.sh route --tier public --task summarise \
    --prompt-file /tmp/prompt.txt

# Privileged tier — uses Ollama; fails if not running
llm-routing-helper.sh route --tier privileged --task draft \
    --prompt-file /tmp/prompt.txt --max-tokens 4096

# Dry-run (no real LLM call — useful in tests)
LLM_ROUTING_DRY_RUN=1 llm-routing-helper.sh route \
    --tier pii --task classify --prompt-file /tmp/data.txt

# Check provider availability
llm-routing-helper.sh status
```

---

## Ollama Integration (t2848)

The `ollama-helper.sh` provides the local LLM substrate used by `llm-routing-helper.sh`
for `pii`, `sensitive`, and `privileged` tiers. The helper is the canonical interface
to Ollama — direct `ollama` CLI calls in new helpers are prohibited.

### Setup

**1. Install Ollama:**

```bash
# macOS (Homebrew)
brew install ollama

# Or download from https://ollama.com
```

**2. Pull the recommended bundle:**

```bash
# Pull all three models (fast + reasoning + embed)
ollama-helper.sh pull llama3.1:8b       # ~4.9 GB — required for pii/sensitive tiers
ollama-helper.sh pull nomic-embed-text  # ~274 MB — required for vector embeddings
# Optional (for privileged drafts requiring high-quality reasoning):
ollama-helper.sh pull llama3.1:70b     # ~39 GB — requires 48+ GB RAM
```

**3. Verify health:**

```bash
ollama-helper.sh health
# Output: Ollama healthy: server up, 2 model(s) installed
```

### Recommended Bundle

The default model bundle is at `.agents/templates/ollama-bundle.json` (deployed to
`~/.aidevops/configs/ollama-bundle.json`). Three tiers:

| Bundle key | Model | Purpose | Size |
|------------|-------|---------|------|
| `fast` | `llama3.1:8b` | classify, short-form summary — `pii`/`sensitive` | ~4.9 GB |
| `reasoning` | `llama3.1:70b` | drafts, structured extraction — `privileged` | ~39 GB |
| `embed` | `nomic-embed-text` | vector embeddings for semantic search | ~274 MB |

The `fast` model is the minimum required for the routing layer to route `pii`/`sensitive`
tiers to a local provider. The `reasoning` model is required for `privileged` tier — if
absent, `llm-routing-helper.sh` exits 1 (hard-fail by policy).

### Subcommands Added (t2848)

| Subcommand | Purpose |
|------------|---------|
| `health` | Exit 0 if daemon running + ≥1 model installed; exit 1 otherwise |
| `chat --model <m> --prompt-file <f>` | Run inference; auto-starts daemon; auto-pulls model |
| `embed --model <m> --text-file <f>` | Get vector embeddings as JSON |
| `privacy-check` | Best-effort check for external connections during inference |

```bash
# Run inference
ollama-helper.sh chat --model llama3.1:8b --prompt-file /tmp/prompt.txt
ollama-helper.sh chat --model llama3.1:8b --prompt-file /tmp/p.txt \
    --max-tokens 512 --temperature 0.7

# Vector embeddings
ollama-helper.sh embed --model nomic-embed-text --text-file /tmp/doc.txt

# Health check
ollama-helper.sh health

# Privacy verification
ollama-helper.sh privacy-check
```

### Privacy Guarantee

Ollama runs models entirely on the local host. No data is sent to external servers
**during normal operation**. However:

- **Model downloads** (`ollama pull`) contact `ollama.com` to fetch model weights.
  These happen once per model. After pulling, inference is fully offline.
- **`privacy-check`** verifies this at runtime by inspecting TCP connections during
  a test inference via `lsof`. It is a **best-effort check** — it cannot detect:
  - DNS queries (name resolution only, no data)
  - UDP traffic
  - Connections that open and close between lsof snapshots
- For **high-assurance offline operation** (e.g. `privileged` tier with extremely
  sensitive content), use a network-level firewall or run on an airgapped host.

The `privacy-check` subcommand documents its limitations in `--help` output and in
its exit summary. Users relying on Ollama for `privileged` content should understand
that the guarantee is architectural (no cloud API calls in the inference path) rather
than technically enforced at every layer.

### Auto-Start

`chat` and `embed` automatically start the Ollama daemon if it is not running:

1. `_ensure_running` calls `ollama serve` in the background.
2. Polls `health` every 1 second for up to 30 seconds.
3. If still not up after 30s, exits 2 with a clear error message.
4. Once running, the daemon persists for the session (not killed on helper exit).

This means users can call `ollama-helper.sh chat ...` without manually running
`ollama serve` first. The daemon stays running in the background for subsequent calls.

### Routing Layer Integration

`llm-routing-helper.sh` calls `ollama-helper.sh chat` for local tiers:

```json
// llm-routing-config.json (template)
{
  "providers": {
    "ollama": {
      "kind": "local",
      "command": "ollama-helper.sh",
      "subcommand": "chat"
    }
  }
}
```

The routing layer passes `--model` (resolved from the sensitivity tier config),
`--prompt-file`, and optionally `--max-tokens`. The `health` subcommand is called
before dispatching to Ollama — if it fails for `privileged` tier, the hard-fail
policy kicks in immediately.
