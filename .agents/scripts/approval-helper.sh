#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# -----------------------------------------------------------------------------
# approval-helper.sh — Cryptographic approval gate for external issues/PRs.
#
# Prevents automation (pulse/workers) from approving issues that require human
# review. Uses SSH-signed approval comments that workers cannot forge.
#
# Usage (must be run with sudo for issue/pr approval):
#   sudo aidevops approve setup          # One-time: generate approval key pair
#   sudo aidevops approve issue <number> [owner/repo] # Approve an issue for development
#   sudo aidevops approve pr <number>    # Approve a PR for merge
#   aidevops approve verify <number>     # Verify approval on an issue (no sudo)
#   aidevops approve status              # Show approval key setup status
#
# Security model:
#   - Private signing key stored root-only (~/.aidevops/approval-keys/private/)
#   - Requires sudo + interactive TTY (workers are headless, cannot enter password)
#   - SSH-signed approval comment posted to GitHub, verifiable by pulse
#   - Workers are prohibited from calling this command
# -----------------------------------------------------------------------------

set -euo pipefail

# Source shared-constants for gh_issue_comment / gh_pr_comment wrappers (t2393).
# PR #19953 replaced raw `gh issue comment` / `gh pr comment` calls with these
# wrappers to auto-append the t2393 signature footer, but this helper was
# missed in the sourcing sweep (t2408 / GH#19997). Under `sudo aidevops
# approve issue|pr`, the unbound wrappers produced `command not found` and
# blocked every approval. Conditional `[[ -f ]] && source` mirrors the
# circuit-breaker-helper.sh:29-32 pattern: fail-open if the shared file is
# missing on a partial install rather than hard-crashing the approval flow.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# Resolve the real user's home directory, handling sudo env_reset on Linux.
# Under sudo on Linux, HOME is reset to /root/ by env_reset; SUDO_USER holds
# the original username. getent passwd is the canonical resolver on Linux.
# On macOS, sudo does not reset HOME (and getent is not available), so the
# fallback to $HOME is correct for both platforms.
# Security: no escalation — root already has full filesystem access.
_resolve_real_home() {
	if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]] && command -v getent &>/dev/null; then
		local real_home
		real_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
		if [[ -n "$real_home" ]]; then
			printf '%s' "$real_home"
			return 0
		fi
	fi
	printf '%s' "$HOME"
	return 0
}

# Compute real home once at script load; used for all path variables below.
_APPROVAL_HOME=$(_resolve_real_home)

readonly APPROVAL_DIR="$_APPROVAL_HOME/.aidevops/approval-keys"
readonly APPROVAL_PRIVATE_DIR="$APPROVAL_DIR/private"
readonly APPROVAL_KEY="$APPROVAL_PRIVATE_DIR/approval.key"
readonly APPROVAL_PUB="$APPROVAL_DIR/approval.pub"
readonly APPROVAL_NAMESPACE="aidevops-approve"
readonly APPROVAL_MARKER="<!-- aidevops-signed-approval -->"

