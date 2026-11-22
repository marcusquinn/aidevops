<!-- aidevops:brief-schema=v2 -->
# t18883: Plan and prototype a buzz-aidevops Desktop plugin

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `buzz plugin aidevops integration plan` → 0 hits
- [x] Discovery pass: no existing Buzz plugin in this repo; related shipped work t18195 (GH#29498), t18205 (GH#29637), t18222 (GH#29831); open t18879 (GH#36926)
- [x] File refs verified: `.agents/scripts/buzz-desktop-helper.sh`, `.agents/tools/ai-assistants/buzz-team-interface.md`, `.agents/reference/team-interface-buzz-provisioning.md`, `.agents/plugins/opencode-aidevops/` present at HEAD
- [x] Tier: `tier:thinking` — new integration surface with a trust boundary (unsandboxed plugin + owner-reviewed host grants)
- [x] Seeded draft PR decision recorded: skipped — phase 0 is an interactive spike whose result decides the layout

## Origin

- **Created:** 2026-11-06
- **Session:** opencode:interactive (block/buzz-app team_create live test)
- **Created by:** ai-interactive
- **Conversation context:** While testing block/buzz-app#2880 in a debug Desktop build, the owner noticed the new Buzz Desktop (block/buzz-app) supports plugins and asked for a buzz-aidevops plugin to cover our setup and enhancement needs. The owner chose "write the plan and brief now; prototype after the team_create test".

## What

A single aidevops-owned Buzz Desktop plugin, shipped from this repository and recommended (never force-installed) by `aidevops buzz` setup, that replaces ad-hoc Desktop state edits with supported plugin extension points:

1. **Phase 0 (spike, interactive):** minimal `manifest.json` + `plugin.js` with one Settings card ("aidevops") that shows `aidevops buzz status` output through one declared, artifact-pinned host command. Install it into a debug Desktop build by Settings → Plugins → Git import, and record what works.
2. **Phase 1 (distribution):** `buzz-desktop-helper.sh` writes `managed-plugins.json` for the installed (`xyz.block.buzz.desktop`) and, when present, development (`xyz.block.buzz.desktop.dev`) app data folders, pinned to a release tag and full commit. Atomic temp-file + rename; restore after "erase local data"; never touch the legacy `xyz.block.buzz.app` store.
3. **Phase 2 (agent tools, read-only first):** `aidevops_*` tools via `ctx.agents.addTool` — e.g. `aidevops_status`, `aidevops_task_lookup` (TODO.md / brief lookup for the bound repo). Each tool runs a declared command; no shell, no credentials in arguments or output.
4. **Phase 3 (channel setup):** evaluate channel templates and a plugin `sidebarSections` contribution for the aidevops channel layout (Teams / Git Repos / Projects / Forums groups, starting Canvas text), after the open questions below are answered.

## Why

- Today aidevops reaches Buzz Desktop through legacy store mutation (t18195) and an external adapter (t18205/t18222). The new Desktop treats the legacy store as a one-time import source (see t18879), so that path is ending.
- Plugins are the supported extension surface: Settings cards, pages, panels, agent tools, notifications, and owner-reviewed host commands. `managed-plugins.json` lets setup recommend the plugin without silent installation.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Unsandboxed plugin code runs with the owner's session; host grants, artifact pinning and tool schemas are a security boundary and an upstream-compatibility decision.

## PR Conventions

Parent-style plan: phase PRs use `For #<this issue>` until the final phase, which uses `Resolves #<this issue>`.

## How (Approach)

### Verified plugin facts (block/buzz-app `docs/plugin-authoring-guide.md`, `docs/managed-plugins.md`, `docs/plugin-architecture.md`)

- One `plugin.js` ES module (`inject`, `apply(ctx)`), no runtime imports, classic `ctx.react.createElement`; module top level must be pure; activation must finish in 10 s; every timer/listener needs `ctx.effect` cleanup.
- Extension points: `pages`, `panels`, `settingsCards`, optional `sidebarSections` (rows `{ id, label, icon?, badge?, count?, status? }`), `conversation`, `agents.addTool` (`name` `/^[a-z][a-z0-9_]{0,63}$/`, plugin-prefixed), `shortcuts`, `navigation`, `notifications`, `browser`, `host`.
- `manifest.host`: at most 16 commands/processes/origins/hooks; bare program names; `runCommand` has a 5 s deadline and 4096-byte default output (max 1 MiB); `artifact: { path, sha256 }` pins exact bytes; changing `manifest.host` requires owner re-approval.
- `managed-plugins.json` v1: `{ version: 1, source, plugins: [{ id, repository, reference, commit, path? }] }`, ≤256 KiB, unknown fields are errors, recommends only.
- Agent types are plugin-registered: `ctx.agents.register` (`src/features/agents/service.ts:1070`, implementation `:2134-2166`); type ids match `^[a-z0-9][a-z0-9._-]*$`; `dispatchHook` only allows hooks under the plugin's own type prefix (`:1539-1559`). The built-in Claude/Codex/Goose/OpenCode harnesses are bundled plugins using this API. Not yet exercised from a third-party plugin.

### OpenCode harness findings (block/buzz-app#2432 at `157bde8ee`, tested 2026-11-07)

- Bundled plugin `buzz.opencode`, `enabledByDefault: false`; the Harness list shows OpenCode only after Settings → Plugins enables it.
- A DM to an OpenCode agent replied as `build-plus`, model `anthropic/claude-opus-5-5`, aidevops v3.39.131, cwd `~/.buzz` (workspace unset). The Finder-launched app found Homebrew `opencode` through the login-shell PATH (`src-tauri/src/host_command.rs`).
- Buzz `Config` has model, effort, instructions, workspace and scope only; every agent gets the machine's `default_agent`. `opencode acp` already reports `configOptions` `mode` (select, 17 aidevops primary agents, current `Build+`). Upstream request with the proposed change (`OPENCODE.select` → `configure("mode", …)`): block/buzz-app#2432 comment 6699412527.
- Implemented in casassg/buzz-app#1 (into `gerardc/opencode-plugin`, head `30a304ca`, ready for review 2026-11-07): `Config.mode`, mode set before model, New agent picker plus Workspace field, OpenCode Settings tab, blank/relative workspace falls back to `~/.buzz`. Live test in a debug bundle: an agent created as "Business" answered as `business`; one with its Workspace set to a repository folder under `~/` ran there. Per-computer agents are therefore a UI setup (`<agent>-<host>`, OpenCode agent, workspace) once #2432 and this land; the plugin only needs to guide or verify it.
- With the OpenCode harness the aidevops interactive greeting still opens each first reply; tracked in t18884 (GH#36983).

### Files to Modify

- NEW: `.agents/plugins/buzz-aidevops/manifest.json` — plugin id `sh.aidevops.buzz` (confirm id rules in phase 0), `apiVersion: 1`, minimal `host.commands`.
- NEW: `.agents/plugins/buzz-aidevops/plugin.js` — Settings card first; model on the guide's `settingsCards` example.
- NEW: `.agents/plugins/buzz-aidevops/README.md` — install, grants, rollback.
- EDIT: `.agents/scripts/buzz-desktop-helper.sh` — phase 1 `managed-plugins.json` writer beside `cmd_status` (`:675`) / `cmd_reconcile` (`:718`).
- EDIT: `.agents/tests/test-buzz-desktop-helper.sh` — phase 1 fixtures (isolated HOME, atomic write, schema validity, legacy store untouched).
- EDIT: `.agents/tools/ai-assistants/buzz-team-interface.md` — pointer to the plugin.

### Complete Write Surface

- **Callers/readers:** Buzz Desktop reads `managed-plugins.json` and the Git-imported plugin; `setup.sh`/`aidevops.sh` call the helper.
- **Writers/mutation paths:** only the helper writes `managed-plugins.json`; nothing writes Desktop localStorage, keychain, or agent stores.
- **Existing verification/tests:** `.agents/tests/test-buzz-desktop-helper.sh`.
- **Schemas/config:** plugin `manifest.json`; `managed-plugins.json` v1.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/` to `~/.aidevops/agents/`; the plugin is installed from the Git repository at a pinned commit, not from the deployed copy.
- **Migrations/backfills:** N/A — new surface.
- **Cleanup/rollback paths:** helper removes only the entry it wrote; owner uninstalls in Settings → Plugins.

### Implementation Steps

1. Phase 0 (team_create live test passed): build the spike in a linked worktree, push a branch, Git-import it into the debug Desktop (`xyz.block.buzz.desktop.dev`), screenshot the review dialog and card, record findings in this brief.
2. Phase 1: managed-plugins writer + fixtures; release-tag pinning.
3. Phase 2: read-only agent tools; restart-impact note (changing tool schema restarts agent sessions).
4. Phase 3: decide channel-template / sidebar approach from the open questions.

### Hazards and Compatibility

- **Trust:** plugins are trusted and unsandboxed. Keep grants minimal; pin command artifacts by SHA-256; never pass secrets through tool args, output, or Canvas.
- **Compatibility:** plugin API is `apiVersion: 1`, pre-1.0 app; re-verify docs at each phase.
- **Legacy:** never write `xyz.block.buzz.app` state (t18879 boundary).
- **Idempotency:** policy writer is idempotent and atomic.

### Verification Before Dispatch

```bash
bash .agents/tests/test-buzz-desktop-helper.sh
shellcheck .agents/scripts/buzz-desktop-helper.sh .agents/tests/test-buzz-desktop-helper.sh
.agents/scripts/linters-local.sh --diff
```

- **Runtime evidence:** Settings → Plugins review dialog lists exactly the declared grants; the card renders `aidevops buzz status`; uninstall leaves no residue.

### Scope Boundaries

**Hard boundaries:** no silent install; no writes to Desktop localStorage, keychain or agent stores; no credential handling; no live Cloudron changes.

**Dispatch hold:** `no-auto-dispatch` — every phase needs the owner's in-app plugin review (a human UI action) and phase 0 is owned by the interactive session that filed this.

**AI brief owner:** marcusquinn interactive session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/plugins/buzz-aidevops/manifest.json`
- `.agents/plugins/buzz-aidevops/plugin.js`
- `.agents/plugins/buzz-aidevops/README.md`
- `.agents/scripts/buzz-desktop-helper.sh`
- `.agents/tests/test-buzz-desktop-helper.sh`
- `.agents/tools/ai-assistants/buzz-team-interface.md`

## Acceptance Criteria

- [x] Phase 0: spike installs via Git import in a debug Desktop, its review dialog shows only the declared grants, and the Settings card renders `aidevops buzz status`; findings recorded here. Done in PR #36998 and tested 2026-11-08 in the official `v0.7.0-preview.254.1` build, installed from the deployed folder (`~/.aidevops/agents/plugins/buzz-aidevops`) rather than Git import: the review listed only `aidevops buzz status` and the card rendered live status.
- [ ] Agent type (GH#37233): an `aidevops` agent type runs `aidevops buzz acp --member NAME --project DIR` per agent; a DM gets a threaded reply in the preview; the review lists the `aidevops buzz acp` process and MCP; Buzz 0.5 agents unaffected.
- [ ] Phase 1: helper writes a valid `managed-plugins.json` (schema v1, pinned commit) atomically for each present new-Desktop identifier; legacy store byte-identical; fixtures pass.
- [ ] Phase 2: read-only `aidevops_*` tools callable by a local agent; no secret in args/output.
- [ ] Phase 3: decision recorded for channel templates and sidebar presentation, with upstream issues linked where the plugin API cannot cover it.

## Context & Decisions

- Owner scope (2026-11-06): run the aidevops primary agents on each computer with Buzz installed, named `<agent>-<host>` (for example `build-plus-marcus-macbook-pro-01`) so a request shows which agent and computer it addresses. Delivery path: OpenCode harness (#2432) plus a per-agent `mode` selection upstream; the plugin's role is setup and status, not a second harness.
- Owner asks filed upstream: per-channel default agent (no @mention needed), block/buzz-app#2923; community rail back in the left sidebar, block/buzz-app#2922. ("Channel icons" meant the community rail.)
- Channel templates in this build are local-only (`buzz.channel-templates.v1` in Desktop localStorage: name, agents, teams, starting Canvas ≤24 KiB; `src/features/channel-templates/local.ts`). Settings → Channel templates offers "New template" only; there is no template import/export (`docs/agents.md:1443`). Phase 3 must work within that or request export upstream.
- Rejected: writing Desktop localStorage from the plugin to seed templates — not a contract.
- ~~Rejected for now: shipping our own OpenCode harness in the plugin — #2432 covers it; revisit only if #2432 stalls or rejects `mode` selection.~~ Reversed by the owner on 2026-11-08: the official 0.7 previews ship no OpenCode harness, and the #2432 review (tellaho, 2026-11-08) asks for it to be distributed externally. The plugin now adds an `aidevops` agent type (GH#37233) using the documented harness kit (`ctx.agents.harness`, `docs/plugin-architecture.md:578-606`), `host.spawn` and `host.serveMcp`. It reuses the aidevops roster, worktree, overlay and launcher, so each agent keeps its `<agent>-<host>` name and Claude models. If #2432 or a shared external OpenCode plugin ships with per-agent `mode`, compare and retire whichever duplicates the other.

## Relevant Files

- `.agents/scripts/buzz-desktop-helper.sh:14,392,642,675,718`
- `.agents/tools/ai-assistants/buzz-team-interface.md`
- `.agents/reference/team-interface-buzz-provisioning.md`
- `todo/tasks/t18879-brief.md`

## Dependencies

- block/buzz-app#2930 (team_create; replaces #2880, closed when its base merged): live test passed 2026-11-06, so phase 0 is unblocked.
- block/buzz-app#2432 (OpenCode harness) and its per-agent `mode` selection, for the per-computer agent layout.
- t18879 (new-Desktop detection) for phase 1 identifier gating.

## Estimate Breakdown

~10h: phase 0 2h, phase 1 3h, phase 2 3h, phase 3 2h.
