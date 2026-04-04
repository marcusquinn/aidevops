---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
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
- **User action:** May require one-time GitHub App installation (org/account level) if using the App-based token creation route. If using `gh auth` delegation with dispatch-level restriction, no user action needed — but isolation is weaker (worker still has the full token, restrictions are advisory not enforced by GitHub). Prefer the zero-config approach; fall back gracefully if GitHub App is not installed rather than breaking existing dispatch.

### Phase 3: Network tiering

Implement as a transparent logging proxy or pf/iptables rules wrapper.
- **User action:** If implemented via local proxy or firewall rules, `setup.sh` should handle installation automatically. Users with legitimate use of denied domains (e.g., ngrok for local tunnel testing) need a config escape hatch (`~/.config/aidevops/network-allowlist-overrides.yaml` or similar). If proxy is not installed, fall back to logging-only mode (no blocking) rather than breaking workers.

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
- Integration point: OpenCode hooks (PostToolUse) or wrapper functions in dispatch

### Phase 5: Command pattern baseline (stretch)

- Log all Bash commands executed by workers
- Flag anomalous patterns: `npm install` from git URLs not in lockfile, `curl | bash`, `wget` to unknown domains, reads of `~/.ssh/` or credential paths
- Baseline built from historical transcript analysis (session data already collected)

### Phase 6: Startup security posture check

Extend `aidevops-update-check.sh` (the interactive session greeting script) to scan for pending security actions the user needs to take. The script already has a pattern for appending checks (stale local models at line 239, concurrent sessions at line 250).

Add a `security-posture-helper.sh check` call that reports:
- Whether worker credential isolation is active (fake HOME configured in dispatch)
- Whether scoped GitHub tokens are available (GitHub App installed, or fallback mode)
- Whether network tiering proxy is installed and running
- Whether prompt-guard-helper.sh patterns are up to date (YAML file present, not stale)
- Any other pending security setup actions

Output format follows existing pattern — a single line or short block appended to the greeting. Example:

```text
Security: 2 actions needed — run `aidevops security setup` for details
```

Or when everything is configured:

```text
Security: all worker protections active
```

The `aidevops security setup` command walks the user through any pending actions (GitHub App install, proxy setup, etc.) interactively. This is the only user-facing entry point for security configuration.

Key files:
- `.agents/scripts/aidevops-update-check.sh:239` — insertion point (after stale models, before session warning)
- `.agents/scripts/security-posture-helper.sh` — new script for posture checks
- `setup.sh` — may need security setup integration

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
- [ ] Interactive session startup shows pending security actions (or "all protections active")
  ```yaml
  verify:
    method: bash
    run: "bash ~/.aidevops/agents/scripts/security-posture-helper.sh check 2>/dev/null; test $? -le 1"
  ```
- [ ] `aidevops security setup` command walks user through pending actions interactively
- [ ] Documentation updated: `prompt-injection-defender.md`, `headless-dispatch.md`, `build.txt`
- [ ] ShellCheck clean on all new/modified scripts
- [ ] Existing worker dispatch tests still pass

## Context & Decisions

Key decisions from the conversation:

