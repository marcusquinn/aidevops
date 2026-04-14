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
#   sudo aidevops approve issue <number> # Approve an issue for development
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

	if [[ "$target_type" == "issue" ]]; then
		gh issue view "$target_number" --repo "$slug" --json title --jq '.title' 2>/dev/null || printf '%s' "(could not fetch title)"
		return 0
	fi

	gh pr view "$target_number" --repo "$slug" --json title --jq '.title' 2>/dev/null || printf '%s' "(could not fetch title)"
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

_post_issue_approval_updates() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"

	# Label updates and assignee are issue-specific (PRs don't use these labels).
	if [[ "$target_type" == "issue" ]]; then
		gh issue edit "$target_number" --repo "$slug" \
			--remove-label "needs-maintainer-review" \
			--add-label "auto-dispatch" >/dev/null 2>&1 || true
		_print_info "Labels updated: removed needs-maintainer-review, added auto-dispatch"

		# t1932: Auto-assign the approving maintainer so the CI maintainer gate
		# passes without a separate manual command. The crypto approval is already
		# the strongest signal of maintainer intent — requiring a second command
		# to set assignee adds friction with zero additional security value.
		local gh_user
		gh_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
		if [[ -n "$gh_user" ]]; then
			gh issue edit "$target_number" --repo "$slug" \
				--add-assignee "$gh_user" >/dev/null 2>&1 || true
			_print_info "Assigned to $gh_user"
		else
			_print_warn "Could not detect GitHub username — set assignee manually"
		fi

		# t1931: Lock the issue immediately at approval time to close the
		# prompt-injection window between crypto-approval and worker dispatch.
		# Previously, the lock only happened at dispatch time (pulse-wrapper.sh
		# lock_issue_for_worker), leaving a gap where non-collaborators could
		# add comments that influence the worker. The pulse's dispatch-time lock
		# becomes a reinforcing no-op (gh issue lock on an already-locked issue
		# is idempotent). Unlock still happens after worker completion.
		gh issue lock "$target_number" --repo "$slug" --reason "resolved" >/dev/null 2>&1 || true
		_print_info "Issue #$target_number locked (scope finalized, unlocks after worker completion)"

		# t2057: idempotent release of status:in-review. If the maintainer was
		# interactively reviewing this contributor issue before signing the
		# cryptographic approval, the `interactive-session-helper.sh claim`
		# will have applied `status:in-review`. Clear it here so the pulse
		# dispatch-dedup guard no longer blocks — signing is the handoff to
		# automation, so the interactive hold must lift. Idempotent: no-op
		# when the label is not present. Delete the stamp too so the local
		# state matches the remote.
		local _ah_labels_json
		_ah_labels_json=$(gh issue view "$target_number" --repo "$slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
		if [[ "$_ah_labels_json" == *"status:in-review"* ]]; then
			# Use set_issue_status from shared-constants.sh for the atomic
			# status transition. Located via deployed helper first, then
			# in-repo source.
			local _ah_helper=""
			if [[ -x "${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh" ]]; then
				_ah_helper="${HOME}/.aidevops/agents/scripts/interactive-session-helper.sh"
			else
				# Resolve sibling path relative to this file
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
	else
		# GH#17903: Lock PRs at approval time to close the same prompt-injection
		# window that exists for issues. Without locking, non-collaborators can
		# add comments to an approved PR between approval and merge, potentially
		# influencing automated review or merge decisions.
		gh pr comment "$target_number" --repo "$slug" \
			--body "This PR has been approved by a maintainer and is now locked for review." \
			>/dev/null 2>&1 || true
		# Note: GitHub does not support locking PRs via gh CLI directly (only issues).
		# The lock_notice in the approval comment serves as the authoritative signal.
		_print_info "PR #$target_number approval recorded (conversation locked via approval comment)"
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
		if ! gh issue comment "$target_number" --repo "$slug" --body "$comment_body"; then
			_print_error "Failed to post approval comment on issue #$target_number"
			return 1
		fi
	else
		if ! gh pr comment "$target_number" --repo "$slug" --body "$comment_body"; then
			_print_error "Failed to post approval comment on PR #$target_number"
			return 1
		fi
	fi

	_post_issue_approval_updates "$target_type" "$target_number" "$slug"
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
	echo "  sudo aidevops approve issue <number>"
	echo "  sudo aidevops approve pr <number>"
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
		owner=$(stat -f '%Su' "$APPROVAL_PRIVATE_DIR" 2>/dev/null || stat -c '%U' "$APPROVAL_PRIVATE_DIR" 2>/dev/null || echo "unknown")
		perms=$(stat -f '%A' "$APPROVAL_PRIVATE_DIR" 2>/dev/null || stat -c '%a' "$APPROVAL_PRIVATE_DIR" 2>/dev/null || echo "unknown")
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
	echo "  sudo aidevops approve issue 17438"
	echo "  sudo aidevops approve issue 17438 marcusquinn/aidevops"
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
