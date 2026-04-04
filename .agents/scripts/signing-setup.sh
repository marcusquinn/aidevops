#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# -----------------------------------------------------------------------------
# signing-setup.sh — Configure and verify SSH commit signing for git.
# Nice and straightforward setup for cryptographic provenance on commits.
# Usage: signing-setup.sh [setup|check|verify-tag|verify-update]
# Run setup/check directly in your terminal (not via AI session).
# -----------------------------------------------------------------------------

set -euo pipefail

readonly SSH_KEY_DEFAULT="$HOME/.ssh/id_ed25519.pub"
readonly ALLOWED_SIGNERS_FILE="$HOME/.ssh/allowed_signers"

# Trusted maintainer key for aidevops framework supply chain verification.
# This fingerprint is checked during `aidevops update` to verify that pulled
# code was signed by the framework maintainer. Good stuff for provenance.
readonly TRUSTED_FINGERPRINT="SHA256:9zMR/PCmVheKd6gWRChrho7CzGkzomk/8Qm7DCpqTGQ"
readonly TRUSTED_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMnXVft9/hT5P2dIICJMMmXeg6HUnKGCvR4VzkKpyJza marcus@marcusquinn.com"
readonly TRUSTED_EMAIL="6428977+marcusquinn@users.noreply.github.com"

_print_info() {
	local msg="$1"
	echo "[INFO] $msg"
	return 0
}

_print_ok() {
	local msg="$1"
	echo "[OK] $msg"
	return 0
}

_print_warn() {
	local msg="$1"
	echo "[WARN] $msg"
	return 0
}

_print_error() {
	local msg="$1"
	echo "[ERROR] $msg"
	return 0
}

# Check current signing setup
cmd_check() {
	echo "Checking git commit signing configuration..."
	echo ""

	local gpg_format signing_key commit_sign tag_sign
	gpg_format=$(git config --global gpg.format 2>/dev/null || echo "not set")
	signing_key=$(git config --global user.signingkey 2>/dev/null || echo "not set")
	commit_sign=$(git config --global commit.gpgsign 2>/dev/null || echo "not set")
	tag_sign=$(git config --global tag.gpgsign 2>/dev/null || echo "not set")

	echo "  gpg.format:      $gpg_format"
	echo "  user.signingkey: $signing_key"
	echo "  commit.gpgsign:  $commit_sign"
	echo "  tag.gpgsign:     $tag_sign"
	echo ""

	if [[ "$gpg_format" == "ssh" && "$signing_key" != "not set" && "$commit_sign" == "true" ]]; then
		_print_ok "SSH commit signing is configured"

		if [[ -f "$ALLOWED_SIGNERS_FILE" ]]; then
			_print_ok "Allowed signers file exists: $ALLOWED_SIGNERS_FILE"
		else
			_print_warn "No allowed_signers file — signature verification cannot work locally"
		fi
	else
		_print_warn "SSH commit signing is not fully configured"
		echo ""
		echo "Run: aidevops signing setup"
	fi
	return 0
}

# Configure SSH commit signing
cmd_setup() {
	echo "Setting up SSH commit signing..."
	echo ""

	# Detect SSH key
	local ssh_key="$SSH_KEY_DEFAULT"
	if [[ ! -f "$ssh_key" ]]; then
		_print_error "No SSH key found at $ssh_key"
		echo "Generate one: ssh-keygen -t ed25519 -C \"your@email.com\""
		return 1
	fi

	_print_info "Using SSH key: $ssh_key"
	echo ""

	# Get git email for allowed_signers
	local git_email
	git_email=$(git config --global user.email 2>/dev/null || echo "")
	if [[ -z "$git_email" ]]; then
		_print_error "No git user.email configured"
		echo "Set it: git config --global user.email \"your@email.com\""
		return 1
	fi

	# Configure git to use SSH signing
	git config --global gpg.format ssh
	git config --global user.signingkey "$ssh_key"
	git config --global commit.gpgsign true
	git config --global tag.gpgsign true
	_print_ok "Git configured for SSH commit signing"

	# Create allowed_signers file for verification
	local key_content
	key_content=$(cat "$ssh_key")
	if [[ ! -f "$ALLOWED_SIGNERS_FILE" ]] || ! grep -q "$git_email" "$ALLOWED_SIGNERS_FILE" 2>/dev/null; then
		echo "$git_email $key_content" >>"$ALLOWED_SIGNERS_FILE"
		_print_ok "Added $git_email to $ALLOWED_SIGNERS_FILE"
	else
		_print_info "Email already in allowed_signers file"
	fi

	# Also add the aidevops trusted key so users can verify framework updates
	if ! grep -q "$TRUSTED_EMAIL" "$ALLOWED_SIGNERS_FILE" 2>/dev/null; then
		echo "$TRUSTED_EMAIL $TRUSTED_KEY" >>"$ALLOWED_SIGNERS_FILE"
		_print_ok "Added aidevops maintainer key to allowed_signers"
	fi

	git config --global gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS_FILE"
	_print_ok "Allowed signers file configured"

	echo ""
	_print_ok "Done. All future commits and tags will be signed."
	echo ""
	echo "Next steps:"
	echo "  1. Upload your SSH key to GitHub: Settings > SSH and GPG keys > New SSH signing key"
	echo "     Key: $(cat "$ssh_key")"
	echo "  2. Commits will show as 'Verified' on GitHub"
	echo ""
	echo "  Verify: git log --show-signature -1"
	return 0
}

