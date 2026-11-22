<!-- aidevops:brief-schema=v2 -->
# t18895: Session bus coordination: who is working on what, and overlap warnings before work starts

## Origin

- **Created:** 2026-11-08
- **Session:** opencode:interactive ses_e480fcfa0ffeCzemlBnZ5j1VBA (t18886 session bus, GH#37149, PR #37165, released in v3.39.136)
- **Created by:** ai-interactive
- **Conversation context:** The owner said a common need for session-to-session messaging is "avoiding working on the same things in competing ways", and asked for the implementation to cover it, based on experience of what helps productivity. Live evidence on 2026-11-08: `aidevops sessions list` showed 9 live sessions, including two pairs that each shared one client repository on `main`. Nothing warned either pair. The mandatory pre-work collision check (`prework-discovery-helper.sh`) only searches GitHub (merged and open PRs, `status:claimed` issues), so it cannot see live sessions that have not pushed or claimed anything yet.

## What

1. **`aidevops sessions who <target>`** (and an `aidevops_sessions` `who` action): for `#<issue>`, `PR#<n>`, a repo slug, a worktree path or a file path, list the live sessions working on it. Each row shows the handle, status, branch, worktree, current task and last activity. A file path matches the sessions whose repo and worktree contain it. The JSON output is stable for scripts.
2. **Pre-work check sees live sessions:** `prework-discovery-helper.sh` gains a "Live sessions" section that calls `aidevops sessions who` for the repo and each `--files` path. It prints matches as warnings, never as failures, and is skipped silently when the bus CLI is unavailable.
3. **Overlap notice:** when a session's presence starts referencing an issue or PR (from its title), a branch, or a worktree already held by another live root session, the plugin shows a toast in both sessions and sends one `info` message to each, naming the other session's handle. Two sessions in different worktrees of the same repo are not an overlap. The same issue, PR, branch or worktree is. Notices fire at most once per session pair per key, and count against the normal send limits.
4. **Claim warning:** `interactive-session-helper.sh claim <N>` prints the live sessions already presenting issue N, using the same `who` call, before claiming. Advisory only.

## Why

Competing work today is found only after the fact: a second PR for the same issue, a rebase conflict, or a release lane refusal. Presence already records repo, branch, worktree, issue and PR for every root session (`session-bus-presence.mjs:99-120`), so the data to warn early exists but nothing uses it. The cheapest place to act is the existing mandatory collision check, which every non-trivial change already runs.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The data and messaging exist. This task adds a query, a presence-change hook and two advisory call sites, with no trust-boundary change.

## How (Approach)

- **Query:** add `whoCommand` next to `listCommand`/`showCommand` (`.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs:49-80`). Reuse `resolveTarget` matching (`session-bus-targets.mjs:62`), but return every match instead of requiring one. Add file-path matching on the `worktree` and `directory` fields with path normalisation.
- **Overlap detection:** in the presence write path (`session-bus-presence.mjs` `record`/write, `:99-120`), compare the new record's `issue`, `pr`, `branch`+`repo` and `worktree` against live peers from `readPresence`. Keep a per-pair, per-key memo (in memory, plus a small `overlaps/` marker file so a restart does not repeat the notice). Send through `store.sendMessage` with `type: "info"` and `origin: "opencode"`. Toast through the existing `bus.toasts`.
- **Pre-work check:** `prework-discovery-helper.sh main` (`:47-94`) already prints merged PRs, open PRs and claimed issues (`:83-87`). Add a `_live_sessions` function that runs `aidevops sessions who --json` with a 5 s timeout and prints a short table.
- **Claim:** `_isc_cmd_claim` (`interactive-session-helper-commands.sh:399`). Print the live matches before claiming. Never block the claim.

### Files to Modify

- EDIT: `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs`: `whoCommand`.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-cli.mjs`: parse `who`.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-targets.mjs`: multi-match and file-path matching helper.
- NEW: `.agents/plugins/opencode-aidevops/session-bus-overlap.mjs`: overlap detection and notice memo.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-presence.mjs`: call overlap detection after a presence change.
- EDIT: `.agents/plugins/opencode-aidevops/session-bus-tool.mjs`: `who` action.
- EDIT: `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`: `who` matching and overlap memo cases.
- EDIT: `.agents/scripts/prework-discovery-helper.sh`: live sessions section.
- EDIT: `.agents/scripts/tests/test-prework-discovery-helper.sh`: live section present when the CLI returns matches, absent when unavailable.
- EDIT: `.agents/scripts/interactive-session-helper-commands.sh`: advisory claim warning.
- EDIT: `.agents/scripts/setup/modules/agent-deploy.sh`: add the new module to the plugin freshness list.
- EDIT: `.agents/reference/session-bus.md`: document `who` and overlap notices.

### Complete Write Surface

- **Callers/readers:** `prework-discovery-helper.sh` (run before every non-trivial change per `.agents/AGENTS.md`), `interactive-session-helper.sh claim`, the `aidevops_sessions` tool, and the V1/V2 sidebars, which show the `info` notices.
- **Writers/mutation paths:** overlap notices through `sendMessage` (`session-bus-messages.mjs:104`); the `overlaps/` memo markers through `writeJsonAtomic` (`session-bus-files.mjs:60`).
- **Existing verification/tests:** `npm test --prefix .agents/plugins/opencode-aidevops`, `bash .agents/scripts/tests/test-prework-discovery-helper.sh`, `bash .agents/scripts/tests/test-interactive-session-claim.sh`.
- **Schemas/config:** new `overlaps/<pairKey>.json` marker; no change to presence or message records. `AIDEVOPS_SESSION_OVERLAP_NOTICES=false` turns notices off.
- **Generated/deployed mirrors:** `.agents/scripts/setup/modules/agent-deploy.sh` plugin freshness list.
- **Migrations/backfills:** not applicable because `overlaps/` is new-file-only.
- **Cleanup/rollback paths:** `pruneBus` (`session-bus-files.mjs:122`) removes markers older than the retention period; the env flag disables notices.

### Implementation Steps

1. Add multi-match and file-path matching to `session-bus-targets.mjs`, then `whoCommand`, the CLI parse and the tool action.
2. Add `session-bus-overlap.mjs` with pure detection (`overlapKeys(record, peers)`) and the memo, then call it from the presence write path.
3. Add the live section to `prework-discovery-helper.sh` and the advisory warning to `_isc_cmd_claim`. ShellCheck both.
4. Extend the existing tests, then run the live self-test.

### Hazards and Compatibility

- **Concurrency/atomicity:** two sessions can detect the same overlap at once; the memo marker is written with an exclusive create, so only one notice per pair and key is sent.
- **Migration/rollback:** additive; rollback is a code revert plus deleting `overlaps/`.
- **Mixed-version/backward compatibility:** an older CLI without `who` makes the pre-work section print nothing (non-zero exit is ignored); older plugins never send notices but still receive them as ordinary `info`.
- **Idempotency/retry:** a repeated presence write with the same keys sends nothing new; a changed key (new issue) can notify once.
- **Partial failure/recovery:** a failed notice send is logged and not retried; the toast still shows. The pre-work check never fails because of the bus.
- **Noise:** sessions in the same repo but on different branches and worktrees do not trigger notices. Default `main` canonical checkouts used read-only also do not trigger: only branch, worktree, issue or PR matches count.

### Files Scope

- `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-cli.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-targets.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-overlap.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-presence.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-tool.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`
- `.agents/scripts/prework-discovery-helper.sh`
- `.agents/scripts/tests/test-prework-discovery-helper.sh`
- `.agents/scripts/interactive-session-helper-commands.sh`
- `.agents/scripts/setup/modules/agent-deploy.sh`
- `.agents/reference/session-bus.md`

### Verification Before Dispatch

```bash
npm test --prefix .agents/plugins/opencode-aidevops
bash .agents/scripts/tests/test-prework-discovery-helper.sh
bash .agents/scripts/tests/test-interactive-session-claim.sh
shellcheck .agents/scripts/prework-discovery-helper.sh .agents/scripts/interactive-session-helper-commands.sh
```

- **Runtime evidence (self-test, no owner needed):** with `AIDEVOPS_SESSION_BUS_DIR` set to a scratch directory, start two `opencode serve` sessions in one scratch Git repo (t18886 "Live verification" setup). Title both "Issue #1: test", then check:
  - Each session gets exactly one overlap notice and toast.
  - `aidevops sessions who '#1' --json` lists both sessions.
  - `prework-discovery-helper.sh --keywords test --files README.md` prints both under "Live sessions".
  - Retitling one session to the same title sends no second notice.
- **Surface mapping:** unit tests cover matching, overlap keys and the memo. The shell tests cover the pre-work section. The live run covers the presence hook, toast and delivery.
- **Broad verification trigger:** not required. The changes stay in the plugin and two helpers.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `npm test --prefix .agents/plugins/opencode-aidevops`
- [ ] WIP commit created before broad gates: `wip: t18895 session coordination`
- [ ] Evidence-triggered broad verification then run: not required

### Scope Boundaries

**Hard boundaries:** advisory only: nothing blocks a claim, a pre-work check or an edit; no GitHub writes; no change to worktree ownership (`shared-worktree-registry.sh`); release coordination is t18896; subagent sessions stay out of presence.

**AI brief owner:** the interactive owner session of t18886 (marcusquinn).

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

## Acceptance Criteria

- [ ] `aidevops sessions who` accepts `#<issue>`, `PR#<n>`, a repo slug, a worktree path or a file path, and returns every matching live root session (text and `--json`).
- [ ] Two live sessions sharing an issue, PR, branch (same repo) or worktree each get one overlap toast and one `info` notice naming the other; sessions that only share a repo get none.
- [ ] `prework-discovery-helper.sh` prints a "Live sessions" section with matches, and prints nothing extra (exit code unchanged) when the bus CLI is missing or times out.
- [ ] `interactive-session-helper.sh claim <N>` prints live sessions presenting issue N before claiming and still claims.
- [ ] Regression: existing session-bus, pre-work and claim tests pass.
- [ ] Negative: repeated presence writes with unchanged keys send no further notices, and `AIDEVOPS_SESSION_OVERLAP_NOTICES=false` sends none.

## Relevant Files

- `.agents/plugins/opencode-aidevops/session-bus-presence.mjs:99-120`
- `.agents/plugins/opencode-aidevops/session-bus-presence-store.mjs:74-79`
- `.agents/plugins/opencode-aidevops/session-bus-targets.mjs:62`
- `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs:49-80`
- `.agents/scripts/prework-discovery-helper.sh:23-45,47-94`
- `.agents/scripts/interactive-session-helper-commands.sh:399`