- **Static allowlist rejected for documentation/project domains** — Tier 4-5 domains are too unpredictable. A worker implementing a HeyGen integration needs `api.heygen.com`; a Cloudron worker needs `docs.cloudron.io`. Static allowlist would cause constant false-positive blocks. Graduated tiering (allow but flag) is the pragmatic choice.
- **Pattern scanner acknowledged as speed bump, not wall** — against an informed attacker who reads our open-source patterns, regex scanning is near-zero value. Enforcement layers (credential isolation, network policy) are effective regardless of attacker knowledge. Scanner remains useful against opportunistic/automated attacks and as telemetry.
- **Interactive sessions explicitly unrestricted** — the human in the loop is the enforcement layer for interactive use. Sandboxing only applies to headless workers.
- **Fake HOME chosen over container sandboxing** — containers provide stronger isolation but require per-project tool matrices (Node, Python, Rust, etc.), path remapping, and significant implementation effort. Fake HOME achieves 80% of the credential isolation value at 5% of the effort. Container sandboxing is a future enhancement.
- **Domain data sourced from session transcripts** — analyzed 1337+ GitHub hits, 276 x.com hits, and hundreds of other domains from OpenCode session transcripts to build the tiering baseline. Real usage data, not guesswork.
- **Content from allowed domains can still contain injections** — the allowlist permits the connection; it doesn't make the content safe. Tier 4 documentation sites, third-party APIs, and project-specific services can all serve injection payloads. Runtime content scanning (Phase 4) addresses this orthogonal concern.
- **Clinejection reference case** — the attack chained: issue title injection → AI bot executes npm install from typosquatted repo → cache poisoning → credential theft → malicious npm publish. Our workers have the same structural exposure (shell access + untrusted input). The typosquatted repo was on github.com (Tier 1 allowed domain), so domain allowlisting alone wouldn't catch it — command pattern analysis (Phase 5) is needed for that class.
- **Intelligence over regex for untrusted content** — non-maintainer issue bodies, PR diffs, and linked content should get a haiku-tier semantic injection scan before reaching worker context. Pattern scanning catches known templates; LLM classification catches paraphrased/novel injections. Cost: ~$0.001 per scan, only triggered for non-collaborator content.
- **Tamper-evident logging via privilege separation** — named pipe to a separate logger process running as a different UID. Worker can write to the pipe but cannot read, modify, or delete the log file. Optional remote syslog forwarding for true tamper-prevention (bytes leave the machine before attacker can delete them). `chattr +a` on Linux as a simpler alternative; macOS `chflags sappnd` is ineffective with SIP.
- **MCP servers are a distinct trust boundary** — MCP servers run as persistent processes with network access and can inject via tool responses. Users should be warned at install time. Socket.dev is already configured for aidevops and can scan MCP server dependencies.
- **CI/CD AI agent security is a documentation gap** — our workers run locally, but users may deploy AI triage in their own CI. The Clinejection pattern (AI bot + shell access + cached credentials + untrusted input) applies to any CI/CD AI integration. Guidance belongs in opsec.md with cross-refs from git-workflow.md.
- **Per-repo security posture via `aidevops init`** — the framework protections (Phases 1-8) apply to all repos automatically via the dispatch layer. But per-repo configuration (branch protection, CI workflow scanning, Socket.dev dependency scanning) needs to happen at init time. `aidevops init` already has a feature-flag system (`planning`, `git-workflow`, `code-quality`, etc.) — add a `security` feature that audits the repo's CI workflows, branch protection, and dependencies. Also add `aidevops security audit` for re-running checks on demand.
- **Phase 7 collaborator check is per-repo, not global** — the intelligence-layer scan checks `gh api repos/{slug}/collaborators` for the specific repo the worker is operating on. A maintainer of repo A is not necessarily trusted in repo B. Never cache a global trusted-users list — always query the target repo's collaborator list at scan time.
- **StackOne Defender as reference implementation and dependency** — `@stackone/defender` (Apache-2.0, github.com/stackoneHQ/defender) provides a two-tier prompt injection defense for tool-calling: Tier 1 regex patterns with keyword pre-filter (~1ms) + Tier 2 ONNX MiniLM classifier (~10ms, F1 0.91, 22MB bundled model). Key techniques to adopt in our framework: (1) keyword pre-filter before regex (100x faster for clean content), (2) NFKC Unicode normalization before pattern matching (closes mathematical/fullwidth/modifier letter bypasses our patterns miss), (3) boundary annotation wrapping untrusted content in `[UNTRUSTED-DATA-{uuid}]...[/UNTRUSTED-DATA-{uuid}]` tags so the model knows the trust boundary, (4) ONNX classifier as fast local Tier 2a before haiku API call (Tier 2b). Additionally, for SaaS/web projects built with aidevops, `@stackone/defender` is a direct dependency recommendation — workers implementing features that process untrusted content with LLMs (email handlers, comment systems, CRM integrations, AI-powered search, MCP tool-calling) should integrate `defendToolResult()` as middleware. Add to agent knowledge base so workers recommend it when building products that handle untrusted user input + LLMs.

## Relevant Files

- `.agents/scripts/dispatch.sh` — worker spawning, primary integration point for Phase 1-2
- `.agents/tools/ai-assistants/headless-dispatch.md` — dispatch guidance docs
- `.agents/scripts/commands/pulse.md` — pulse dispatch flow
- `.agents/scripts/prompt-guard-helper.sh` — existing pattern scanner, Phase 4 + 7 integration
- `.agents/configs/prompt-injection-patterns.yaml` — pattern database
- `.agents/tools/security/prompt-injection-defender.md` — security docs to update
- `.agents/tools/security/opsec.md` — CI/CD security guidance (Phase 9)
- `.agents/workflows/git-workflow.md` — cross-ref for CI/CD guidance
- `prompts/build.txt` — framework rules, security section to update
- `.agents/scripts/aidevops-update-check.sh:239` — startup greeting, insertion point for security posture check
- `.agents/scripts/security-posture-helper.sh` — new: security posture checker
- `.agents/tools/mcp-toolkit/mcporter.md` — MCP install flow, add security warnings (Phase 10)
- `.agents/tools/code-review/skill-scanner.md` — existing skill scanning, extend to MCP servers
- `.agents/services/monitoring/socket.md` — Socket.dev integration (already configured)
- `aidevops.sh:1170` — `cmd_init()` function, add security feature (Phase 11)

## Dependencies

- **Blocked by:** nothing — can start immediately
- **Blocks:** nothing directly, but improves security posture for all pulse-dispatched work
- **External:** GitHub fine-grained PAT API (Phase 2), possibly `pf`/`iptables` knowledge (Phase 3), Anthropic API for haiku calls (Phase 7)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Phase 1: Fake HOME | ~2h | dispatch.sh modification, temp dir lifecycle |
| Phase 2: Scoped tokens | ~3h | GitHub API integration, token lifecycle |
| Phase 3: Network tiering | ~4h | Proxy/firewall wrapper, config, logging |
| Phase 4: Runtime content scanning | ~3h | Hook integration, scan-stdin wiring |
| Phase 5: Command baseline | ~3h | Logging, anomaly patterns, transcript analysis |
| Phase 6: Startup security check | ~2h | security-posture-helper.sh, `aidevops security setup` |
| Phase 7: Intelligence-layer scan | ~3h | Haiku classifier, per-repo collaborator check, dispatch integration |
| Phase 8: Tamper-evident audit logging | ~4h | Named pipe, privileged logger daemon, launchd/systemd |
| Phase 9: CI/CD AI agent security docs | ~2h | opsec.md section, cross-refs, Clinejection case study |
| Phase 10: MCP install security warnings | ~2h | mcporter.md, install flow warnings, Socket.dev integration |
| Phase 11: Per-repo security in aidevops init | ~3h | CI workflow scan, branch protection check, Socket.dev, `aidevops security audit` |
| Testing | ~3h | End-to-end worker dispatch + audit trail verification |
| **Total** | **~34h** | Phases are independent, can be parallelised |
