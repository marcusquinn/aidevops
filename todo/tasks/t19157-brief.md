## Origin

- **Created:** 2026-11-19, interactive session (maintainer asked for every parallel-session blind spot found in a session-bus audit to be fixed: "work on all these gaps here. full-loop please").
- **Evidence:** #39234 was filed by this interactive session and then implemented and closed at 15:25Z by a worker on another runner. `aidevops_sessions who #39234` returned "No other live session is working on #39234", and the filing session got no bus notice. It only found out by polling GitHub. The pulse steering relay (`.agents/scripts/worker-bus-relay-helper.sh`) carries GitHub changes to workers only. Workers can only answer an `ask` (`session-bus-format.mjs:110-116`), and no worker instructions say how to flag a dependency to a live session.

## What

Close three session-bus blind spots so interactive sessions and pulse workers see each other's progress:

1. **Issue watches (relay for interactive sessions):** a root session can watch `owner/repo#N` (issue or PR) for 7 days. The 2-minute relay sends it one batched `info` pointer per pass when a watched item changes status label, assignees, state (closed/reopened/merged), or gains non-bot comments (worker comments included). Issues filed by an interactive session through `claim-task-id.sh` are watched automatically.
2. **Cross-runner visibility:** when `who` finds no local session on `#N`/`PR#N`, it says that workers on other runners are not on this bus, and names the GitHub command that shows their claim. Watches report pickup by any runner as assignee and status changes.
3. **Worker-initiated pointers:** headless rules tell a worker to flag a dependency or overlap in a comment on its own issue, which watchers receive. When `aidevops sessions who` shows a live local session on the other item, the worker also sends that session a one-line `aidevops sessions send` pointer.

## Why

Interactive sessions file worker-ready issues, then lose sight of them. Outcomes and blockers from workers on other machines arrive only if someone polls GitHub. That wastes the human attention the framework is meant to save, and leaves follow-ups such as release sweeps or dependent work stalled.

## Tier

`tier:standard`: a new bus module plus CLI/tool/relay wiring across about 10 files.

## How (Approach)

### Files to Modify

- `NEW: .agents/plugins/opencode-aidevops/session-bus-issue-watch.mjs`: watch records under `issue-watch/<session>/<owner>@<repo>@<n>.json`. Covers add, remove, list and prune, reject headless subscribers, cap at 50 per session and expire after 7 days. Model on `session-bus-release.mjs`.
- `EDIT: .agents/plugins/opencode-aidevops/session-bus-files.mjs`: add `issueWatchDir` and prune watches in `pruneBusFiles`.
- `EDIT: .agents/plugins/opencode-aidevops/session-bus-cli.mjs` + `NEW: session-bus-cli-watch.mjs`: add `watch-issue <owner/repo#N|#N> [--repo] [--new] [--off]` and `watches [--all] [--json]`.
- `EDIT: .agents/plugins/opencode-aidevops/session-bus-tool.mjs`: add the `watch-issue` action and the who-miss hint.
- `EDIT: .agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs` + `session-bus-targets.mjs`: add the who-miss hint for the CLI.
- `NEW: .agents/scripts/worker-bus-relay-watches.sh` (sourced) + `EDIT: .agents/scripts/worker-bus-relay-helper.sh`: an issue-watch pass that makes one issue listing per repo, diffs labels, assignees and state against per-watch state, reads comments only when the count rose, and sends one batched message per subscriber.
- `EDIT: .agents/scripts/claim-task-id.sh`: best-effort `watch-issue <slug>#N --new` after issue creation (5 s budget, silent).
- `EDIT: .agents/scripts/commands/full-loop.md` (Headless Dispatch Rules): add the cross-session pointer rule.
- `EDIT: .agents/reference/session-bus.md`: document issue watches, the who hint and worker pointers.

### Verification

```bash
node --test .agents/plugins/opencode-aidevops/tests/test-session-bus.mjs
shellcheck .agents/scripts/worker-bus-relay-helper.sh .agents/scripts/worker-bus-relay-watches.sh .agents/scripts/claim-task-id.sh
# Runtime: watch a recently closed issue as --new from a live session, run one relay pass, confirm one pointer message arrives.
aidevops sessions watch-issue marcusquinn/aidevops#39234 --new
.agents/scripts/worker-bus-relay-helper.sh relay && aidevops sessions inbox
```

### Files Scope

- `.agents/plugins/opencode-aidevops/session-bus-issue-watch.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-files.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-cli.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-cli-watch.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-cli-commands.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-targets.mjs`
- `.agents/plugins/opencode-aidevops/session-bus-tool.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-session-bus.mjs`
- `.agents/scripts/worker-bus-relay-helper.sh`
- `.agents/scripts/worker-bus-relay-watches.sh`
- `.agents/scripts/claim-task-id.sh`
- `.agents/scripts/commands/full-loop.md`
- `.agents/reference/session-bus.md`

### Scope Boundaries

The relay never writes to GitHub, and messages are pointers only: no comment bodies or titles. Watches are advisory and grant no authority. Worker presence and dispatch semantics are unchanged.

## Acceptance Criteria

- [ ] A live interactive session can `watch-issue` an issue or PR; headless sessions are refused; `--off` removes the watch; `watches` lists it.
- [ ] One relay pass sends one batched pointer per subscriber for status-label, assignee, state and new-comment changes, and nothing when nothing changed. A `--new` watch reports a pickup that happened before the first pass.
- [ ] `claim-task-id.sh` run from an OpenCode interactive session watches the issues it creates, and stays silent and non-fatal everywhere else.
- [ ] `who #N` with no local match prints the cross-runner hint.
- [ ] full-loop headless rules include the worker pointer rule.
- [ ] Regression guarantee: the existing worker relay behaviour, `watch-release` and the `test-session-bus.mjs` suite are unchanged and pass.
