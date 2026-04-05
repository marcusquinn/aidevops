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

readonly APPROVAL_DIR="$HOME/.aidevops/approval-keys"
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
		local repos_json="$HOME/.config/aidevops/repos.json"
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
	real_home=$(eval echo "~$real_user")
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

	if [[ -z "$issue_number" ]]; then
		_print_error "Usage: sudo aidevops approve issue <number> [owner/repo]"
		return 1
	fi

	# Validate number
	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		_print_error "Issue number must be numeric: $issue_number"
		return 1
	fi

	# Must be interactive TTY (rejects headless workers)
	if [[ ! -t 0 ]]; then
		_print_error "This command requires an interactive terminal (cannot run headless)"
		return 1
	fi

	# Must be run as root (via sudo)
	if [[ "$(id -u)" -ne 0 ]]; then
		_print_error "This command must be run with sudo"
		echo "Usage: sudo aidevops approve issue $issue_number"
		return 1
	fi

	# Resolve paths for the real user
	local real_user="${SUDO_USER:-$(whoami)}"
	local real_home
	real_home=$(eval echo "~$real_user")
	local actual_key="$real_home/.aidevops/approval-keys/private/approval.key"

	if [[ ! -f "$actual_key" ]]; then
		_print_error "No approval key found. Run: sudo aidevops approve setup"
		return 1
	fi

	# Auto-detect slug if not provided
	if [[ -z "$slug" ]]; then
		slug=$(_detect_slug)
	fi
	if [[ -z "$slug" || "$slug" != *"/"* ]]; then
		_print_error "Could not detect repo slug. Provide it: sudo aidevops approve issue $issue_number owner/repo"
		return 1
	fi

	# Fetch issue title for confirmation
	local issue_title
	issue_title=$(gh issue view "$issue_number" --repo "$slug" --json title --jq '.title' 2>/dev/null || echo "(could not fetch title)")

	echo ""
	echo "Approving issue for development:"
	echo "  Issue:  #$issue_number"
	echo "  Repo:   $slug"
	echo "  Title:  $issue_title"
	echo ""

	# Interactive confirmation
	printf "Type APPROVE to confirm: "
	local confirmation
	read -r confirmation
	if [[ "$confirmation" != "APPROVE" ]]; then
		_print_error "Approval cancelled"
		return 1
	fi

	# Sign the approval
	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local payload="APPROVE:issue:${slug}:${issue_number}:${timestamp}"

	local sig_file
	sig_file=$(mktemp)
	trap 'rm -f "$sig_file"' EXIT

	printf '%s' "$payload" | ssh-keygen -Y sign \
		-f "$actual_key" \
		-n "$APPROVAL_NAMESPACE" \
		-q - >"$sig_file" 2>/dev/null

	if [[ ! -s "$sig_file" ]]; then
		_print_error "Signing failed"
		return 1
	fi

	local signature
	signature=$(cat "$sig_file")

	# Build the comment
	local comment_body
	comment_body="${APPROVAL_MARKER}
## Maintainer Approval (cryptographically signed)

