#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# oauth-pool-remote-sync.sh — bidirectional sync of ONE pool account to another host/user.
#
# Sub-library of oauth-pool-helper.sh (sourced; do not execute directly).
#
# Why not rsync oauth-pool.json: refresh tokens rotate on every refresh, so two
# independent refreshers invalidate each other's grant (only the newest
# `expires` is live); a whole-file copy would also overwrite the remote user's
# other providers/accounts, and bypass the oauth-pool.json.lock.d lock.
# This moves one entry at a time: `local get | ssh remote put | local put`.
# Tokens travel only over stdin/stdout; `status` prints sha256 fingerprints.
#
# Commands: remote-sync [install|sync|status|enable|disable]
#           --host H [--remote-user U] --provider P --email E
#
# Dependencies: oauth-pool-helper.sh (POOL_FILE, POOL_OPS, print_*), ssh.

if [[ -n "${_OAUTH_POOL_REMOTE_SYNC_LOADED:-}" ]]; then
	return 0
fi
_OAUTH_POOL_REMOTE_SYNC_LOADED=1

_RS_HOST=""
_RS_USER=""
_RS_PROVIDER="anthropic"
_RS_EMAIL=""
# Optional seat selector (GH#38959): orgId prefix or org name, for an email
# that holds several seats (e.g. Team + Personal). Empty keeps legacy behaviour.
_RS_ORG=""
_RS_REMOTE_HELPER=".aidevops/agents/scripts/oauth-pool-helper.sh"
_RS_LABEL="sh.aidevops.oauth-pool-remote-sync"

# Local single-entry op: _rs_local_op <get|put|fingerprint> (stdin forwarded).
_rs_local_op() {
	local op="$1"
	POOL_FILE_PATH="$POOL_FILE" PROVIDER="$_RS_PROVIDER" EMAIL="$_RS_EMAIL" ORG="$_RS_ORG" \
		python3 "$POOL_OPS" "entry-${op}"
	return $?
}

# Internal subcommand run on the remote side: entry <get|put|fingerprint> PROVIDER EMAIL [ORG]
cmd_entry() {
	local op="${1:-}"
	_RS_PROVIDER="${2:-}"
	_RS_EMAIL="${3:-}"
	_RS_ORG="${4:-}"
	case "$op" in
	get | put | fingerprint) ;;
	*)
		print_error "Usage: entry <get|put|fingerprint> <provider> <email> [org]"
		return 1
		;;
	esac
	if [[ -z "$_RS_PROVIDER" || -z "$_RS_EMAIL" ]]; then
		print_error "entry requires <provider> <email>"
		return 1
	fi
	_rs_local_op "$op"
	return $?
}

_rs_parse_args() {
	local opt
	while [[ $# -gt 0 ]]; do
		opt="${1:-}"
		case "$opt" in
		--host)
			_RS_HOST="${2:-}"
			shift 2 || return 1
			;;
		--remote-user)
			_RS_USER="${2:-}"
			shift 2 || return 1
			;;
		--provider)
			_RS_PROVIDER="${2:-}"
			shift 2 || return 1
			;;
		--email)
			_RS_EMAIL="${2:-}"
			shift 2 || return 1
			;;
		--org)
			_RS_ORG="${2:-}"
			shift 2 || return 1
			;;
		--remote-helper)
			_RS_REMOTE_HELPER="${2:-}"
			shift 2 || return 1
			;;
		*)
			print_error "Unknown option: ${opt}"
			return 1
			;;
		esac
	done
	if [[ -z "$_RS_HOST" || -z "$_RS_EMAIL" ]]; then
		print_error "--host and --email are required"
		return 1
	fi
	if [[ ! "$_RS_PROVIDER" =~ ^(anthropic|openai|cursor|google)$ ]]; then
		print_error "Invalid --provider: $_RS_PROVIDER"
		return 1
	fi
	# Values are re-quoted for the remote shell, but reject odd characters early.
	if [[ ! "$_RS_HOST$_RS_USER" =~ ^[A-Za-z0-9@._:-]*$ || "$_RS_HOST" == -* ]]; then
		print_error "Invalid --host/--remote-user"
		return 1
	fi
	# Org names may hold spaces/apostrophes ("...'s Organization"); reject shell
	# and XML metacharacters. An orgId prefix is the most robust selector.
	local org_re="^[A-Za-z0-9 ._@:'-]*$"
	if [[ ! "$_RS_ORG" =~ $org_re ]]; then
		print_error "Invalid --org (use an orgId prefix or a plain org name)"
		return 1
	fi
	return 0
}

