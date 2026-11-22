<!-- aidevops:brief-schema=v2 -->

# feat(opencode): one-command switch from an unintended global OpenCode 2 back to stable OpenCode 1

## Pre-flight

- [x] Memory recall: no relevant lessons for "OpenCode 2 global install downgrade v1 homebrew data directory"
- [x] Duplicate search: `gh issue list --search "brew opencode 2.3 upgrade v1"` and `"tool-version-check opencode brew"` found only #39271 (stop new silent moves to V2), which is complementary. No existing switch-back command (`rg -n "use-stable|opencode-runtime" .agents/scripts aidevops.sh` is empty).
- [x] File refs verified at `main` `292d5182c6`: `aidevops.sh:1690-1702` (`_main_dispatch_opencode_tools`), `aidevops.sh:1748`; `.agents/scripts/shared-constants.sh:316-360` (`aidevops_opencode_owner_payload`, `aidevops_opencode_install_owner`); `.agents/scripts/opencode-runtime-profile.py` (`installed`, `get`); `.agents/scripts/setup/modules/tool-install.sh:1636-1715` (global-V2 handling, preview install); `.agents/scripts/agent-discovery.py:260-394` (V1/V2 config key conversion); `.agents/scripts/opencode-service-helper.py:44-104` (`stop`); `README.md:66-77`
- [x] Tier: `tier:standard`

## Origin

