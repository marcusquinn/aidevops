#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../project-node-runtime.sh
source "$SCRIPT_DIR/project-node-runtime.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
# Volta and n also enumerate fixed HOME-relative paths, so isolate HOME itself.
export HOME="$root/home"
# Keep host runtimes (for example Homebrew or Nix Node) out of the candidate set.
export AIDEVOPS_NODE_BREW_PREFIXES="$root/missing" AIDEVOPS_NODE_NIX_PROFILES="$root/missing" NVM_DIR="$root/missing" MISE_DATA_DIR="$root/missing" N_PREFIX="$root/missing"
mkdir -p "$root/project/packages/app" "$root/active" "$root/fnm/node-versions/v24.18.0/installation/bin"
# A fake active runtime lets the test run regardless of the host Node version.
printf '#!/bin/sh\nprintf "v26.0.0\\n"\n' >"$root/active/node"
printf '#!/bin/sh\nprintf "v24.18.0\\n"\n' >"$root/fnm/node-versions/v24.18.0/installation/bin/node"
chmod +x "$root/active/node" "$root/fnm/node-versions/v24.18.0/installation/bin/node"
printf '%s\n' '24' >"$root/project/.nvmrc"
printf '%s\n' 'nodejs 24.18.0' >"$root/project/.tool-versions"
printf '%s\n' '{"engines":{"node":">=24 <25"}}' >"$root/project/package.json"
printf '%s\n' '24.18' >"$root/project/packages/app/.node-version"
printf '%s\n' '{"engines":{"node":"^24.0.0"}}' >"$root/project/packages/app/package.json"
expected="$root/fnm/node-versions/v24.18.0/installation/bin"
actual=$(PATH="$root/active:$PATH" FNM_DIR="$root/fnm" _project_node_bin "$root/project" packages/app)
[[ "$actual" == "$expected" ]] || { printf 'FAIL installed match: %s\n' "$actual"; exit 1; }
printf 'PASS installed matching Node satisfies root and scope\n'
if PATH="$root/active:$PATH" FNM_DIR="$root/missing" NVM_DIR="$root/missing" MISE_DATA_DIR="$root/missing" N_PREFIX="$root/missing" \
	_project_node_bin "$root/project" packages/app >"$root/output" 2>"$root/error"; then
	printf 'FAIL mismatched Node accepted\n'; exit 1
fi
if ! rg -q 'ENVIRONMENT FAILURE: node v26.*engines.*Install a matching Node' "$root/error"; then
	printf 'FAIL missing actionable environment diagnostic\n'; exit 1
fi
printf 'PASS mismatched active Node fails closed\n'
printf '%s\n' '25' >"$root/project/packages/app/.node-version"
if PATH="$root/active:$PATH" FNM_DIR="$root/fnm" _project_node_bin "$root/project" packages/app >"$root/output" 2>"$root/error"; then
	printf 'FAIL conflicting root/scoped pins accepted\n'; exit 1
fi
printf '%s\n' '24.18' >"$root/project/packages/app/.node-version"
printf 'PASS conflicting scoped pin fails closed\n'

