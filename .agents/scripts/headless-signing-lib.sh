#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Commit Signing Library (GH#36491)
# =============================================================================
# Shared non-interactive signing preparation for every headless Git writer:
# workers (headless-runtime-attempt.sh), pulse script routines
# (pulse-routines.sh) and committing helpers (badges-sync-helper.sh).
#
# Design: the user's passphrase-protected interactive key stays the global Git
# default. Headless processes prefer the dedicated signing-only key
# (~/.ssh/id_ed25519_signing) through process-scoped GIT_CONFIG_* entries,
# prove signing with a prompt-free commit-tree probe, and self-heal a stopped
# headless ssh-agent once. Signing is never disabled here.
#
# Usage: source "${SCRIPT_DIR}/headless-signing-lib.sh"
# Part of aidevops framework: https://aidevops.sh

[[ -n "${_HEADLESS_SIGNING_LIB_LOADED:-}" ]] && return 0
_HEADLESS_SIGNING_LIB_LOADED=1
_HEADLESS_SIGNING_LIB_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_HEADLESS_SIGNING_LIB_DIR" == "${BASH_SOURCE[0]}" ]] && _HEADLESS_SIGNING_LIB_DIR="."

# headless_signing_required <dir> — 0 when the effective config at <dir>
# requires signed commits.
headless_signing_required() {
	local work_dir="$1"
	local required=""
	required=$(git -C "$work_dir" config --bool commit.gpgsign 2>/dev/null || true)
	[[ "$required" == "true" ]] || return 1
	return 0
}

# headless_signing_commit_probe <dir> [drop_agent]
# Create a signed commit object without prompting, moving refs, or touching
# the worktree. drop_agent=1 probes without the caller's ssh-agent (sandboxed
# workers never receive SSH_AUTH_SOCK, GH#33064).
# commit-tree ignores commit.gpgsign, so -S is passed whenever <dir> requires
# signing; without it the probe never signs and cannot detect an unusable key
# or agent (GH#36515). Directories without required signing stay unsigned.
headless_signing_commit_probe() {
	local work_dir="$1"
	local drop_agent="${2:-0}"
	local tree_id=""
	local sign_args=()
	tree_id=$(git -C "$work_dir" rev-parse 'HEAD^{tree}' 2>/dev/null) || return 1
	headless_signing_required "$work_dir" && sign_args=(-S)
	(
		if [[ "$drop_agent" == "1" ]]; then
			unset SSH_AUTH_SOCK SSH_AGENT_PID
		fi
		GIT_TERMINAL_PROMPT=0 \
			SSH_ASKPASS=/usr/bin/false \
			SSH_ASKPASS_REQUIRE=force \
			DISPLAY=aidevops-headless \
			git -C "$work_dir" commit-tree ${sign_args[@]+"${sign_args[@]}"} "$tree_id" \
				-m "aidevops headless signing preflight" </dev/null >/dev/null 2>&1
	) || return 1
	return 0
}

# headless_signing_commit_probe_isolated <dir>
# Same proof for callers that hold only a canonical checkout: sign a commit in
# a private temporary bare repository using <dir>'s effective identity and
# signing configuration, so the canonical object store is never written.
# commit-tree ignores commit.gpgsign, so -S is required to prove signing.
headless_signing_commit_probe_isolated() {
	local work_dir="$1"
	local probe_root="" tree_id="" key="" value="" status=0
	local config_args=()
	for key in user.name user.email gpg.format user.signingkey gpg.program \
		gpg.openpgp.program gpg.ssh.program gpg.ssh.defaultKeyCommand gpg.x509.program; do
		value=$(git -C "$work_dir" config --get "$key" 2>/dev/null) || continue
		config_args+=(-c "${key}=${value}")
	done
	probe_root=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-signing-probe.XXXXXX") || return 1
	# -C keeps every probe command scoped to the private directory, never the
	# caller's working directory.
	if git -C "$probe_root" init -q --bare repo.git >/dev/null 2>&1 &&
		tree_id=$(git -C "$probe_root/repo.git" hash-object -w -t tree --stdin </dev/null 2>/dev/null); then
		GIT_TERMINAL_PROMPT=0 \
			SSH_ASKPASS=/usr/bin/false \
			SSH_ASKPASS_REQUIRE=force \
			DISPLAY=aidevops-headless \
			git -C "$probe_root/repo.git" "${config_args[@]}" commit-tree -S "$tree_id" \
				-m "aidevops headless signing preflight" </dev/null >/dev/null 2>&1 || status=1
	else
		status=1
	fi
	rm -rf -- "$probe_root"
	return "$status"
}