_rs_control_path() {
	local dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$dir"
	chmod 700 "$dir" 2>/dev/null || true
	printf '%s/oauth-rs-%s.sock' "$dir" "$$"
	return 0
}

# Run the remote helper: _rs_remote <op> (stdin forwarded to the remote op).
# ssh ControlMaster avoids sshd MaxStartups resets on rapid reconnects.
_rs_remote() {
	local op="$1"
	local cp
	cp=$(_rs_control_path)
	local inner
	# shellcheck disable=SC2016  # $HOME must expand on the remote side
	inner=$(printf 'exec "$HOME"/%q entry %q %q %q' "$_RS_REMOTE_HELPER" "$op" "$_RS_PROVIDER" "$_RS_EMAIL")
	# Append the org only when set, so single-seat syncs keep working against
	# remote helpers that predate seat identity.
	if [[ -n "$_RS_ORG" ]]; then
		inner="${inner} $(printf '%q' "$_RS_ORG")"
	fi
	local cmd
	if [[ -n "$_RS_USER" ]]; then
		cmd=$(printf 'sudo -n -u %q sh -c %q' "$_RS_USER" "$inner")
	else
		cmd="sh -c $(printf '%q' "$inner")"
	fi
	ssh -o BatchMode=yes -o ControlMaster=auto -o "ControlPath=${cp}" -o ControlPersist=30 \
		-- "$_RS_HOST" "$cmd"
	local rc=$?
	ssh -O exit -o "ControlPath=${cp}" -- "$_RS_HOST" >/dev/null 2>&1 || true
	return $rc
}

# One pipeline per sync: local get | remote put | local put.
_rs_sync() {
	local tmp_dir tmp_back
	tmp_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$tmp_dir"
	tmp_back=$(mktemp "${tmp_dir}/oauth-rs-back.XXXXXX") || return 1
	chmod 600 "$tmp_back"
	# shellcheck disable=SC2064
	trap "rm -f '$tmp_back'" RETURN

	# Refuse up front when the email holds several local seats and --org does
	# not pick one; otherwise the pipeline would misreport an ssh failure.
	local seat_rc=0
	_rs_local_op fingerprint >/dev/null || seat_rc=$?
	if [[ "$seat_rc" -eq 2 ]]; then
		print_error "remote-sync: ${_RS_EMAIL} has several ${_RS_PROVIDER} seats; pass --org <orgId-prefix|org name>"
		return 1
	fi

	if ! _rs_local_op get | _rs_remote put >"$tmp_back"; then
		print_error "remote-sync: remote put failed (check ssh/sudo access)"
		return 1
	fi
	local back_status
	back_status=$(_rs_local_op put <"$tmp_back" 2>&1 >/dev/null) || {
		print_error "remote-sync: local put failed"
		return 1
	}
	print_success "remote-sync ${_RS_PROVIDER}/${_RS_EMAIL}${_RS_ORG:+ [${_RS_ORG}]} <-> ${_RS_HOST}: local ${back_status}"
	return 0
}

_rs_status() {
	local lfp rfp
	local err_word="unreachable"
	lfp=$(_rs_local_op fingerprint) || lfp="$err_word"
	rfp=$(_rs_remote fingerprint) || rfp="$err_word"
	printf 'local : %s\nremote: %s\n' "$lfp" "$rfp"
	if [[ "$lfp" == "$rfp" && "$lfp" != "absent" && "$lfp" != "$err_word" ]]; then
		print_success "Refresh fingerprints match"
		return 0
	fi
	print_warning "Pools differ (run: remote-sync sync)"
	return 1
}

_rs_slug() {
	# Hash separate fields to retain punctuation/boundaries without exceeding
	# scheduler filename limits. Empty user (SSH login) is not sudo user "self".
	# The org is hashed only when set, so existing installs keep their slug.
	if [[ -n "$_RS_ORG" ]]; then
		python3 -c 'import hashlib, json, sys; print(hashlib.sha256(json.dumps(sys.argv[1:]).encode()).hexdigest())' \
			"$_RS_HOST" "$_RS_USER" "$_RS_PROVIDER" "$_RS_EMAIL" "$_RS_ORG"
		return $?
	fi
	python3 -c 'import hashlib, json, sys; print(hashlib.sha256(json.dumps(sys.argv[1:]).encode()).hexdigest())' \
		"$_RS_HOST" "$_RS_USER" "$_RS_PROVIDER" "$_RS_EMAIL"
	return $?
}