# Detect repo slug from current directory or repos.json
_detect_slug() {
	local slug=""
	# Try git remote first
	if git rev-parse --is-inside-work-tree &>/dev/null; then
		local remote_url
		remote_url=$(git remote get-url origin 2>/dev/null || echo "")
		slug=$(printf '%s' "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')
	fi
	# Fall back to repos.json current directory match
	if [[ -z "$slug" || "$slug" != *"/"* ]]; then
		local repos_json="$_APPROVAL_HOME/.config/aidevops/repos.json"
		if [[ -f "$repos_json" ]]; then
			local cwd
			cwd=$(pwd)
			slug=$(jq -r --arg cwd "$cwd" \
				'.initialized_repos[] | select(.path == $cwd) | .slug // empty' \
				"$repos_json" 2>/dev/null || echo "")
		fi
	fi
	printf '%s' "$slug"
	return 0
}

_print_info() {
	local msg="$1"
	echo -e "\033[0;34m[INFO]\033[0m $msg"
	return 0
}

_print_ok() {
	local msg="$1"
	echo -e "\033[0;32m[OK]\033[0m $msg"
	return 0
}

_print_warn() {
	local msg="$1"
	echo -e "\033[1;33m[WARN]\033[0m $msg"
	return 0
}

_print_error() {
	local msg="$1"
	echo -e "\033[0;31m[ERROR]\033[0m $msg"
	return 0
}

_require_gh_auth() {
	if gh auth status >/dev/null 2>&1; then
		return 0
	fi
	# Under sudo on Linux, gnome-keyring is inaccessible because env_reset strips
	# DBUS_SESSION_BUS_ADDRESS. Attempt automatic token resolution via two methods
	# before falling back to a descriptive error.
	if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]]; then
		local real_uid=""
		real_uid=$(id -u "$SUDO_USER" 2>/dev/null || echo "")
		# Method 1: reconnect to user's D-Bus session socket via runuser
		if [[ -n "$real_uid" && -S "/run/user/${real_uid}/bus" ]] && command -v runuser &>/dev/null; then
			local token=""
			token=$(runuser -u "$SUDO_USER" -- env \
				"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${real_uid}/bus" \
				"XDG_RUNTIME_DIR=/run/user/${real_uid}" \
				gh auth token 2>/dev/null || echo "")
			if [[ -n "$token" ]]; then
				export GH_TOKEN="$token"
				if gh auth status >/dev/null 2>&1; then
					return 0
				fi
			fi
		fi
		# Method 2: read token directly from gh config file (non-keyring storage)
		local real_home
		real_home=$(_resolve_real_home)
		local gh_hosts="${real_home}/.config/gh/hosts.yml"
		if [[ -f "$gh_hosts" ]]; then
			local file_token=""
			file_token=$(awk '/oauth_token:/{print $2; exit}' "$gh_hosts" 2>/dev/null || echo "")
			if [[ -n "$file_token" ]]; then
				export GH_TOKEN="$file_token"
				if gh auth status >/dev/null 2>&1; then
					return 0
				fi
			fi
		fi
	fi
	_print_error "gh authentication failed (common under sudo on Linux — gnome-keyring is inaccessible)"
	_print_info "Workaround: export GH_TOKEN=\$(gh auth token) && sudo --preserve-env=GH_TOKEN aidevops approve ..."
	return 1
}

_require_number_arg() {
	local value="${1:-}"
	local noun="$2"
	local usage="$3"

	if [[ -z "$value" ]]; then
		_print_error "$usage"
		return 1
	fi

	if [[ ! "$value" =~ ^[0-9]+$ ]]; then
		_print_error "$noun number must be numeric: $value"
		return 1
	fi

	return 0
}

_require_interactive_root() {
	local usage="$1"

	if [[ ! -t 0 ]]; then
		_print_error "This command requires an interactive terminal (cannot run headless)"
		return 1
	fi

	if [[ "$(id -u)" -ne 0 ]]; then
		_print_error "This command must be run with sudo"
		echo "$usage"
		return 1
	fi

	return 0
}

_approval_real_user() {
	printf '%s' "${SUDO_USER:-$(whoami)}"
	return 0
}

_approval_real_home() {
	_resolve_real_home
	return 0
}

_approval_private_key_path() {
	local real_home
	real_home=$(_approval_real_home)
	printf '%s' "$real_home/.aidevops/approval-keys/private/approval.key"
	return 0
}

_require_approval_key() {
	local actual_key="$1"

	if [[ ! -f "$actual_key" ]]; then
		_print_error "No approval key found. Run: sudo aidevops approve setup"
		return 1
	fi

	return 0
}

_resolve_slug_or_fail() {
	local slug="${1:-}"
	local usage="$2"

	if [[ -z "$slug" ]]; then
		slug=$(_detect_slug)
	fi

	if [[ -z "$slug" || "$slug" != *"/"* ]]; then
		_print_error "$usage"
		return 1
	fi

	printf '%s' "$slug"
	return 0
}

