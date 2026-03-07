---
mode: subagent
---
# t1412: Worker sandboxing — credential isolation, network tiering, and content trust boundaries

## Origin

- **Created:** 2026-03-07
- **Session:** OpenCode (interactive)
- **Created by:** human + ai-interactive
- **Conversation context:** Analysis of the Clinejection attack (grith.ai/blog/clinejection-when-your-ai-tool-installs-another) against aidevops defenses. Identified that our prompt-guard-helper.sh pattern scanner is bypassable by an informed attacker who reads our open-source repo, and that we lack enforcement-layer defenses (credential isolation, network policy, command sandboxing). Current defenses are detection-oriented (scan, warn, log) not enforcement-oriented (prevent, restrict, sandbox).

## What

A multi-layer worker sandboxing system that limits blast radius when a headless worker is compromised via prompt injection, even when the attacker has full knowledge of our defenses (open-source threat model).

Three enforcement layers, each effective regardless of attacker knowledge:

1. **Credential isolation** — workers run with a fake `HOME` directory containing only git config and a scoped GitHub token. No access to `~/.ssh/`, gopass, `~/.config/aidevops/credentials.sh`, cloud provider tokens, or publish tokens.

2. **Network tiering** — four-tier domain classification (always-allow, allow+log, log+flag, deny) with a static deny list for known exfiltration endpoints and anomaly flagging for novel domains. Not a hard allowlist (which breaks Tier 5 project-specific domains) but a graduated trust model.

3. **Content trust boundaries** — all content fetched during worker execution (web pages, API responses, issue bodies, PR diffs, dependency READMEs) passes through prompt-guard-helper.sh scan-stdin before reaching the LLM context. Currently scanning happens only at dispatch time; this extends it to runtime content ingestion.

Interactive sessions remain unrestricted — the human in the loop is the enforcement layer.

## Why

- aidevops is open-source. An attacker can read every regex pattern in `prompt-injection-patterns.yaml`, every credential path in `build.txt`, every dispatch flow in `dispatch.sh`, and the documented absence of enforcement layers.
- Pattern-based scanning (Layer 1) is near-zero value against a targeted attacker who has read our patterns. They paraphrase around every regex.
- Workers have full shell access (required for their job) and currently inherit the user's full HOME directory, SSH keys, gopass access, and unrestricted network.
- The Clinejection attack demonstrated that prompt injection in a GitHub issue title can chain through AI triage → code execution → credential theft → supply chain compromise. Our workers read issue bodies and have shell access — same attack surface.
- Enforcement-based defenses (isolation, scoping, sandboxing) remain effective even when the mechanism is public. Knowing the worker runs with a fake HOME doesn't help the attacker access the real HOME.

## How (Approach)

### Phase 1: Fake HOME for workers (lowest effort, highest value)

Modify `dispatch.sh` (or the dispatch wrapper) to:
- Create a temporary HOME directory: `/tmp/aidevops-worker-XXXX/`
- Populate with: `.gitconfig` (name/email only), scoped GitHub token via `gh auth`
- Set `HOME=/tmp/aidevops-worker-XXXX/` in the worker's environment
- Worker operates in the repo directory as normal — code operations unaffected
- Clean up temp HOME after worker exits

Key files:
- `.agents/scripts/dispatch.sh` — worker spawning
- `.agents/tools/ai-assistants/headless-dispatch.md` — dispatch guidance
- `.agents/scripts/commands/pulse.md` — pulse dispatch flow

### Phase 2: Scoped short-lived GitHub tokens

- Before dispatch, create a fine-grained GitHub PAT scoped to the target repo only
- Permissions: `contents:write`, `pull_requests:write`, `issues:write`
- TTL: 1 hour (or session duration)
- Pass to worker via environment, not filesystem
- Requires: GitHub API for token creation, or `gh auth token` scoping

### Phase 3: Network tiering

Implement as a transparent logging proxy or iptables/pf rules wrapper:

**Tier 1 — Always allowed (no logging overhead):**
- `github.com`, `*.github.com`, `*.githubusercontent.com`
- `api.github.com`

**Tier 2 — Allowed + logged (package registries):**
- `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`
- `crates.io`, `static.crates.io`
- `ghcr.io`, `docker.io`, `hub.docker.com`

**Tier 3 — Allowed + logged (known tools/docs):**
- `sonarcloud.io`, `qlty.sh`, `app.codacy.com`
- `bun.sh`, `nodejs.org`, `playwright.dev`
- `docs.anthropic.com`, `developers.cloudflare.com`
- `docs.github.com`, `cli.github.com`
- Extensible via config file per-installation

**Tier 4 — Allowed + flagged (unknown domains):**
- Any domain not in Tiers 1-3
- Logged with alert for post-session review
- Baseline learning: domains seen in last 30 days of normal operation get promoted to Tier 3

**Tier 5 — Denied (exfiltration indicators):**
- Raw IP addresses (not hostnames)
- `.onion`, `.bit` TLDs
- Known paste/webhook sites: `requestbin.com`, `webhook.site`, `ngrok.io`, `pipedream.com`, `hookbin.com`
- Configurable deny list

### Phase 4: Runtime content scanning

- Wrap webfetch, MCP tool outputs, and file reads from untrusted sources with `prompt-guard-helper.sh scan-stdin`
- Currently scanning happens at dispatch time only (task description)
- Extend to: issue body fetch, PR diff fetch, web page fetch, dependency README reads
- Integration point: Claude Code hooks (PostToolUse via `claude` CLI workers) or wrapper functions in dispatch

