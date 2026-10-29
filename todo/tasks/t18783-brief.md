# t18783: OpenCode 2.x migration-readiness checks (V2 parity tracker)

## Origin

- Issue: GH#35902 (interactive session; parent tracker, never dispatched)

## What

Persistent tracker for OpenCode 2.x (V2) migration-readiness checks: aidevops features that work on V1 (`opencode`) but are missing, degraded or unverified on V2 (`opencode2`). Each item links its own child issue; this parent is never dispatched itself.

## Why

Many V2 parity gaps surface only by accident during unrelated work (for example GH#35898, found while shipping the GH#35517 idle-gated archive). The recurring canary (GH#35179-style "Promote passing OpenCode v2 compatibility candidate") proves that V2 loads, not that every framework feature works. Without one checklist, gaps get lost before `.agents/configs/opencode-runtime-profiles.json` switches `"default"` from `v1` to `v2`.

## How (Approach)

Add one checklist line per gap, with evidence and the child issue. File each fix as a separate worker-ready child issue (`Parent: #<this>`), and tick the line when that child merges.

### Checklist

- [ ] **DB activity heartbeat (GH#35898, PR #35901).** The V2 plugin never installed the GH#35517 heartbeat, so V2-held `opencode.db` files were never archived. The V1 module also misread V2 `{type, data}` events. Fixed in PR #35901 and runtime-verified through `setupAidevopsV2`.
- [ ] **Heartbeat PID match on a live `opencode2` host.** The archive gate matches heartbeat files by DB holder PID (`.agents/scripts/opencode-db-idle-gate-lib.sh:130`). `v2.mjs:523` says plugins run in-process, but this has not been confirmed on a real `opencode2` binary. Check: `lsof` holder PID equals the `pid` field in `~/.aidevops/.agent-workspace/state/opencode-activity/*.json`. The gate fails closed (defers) if they differ.
- [ ] **DB archive/maintenance path and schema on V2.** `.agents/scripts/opencode-db-archive.sh:51-54` assumes the V1 data dir `${XDG_DATA_HOME:-~/.local/share}/opencode`. V2's storage path and schema compatibility are unverified (`@opencode/schema` 2.2.0 ships `session-legacy.js`). Exact paths are unknown until checked on an `opencode2` install.
- [ ] **Compaction cache-prefix divergence (GH#33471).** Existing blocked investigation.
- [ ] **`textCompletionHook: false`** (`.agents/plugins/opencode-aidevops/v2.mjs:115`). No V2 equivalent is wired. Needs an inventory of the V1 features that depend on it.
- [ ] **`compactionAutocontinue: false`** (`v2.mjs:116`). V1 post-compaction auto-continue has no V2 equivalent yet.
- [ ] **`tuiToast: false`** (`v2.mjs:117`). V1 toasts (greeting/advisories, update warnings) have no V2 surface yet.

### Files Scope

- `.agents/plugins/opencode-aidevops/v2.mjs`
- `.agents/scripts/opencode-db-archive.sh`
- `.agents/scripts/opencode-db-idle-gate-lib.sh`
- `.agents/configs/opencode-runtime-profiles.json`

## Acceptance Criteria

- [ ] Every checklist item is either ticked against a merged child PR or recorded as an explicit accepted V2 limitation with rationale.
- [ ] Regression guard: `.agents/configs/opencode-runtime-profiles.json` `"default"` does not switch to `v2` while any unticked item affects interactive sessions or DB maintenance.

## Context & Decisions

- This is a parent tracker (`parent-task`): it blocks dispatch of itself only; children are dispatched normally.
- Capability flags are the authoritative in-code gap list; keep this checklist in sync when a flag flips.