\`\`\`
${payload}
\`\`\`

\`\`\`
${signature}
\`\`\`

This approval was signed with a root-protected SSH key. It cannot be forged by automation."

	# Post comment and update labels
	gh issue comment "$issue_number" --repo "$slug" --body "$comment_body" >/dev/null 2>&1
	gh issue edit "$issue_number" --repo "$slug" \
		--remove-label "needs-maintainer-review" \
		--add-label "auto-dispatch" >/dev/null 2>&1 || true

	_print_ok "Issue #$issue_number approved and signed"
	_print_info "Labels updated: removed needs-maintainer-review, added auto-dispatch"
	echo ""
	return 0
}

# ── Approve PR ───────────────────────────────────────────────────────────────

cmd_pr_approved() {
	local pr_number="${1:-}"
	local slug="${2:-}"

	if [[ -z "$pr_number" ]]; then
		_print_error "Usage: sudo aidevops approve pr <number> [owner/repo]"
		return 1
	fi

	if [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
		_print_error "PR number must be numeric: $pr_number"
		return 1
	fi

	if [[ ! -t 0 ]]; then
		_print_error "This command requires an interactive terminal (cannot run headless)"
		return 1
	fi

	if [[ "$(id -u)" -ne 0 ]]; then
		_print_error "This command must be run with sudo"
		echo "Usage: sudo aidevops approve pr $pr_number"
		return 1
	fi

	local real_user="${SUDO_USER:-$(whoami)}"
	local real_home
	real_home=$(eval echo "~$real_user")
	local actual_key="$real_home/.aidevops/approval-keys/private/approval.key"

	if [[ ! -f "$actual_key" ]]; then
		_print_error "No approval key found. Run: sudo aidevops approve setup"
		return 1
	fi

	if [[ -z "$slug" ]]; then
		slug=$(_detect_slug)
	fi
	if [[ -z "$slug" || "$slug" != *"/"* ]]; then
		_print_error "Could not detect repo slug. Provide it: sudo aidevops approve pr $pr_number owner/repo"
		return 1
	fi

	local pr_title
	pr_title=$(gh pr view "$pr_number" --repo "$slug" --json title --jq '.title' 2>/dev/null || echo "(could not fetch title)")

	echo ""
	echo "Approving PR for merge:"
	echo "  PR:     #$pr_number"
	echo "  Repo:   $slug"
	echo "  Title:  $pr_title"
	echo ""

	printf "Type APPROVE to confirm: "
	local confirmation
	read -r confirmation
	if [[ "$confirmation" != "APPROVE" ]]; then
		_print_error "Approval cancelled"
		return 1
	fi

	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local payload="APPROVE:pr:${slug}:${pr_number}:${timestamp}"

	local sig_file
	sig_file=$(mktemp)
	trap 'rm -f "$sig_file"' EXIT

	printf '%s' "$payload" | ssh-keygen -Y sign \
		-f "$actual_key" \
		-n "$APPROVAL_NAMESPACE" \
		-q - >"$sig_file" 2>/dev/null

	if [[ ! -s "$sig_file" ]]; then
		_print_error "Signing failed"
		return 1
	fi

	local signature
	signature=$(cat "$sig_file")

	local comment_body
	comment_body="${APPROVAL_MARKER}
## Maintainer Approval (cryptographically signed)

\`\`\`
${payload}
\`\`\`

\`\`\`
${signature}
\`\`\`

This approval was signed with a root-protected SSH key. It cannot be forged by automation."

	gh pr comment "$pr_number" --repo "$slug" --body "$comment_body" >/dev/null 2>&1

	_print_ok "PR #$pr_number approved and signed"
	echo ""
	return 0
}

# ── Verify Approval ──────────────────────────────────────────────────────────

# Verify that an issue has a valid signed approval comment.
# Returns 0 if valid approval found, 1 otherwise.
# This is the function the pulse calls to check approvals.
cmd_verify() {
	local issue_number="${1:-}"
	local slug="${2:-}"

	if [[ -z "$issue_number" ]]; then
		_print_error "Usage: aidevops approve verify <number> [owner/repo]"
		return 1
	fi

	if [[ -z "$slug" ]]; then
		slug=$(_detect_slug)
	fi
	if [[ -z "$slug" || "$slug" != *"/"* ]]; then
		_print_error "Could not detect repo slug"
		return 1
	fi

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

		# Extract payload (between first ``` pair)
		local payload
		# shellcheck disable=SC2016 # $ is regex end-of-line anchor, not bash variable
		payload=$(printf '%s' "$body" | sed -n '/^```$/,/^```$/{ /^```$/d; p; }' | head -1)

		if [[ -z "$payload" ]]; then
			continue
		fi

		# Verify payload matches expected format
		if [[ ! "$payload" =~ ^APPROVE:(issue|pr):.*:[0-9]+: ]]; then
			continue
		fi

		# Extract signature (between second ``` pair)
		local signature
		signature=$(printf '%s' "$body" | awk '/^```$/{n++} n==3{print} n==4{exit}' | sed '1d')

		if [[ -z "$signature" ]]; then
			continue
		fi

		# Create temp files for verification
		local payload_file sig_file allowed_signers_file
		payload_file=$(mktemp)
		sig_file=$(mktemp)
		allowed_signers_file=$(mktemp)
		trap 'rm -f "$payload_file" "$sig_file" "$allowed_signers_file"' EXIT

		printf '%s' "$payload" >"$payload_file"
		printf '%s\n' "$signature" >"$sig_file"

		# Build allowed signers file using the approval public key
		local key_content
		key_content=$(cat "$pub_key")
		echo "approval@aidevops.sh namespaces=\"$APPROVAL_NAMESPACE\" $key_content" >"$allowed_signers_file"

		# Verify signature
		if ssh-keygen -Y verify \
			-f "$allowed_signers_file" \
			-I "approval@aidevops.sh" \
			-n "$APPROVAL_NAMESPACE" \
			-s "$sig_file" <"$payload_file" >/dev/null 2>&1; then

			# Check that the payload references the correct issue
			if printf '%s' "$payload" | grep -q ":${issue_number}:"; then
				echo "VERIFIED"
				rm -f "$payload_file" "$sig_file" "$allowed_signers_file"
				return 0
			fi
		fi

		rm -f "$payload_file" "$sig_file" "$allowed_signers_file"
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
	echo "approval-helper.sh — Cryptographic approval gate for external issues/PRs"
	echo ""
	echo "Commands (require sudo):"
	echo "  setup                      Generate root-protected approval key pair"
	echo "  issue <number> [slug]      Approve an issue for development"
	echo "  pr <number> [slug]         Approve a PR for merge"
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