# headless_signing_append_git_config_env <key> <value> — append one
# process-scoped Git config entry inherited by child processes.
headless_signing_append_git_config_env() {
	local config_key="$1"
	local config_value="$2"
	local config_count="${GIT_CONFIG_COUNT:-0}"
	[[ "$config_count" =~ ^[0-9]+$ ]] || return 1
	export "GIT_CONFIG_KEY_${config_count}=${config_key}"
	export "GIT_CONFIG_VALUE_${config_count}=${config_value}"
	export GIT_CONFIG_COUNT=$((config_count + 1))
	return 0
}

# headless_signing_public_key — print the dedicated public key path.
headless_signing_public_key() {
	printf '%s\n' "${AIDEVOPS_HEADLESS_SIGNING_PUBLIC_KEY:-${HOME}/.ssh/id_ed25519_signing.pub}"
	return 0
}

# headless_signing_export_key_env — make the dedicated key the signing key for
# this process and its children when it exists. Does not set commit.gpgsign, so
# repositories that do not require signing keep committing unsigned. Returns 1
# only when the key is absent (existing signing config is then left alone).
headless_signing_export_key_env() {
	[[ "${_AIDEVOPS_HEADLESS_SIGNING_KEY_EXPORTED:-0}" == "1" ]] && return 0
	local signing_public_key=""
	signing_public_key=$(headless_signing_public_key)
	[[ -r "$signing_public_key" ]] || return 1
	headless_signing_append_git_config_env "gpg.format" "ssh" || return 1
	headless_signing_append_git_config_env "user.signingkey" "$signing_public_key" || return 1
	export _AIDEVOPS_HEADLESS_SIGNING_KEY_EXPORTED=1
	return 0
}

# headless_signing_heal_agent — restart the headless ssh-agent once when the
# dedicated private key exists, then load its environment. Never generates
# keys or prompts; setup remains terminal-only.
headless_signing_heal_agent() {
	local signing_helper="${AIDEVOPS_SIGNING_SETUP_HELPER:-${_HEADLESS_SIGNING_LIB_DIR}/signing-setup.sh}"
	local signing_key="${AIDEVOPS_HEADLESS_SIGNING_KEY:-${HOME}/.ssh/id_ed25519_signing}"
	local agent_env="${AIDEVOPS_SSH_AGENT_ENV:-${HOME}/.ssh/agent.env}"
	[[ -f "$signing_key" && -x "$signing_helper" ]] || return 1
	SSH_ASKPASS=/usr/bin/false SSH_ASKPASS_REQUIRE=force \
		"$signing_helper" agent-start </dev/null >/dev/null 2>&1 || true
	if [[ -r "$agent_env" ]]; then
		# shellcheck source=/dev/null
		. "$agent_env" >/dev/null 2>&1 || true
	fi
	return 0
}

# headless_signing_preflight <dir> — 0 when <dir> does not require signing or
# a prompt-free signed commit succeeds (after at most one agent heal). Uses the
# isolated probe so canonical checkouts are never written.
headless_signing_preflight() {
	local work_dir="$1"
	headless_signing_required "$work_dir" || return 0
	headless_signing_commit_probe_isolated "$work_dir" && return 0
	headless_signing_heal_agent || return 1
	headless_signing_commit_probe_isolated "$work_dir" && return 0
	return 1
}