# GH#32897: a patch pin is a preference; the same major with engines is accepted.
mkdir -p "$root/drift/node-versions/v24.11.0/installation/bin"
printf '#!/bin/sh\nprintf "v24.11.0\\n"\n' >"$root/drift/node-versions/v24.11.0/installation/bin/node"
chmod +x "$root/drift/node-versions/v24.11.0/installation/bin/node"
drift_bin="$root/drift/node-versions/v24.11.0/installation/bin"
actual=$(PATH="$root/active:$PATH" FNM_DIR="$root/drift" _project_node_bin "$root/project" packages/app 2>"$root/error")
[[ "$actual" == "$drift_bin" ]] || { printf 'FAIL same-major patch drift rejected: %s\n' "$actual"; exit 1; }
rg -q 'WARNING: project pins node .*24\.18\.0.*using installed v24\.11\.0' "$root/error" || { printf 'FAIL missing pin drift warning\n'; exit 1; }
printf 'PASS same-major patch drift resolves with a warning\n'
cp -R "$root/fnm/node-versions/v24.18.0" "$root/drift/node-versions/v24.18.0"
actual=$(PATH="$root/active:$PATH" FNM_DIR="$root/drift" _project_node_bin "$root/project" packages/app 2>"$root/error")
[[ "$actual" == "$root/drift/node-versions/v24.18.0/installation/bin" ]] || { printf 'FAIL exact pin not preferred: %s\n' "$actual"; exit 1; }
[[ ! -s "$root/error" ]] || { printf 'FAIL exact pin match warned\n'; exit 1; }
printf 'PASS exact pinned patch preferred over same-major drift\n'
mkdir -p "$root/alias"
printf '%s\n' 'lts/*' >"$root/alias/.nvmrc"
alias_rc=0
PATH="$root/active:$PATH" _project_node_bin "$root/alias" . >"$root/output" 2>"$root/error" || alias_rc=$?
[[ "$alias_rc" -eq 2 ]] || { printf 'FAIL alias pin should mean no requirement, rc=%s\n' "$alias_rc"; exit 1; }
printf 'PASS alias pin is not treated as an unsatisfiable requirement\n'

# GH#39156: unversioned Homebrew kegs and <prefix>/bin installs are candidates,
# but a shared multi-tool bin is never returned as the PATH prefix.
mkdir -p "$root/brew/opt/node/bin" "$root/sys/bin" "$root/sys26/bin"
printf '#!/bin/sh\nprintf "v24.18.0\\n"\n' >"$root/brew/opt/node/bin/node"
cp "$root/brew/opt/node/bin/node" "$root/sys/bin/node"
printf '#!/bin/sh\nexit 0\n' >"$root/sys/bin/git"
printf '#!/bin/sh\nexit 0\n' >"$root/sys/bin/npm"
printf '#!/bin/sh\nprintf "v26.1.0\\n"\n' >"$root/sys26/bin/node"
chmod +x "$root/brew/opt/node/bin/node" "$root/sys/bin/node" "$root/sys/bin/git" "$root/sys/bin/npm" "$root/sys26/bin/node"
actual=$(PATH="$root/active:$PATH" AIDEVOPS_NODE_BREW_PREFIXES="$root/brew" _project_node_bin "$root/project" packages/app)
[[ "$actual" == "$root/brew/opt/node/bin" ]] || { printf 'FAIL unversioned Homebrew keg not selected: %s\n' "$actual"; exit 1; }
printf 'PASS unversioned Homebrew node keg resolves\n'
actual=$(PATH="$root/active:$PATH" AIDEVOPS_NODE_BREW_PREFIXES="$root/sys" AIDEVOPS_TEMP_DIR="$root/tmp" _project_node_bin "$root/project" packages/app)
[[ -n "$actual" && "$actual" != "$root/sys/bin" && "$actual" == "$root/tmp/"* ]] || { printf 'FAIL shared prefix bin returned: %s\n' "$actual"; exit 1; }
[[ "$("$actual/node" --version)" == v24.18.0 && -L "$actual/npm" && ! -e "$actual/git" ]] || { printf 'FAIL private Node link dir incomplete or leaks other tools: %s\n' "$actual"; exit 1; }
printf 'PASS shared prefix Node resolves through a private link dir\n'
if PATH="$root/active:$PATH" AIDEVOPS_NODE_BREW_PREFIXES="$root/sys26" AIDEVOPS_TEMP_DIR="$root/tmp" \
	_project_node_bin "$root/project" packages/app >"$root/output" 2>"$root/error"; then
	printf 'FAIL shared prefix Node with another major accepted\n'; exit 1
fi
printf 'PASS shared prefix Node with another major fails closed\n'

