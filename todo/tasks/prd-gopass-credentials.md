---
mode: subagent
---
# Product Requirements Document: gopass Integration & Credentials Rename

Based on [ai-dev-tasks](https://github.com/snarktank/ai-dev-tasks) PRD format, with time tracking.

<!--TOON:prd{id,feature,author,status,est,est_ai,est_test,est_read,logged}:
prd-gopass-credentials,gopass Integration & Credentials Rename,aidevops,draft,2d,1d,4h,4h,2026-02-06T20:00Z
-->

## Overview

**Feature:** gopass Integration & Credentials Rename
**Author:** aidevops
**Date:** 2026-02-06
**Status:** Draft
**Estimate:** ~2d (ai:1d test:4h read:4h)

### Problem Statement

aidevops stores credentials as plaintext `export` statements in `~/.config/aidevops/mcp-env.sh` (permissions 600). While file permissions prevent other users from reading the file, the secrets are:

1. **Unencrypted at rest** -- anyone with disk access (stolen laptop, backup leak) can read them
2. **Visible to AI agents** -- agents can `cat`, `source`, `echo`, or `env` to see secret values in their context window
3. **Named misleadingly** -- `mcp-env.sh` implies MCP-only use, but the file stores credentials for agents, scripts, skills, CLI tools, and services
4. **Not team-shareable** -- no mechanism to share secrets across team members securely
5. **Not auditable** -- no history of who changed what credential and when

### Goal

1. Adopt gopass as the recommended encrypted secrets backend (GPG/age encryption, git-versioned, team-shareable)
2. Build an AI-native wrapper (`aidevops secret`) that keeps secret values out of agent context windows via subprocess injection and output redaction
3. Rename `mcp-env.sh` to `credentials.sh` across the entire codebase (83 files, 261 references) with backward-compatible symlink migration
4. Ensure users are always prompted to store secrets via shell interactive input, never in AI conversation context

## User Stories

### Primary User Story

As an aidevops user, I want my API keys encrypted at rest and invisible to AI agents so that a stolen laptop or context window leak doesn't expose my credentials.

### Additional User Stories

- As a team lead, I want to share API keys with team members via GPG-encrypted git sync so that onboarding doesn't require pasting secrets in Slack.
- As an AI agent, I want to execute commands that need API keys without seeing the key values so that secrets never enter my context window.
- As a developer, I want `credentials.sh` as the filename so that the purpose of the file is immediately obvious regardless of which tool consumes it.
- As a user migrating from the old system, I want a symlink from `mcp-env.sh` to `credentials.sh` so that my existing shell config doesn't break.
- As a user, I want to store secrets via `gopass insert` or `aidevops secret set` at my terminal prompt so that the value is never typed into an AI conversation.

## Functional Requirements

### Core Requirements

1. **gopass as recommended backend**: Document gopass installation, setup, and usage. Detect gopass availability in credential-helper.sh and prefer it when present.
2. **`aidevops secret` wrapper command**: CLI subcommand that provides:
   - `aidevops secret set NAME` -- delegates to `gopass insert` (interactive hidden input)
   - `aidevops secret list` -- delegates to `gopass ls` (names only, never values)
   - `aidevops secret run CMD` -- inject all secrets into subprocess environment, redact output
   - `aidevops secret NAME [NAME...] -- CMD` -- inject specific secrets, redact output
   - `aidevops secret import-credentials` -- migrate from credentials.sh to gopass vault
3. **Output redaction**: All stdout/stderr from `aidevops secret run` must have secret values replaced with `[REDACTED]` before reaching the agent's context.
4. **Rename mcp-env.sh to credentials.sh**: Update all 83 files (261 references). Variable rename `MCP_ENV_FILE` to `CREDENTIALS_FILE` in 7 scripts.
5. **Backward-compatible migration**: If `mcp-env.sh` exists and `credentials.sh` doesn't, auto-migrate (move + symlink). Symlink preserved for shell rc compat.
6. **Agent instructions**: AGENTS.md updated with mandatory rule: "When a user needs to store a secret, ALWAYS instruct them to run `aidevops secret set NAME` or `gopass insert NAME` at their shell. NEVER accept secret values in conversation context."

### Secondary Requirements

7. **`psst get` defense**: Agent instructions must prohibit `gopass show` / `psst get` / any command that prints secret values. Defense in depth: instructions + documentation.
8. **gopass environment mapping**: Map aidevops multi-tenant concept to gopass mounts (default store + per-tenant mounted stores).
9. **MCP server credential injection**: Document `aidevops secret run -- npx some-mcp-server` pattern as replacement for `source credentials.sh && npx some-mcp-server`.
10. **psst as documented alternative**: Document psst alongside gopass for users who prefer it. Note trade-offs (simpler, less mature, no team features, Bun dependency).
11. **gopass for git credentials**: Document `git-credential-gopass` integration for storing git tokens.
12. **gopass for browser passwords**: Document gopass-bridge for Firefox/Chrome password filling.

## Non-Goals (Out of Scope)

- Replacing Vaultwarden/Bitwarden integration (remains as optional enterprise layer)
- Automated secret rotation (manual with documented 90-day policy)
- Cloud-hosted secret management (gopass is local-first; cloud sync via git remote)
- Removing credentials.sh entirely (kept as fallback for MCP server launching and non-gopass workflows)

## Design Considerations

### User Interface

All secret operations happen at the shell prompt. The AI agent never sees secret values. The agent instructs the user what command to run, and the user executes it in their terminal.

```text
Agent: "I need a Stripe API key. Please run: aidevops secret set STRIPE_KEY"
User runs at terminal: aidevops secret set STRIPE_KEY
  Enter value for STRIPE_KEY: ******* (hidden input)
Agent: "Now I can use it: aidevops secret STRIPE_KEY -- curl ..."
```

### User Experience

1. `aidevops update` installs gopass if not present (with user confirmation)
2. `aidevops secret init` runs `gopass setup` (one-time)
3. `aidevops secret import-credentials` migrates existing keys
4. Day-to-day: agent uses `aidevops secret NAME -- command` transparently

## Technical Considerations

### Architecture

```text
                    User Terminal (interactive)
                           |
                    aidevops secret set NAME
                           |
                    gopass insert aidevops/NAME
                           |
              ~/.local/share/gopass/stores/root/
              (GPG-encrypted files, git-versioned)
                           |
              aidevops secret NAME -- command
                           |
              1. gopass show -o aidevops/NAME
              2. Inject into subprocess env
              3. Execute command
              4. Redact output
              5. Return exit code
```

### Dependencies

- **gopass**: `brew install gopass` / `apt install gopass` / `pacman -S gopass` -- single Go binary, no runtime deps
- **GPG**: Required for gopass encryption (already common on dev machines)
- **git**: Required for gopass versioned storage (already required by aidevops)

### Constraints

- gopass requires GPG key pair (setup wizard handles this)
- macOS users need `pinentry-mac` for GPG passphrase entry
- CI/headless environments need `GOPASS_PASSWORD` or age backend (no GPG agent)

### Security Considerations

- Secret values NEVER appear in agent context (subprocess injection only)
- Secret values NEVER appear in command output (automatic redaction)
- Secrets encrypted at rest with GPG (industry-standard, audited)
- Encryption keys in GPG keyring (OS-level protection)
- Git history provides audit trail of credential changes
- `gopass audit` checks for weak/compromised passwords
- `gopass-hibp` integration checks against known breaches

## Time Estimate Breakdown

| Phase | AI Time | Test Time | Read Time | Total |
|-------|---------|-----------|-----------|-------|
| Part A: Rename (mechanical) | 3h | 1h | 30m | 4.5h |
| Part B: gopass integration | 4h | 2h | 2h | 8h |
| Part C: Documentation | 1h | 1h | 1.5h | 3.5h |
| **Total** | **8h** | **4h** | **4h** | **16h** |

<!--TOON:time_breakdown[3]{phase,ai,test,read,total}:
part-a-rename,3h,1h,30m,4.5h
part-b-gopass,4h,2h,2h,8h
part-c-docs,1h,1h,1.5h,3.5h
-->

## Success Metrics

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| Secret values in agent context | 0 occurrences | Grep agent logs for known test secret patterns |
| Encryption at rest | 100% of secrets | `gopass ls` shows all migrated keys |
| Backward compat | Zero breakage | `source ~/.config/aidevops/mcp-env.sh` still works via symlink |
| Rename coverage | 83/83 files updated | `rg 'mcp-env' .agents/ setup.sh configs/` returns 0 |
| Team sharing | Functional | Two GPG recipients can both decrypt shared store |

## Open Questions

- [x] gopass vs psst as primary? **Decision: gopass** (mature, GPG, team-ready, zero runtime deps)
- [ ] Should `aidevops secret` be a new script or extend `credential-helper.sh`?
- [ ] Should gopass store path use `aidevops/` prefix or flat namespace?
- [ ] Should `aidevops update` auto-install gopass or just recommend it?
- [ ] age vs GPG as default encryption backend? (age is simpler but less ecosystem support)

## Appendix

### Related Documents

- `.agents/tools/credentials/api-key-setup.md` -- Current setup guide (to be updated)
- `.agents/tools/credentials/multi-tenant.md` -- Multi-tenant architecture (to be mapped to gopass mounts)
- `.agents/tools/credentials/vaultwarden.md` -- Enterprise layer (unchanged)
- gopass docs: https://github.com/gopasspw/gopass/tree/master/docs

### Alternatives Evaluated

| Tool | Verdict | Reason |
|------|---------|--------|
| **gopass** | **Selected** | 6.7k stars, GPG/age, git-versioned, team-ready, single Go binary, 8+ years |
| psst | Documented alternative | AI-native design but v0.3.0, 61 stars, Bun dep, no team features |
| mcp-secrets-vault | Rejected | 4 stars, no encryption (just env var wrapper), MCP-only |
| rsec (RunSecret) | Rejected | 7 stars, no local encryption, team vault only (AWS/Azure/HashiCorp) |
| cross-keychain | Rejected | Library not CLI, no vault concept |

### Revision History

| Date | Author | Changes |
|------|--------|---------|
| 2026-02-06 | aidevops | Initial draft from research session |