### Phase 5: Command pattern baseline (stretch)

- Log all Bash commands executed by workers
- Flag anomalous patterns: `npm install` from git URLs not in lockfile, `curl | bash`, `wget` to unknown domains, reads of `~/.ssh/` or credential paths
- Baseline built from historical transcript analysis (session data already collected)

## Acceptance Criteria

- [ ] Workers dispatched by pulse/supervisor run with isolated HOME (no access to real `~/.ssh/`, gopass, `credentials.sh`)
  ```yaml
  verify:
    method: bash
    run: "grep -q 'HOME=' .agents/scripts/dispatch.sh || grep -q 'HOME=' .agents/scripts/worker-sandbox.sh"
  ```
- [ ] Interactive sessions are unaffected — full HOME, full network, full credentials
  ```yaml
  verify:
    method: subagent
    prompt: "Review the sandboxing implementation and confirm that interactive sessions (non-headless) are explicitly excluded from all restrictions"
    files: ".agents/scripts/dispatch.sh .agents/scripts/worker-sandbox.sh"
  ```
- [ ] Worker can still: create branches, push, create PRs, run tests, install dependencies from lockfile, run linters
  ```yaml
  verify:
    method: manual
    prompt: "Dispatch a test worker with sandboxing enabled and verify it completes a full PR cycle"
  ```
- [ ] Network deny list blocks known exfiltration endpoints (requestbin, ngrok, webhook.site, raw IPs)
- [ ] All worker network connections to Tier 4 (unknown) domains are logged with timestamps
- [ ] Content fetched during worker execution is scanned for injection patterns before reaching LLM context
- [ ] Documentation updated: `prompt-injection-defender.md`, `headless-dispatch.md`, `build.txt`
- [ ] ShellCheck clean on all new/modified scripts
- [ ] Existing worker dispatch tests still pass

## Context & Decisions

Key decisions from the conversation:

- **Static allowlist rejected for documentation/project domains** — Tier 4-5 domains are too unpredictable. A worker implementing a HeyGen integration needs `api.heygen.com`; a Cloudron worker needs `docs.cloudron.io`. Static allowlist would cause constant false-positive blocks. Graduated tiering (allow but flag) is the pragmatic choice.
- **Pattern scanner acknowledged as speed bump, not wall** — against an informed attacker who reads our open-source patterns, regex scanning is near-zero value. Enforcement layers (credential isolation, network policy) are effective regardless of attacker knowledge. Scanner remains useful against opportunistic/automated attacks and as telemetry.
- **Interactive sessions explicitly unrestricted** — the human in the loop is the enforcement layer for interactive use. Sandboxing only applies to headless workers.
- **Fake HOME chosen over container sandboxing** — containers provide stronger isolation but require per-project tool matrices (Node, Python, Rust, etc.), path remapping, and significant implementation effort. Fake HOME achieves 80% of the credential isolation value at 5% of the effort. Container sandboxing is a future enhancement.
- **Domain data sourced from session transcripts** — analyzed 1337+ GitHub hits, 276 x.com hits, and hundreds of other domains from Claude Code session transcripts (`~/.claude/transcripts/`) to build the tiering baseline. Real usage data, not guesswork.
- **Content from allowed domains can still contain injections** — the allowlist permits the connection; it doesn't make the content safe. Tier 4 documentation sites, third-party APIs, and project-specific services can all serve injection payloads. Runtime content scanning (Phase 4) addresses this orthogonal concern.
- **Clinejection reference case** — the attack chained: issue title injection → AI bot executes npm install from typosquatted repo → cache poisoning → credential theft → malicious npm publish. Our workers have the same structural exposure (shell access + untrusted input). The typosquatted repo was on github.com (Tier 1 allowed domain), so domain allowlisting alone wouldn't catch it — command pattern analysis (Phase 5) is needed for that class.

## Relevant Files

- `.agents/scripts/dispatch.sh` — worker spawning, primary integration point for Phase 1-2
- `.agents/tools/ai-assistants/headless-dispatch.md` — dispatch guidance docs
- `.agents/scripts/commands/pulse.md` — pulse dispatch flow
- `.agents/scripts/prompt-guard-helper.sh` — existing pattern scanner, Phase 4 integration
- `.agents/configs/prompt-injection-patterns.yaml` — pattern database
- `.agents/tools/security/prompt-injection-defender.md` — security docs to update
- `prompts/build.txt` — framework rules, security section to update

## Dependencies

- **Blocked by:** nothing — can start immediately
- **Blocks:** nothing directly, but improves security posture for all pulse-dispatched work
- **External:** GitHub fine-grained PAT API (Phase 2), possibly `pf`/`iptables` knowledge (Phase 3)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Phase 1: Fake HOME | ~2h | dispatch.sh modification, temp dir lifecycle |
| Phase 2: Scoped tokens | ~3h | GitHub API integration, token lifecycle |
| Phase 3: Network tiering | ~4h | Proxy/firewall wrapper, config, logging |
| Phase 4: Runtime content scanning | ~3h | Hook integration, scan-stdin wiring |
| Phase 5: Command baseline | ~3h | Logging, anomaly patterns, transcript analysis |
| Documentation | ~1h | Update security docs |
| Testing | ~2h | End-to-end worker dispatch verification |
| **Total** | **~18h** | Phases are independent, can be parallelised |
