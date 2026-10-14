## Problem

On NixOS, `aidevops update` attempts to upgrade ripgrep using brew/apt-get/dnf/yum and fails with `No supported package manager found (brew/apt-get/dnf/yum)`. Ripgrep is installed and working from the Nix store (15.1.0). The updater should respect installation ownership rather than attempt an unrelated package manager.

## Implementation scope

- Modify `.agents/scripts/tool-version-check.sh`: resolve installed binary symlinks and identify `/nix/store/` ownership before latest-version lookups or automatic update queueing.
- Represent Nix-owned tools as externally managed in console/JSON output, with no executable update command. Explain that users should update through the Nix configuration or profile that owns the tool.
- Never automatically invoke `nixos-rebuild`, Home Manager, or profile upgrades. Do not infer ownership merely from the presence of `nix`.
- Preserve existing update behavior for non-Nix binaries, including on hosts with Nix installed.
- Reference pattern: `check_tool`, `_print_tool_status`, `_output_summary_and_updates`, and existing `.agents/scripts/tests/test-tool-version-check-*.sh` checks.

## Acceptance and verification

- Nix-owned binaries (direct store paths and profile/system symlinks) receive an explicit externally-managed status, are excluded from automatic updates, and do not cause maintenance failure or false claims that an update was applied.
- Non-Nix tools retain existing classification and update routing.
- Run ShellCheck, bash syntax validation, existing tool-version regression checks, and the real `--category brew --update` and JSON paths on NixOS.

## Execution ownership

Requested by the operator for interactive implementation and assignment to their authenticated GitHub account. The primary interactive session owns implementation; no separate worker is needed while it is active.

## Delivery evidence

- Issue: https://github.com/marcusquinn/aidevops/issues/34646, assigned to `vladimirdulov` and claimed for interactive implementation.
- Implementation was verified in the `bugfix/nix-managed-tool-updates` linked worktree. Deployment and release are outside this change's scope.
- ShellCheck, bash syntax validation, and `git diff --check` pass.
- Existing ripgrep, classification, update-failure, tap-formula, and OpenCode checks pass (OpenCode: 33 assertions). Classification coverage also exercises direct Nix ownership, symlink resolution, rejection of non-Nix/missing tools, skipped registry lookups, empty update queues, and honest summary wording.
- Real `tool-version-check.sh --category brew --update` succeeds on NixOS and skips jq/ripgrep. JSON reports `externally_managed` and an empty `update_cmd` for both.
- Existing `test-tool-version-check-brew-convergence.sh` exits 1 on both the implementation and unchanged canonical main. Its package-manager mocks do not change installed binary versions, while the updater requires verified version convergence. This is a separate baseline failure, not evidence of a Nix regression.

Resolves #34646