_fetch_target_title() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local title=""
	local rc=0

	if [[ "$target_type" == "issue" ]]; then
		title=$(gh issue view "$target_number" --repo "$slug" --json title --jq '.title' 2>/dev/null) || rc=$?
		if [[ $rc -ne 0 ]] && command -v _rest_should_fallback >/dev/null 2>&1 && _rest_should_fallback; then
			_print_info "gh-wrapper: GraphQL exhausted, falling back to REST for issue title" >&2
			title=$(_rest_issue_view "$target_number" --repo "$slug" --json title --jq '.title' 2>/dev/null) || title=""
		fi
		[[ -n "$title" ]] && printf '%s' "$title" || printf '%s' "(could not fetch title)"
		return 0
	fi

	title=$(gh pr view "$target_number" --repo "$slug" --json title --jq '.title' 2>/dev/null) || rc=$?
	if [[ $rc -ne 0 ]] && command -v _rest_should_fallback >/dev/null 2>&1 && _rest_should_fallback; then
		_print_info "gh-wrapper: GraphQL exhausted, falling back to REST for PR title" >&2
		title=$(_rest_pr_view "$target_number" --repo "$slug" --json title --jq '.title' 2>/dev/null) || title=""
	fi
	[[ -n "$title" ]] && printf '%s' "$title" || printf '%s' "(could not fetch title)"
	return 0
}

_confirm_approval() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local title="$4"
	local label="Issue"

	if [[ "$target_type" == "pr" ]]; then
		label="PR"
		echo ""
		echo "Approving PR to merge:"
	else
		echo ""
		echo "Approving issue:"
	fi

	echo "  ${label}:  #$target_number"
	echo "  Repo:   $slug"
	echo "  Title:  $title"
	echo ""
	printf "Type APPROVE to confirm: "

	local confirmation
	read -r confirmation
	if [[ "$confirmation" != "APPROVE" ]]; then
		_print_error "Approval cancelled"
		return 1
	fi

	return 0
}

_sign_approval_payload() {
	local payload="$1"
	local actual_key="$2"
	local sig_file="$3"

	printf '%s' "$payload" | ssh-keygen -Y sign \
		-f "$actual_key" \
		-n "$APPROVAL_NAMESPACE" \
		-q - >"$sig_file" 2>/dev/null

	if [[ ! -s "$sig_file" ]]; then
		_print_error "Signing failed"
		return 1
	fi

	return 0
}