- **Created:** 2026-11-19
- **Created by:** ai-interactive (maintainer decision on #35902: keep OpenCode 1 as the stable default and give affected users a one-command way back before posting guidance on #39095)
- **Evidence:** the reporter of GH#38922 and GH#39095 runs a global `opencode v2.3.0` without having chosen it deliberately. `brew info --json=v2 opencode` reports stable `2.3.2`. Upstream v1.19.2 release notes say Homebrew Core "now track[s] OpenCode 2". Since GH#38922, setup treats a global OpenCode 2 as the primary runtime and never offers V1 (`tool-install.sh:1636-1648,1689-1698`). A global V2 and V1 share `~/.local/share/opencode/opencode.db` with different schemas: V2 has `session_v2` and `instruction_*`, while V1 has `__drizzle_migrations`, `session`, `message` and `part`. This was compared with `sqlite3 .tables` on the isolated V2 DB `~/.aidevops/runtimes/opencode-v2/data/opencode/opencode.db` and a V1 DB.

## What

A new top-level command, `aidevops opencode-runtime`, with these subcommands:

- `status`: prints the global `opencode` path, version, profile (`v1` stable or `v2` preview), install owner (Homebrew, npm, bun, or the upstream installer in `~/.opencode/bin`), whether the isolated `opencode2` preview exists, and any `AIDEVOPS_OPENCODE_PROFILE` override. For a V2 global it also prints the one-line fix.
- `use-stable [--yes] [--dry-run]`: when the global `opencode` is OpenCode 2, it shows the plan and asks once. It then stops the managed OpenCode service if one is configured, and moves the OpenCode data directory aside to a timestamped backup, copying any V1 `auth.json` and `mcp-auth.json` back. It removes OpenCode 2 through the channel that owns it and installs `opencode-ai@<v1 testedVersion>` with npm (bun as fallback, as in setup). Then it runs `aidevops setup --scope full`, verifies that `opencode --version` reports major 1, and prints the sign-in check plus how to restore the backup. On a V1 global it reports "already stable" and changes nothing.

`README.md` Quick Setup gains a short "OpenCode version" note pointing at both subcommands.

## Why

Users who ended up on OpenCode 2 without choosing it hit preview gaps such as the Pulse dispatch and auth breakage in GH#38922 and GH#39095, and the V2 gaps still listed on #35902. Today, switching back takes six manual steps, including an uninstall and a data-directory move, which non-technical users cannot do safely. #39095 will be pointed at this command once it is released.

## Tier

`tier:standard`.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/opencode-runtime-switch-helper.sh`: `status` and `use-stable`. Source `shared-constants.sh`. Resolve the real binary and its owner with `aidevops_opencode_owner_payload v1` (it follows the aidevops stable shim). Get the profile from `opencode-runtime-profile.py installed <real-binary>` and the V1 version from `opencode-runtime-profile.py get v1 testedVersion`. Keep each function small (qlty new-file gate).
- `EDIT: aidevops.sh:1690-1702,1748`: route `opencode-runtime` through `_main_dispatch_opencode_tools`.
- `EDIT: .agents/scripts/aidevops-cli/aidevops-help-lib.sh`: one help line next to the other `opencode-*` commands.
- `EDIT: README.md:66-77`: an "OpenCode version" note covering stable vs preview, avoiding `brew install opencode`, and `aidevops opencode-runtime status|use-stable`.

### Complete Write Surface

- **Callers/readers:** new entry point only: `aidevops opencode-runtime ...`. The future #39095 comment links to it. Nothing else calls the helper.
- **Writers/mutation paths:** the helper writes only: the backup rename of `${XDG_DATA_HOME:-~/.local/share}/opencode`, a copy of `~/.config/opencode/opencode.json` to a timestamped backup, the owner's uninstall (`brew uninstall <formula>`, `npm uninstall -g @opencode/cli`, `bun remove -g @opencode/cli`, or renaming `~/.opencode/bin/opencode` to a backup name), `npm|bun install -g opencode-ai@<version>`, `opencode-service-helper.py stop`, and `aidevops setup --scope full`. That setup run already performs the V2-to-V1 config key conversion (`agent-discovery.py:260-394`), the shim/receipt repair, and the service reconcile.
- **Existing verification/tests:** no existing test covers this new command. Verify through the production path in a sandbox (see Verification). `shellcheck` and the qlty new-file gate apply.
- **Schemas/config:** N/A, with evidence: no new config keys. Reads `.agents/configs/opencode-runtime-profiles.json` through `opencode-runtime-profile.py`.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` to `~/.aidevops/agents/scripts/`. No generated files.
- **Migrations/backfills:** N/A, with evidence: this runs per user, on demand. Nothing is migrated automatically.
- **Cleanup/rollback paths:** every data change in `.agents/scripts/opencode-runtime-switch-helper.sh` is a rename or copy to a timestamped backup that the helper prints. Restoring means moving the backup back and reinstalling OpenCode 2 through the original channel, and the helper prints both commands. The helper never deletes data.

### Implementation Steps

1. Write `status`: path, version, profile, owner, preview presence, override. Exit 0.
2. Write `use-stable`. Refuse inside an OpenCode session (`OPENCODE` set) with "run this from a plain terminal after closing OpenCode". On V1, report and exit 0. On an unknown owner, print the manual steps and exit 1. Otherwise show the plan, confirm once (skip with `--yes`; `--dry-run` prints the plan and exits 0), then run the steps in this order: service stop, data backup, uninstall V2, install V1, setup, verify.
3. If any step fails, stop and print what already happened and how to restore. Never continue past a failed uninstall or install.
4. Wire up `aidevops.sh` and the help line, and add the README note.
5. Run ShellCheck and the sandbox verification below.

### Hazards and Compatibility

- **Concurrency/atomicity:** a running OpenCode TUI or service keeps the DB open, so the helper refuses inside OpenCode and stops the managed service before the rename. The rename is atomic within one filesystem, and the backup sits next to the original.
- **Migration/rollback:** reversible by design, using backups plus the printed restore commands. V2 sessions stay in the backup and are not imported into V1, because the schemas differ.
- **Mixed-version/backward compatibility:** V1 users are untouched. An explicit `AIDEVOPS_OPENCODE_PROFILE=v2` export would make setup keep V2, so `use-stable` warns and stops until it is unset. Credentials stored in the V2 DB, such as API-key providers, are not carried over, so the helper prints `opencode auth login`. OAuth pool accounts in `~/.aidevops` are unaffected.
- **Idempotency/retry:** rerunning after success reports "already stable". Rerunning after a partial failure resumes from the current state, for example when V2 is already removed and V1 is missing.
- **Partial failure/recovery:** if V1 install or setup fails after V2 was removed, the helper prints the exact recovery command (`npm install -g opencode-ai@<version> && aidevops setup --scope full`) and the restore commands.

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/opencode-runtime-switch-helper.sh aidevops.sh
bash .agents/scripts/opencode-runtime-switch-helper.sh status          # real V1 host: profile v1, "stable"
bash .agents/scripts/opencode-runtime-switch-helper.sh use-stable --dry-run   # real V1 host: "already stable", no changes
# Sandbox V2 host: temp HOME + temp npm prefix; npm install -g @opencode/cli there; create a data dir;
# stub only `aidevops` (setup) on PATH; run use-stable --yes; expect V2 removed, opencode-ai installed,
# data dir moved to a timestamped backup, `opencode --version` major 1.
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the real-host runs cover the V1 no-op path. The sandbox run covers owner detection, the real npm uninstall and install, the data backup, and the post-switch version check. Setup itself is existing code, exercised on every update.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** do not change setup's GH#38922 global-V2 handling or #39271's update guard. Do not import V2 sessions into V1. Do not add a "use preview" command yet.

**AI brief owner:** marcusquinn (interactive maintainer session)

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/opencode-runtime-switch-helper.sh`
- `aidevops.sh`
- `.agents/scripts/aidevops-cli/aidevops-help-lib.sh`
- `README.md`

## Acceptance Criteria

- [ ] Positive: on a host whose global `opencode` is OpenCode 2 installed with npm (`@opencode/cli`), `aidevops opencode-runtime use-stable --yes` leaves `opencode --version` at major 1. It prints a timestamped backup path that contains the previous data directory, and `@opencode/cli` is no longer globally installed.
- [ ] Positive: `aidevops opencode-runtime status` reports profile, version and owner, and prints the `use-stable` hint for an OpenCode 2 global.
- [ ] Regression: on a V1 host, `use-stable` changes nothing and reports "already stable". Inside an OpenCode session (`OPENCODE` set) it refuses without changes. The helper never deletes the data directory.

## Context & Decisions

- Move rather than migrate: V1 and V2 schemas in the shared `opencode.db` differ, and V1 cannot show V2 sessions anyway. A reversible backup is the stable choice.
- Install the V1 profile's `testedVersion`, not `latest`, so the switch lands on the version aidevops qualifies.
- The managed service, plugin registration, config keys and shim are all reconciled by the existing full setup. The helper does not duplicate them.
- Implementation decision: `aidevops opencode` and Tabby launches use per-project isolated data folders (`~/.aidevops/.agent-workspace/work/opencode-interactive/<id>/opencode`), so a global OpenCode 2 also wrote V2 tables there. The helper also renames every fixed-depth isolated folder whose `opencode.db` has `session_v2`. V1-only folders are left untouched.
- Implementation decision: instead of printing restore commands, each run writes a ready-to-run undo script (`~/.aidevops/opencode-use-stable/undo-<stamp>.sh`). It holds the inverse of each completed step in reverse order, so a non-technical user can undo with one command.
