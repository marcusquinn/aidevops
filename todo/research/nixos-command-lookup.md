<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# NixOS command lookup audit — 2026-10-07

## Observed failure

A merge helper assumed `/usr/bin/git` despite native Git being available at
`/run/current-system/sw/bin/git`. Framework Git wrappers correctly preceded it
in PATH. A persistent environment override is a workaround, not the framework
fix; native lookup must skip framework wrappers while preserving policy gates.

## Implemented scope

- `scripts/runtime-env.sh`, sourced by `scripts/shared-constants.sh` and the
  canonical recovery helper: append existing stable Nix profiles, resolve native
  Git through PATH without selecting a deployed/source wrapper, export the
  existing native-Git override contract, and preserve explicit overrides.
- OpenCode `runtime-path.mjs` and `shell-env.mjs`: recover stable profiles for
  plugin-native subprocesses and shell tools, preserving guard/project precedence.
- Pulse scheduler PATH and persistent OpenCode service PATH include stable
  profiles. Service launch/attach discovers Bash from its configured PATH.
- Git shim enumeration no longer requires an external `which` executable.

Paths above are relative to `.agents/` unless otherwise stated. This patch does
not install missing packages, configure NixOS, or prove all integrations work.
Existing running processes and service definitions need activation/regeneration.

## Verification

- `bash .agents/scripts/tests/test-runtime-env.sh`: passes with a synthetic home,
  shim-only inherited PATH, two Nix profiles, and no inherited FHS tools.
- `python3 .agents/scripts/tests/test_opencode_service.py`: 36 passing cases.
- `node --test .agents/plugins/opencode-aidevops/tests/test-shell-env-origin.mjs`:
  20 passing cases.
- `bash .agents/scripts/tests/test-canonical-git-command-guard.sh`: 122 passing cases.
- Pulse systemd timeout checks, launchd PATH sanitation (4), shared source retry
  (2), and shared cleanup stack (4) pass. The Pulse test also emits existing
  `_launchd_has_agent: command not found` diagnostics.
- ShellCheck on changed shell files, Node syntax checks, Python AST parsing and
  `git diff --check` pass.

The runtime-discovery suite `test-resolve-pulse-runtime-binary.sh` fails the same
three cases on both the patch and unchanged checkout: most-recent Node selection,
Claude-in-nvm rejection, and Claude-fixed-path rejection. Do not attribute these
to the PATH patch. Investigate host/runtime discovery leakage in that existing
suite separately; preserve its negative-discovery assertions.

## Remaining portability work

The identified source-access and team-interface literals are included in the
implementation for GH#33891: use fixed trusted system roots, including NixOS,
without accepting caller PATH/overrides for approval or project-root probes.
Signed standalone broker setup uses self-contained lookup for all its system
commands, including NixOS's `/run/wrappers/bin/sudo`. No privilege or consent
policy changes are authorized.

Broader packaging/integration validation remains outside command-discovery scope.
Do not infer support for every downloaded binary from successful PATH lookup.

No real NixOS end-to-end validation or installed-runtime deployment was performed
in this source worktree. Do not describe this as complete NixOS platform support.