_rs_sync_command_line() {
	local self="${SCRIPT_DIR}/oauth-pool-helper.sh"
	printf '%q remote-sync sync --host %q --provider %q --email %q' \
		"$self" "$_RS_HOST" "$_RS_PROVIDER" "$_RS_EMAIL"
	if [[ -n "$_RS_ORG" ]]; then
		printf ' --org %q' "$_RS_ORG"
	fi
	if [[ -n "$_RS_USER" ]]; then
		printf ' --remote-user %q' "$_RS_USER"
	fi
	printf ' --remote-helper %q' "$_RS_REMOTE_HELPER"
	return 0
}

_rs_unit_dir() {
	printf '%s/.config/systemd/user' "$HOME"
	return 0
}

_rs_install_launchd() {
	local plist slug cmd
	slug=$(_rs_slug)
	plist="$HOME/Library/LaunchAgents/${_RS_LABEL}.${slug}.plist"
	cmd=$(_rs_sync_command_line)
	mkdir -p "$(dirname "$plist")"
	cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${_RS_LABEL}.${slug}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>-c</string>
		<string>${cmd//&/&amp;}</string>
	</array>
	<key>WatchPaths</key>
	<array>
		<string>${POOL_FILE}</string>
	</array>
	<key>StartInterval</key>
	<integer>60</integer>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
PLIST
	chmod 644 "$plist"
	return 0
}

_rs_install_systemd() {
	local dir slug cmd
	dir=$(_rs_unit_dir)
	slug=$(_rs_slug)
	cmd=$(_rs_sync_command_line)
	mkdir -p "$dir"
	cat >"${dir}/aidevops-oauth-pool-remote-sync-${slug}.service" <<UNIT
[Unit]
Description=aidevops OAuth pool remote-sync (${slug})

[Service]
Type=oneshot
ExecStart=/bin/bash -c '${cmd//\'/\'\\\'\'}'
UNIT
	cat >"${dir}/aidevops-oauth-pool-remote-sync-${slug}.path" <<UNIT
[Unit]
Description=Trigger OAuth pool remote-sync on pool change (${slug})

[Path]
PathChanged=${POOL_FILE}
Unit=aidevops-oauth-pool-remote-sync-${slug}.service

[Install]
WantedBy=default.target
UNIT
	cat >"${dir}/aidevops-oauth-pool-remote-sync-${slug}.timer" <<UNIT
[Unit]
Description=Periodic OAuth pool remote-sync (${slug})

[Timer]
OnBootSec=60
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
UNIT
	return 0
}

_rs_scheduler_toggle() {
	local action="$1"
	local slug
	slug=$(_rs_slug)
	if [[ "$(uname -s)" == "Darwin" ]]; then
		local plist="$HOME/Library/LaunchAgents/${_RS_LABEL}.${slug}.plist"
		if [[ "$action" == "enable" ]]; then
			launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || launchctl load "$plist"
		else
			launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || launchctl unload "$plist" 2>/dev/null || true
		fi
		return 0
	fi
	local base="aidevops-oauth-pool-remote-sync-${slug}"
	if [[ "$action" == "enable" ]]; then
		systemctl --user daemon-reload && systemctl --user enable --now "${base}.path" "${base}.timer"
	else
		systemctl --user disable --now "${base}.path" "${base}.timer" 2>/dev/null || true
	fi
	return 0
}

_rs_install() {
	if [[ "$(uname -s)" == "Darwin" ]]; then
		_rs_install_launchd
	else
		_rs_install_systemd
	fi
	print_success "Installed scheduler for ${_RS_LABEL} (run 'remote-sync enable' with the same options to start)"
	return 0
}

cmd_remote_sync() {
	local sub="${1:-}"
	shift || true
	case "$sub" in
	sync | status | install | enable | disable) ;;
	*)
		print_error "Usage: remote-sync <install|sync|status|enable|disable> --host H [--remote-user U] --provider P --email E [--org O]"
		return 1
		;;
	esac
	_rs_parse_args "$@" || return 1
	case "$sub" in
	sync) _rs_sync ;;
	status) _rs_status ;;
	install) _rs_install ;;
	enable | disable) _rs_scheduler_toggle "$sub" ;;
	esac
	return $?
}