# GH#40354: Nix profile bins must expose only the selected Node toolchain.
for profile in "$root/nix-home/.nix-profile" "$root/nix-state/nix/profiles/profile" "$root/nix/per-user/test/profile" "$root/nix-system/sw"; do
	mkdir -p "$profile/bin"
	cp "$root/sys/bin/node" "$profile/bin/node"
	for tool in npm npx corepack git gh jq python3; do
		cp "$root/sys/bin/npm" "$profile/bin/$tool"
	done
	actual=$(PATH="$root/active:$PATH" FNM_DIR="$root/missing" AIDEVOPS_NODE_NIX_PROFILES="$root/missing $profile" AIDEVOPS_TEMP_DIR="$root/tmp" _project_node_bin "$root/project" packages/app)
	[[ -n "$actual" && "$actual" == "$root/tmp/"* && "$actual" != "$profile/bin" ]] || {
		printf 'FAIL Nix shared bin returned: %s\n' "$actual"
		exit 1
	}
	[[ "$("$actual/node" --version)" == v24.18.0 ]] || {
		printf 'FAIL Nix Node version\n'
		exit 1
	}
	for tool in node npm npx corepack; do
		[[ -L "$actual/$tool" ]] || {
			printf 'FAIL missing Nix toolchain link: %s\n' "$tool"
			exit 1
		}
	done
	for tool in git gh jq python3; do
		[[ ! -e "$actual/$tool" && "$(PATH="$actual:$PATH" command -v "$tool")" == "$(command -v "$tool")" ]] || {
			printf 'FAIL Nix reordered tool: %s\n' "$tool"
			exit 1
		}
	done
done
printf 'PASS Nix profile layouts resolve without reordering unrelated tools\n'
if PATH="$root/active:$PATH" FNM_DIR="$root/missing" AIDEVOPS_NODE_NIX_PROFILES="$root/sys26" \
	_project_node_bin "$root/project" packages/app >"$root/output" 2>"$root/error"; then
	printf 'FAIL Nix Node with another major accepted\n'
	exit 1
fi
rg -q 'Install a matching Node.*Nix' "$root/error" || {
	printf 'FAIL missing Nix installation diagnostic\n'
	exit 1
}
printf 'PASS incompatible Nix Node fails closed with actionable diagnostic\n'

# Default HOME/XDG profile paths preserve spaces without the test override.
for profile in "$root/home with spaces/.nix-profile" "$root/state with spaces/nix/profiles/profile"; do
	mkdir -p "$profile/bin"
	cp "$root/sys/bin/node" "$profile/bin/node"
	actual=$(PATH="$root/active:$PATH" HOME="$root/home with spaces" XDG_STATE_HOME="$root/state with spaces" FNM_DIR="$root/missing" AIDEVOPS_NODE_NIX_PROFILES="" AIDEVOPS_TEMP_DIR="$root/tmp" _project_node_bin "$root/project" packages/app)
	[[ -n "$actual" && "$actual" == "$root/tmp/"* && "$(readlink "$actual/node")" == "$profile/bin/node" ]] || {
		printf 'FAIL default Nix profile path with spaces: %s\n' "$actual"
		exit 1
	}
	rm "$profile/bin/node"
done
printf 'PASS default HOME and XDG Nix profiles preserve path spaces\n'

# Exercise the worker preparation path without a live dispatch claim.
# shellcheck source=../headless-runtime-worker-prepare.sh
source "$SCRIPT_DIR/headless-runtime-worker-prepare.sh"
_hrff_capture_external_outcome_contract() { return 0; }
_headless_private_workload_enabled() { return 1; }
_acquire_session_lock() { return 0; }
aidevops_sensitive_temp_root() { return 0; }
_hrw_claim_worker_worktree() { return 0; }
_register_dispatch_ledger() { return 0; }
_exit_trap_handler() { return 0; }
aidevops_runtime_bundle_lease_release() { return 0; }
print_error() { printf '%s\n' "$1" >&2; return 0; }
(
	unset WORKER_ISSUE_NUMBER AIDEVOPS_DISPATCH_LEASE_TOKEN
	export PATH="$root/active:$PATH" FNM_DIR="$root/fnm"
	_cmd_run_prepare test-session "$root/project" worker || exit 1
	[[ "$(command -v node)" == "$expected/node" ]] || exit 1
	trap - EXIT
) || { printf 'FAIL worker preparation did not select project Node\n'; exit 1; }
printf 'PASS worker commands inherit selected Node\n'
