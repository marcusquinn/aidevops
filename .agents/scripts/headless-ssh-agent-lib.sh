#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# -----------------------------------------------------------------------------
# headless-ssh-agent-lib.sh — liveness check and self-heal for the persisted
# headless signing agent named by ~/.ssh/agent.env (GH#36493).
#
# A plain ssh-agent does not survive a reboot, but agent.env does. Every
# headless entry point (Pulse, script routines, the headless runtime) sources
# this library instead of sourcing agent.env blindly, so a stale file is
# detected and the agent restarted with only the dedicated passphrase-less
# signing key. Passphrase-protected keys are never loaded and nothing prompts.
#
# Source, never execute: the functions must export SSH_AUTH_SOCK/SSH_AGENT_PID
# into the caller's shell. Do not call them inside command substitution.
#
# `ssh-add -l` exit codes: 0 = identities listed, 1 = live agent without
# identities, 2 = agent unreachable. Only 2 means the agent is dead.
# -----------------------------------------------------------------------------

[[ -n "${_AIDEVOPS_HEADLESS_SSH_AGENT_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_HEADLESS_SSH_AGENT_LIB_LOADED=1

# Result of the most recent headless_ssh_agent_ensure call:
# absent | live | healed | dead
HEADLESS_SSH_AGENT_STATUS=""

# Return 0 when SSH_AUTH_SOCK names a reachable agent, with or without keys.
headless_ssh_agent_reachable() {
	[[ -n "${SSH_AUTH_SOCK:-}" ]] || return 1
	local list_rc=0
	ssh-add -l >/dev/null 2>&1 </dev/null || list_rc=$?
	[[ "$list_rc" -eq 0 || "$list_rc" -eq 1 ]] || return 1
	return 0
}

_headless_ssh_agent_source_env() {
	local agent_env="$1"
	[[ -r "$agent_env" ]] || return 0
	# shellcheck source=/dev/null
	. "$agent_env" >/dev/null 2>&1 || true
	return 0
}

# headless_ssh_agent_ensure [signing-setup-helper]
# Source agent.env. When it names an unreachable agent and the dedicated
# headless key exists, restart the agent through `signing-setup.sh agent-start`
# without any prompt, then re-source. Sets HEADLESS_SSH_AGENT_STATUS.
# Returns 0 for absent/live/healed and 1 when the agent is still unreachable.
headless_ssh_agent_ensure() {
	local signing_helper="${1:-${AIDEVOPS_SIGNING_SETUP_HELPER:-}}"
	local agent_env="${AIDEVOPS_SSH_AGENT_ENV:-${HOME}/.ssh/agent.env}"
	local headless_key_path="${AIDEVOPS_HEADLESS_SIGNING_KEY_PATH:-${HOME}/.ssh/id_ed25519_signing}"

	# No persisted agent: the host uses another agent (for example a desktop
	# keyring or launchd). Leave the inherited environment untouched.
	if [[ ! -r "$agent_env" ]]; then
		HEADLESS_SSH_AGENT_STATUS="absent"
		return 0
	fi
	_headless_ssh_agent_source_env "$agent_env"
	if headless_ssh_agent_reachable; then
		HEADLESS_SSH_AGENT_STATUS="live"
		return 0
	fi
	if [[ -f "$headless_key_path" && -n "$signing_helper" && -x "$signing_helper" ]]; then
		SSH_ASKPASS=/usr/bin/false SSH_ASKPASS_REQUIRE=force DISPLAY=aidevops-headless \
			"$signing_helper" agent-start </dev/null >/dev/null 2>&1 || true
		_headless_ssh_agent_source_env "$agent_env"
		if headless_ssh_agent_reachable; then
			HEADLESS_SSH_AGENT_STATUS="healed"
			return 0
		fi
	fi
	HEADLESS_SSH_AGENT_STATUS="dead"
	return 1
}
