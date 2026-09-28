#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../project-node-runtime.sh
source "$SCRIPT_DIR/project-node-runtime.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
# Keep host runtimes (for example Homebrew node@24) out of the candidate set.
export AIDEVOPS_NODE_BREW_PREFIXES="$root/missing" NVM_DIR="$root/missing" MISE_DATA_DIR="$root/missing" N_PREFIX="$root/missing"
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