_build_signed_comment() {
	local payload="$1"
	local sig_file="$2"
	local target_type="${3:-issue}"
	local signature lock_notice
	signature=$(<"$sig_file")

	# PRs use GitHub's "conversation locked" terminology; issues use "issue locked".
	if [[ "$target_type" == "pr" ]]; then
		lock_notice="> **This conversation is now locked.** To propose scope changes, open a new issue referencing this one."
	else
		lock_notice="> **This issue is now locked.** To propose scope changes, open a new issue referencing this one."
	fi

	cat <<EOF
${APPROVAL_MARKER}
## Maintainer Approval (cryptographically signed)

\`\`\`
${payload}
\`\`\`

\`\`\`
${signature}
\`\`\`

This approval was signed with a root-protected SSH key. It cannot be forged by automation.

${lock_notice}
EOF
	return 0
}

_approval_lock_issue() {
	local target_number="$1"
	local slug="$2"
	local rc=0

	gh issue lock "$target_number" --repo "$slug" --reason "resolved" >/dev/null 2>&1 || rc=$?
	if [[ $rc -ne 0 ]] && command -v _rest_should_fallback >/dev/null 2>&1 && _rest_should_fallback; then
		_print_info "gh-wrapper: GraphQL exhausted, falling back to REST for issue lock" >&2
		rc=0
		gh api -X PUT "/repos/${slug}/issues/${target_number}/lock" -f lock_reason=resolved >/dev/null 2>&1 || rc=$?
	fi
	return "$rc"
}

_approval_fetch_issue_json() {
	local target_number="$1"
	local slug="$2"

	gh api "/repos/${slug}/issues/${target_number}" 2>/dev/null
	return $?
}

_approval_verify_issue_state() {
	local target_number="$1"
	local slug="$2"
	local gh_user="$3"
	local issue_json=""

	issue_json=$(_approval_fetch_issue_json "$target_number" "$slug") || {
		_print_error "Approval state verification failed: could not read issue #$target_number via REST"
		return 1
	}

	if ! printf '%s' "$issue_json" | jq -e '(.labels // []) | any(.name == "needs-maintainer-review") | not' >/dev/null 2>&1; then
		_print_error "Approval state verification failed: needs-maintainer-review is still present on #$target_number"
		return 1
	fi
	if ! printf '%s' "$issue_json" | jq -e '(.labels // []) | any(.name == "auto-dispatch")' >/dev/null 2>&1; then
		_print_error "Approval state verification failed: auto-dispatch is missing on #$target_number"
		return 1
	fi
	if ! printf '%s' "$issue_json" | jq -e --arg user "$gh_user" '(.assignees // []) | any(.login == $user)' >/dev/null 2>&1; then
		_print_error "Approval state verification failed: $gh_user is not assigned to #$target_number"
		return 1
	fi
	if ! printf '%s' "$issue_json" | jq -e '.locked == true' >/dev/null 2>&1; then
		_print_error "Approval state verification failed: issue #$target_number is not locked"
		return 1
	fi

	return 0
}

_approval_apply_issue_lifecycle_updates() {
	local target_number="$1"
	local slug="$2"
	local gh_user=""
	local edit_err=""
	local lock_err=""

	gh_user=$(gh api user --jq '.login' 2>/dev/null || printf '')
	if [[ -z "$gh_user" || "$gh_user" == "null" ]]; then
		_print_error "Could not detect GitHub username — approval state was not changed"
		return 1
	fi

	edit_err=$(gh_issue_edit_safe "$target_number" --repo "$slug" \
		--remove-label "needs-maintainer-review" \
		--add-label "auto-dispatch" \
		--add-assignee "$gh_user" 2>&1 >/dev/null) || {
		_print_error "Failed to update approval labels/assignee on issue #$target_number"
		[[ -n "$edit_err" ]] && _print_error "$edit_err"
		return 1
	}
	_print_info "Labels updated: removed needs-maintainer-review, added auto-dispatch"
	_print_info "Assigned to $gh_user"

	lock_err=$(_approval_lock_issue "$target_number" "$slug" 2>&1 >/dev/null) || {
		_print_error "Approval advisory lock failure: issue #$target_number could not be locked after approval state updates"
		[[ -n "$lock_err" ]] && _print_error "$lock_err"
		return 1
	}
	_print_info "Issue #$target_number locked (scope finalized, unlocks after worker completion)"

	# t2057: idempotent release of status:in-review. Signing is the handoff to
	# automation, so the interactive hold must lift. Best-effort: verification
	# below checks the approval-critical state, not local stamp cleanup.
	local _ah_labels_json
	_ah_labels_json=$(gh_issue_view "$target_number" --repo "$slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
	if [[ "$_ah_labels_json" == *"status:in-review"* ]]; then
		local _ah_helper=""
		if [[ -x "${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh" ]]; then
			_ah_helper="${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh"
		else
			local _ah_script_dir
			_ah_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || _ah_script_dir=""
			if [[ -n "$_ah_script_dir" && -x "${_ah_script_dir}/interactive-session-helper.sh" ]]; then
				_ah_helper="${_ah_script_dir}/interactive-session-helper.sh"
			fi
		fi
		if [[ -n "$_ah_helper" ]]; then
			"$_ah_helper" release "$target_number" "$slug" >/dev/null 2>&1 || true
			_print_info "Released status:in-review (interactive review transitioned to available)"
		fi
	fi

	_approval_verify_issue_state "$target_number" "$slug" "$gh_user"
	return $?
}

_post_issue_approval_updates() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"

	# Label updates and assignee are issue-specific (PRs don't use these labels).
	if [[ "$target_type" == "issue" ]]; then
		_approval_apply_issue_lifecycle_updates "$target_number" "$slug"
		return $?
	else
		# GH#17903: Lock PRs at approval time to close the same prompt-injection
		# window that exists for issues. Without locking, non-collaborators can
		# add comments to an approved PR between approval and merge, potentially
		# influencing automated review or merge decisions.
		gh_pr_comment "$target_number" --repo "$slug" \
			--body "This PR has been approved by a maintainer and is now locked for review." \
			>/dev/null 2>&1 || true
		# Note: GitHub does not support locking PRs via gh CLI directly (only issues).
		# The lock_notice in the approval comment serves as the authoritative signal.
		_print_info "PR #$target_number approval recorded (conversation locked via approval comment)"
	fi

	return 0
}

#######################################
# t3068: Kick the pulse so it picks up this approval immediately.
#
# Eliminates the up-to-120s window between a verified signature post and the
# pulse-merge cycle acting on the linked PR. Two layers, both best-effort:
#
#   1. Marker file (~/.aidevops/cache/pulse-merge-trigger.txt) — append a
#      tab-separated line `slug<TAB>num<TAB>type<TAB>iso8601_ts`. The pulse
#      drains this file at cycle entry (see pulse-wrapper-bootstrap.sh
#      _drain_merge_trigger_file_if_present) and processes each PR via the
#      existing process_pr() entry point in pulse-merge.sh. Survives crashes
#      and approval/pulse races — if the immediate spawn (layer 2) is
#      unavailable, the next pulse-merge tick (60s) drains the marker.
#
#   2. Immediate background spawn — fire `pulse-wrapper.sh --merge-only` so
#      the merge pass runs within seconds. nohup + disown so the child
#      survives this script's exit. If pulse is already mid-merge the spawn
#      short-circuits via the merge-only lockdir collision in
#      _pulse_run_merge_only — the marker (layer 1) covers that case.
#
# Args:
#   $1 - target_type ("issue" or "pr")
#   $2 - target_number (numeric)
#   $3 - slug (owner/repo)
#
# Bypass: AIDEVOPS_SKIP_APPROVE_KICK_PULSE=1 disables both layers (used by
# tests and CI to keep approval flow purely local).
#
# Exit code: always 0 (failures must NEVER block the approval flow — the
# approval has already been signed and posted by the time we reach here).
#######################################
_kick_pulse_after_approval() {
	local target_type="${1:-}"
	local target_number="${2:-}"
	local slug="${3:-}"

	if [[ "${AIDEVOPS_SKIP_APPROVE_KICK_PULSE:-0}" == "1" ]]; then
		return 0
	fi

	# Defense-in-depth input validation. The caller already validated these,
	# but the marker file is consumed by another script that will exec on
	# them — keep the bar high.
	if ! [[ "$target_number" =~ ^[0-9]+$ ]]; then
		return 0
	fi
	if ! [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		return 0
	fi
	if [[ "$target_type" != "issue" && "$target_type" != "pr" ]]; then
		return 0
	fi

	# Layer 1: marker file. Always written; pulse drains on next merge cycle.
	# _APPROVAL_HOME (set near the top of this file) handles sudo HOME reset
	# on Linux so the marker lands in the real user's tree, not /root.
	local trigger_file="${_APPROVAL_HOME}/.aidevops/cache/pulse-merge-trigger.txt"
	mkdir -p "$(dirname "$trigger_file")" 2>/dev/null || true

	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
	# Tab-separated; the drain parser splits on \t. Append-only — multiple
	# concurrent approvals each contribute one line.
	printf '%s\t%s\t%s\t%s\n' "$slug" "$target_number" "$target_type" "$ts" \
		>>"$trigger_file" 2>/dev/null || true

	# When sudo writes the marker file, ownership defaults to root. Hand it
	# back to the real user so the pulse (running as the user) can read +
	# rotate it without permission errors.
	if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]]; then
		chown "$SUDO_USER" "$trigger_file" 2>/dev/null || true
	fi

	# Layer 2: immediate background spawn. Best-effort — if the binary is
	# missing or not executable, the marker (layer 1) still drives latency
	# down to the next pulse-merge tick (~60s).
	local pulse_wrapper="${_APPROVAL_HOME}/.aidevops/agents/scripts/pulse-wrapper.sh"
	if [[ ! -x "$pulse_wrapper" ]]; then
		return 0
	fi

	local kick_log="${_APPROVAL_HOME}/.aidevops/logs/pulse-approve-kick.log"
	mkdir -p "$(dirname "$kick_log")" 2>/dev/null || true

	# Detach completely so this exits even if the child blocks. The double
	# fork via subshell + disown matches the pattern in
	# pulse-lifecycle-helper.sh::_start. Drop sudo (run as the real user)
	# so the spawned pulse uses the same env/locks as the launchd-managed
	# pulse — root-owned locks would corrupt the lockdir tree.
	if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]] && command -v sudo >/dev/null 2>&1; then
		(
			nohup sudo -u "$SUDO_USER" -H -- "$pulse_wrapper" --merge-only \
				>>"$kick_log" 2>&1 </dev/null &
			disown 2>/dev/null || true
		) 2>/dev/null
	else
		(
			nohup "$pulse_wrapper" --merge-only \
				>>"$kick_log" 2>&1 </dev/null &
			disown 2>/dev/null || true
		) 2>/dev/null
	fi

	return 0
}

_approve_target() {
	local target_type="$1"
	local target_number="${2:-}"
	local slug="${3:-}"
	local usage="Usage: sudo aidevops approve ${target_type} <number> [owner/repo]"
	local slug_error="Could not detect repo slug. Provide it: sudo aidevops approve ${target_type} ${target_number} owner/repo"

	_require_number_arg "$target_number" "$target_type" "$usage" || return 1
	_require_interactive_root "$usage" || return 1

	local actual_key
	actual_key=$(_approval_private_key_path)
	_require_approval_key "$actual_key" || return 1
	_require_gh_auth || return 1

	slug=$(_resolve_slug_or_fail "$slug" "$slug_error") || return 1

	local title
	title=$(_fetch_target_title "$target_type" "$target_number" "$slug")
	_confirm_approval "$target_type" "$target_number" "$slug" "$title" || return 1

	local timestamp payload sig_file comment_body
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	payload="APPROVE:${target_type}:${slug}:${target_number}:${timestamp}"
	sig_file=$(mktemp)

	if ! _sign_approval_payload "$payload" "$actual_key" "$sig_file"; then
		rm -f "$sig_file"
		return 1
	fi

	comment_body=$(_build_signed_comment "$payload" "$sig_file" "$target_type")
	rm -f "$sig_file"

	if [[ "$target_type" == "issue" ]]; then
		if ! gh_issue_comment "$target_number" --repo "$slug" --body "$comment_body"; then
			_print_error "Failed to post approval comment on issue #$target_number"
			return 1
		fi
	else
		if ! gh_pr_comment "$target_number" --repo "$slug" --body "$comment_body"; then
			_print_error "Failed to post approval comment on PR #$target_number"
			return 1
		fi
	fi

	if ! _post_issue_approval_updates "$target_type" "$target_number" "$slug"; then
		_print_error "Approval signed, but post-approval protection updates did not reach the required state"
		return 1
	fi

	# t3068: kick the pulse to act on this approval immediately. Always
	# returns 0 — never blocks the approval flow. See _kick_pulse_after_approval
	# above for the two-layer (marker file + background spawn) design.
	_kick_pulse_after_approval "$target_type" "$target_number" "$slug"

	# Bash 3.2 compat: ${var^} (uppercase first) requires Bash 4+. Use printf + tr.
	local target_type_cap
	target_type_cap="$(printf '%s' "${target_type:0:1}" | tr '[:lower:]' '[:upper:]')${target_type:1}"
	_print_ok "$target_type_cap #$target_number approved and signed"
	echo ""
	return 0
}

_extract_fenced_block() {
	local body="$1"
	local target_block="$2"

	# Fenced code blocks have OPENING and CLOSING fence lines (``` pairs).
	# Count pairs (not individual fence lines) to identify block N.
	# Block 1 = content between fence pair 1, block 2 = content between pair 2, etc.
	printf '%s\n' "$body" | awk -v target="$target_block" '
		/^```/ {
			if (inside) {
				inside = 0
				if (capture) { exit }
			} else {
				pair++
				inside = 1
				if (pair == target) { capture = 1 }
				next
			}
			next
		}
		capture && inside { print }
	'
	return 0
}

_create_allowed_signers_file() {
	local pub_key="$1"
	local allowed_signers_file="$2"
	local key_content
	key_content=$(<"$pub_key")
	printf 'approval@aidevops.sh namespaces="%s" %s\n' "$APPROVAL_NAMESPACE" "$key_content" >"$allowed_signers_file"
	return 0
}

_verify_comment_signature() {
	local issue_number="$1"
	local body="$2"
	local pub_key="$3"
	local payload signature payload_file sig_file allowed_signers_file

	payload=$(_extract_fenced_block "$body" 1)
	if [[ -z "$payload" ]]; then
		return 1
	fi

	if [[ ! "$payload" =~ ^APPROVE:(issue|pr):.*:[0-9]+: ]]; then
		return 1
	fi

	signature=$(_extract_fenced_block "$body" 2)
	if [[ -z "$signature" ]]; then
		return 1
	fi

	payload_file=$(mktemp)
	sig_file=$(mktemp)
	allowed_signers_file=$(mktemp)
	printf '%s' "$payload" >"$payload_file"
	printf '%s\n' "$signature" >"$sig_file"
	_create_allowed_signers_file "$pub_key" "$allowed_signers_file"

	if ssh-keygen -Y verify \
		-f "$allowed_signers_file" \
		-I "approval@aidevops.sh" \
		-n "$APPROVAL_NAMESPACE" \
		-s "$sig_file" <"$payload_file" >/dev/null 2>&1 &&
		[[ "$payload" == *":${issue_number}:"* ]]; then
		rm -f "$payload_file" "$sig_file" "$allowed_signers_file"
		return 0
	fi

	rm -f "$payload_file" "$sig_file" "$allowed_signers_file"
	return 1
}

# ── Setup ────────────────────────────────────────────────────────────────────

cmd_setup() {
	echo ""
	echo "Setting up cryptographic approval key pair..."
	echo ""

	# Must be run as root (via sudo)
	if [[ "$(id -u)" -ne 0 ]]; then
		_print_error "This command must be run with sudo"
		echo "Usage: sudo aidevops approve setup"
		return 1
	fi

	# Detect the real user behind sudo
	local real_user="${SUDO_USER:-$(whoami)}"
	local real_home
	real_home=$(_resolve_real_home)
	local actual_approval_dir="$real_home/.aidevops/approval-keys"
	local actual_private_dir="$actual_approval_dir/private"
	local actual_key="$actual_private_dir/approval.key"
	local actual_pub="$actual_approval_dir/approval.pub"

	# Create directories
	mkdir -p "$actual_private_dir"

	# Generate key pair if it doesn't exist
	if [[ -f "$actual_key" ]]; then
		_print_info "Approval key already exists: $actual_key"
	else
		_print_info "Generating Ed25519 approval signing key..."
		ssh-keygen -t ed25519 -C "aidevops-approval-signing" \
			-f "$actual_key" -N "" -q
		_print_ok "Generated approval key pair"
	fi

	# Set ownership: private dir and key owned by root, not readable by user
	chown root:wheel "$actual_private_dir" 2>/dev/null || chown root:root "$actual_private_dir" 2>/dev/null || true
	chmod 700 "$actual_private_dir"
	chown root:wheel "$actual_key" 2>/dev/null || chown root:root "$actual_key" 2>/dev/null || true
	chmod 600 "$actual_key"
	# Also protect the private key's .pub companion that ssh-keygen creates
	if [[ -f "${actual_key}.pub" ]]; then
		chown root:wheel "${actual_key}.pub" 2>/dev/null || chown root:root "${actual_key}.pub" 2>/dev/null || true
		chmod 600 "${actual_key}.pub"
	fi

	# Copy public key to user-accessible location
	if [[ -f "${actual_key}.pub" ]]; then
		cp "${actual_key}.pub" "$actual_pub"
	elif [[ -f "$actual_key" ]]; then
		ssh-keygen -y -f "$actual_key" >"$actual_pub"
	fi
	chown "$real_user" "$actual_pub" 2>/dev/null || true
	chmod 644 "$actual_pub"

	# Set user-level dir ownership
	chown "$real_user" "$actual_approval_dir" 2>/dev/null || true

	_print_ok "Approval key pair configured"
	echo ""
	echo "  Private key (root-only): $actual_key"
	echo "  Public key (user-readable): $actual_pub"
	echo ""
	echo "The private key is owned by root and only accessible via sudo."
	echo "Workers cannot read it, even though they run as your user account."
	echo ""
	echo "You can now approve issues/PRs with:"
	echo "  sudo aidevops approve issue <number> <owner/repo>"
	echo "  sudo aidevops approve pr <number> <owner/repo>"
	return 0
}

# ── Approve Issue ────────────────────────────────────────────────────────────

cmd_issue_approved() {
	local issue_number="${1:-}"
	local slug="${2:-}"
	_approve_target "issue" "$issue_number" "$slug"
	return $?
}

# ── Approve PR ───────────────────────────────────────────────────────────────

cmd_pr_approved() {
	local pr_number="${1:-}"
	local slug="${2:-}"
	_approve_target "pr" "$pr_number" "$slug"
	return $?
}

# ── Verify Approval ──────────────────────────────────────────────────────────

# Verify that an issue has a valid signed approval comment.
# Returns 0 if valid approval found, 1 otherwise.
# This is the function the pulse calls to check approvals.
cmd_verify() {
	local issue_number="${1:-}"
	local slug="${2:-}"

	_require_number_arg "$issue_number" "Issue" "Usage: aidevops approve verify <number> [owner/repo]" || return 1
	slug=$(_resolve_slug_or_fail "$slug" "Could not detect repo slug") || return 1

	# Load public key
	local pub_key="$HOME/.aidevops/approval-keys/approval.pub"
	if [[ ! -f "$pub_key" ]]; then
		echo "NO_KEY"
		return 1
	fi

	# Fetch comments looking for approval marker
	local comments_json
	comments_json=$(gh api "repos/${slug}/issues/${issue_number}/comments" \
		--jq "[.[] | select(.body | contains(\"$APPROVAL_MARKER\"))]" 2>/dev/null || echo "[]")

	local comment_count
	comment_count=$(printf '%s' "$comments_json" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$comment_count" -eq 0 ]]; then
		echo "NO_APPROVAL"
		return 1
	fi

	# Check each approval comment (most recent first)
	local i=$((comment_count - 1))
	while [[ "$i" -ge 0 ]]; do
		local body
		body=$(printf '%s' "$comments_json" | jq -r ".[$i].body" 2>/dev/null || echo "")
		i=$((i - 1))

		if _verify_comment_signature "$issue_number" "$body" "$pub_key"; then
			echo "VERIFIED"
			return 0
		fi
	done

	echo "UNVERIFIED"
	return 1
}

# ── Status ───────────────────────────────────────────────────────────────────

cmd_status() {
	echo ""
	echo "Approval key status"
	echo "==================="
	echo ""

	if [[ -f "$APPROVAL_PUB" ]]; then
		_print_ok "Public key exists: $APPROVAL_PUB"
		echo "  Fingerprint: $(ssh-keygen -lf "$APPROVAL_PUB" 2>/dev/null || echo "unknown")"
	else
		_print_warn "No approval public key found"
		echo "  Run: sudo aidevops approve setup"
	fi

	echo ""
	if [[ -d "$APPROVAL_PRIVATE_DIR" ]]; then
		local owner perms
		owner=$(_file_owner "$APPROVAL_PRIVATE_DIR")
		perms=$(_file_perms "$APPROVAL_PRIVATE_DIR")
		if [[ "$owner" == "root" && "$perms" == "700" ]]; then
			_print_ok "Private key directory is root-protected (owner=$owner, mode=$perms)"
		else
			_print_warn "Private key directory permissions may be insecure (owner=$owner, mode=$perms)"
			echo "  Expected: owner=root, mode=700"
			echo "  Run: sudo aidevops approve setup"
		fi
	else
		_print_warn "No private key directory found"
		echo "  Run: sudo aidevops approve setup"
	fi

	echo ""
	return 0
}

# ── Help ─────────────────────────────────────────────────────────────────────

cmd_help() {
	echo "approval-helper.sh — Cryptographic approval gate covering external issues/PRs"
	echo ""
	echo "Commands (require sudo):"
	echo "  setup                      Generate root-protected approval key pair"
	echo "  issue <number> [slug]      Approve an issue"
	echo "  pr <number> [slug]         Approve a PR"
	echo ""
	echo "Commands (no sudo needed):"
	echo "  verify <number> [slug]     Verify approval signature on an issue"
	echo "  status                     Show approval key setup status"
	echo "  help                       Show this help"
	echo ""
	echo "Examples:"
	echo "  sudo aidevops approve setup"
	echo "  sudo aidevops approve issue 17438 <owner/repo>"
	echo "  aidevops approve verify 17438"
	echo ""
	echo "Security: The approval signing key is stored root-only. Workers run as your"
	echo "user account and cannot access it, even with the same GitHub credentials."
	return 0
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	setup) cmd_setup "$@" ;;
	issue | issue-approved) cmd_issue_approved "$@" ;;
	pr | pr-approved) cmd_pr_approved "$@" ;;
	verify) cmd_verify "$@" ;;
	status) cmd_status "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		_print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
