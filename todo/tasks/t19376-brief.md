## What

Set `OPENCODE_DISABLE_FFF=1` for headless worker OpenCode runs. Each worker then uses OpenCode's ripgrep file-search backend instead of the native fff index and its background file watcher.

## Why

Observed on a 16-core macOS runner on 2026-11-25, with load averages of 65–113:

- 3 of 6 live `opencode run` workers had a lifetime CPU share of 0.66–0.90 cores (4–6.5 CPU-minutes in 5–7.5 minutes). The other 3 used 0.03–0.07. All hot workers were in worktrees of one large application repository (49,870 tracked files) while package installs and builds ran there. Each worker held about 1.3 GB RSS.
- A 3 s `sample` of the hottest worker put the on-CPU stacks in `fff_search::watch::background_watcher` → `FileSync::find_file_index`, and in `git_status_for_paths` → `git_status_list_new` → `git_diff_index_to_workdir` → `git_pathspec__match` → `dowild`/`__tolower`/`git__strcasecmp`, plus `read`/`open`/`stat`. fff re-runs a libgit2 status pass over the 50k-entry index on each watcher batch, so worktree file churn becomes continuous CPU.
- In OpenCode 1.19.6, `OPENCODE_DISABLE_FFF` selects the v2 `FileSystem/Search` layer (`Kl = OPENCODE_DISABLE_FFF || !Gl() ? Wl : zl`). The fff layer's `grep` runs with `timeBudgetMs: 1500`, so on a saturated host a worker's grep results can be silently truncated. The fallback layer runs live ripgrep for every `glob` and `grep`. Only its fuzzy `find`, which feeds the TUI file picker, reads a startup file list.
- A/B on a 9,953-file repo with `opencode debug file search`: same result, system CPU 1.06 s → 0.49 s, peak RSS 768 MB → 568 MB.

## How

### Files Scope

- `.agents/scripts/headless-runtime-invoke.sh`

### Changes

1. Add `_invoke_opencode_disable_fff` next to `_invoke_opencode_disable_snapshots`, following the GH#38491 pattern. In the launch subshell, export `OPENCODE_DISABLE_FFF=1` unless the caller already set `OPENCODE_DISABLE_FFF` or set `AIDEVOPS_WORKER_OPENCODE_FFF=1` to opt out.
2. Call it from `_invoke_opencode_prepare_child_command`, beside the snapshot call. The worker sandbox already passes `OPENCODE_*` through (`build_sandbox_passthrough_csv` in `.agents/scripts/headless-runtime-lib.sh`). Triage roles keep their explicit allowlist and are unchanged.

Interactive sessions are not affected. The TUI file picker still uses fff.

## Acceptance

- A worker launched after deployment has `OPENCODE_DISABLE_FFF=1` in its `opencode run` environment, and a 3 s `sample` of it shows no `fff_search` frames.
- In a comparable later window, the mean lifetime CPU share of `opencode run` workers is below the 0.34-core baseline (n=6), and no worker sits above 0.5 cores in fff frames.
- With `AIDEVOPS_WORKER_OPENCODE_FFF=1`, the flag is not exported.
- ShellCheck is clean on the changed file.
