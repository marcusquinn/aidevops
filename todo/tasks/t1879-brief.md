---
mode: subagent
---
# t1879: Research mngr tmux/provider Architecture for SaaS Agent Hosting

## Origin

- **Created:** 2026-04-03
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) + ai-interactive
- **Conversation context:** Analysis of imbue-ai/mngr repo. User noted aidevops will be used for SaaS development where users need AI agents running on secure containers for the lifespan of their use. mngr's tmux-based process management, provider abstraction, and idle detection could inform the hosting layer architecture. Also noted similarity to fly.io and others in the hosting agents space. Current runners are OpenCode sessions.

## What

Produce a design research document at `todo/research/saas-agent-hosting.md` that evaluates mngr's architecture as a design reference for aidevops SaaS agent hosting, covering process management, provider abstraction, idle detection, state management, and multi-tenant security. Conclude with a recommended architecture for an MVP.

This is a **research task** — no code changes. Output is a design document that informs future implementation tasks.

## Why

aidevops is moving toward SaaS development where users will need AI agents running in secure containers. Key requirements:
- Agents must run for the duration of the user's session (minutes to hours)
- Secure isolation between tenants
- Cost control (auto-shutdown idle agents)
- Support multiple hosting providers (Hetzner, fly.io, Modal, Docker, bare VPS)
- Observable (transcripts, status, debugging access)

mngr has solved many of these problems for single-user developer tooling. The question is: what patterns transfer to multi-tenant SaaS, what needs modification, and what's missing?

## How (Approach)

### Research areas

1. **Process management: tmux vs alternatives**
   - mngr uses tmux sessions as the agent container. Evaluate:
   - tmux: universal, scriptable, detachable, no daemon. But: no cgroups, no resource limits, no native health checks.
   - systemd: resource limits, restart policies, journal logging. But: requires root, per-user units are newer.
   - supervisor/pm2: language-specific, daemon overhead.
   - Recommendation: tmux for simplicity on MVP, with a path to systemd for production.

2. **Provider abstraction**
   - mngr's `ProviderBackend` interface: `create_host()`, `destroy_host()`, `get_host_state()`, `list_hosts()`.
   - How to support: Hetzner Cloud (API), fly.io (flyctl), Modal (Python SDK), Docker (docker CLI), bare VPS (SSH).
   - Key question: do we wrap mngr, fork it, or build our own provider layer?

3. **Idle detection and cost control**
   - mngr's idle modes (io, user, agent, ssh, create, boot, run, disabled).
   - Activity file pattern (`$MNGR_HOST_DIR/activity/`).
   - How this maps to SaaS billing: pause on idle, resume on request, auto-destroy after timeout.

4. **Convention-based state discovery**
   - mngr uses prefixed naming and standard directories instead of a database.
   - Pros: no single point of failure, multiple managers can coexist, self-describing containers.
   - Cons: discovery is slower than DB lookup, requires SSH to query state.
   - For SaaS: we likely need a thin metadata layer (Redis/SQLite) on top of convention-based container state.

5. **Multi-tenant security**
   - mngr is single-user. For SaaS:
   - Container isolation per tenant (Docker/fly.io machines)
   - SSH key isolation per tenant (mngr already does per-host SSH keys)
   - Network allowlists (mngr supports `-b offline` and `-b cidr-allowlist`)
   - Credential injection per-agent (environment variables, not filesystem)
   - Audit trail per-tenant

6. **Snapshot/restore lifecycle**
   - mngr snapshots on stop, restores on start. Enables pause/resume billing.
   - Docker: `docker commit` (slow for large containers)
   - Modal: native snapshots (fast, incremental)
   - fly.io: machine pause/resume (native)
   - For SaaS: snapshot = billing stops, resume = billing starts.

7. **Build vs adopt vs fork**
   - **Adopt mngr**: Use as dependency. Pros: ready-made CLI, tested provider backends. Cons: Python dependency, single-user assumption baked deep, MIT license allows it.
   - **Fork mngr**: Take the architecture, rewrite multi-tenant parts. Pros: proven patterns. Cons: maintenance burden of a fork.
   - **Build own**: Use mngr patterns as design reference. Pros: tailored to our stack (shell + agent framework). Cons: more upfront work.
   - **Hybrid**: Use mngr as the per-container agent manager, build the multi-tenant orchestration layer on top.

### Output format

`todo/research/saas-agent-hosting.md` with:
- Architecture diagram (mermaid)
- Comparison tables for each research area
- Recommended MVP architecture
- Estimated implementation effort
- Open questions for user decision

## Acceptance Criteria

- [ ] Design document exists at `todo/research/saas-agent-hosting.md`
  ```yaml
  verify:
    method: bash
    run: "test -f todo/research/saas-agent-hosting.md"
  ```
- [ ] Covers all 7 research areas listed above
  ```yaml
  verify:
    method: subagent
    prompt: "Does the document cover: (1) process management comparison, (2) provider abstraction, (3) idle detection, (4) state management, (5) multi-tenant security, (6) snapshot/restore, (7) build vs adopt vs fork recommendation?"
    files: "todo/research/saas-agent-hosting.md"
  ```
- [ ] Includes comparison table: build vs adopt vs fork mngr
  ```yaml
  verify:
    method: codebase
    pattern: "build.*adopt.*fork|adopt.*fork.*build"
    path: "todo/research/saas-agent-hosting.md"
  ```
- [ ] Includes recommended MVP architecture with diagram
  ```yaml
  verify:
    method: codebase
    pattern: "mermaid|```mermaid"
    path: "todo/research/saas-agent-hosting.md"
  ```
- [ ] Includes estimated implementation effort
  ```yaml
  verify:
    method: codebase
    pattern: "estimate|effort|timeline"
    path: "todo/research/saas-agent-hosting.md"
  ```
- [ ] References mngr repo as source
  ```yaml
  verify:
    method: codebase
    pattern: "imbue-ai/mngr"
    path: "todo/research/saas-agent-hosting.md"
  ```

## Context & Decisions

- mngr is MIT licensed — adoption/forking is legally viable
- User explicitly noted this is relevant to the aidevops SaaS roadmap, not just an academic exercise
- User corrected: runners are OpenCode sessions, not Claude Code
- User noted similarity to fly.io and others in the hosting agents space
- This is opus-tier research — needs deep architectural thinking, not just surface comparison
- The research should be actionable: when the SaaS hosting work begins, this doc should be the starting point

## Relevant Files

- mngr source: `https://github.com/imbue-ai/mngr/` (external)
- mngr architecture: `libs/mngr/docs/architecture.md` (external)
- mngr concepts: `libs/mngr/docs/concepts/` (external — agents, hosts, providers, idle_detection, plugins, provisioning, snapshot)
- aidevops headless dispatch: `.agents/scripts/headless-runtime-helper.sh`
- aidevops pulse: `.agents/scripts/commands/pulse.md`
- aidevops repos config: `~/.config/aidevops/repos.json`

## Dependencies

- **Blocked by:** nothing
- **Blocks:** future SaaS agent hosting implementation tasks
- **External:** access to mngr repo (public, MIT)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 3h | Deep read of mngr architecture, providers, idle detection, security model |
| Analysis | 3h | Comparison tables, architecture evaluation, multi-tenant gap analysis |
| Writing | 2h | Design document with diagrams and recommendations |
| **Total** | **8h** | |