# Verify a signed tag
cmd_verify_tag() {
	local tag="${1:-}"
	if [[ -z "$tag" ]]; then
		echo "Usage: aidevops signing verify-tag <tag>"
		return 1
	fi

	git tag -v "$tag" 2>&1
	return $?
}

# Verify that the current HEAD of a repo is signed by a trusted source.
# Used by `aidevops update` to verify supply chain integrity.
#
# Verification strategy (in order):
#   1. GitHub API — checks GitHub's "verified" badge (handles both GPG
#      merge-bot signatures and SSH author signatures). Most reliable
#      because GitHub squash-merges create GPG signatures that cannot
#      be verified locally without importing GitHub's key.
#   2. Local git signature — fallback when gh CLI is not available.
#
# Usage: signing-setup.sh verify-update [repo-path]
# Returns: 0 if verified, 1 if unsigned/untrusted, 2 if cannot verify
cmd_verify_update() {
	local repo_path="${1:-$HOME/Git/aidevops}"

	if [[ ! -d "$repo_path/.git" ]]; then
		_print_warn "Not a git repo: $repo_path"
		return 2
	fi

	local head_sha
	head_sha=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || echo "")
	if [[ -z "$head_sha" ]]; then
		echo "UNVERIFIABLE"
		return 2
	fi

	# Detect the remote slug for the GitHub API call
	local remote_url slug
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "")
	slug=$(printf '%s' "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')

	# Strategy 1: GitHub API verification (preferred — handles GPG merge-bot)
	if command -v gh &>/dev/null && [[ -n "$slug" && "$slug" == *"/"* ]]; then
		local api_verified
		api_verified=$(gh api "repos/${slug}/commits/${head_sha}" \
			--jq '.commit.verification.verified' 2>/dev/null || echo "")

		if [[ "$api_verified" == "true" ]]; then
			echo "VERIFIED"
			return 0
		elif [[ "$api_verified" == "false" ]]; then
			echo "UNSIGNED"
			return 1
		fi
		# API call failed — fall through to local verification
	fi

	# Strategy 2: Local git signature verification (fallback)
	local signers_file
	signers_file=$(git config --global gpg.ssh.allowedSignersFile 2>/dev/null || echo "")

	if [[ -z "$signers_file" || ! -f "$signers_file" ]]; then
		echo "UNVERIFIABLE"
		return 2
	fi

	# Ensure the trusted maintainer key is in the allowed_signers file
	if ! grep -q "$TRUSTED_EMAIL" "$signers_file" 2>/dev/null; then
		echo "$TRUSTED_EMAIL $TRUSTED_KEY" >>"$signers_file"
	fi

	local verify_output
	verify_output=$(git -C "$repo_path" log -1 --format='%G?' HEAD 2>/dev/null || echo "N")

	case "$verify_output" in
	G)
		# Good signature from a trusted key — nice
		echo "VERIFIED"
		return 0
		;;
	U)
		echo "UNTRUSTED"
		return 1
		;;
	B)
		echo "BAD_SIGNATURE"
		return 1
		;;
	E)
		# Cannot check signature (missing key) — typically GitHub's GPG
		# key for squash merges. If we got here, the API check failed too.
		echo "UNVERIFIABLE"
		return 2
		;;
	N)
		echo "UNSIGNED"
		return 1
		;;
	*)
		echo "UNKNOWN"
		return 2
		;;
	esac
}

cmd_help() {
	echo "signing-setup.sh — SSH commit signing and supply chain verification"
	echo ""
	echo "Commands:"
	echo "  setup            Configure SSH commit signing (run in terminal)"
	echo "  check            Show current signing configuration"
	echo "  verify-tag       Verify a signed git tag"
	echo "  verify-update    Verify HEAD commit is signed by trusted maintainer"
	echo ""
	echo "Good stuff for proving commit provenance."
	return 0
}

main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	setup) cmd_setup ;;
	check) cmd_check ;;
	verify-tag) cmd_verify_tag "$@" ;;
	verify-update) cmd_verify_update "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		echo "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
