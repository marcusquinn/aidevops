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
- Source-access Python suite: 72 cases, one platform-conditional skip; shell
  entrypoint suites pass. Run with umask 022 and an owner-only temporary root:
  this host's default workspace ancestor is group-writable, which the broker
  correctly rejects. No trust check was disabled to run the suite.
- Signed broker setup and team-interface Buzz worktree/OpenCode overlay suites
  pass, including caller-PATH shadow rejection and existing ownership bindings.
- Changed-file `linters-local.sh --changed --base-ref origin/main` passes its
  required gates. Cached `npx --no-install markdownlint-cli2` reports zero issues
  for changed documentation; pre-existing formatting/size advisories remain.
- Independent staged-diff review and metadata portability delta review found no
  material introduced defects. Deployment copy in `setup/modules/agent-deploy.sh`
  copies complete scripts/plugins trees, including both new sibling helpers.

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

## PR-loop repair and delivery

Framework Validation caught a missing mandatory sibling in isolated profile
fixtures: the new direct `BASH_SOURCE` load was invisible to existing dependency
discovery. Switching that load to the established `_SC_SELF` convention fixed
the production/fixture contract without changing assertions or gates.
Profile boundary tests then passed 27/27, test-helper metadata checks 24/24,
shared-source retry checks 2/2, and minimal-PATH and ShellCheck checks passed.

All six required CI checks passed on `bc805b0e6a5f3626e5838baca616ef8f05fb7ac8`.
PR #33893 merged as `fc30e91afd25ab9c57ea8d8a78d559e335bc9a92`; issue #33891
closed and canonical main synchronized through the audited helper. No release
publication was requested or performed.

https://github.com/marcusquinn/aidevops/pull/33893
