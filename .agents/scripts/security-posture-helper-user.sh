#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Security Posture Helper -- User-Level Checks & Setup Sub-Library
# =============================================================================
# User-level security posture checks and interactive guided setup (t1412.6):
# prompt guard patterns, secret storage, GitHub CLI auth, SSH keys, git
# signing, and secretlint.
#
# Usage: source "${SCRIPT_DIR}/security-posture-helper-user.sh"
#
# Dependencies:
#   - shared-constants.sh (gh_token_has_workflow_scope, etc.)
#   - security-posture-helper.sh orchestrator (AGENTS_DIR, CONFIG_DIR,
#     CREDENTIALS_FILE, colour variables)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SECURITY_POSTURE_USER_LIB_LOADED:-}" ]] && return 0
_SECURITY_POSTURE_USER_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# ============================================================
# USER-LEVEL STARTUP CHECKS (t1412.6)
# ============================================================
# Each check function:
#   - Prints nothing (results collected by caller)
#   - Returns 0 if OK, 1 if action needed
#   - Sets CHECK_LABEL and CHECK_FIX for the caller

# Check 1: Prompt injection patterns are up to date
check_prompt_guard_patterns() {
	local yaml_file=""
	local label="Prompt guard patterns"

	# Check deployed location
	if [[ -f "${AGENTS_DIR}/configs/prompt-injection-patterns.yaml" ]]; then
		yaml_file="${AGENTS_DIR}/configs/prompt-injection-patterns.yaml"
	fi

	if [[ -z "$yaml_file" ]]; then
		CHECK_LABEL="$label: YAML patterns file missing"
		CHECK_FIX="Run: aidevops update"
		return 1
	fi

	# Check staleness (>30 days since last confirmed refresh).
	# Three-level fallback chain (GH#20312 / Option B):
	#  1. ~/.aidevops/.deployed-sha mtime  — written after every successful deploy;
	#     measures "time since we last confirmed the install is current", not upstream
	#     release cadence. rsync -a preserves source mtime, so the yaml file mtime
	#     keeps measuring the upstream commit date, not the local refresh date.
	#  2. git log commit date from the canonical repo, if present  — measures when
	#     upstream last changed the patterns file.  Falls back to this on installs
	#     that pre-date the .deployed-sha stamp (t2156).
	#  3. Deployed file mtime  — current behaviour; preserved for alt install paths
	#     (Homebrew, .deb, airgapped tarballs) that have neither a stamp nor a repo.
	local now
	now=$(date +%s)
	local ref_epoch=0
	local ref_source="file mtime"

	# Determine stat mtime flag once — avoids repeating the "Darwin" literal
	# (ratchet gate triggers at >=3 occurrences per file; Darwin already appears
	# twice in this file in other check functions).
	local stat_flag
	if [[ "$(uname)" == "Darwin" ]]; then
		stat_flag="-f %m"
	else
		stat_flag="-c %Y"
	fi

	# Level 1: .deployed-sha stamp mtime
	local deployed_sha_file="${HOME}/.aidevops/.deployed-sha"
	if [[ -f "$deployed_sha_file" ]]; then
		local stamp_mtime
		# shellcheck disable=SC2086
		stamp_mtime=$(stat $stat_flag "$deployed_sha_file" 2>/dev/null || echo "0")
		if [[ "$stamp_mtime" -gt 0 ]]; then
			ref_epoch="$stamp_mtime"
			ref_source="deploy stamp"
		fi
	fi

	# Level 2: upstream git commit date (only if stamp was not found)
	if [[ "$ref_epoch" -eq 0 ]]; then
		local framework_repo="${AIDEVOPS_FRAMEWORK_REPO:-${HOME}/Git/aidevops}"
		if [[ -d "${framework_repo}/.git" ]]; then
			local git_epoch
			git_epoch=$(git -C "$framework_repo" log -1 --format=%ct -- \
				.agents/configs/prompt-injection-patterns.yaml 2>/dev/null || echo "0")
			if [[ "$git_epoch" -gt 0 ]]; then
				ref_epoch="$git_epoch"
				ref_source="upstream commit"
			fi
		fi
	fi

	# Level 3: deployed file mtime (fallback — preserves prior behaviour)
	if [[ "$ref_epoch" -eq 0 ]]; then
		# shellcheck disable=SC2086
		ref_epoch=$(stat $stat_flag "$yaml_file" 2>/dev/null || echo "0")
	fi

	local file_age_days=0
	if [[ "$ref_epoch" -gt 0 ]]; then
		file_age_days=$(( (now - ${ref_epoch:-0}) / 86400 ))
	fi

	if [[ "$file_age_days" -gt 30 ]]; then
		CHECK_LABEL="$label: ${file_age_days}d old (>30d, ref: ${ref_source})"
		CHECK_FIX="Run: aidevops update"
		return 1
	fi

	CHECK_LABEL="$label"
	return 0
}

# Check 2: Secret storage backend is configured
check_secret_storage() {
	local label="Secret storage"

	# Prefer gopass
	if command -v gopass &>/dev/null; then
		# Check if gopass store is initialized
		if gopass ls &>/dev/null 2>&1; then
			CHECK_LABEL="$label (gopass)"
			return 0
		fi
		CHECK_LABEL="$label: gopass installed but store not initialized"
		CHECK_FIX="Run: aidevops secret init"
		return 1
	fi

	# Fallback: credentials.sh with correct permissions
	if [[ -f "$CREDENTIALS_FILE" ]]; then
		local perms
		if [[ "$(uname)" == "Darwin" ]]; then
			perms=$(stat -f %Lp "$CREDENTIALS_FILE" || echo "000")
		else
			perms=$(stat -c %a "$CREDENTIALS_FILE" || echo "000")
		fi
		if [[ "$perms" == "600" ]]; then
			CHECK_LABEL="$label (credentials.sh, 600)"
			return 0
		fi
		CHECK_LABEL="$label: credentials.sh has insecure permissions ($perms, need 600)"
		CHECK_FIX="Run: chmod 600 $CREDENTIALS_FILE"
		return 1
	fi

	# No secret storage at all
	CHECK_LABEL="$label: no backend configured"
	CHECK_FIX="Run: aidevops secret init (gopass) or create ~/.config/aidevops/credentials.sh"
	return 1
}

# Check 3: GitHub CLI is authenticated
check_gh_auth() {
	local label="GitHub CLI auth"

	if ! command -v gh &>/dev/null; then
		CHECK_LABEL="$label: gh not installed"
		CHECK_FIX="Run: brew install gh && gh auth login -s workflow"
		return 1
	fi

	if gh auth status &>/dev/null 2>&1; then
		CHECK_LABEL="$label"
		return 0
	fi

	CHECK_LABEL="$label: not authenticated"
	CHECK_FIX="Run: gh auth login -s workflow"
	return 1
}

# Check 3b: GitHub CLI token has workflow scope (t1540)
# Without this scope, pushes/merges of PRs containing .github/workflows/
# changes fail silently. Workers complete locally but no PR is created.
check_gh_workflow_scope() {
	local label="GitHub CLI workflow scope"

	if ! command -v gh &>/dev/null; then
		CHECK_LABEL="$label: gh not installed"
		return 1
	fi

	local scope_exit=0
	gh_token_has_workflow_scope || scope_exit=$?

	if [[ "$scope_exit" -eq 0 ]]; then
		CHECK_LABEL="$label"
		return 0
	fi

	if [[ "$scope_exit" -eq 2 ]]; then
		CHECK_LABEL="$label: unable to check (gh auth failed)"
		return 1
	fi

	CHECK_LABEL="$label: missing (CI workflow PRs will fail)"
	CHECK_FIX="Run: gh auth refresh -s workflow"
	return 1
}

# Check 4: SSH key exists
check_ssh_key() {
	local label="SSH key"

	if [[ -f "$HOME/.ssh/id_ed25519" ]] || [[ -f "$HOME/.ssh/id_rsa" ]]; then
		CHECK_LABEL="$label"
		return 0
	fi

	CHECK_LABEL="$label: no SSH key found"
	CHECK_FIX="Run: ssh-keygen -t ed25519"
	return 1
}

# Check 5: Git commit signing (optional — informational only)
check_git_signing() {
	local label="Git commit signing"

	local signing_key
	signing_key=$(git config --global user.signingkey || echo "")
	local gpg_sign
	gpg_sign=$(git config --global commit.gpgsign || echo "false")

	if [[ -n "$signing_key" && "$gpg_sign" == "true" ]]; then
		CHECK_LABEL="$label"
		return 0
	fi

	# Optional — don't count as a required action
	CHECK_LABEL="$label: not configured (optional)"
	CHECK_FIX="See: https://docs.github.com/en/authentication/managing-commit-signature-verification"
	return 0
}

# Check 6: Secretlint available for pre-commit scanning
check_secretlint() {
	local label="Secret scanning (secretlint)"

	if command -v secretlint &>/dev/null; then
		CHECK_LABEL="$label"
		return 0
	fi

	CHECK_LABEL="$label: not installed"
	CHECK_FIX="Run: npm install -g secretlint @secretlint/secretlint-rule-preset-recommend"
	return 1
}

# ============================================================
# USER-LEVEL COMMANDS (t1412.6)
# ============================================================

# Quick startup check — outputs a single line for the greeting
cmd_startup_check() {
	local actions_needed=0
	local CHECK_LABEL="" CHECK_FIX=""

	# Run all checks, count failures
	if ! check_prompt_guard_patterns; then
		actions_needed=$((actions_needed + 1))
	fi

	if ! check_secret_storage; then
		actions_needed=$((actions_needed + 1))
	fi

	if ! check_gh_auth; then
		actions_needed=$((actions_needed + 1))
	fi

	if ! check_gh_workflow_scope; then
		actions_needed=$((actions_needed + 1))
	fi

	if ! check_ssh_key; then
		actions_needed=$((actions_needed + 1))
	fi

	check_git_signing # optional, doesn't increment counter

	if ! check_secretlint; then
		actions_needed=$((actions_needed + 1))
	fi

	if [[ "$actions_needed" -eq 0 ]]; then
		echo "Security: all protections active"
		return 0
	fi

	local plural=""
	if [[ "$actions_needed" -gt 1 ]]; then
		plural="s"
	fi
	echo "Security: ${actions_needed} action${plural} needed — run \`aidevops security setup\` for details"
	return 1
}

# Detailed status report
cmd_status() {
	echo -e "${BOLD}${CYAN}Security Posture Status${NC}"
	echo "========================"
	echo ""

	local actions_needed=0
	local CHECK_LABEL="" CHECK_FIX=""

	# Check 1: Prompt guard patterns
	if check_prompt_guard_patterns; then
		echo -e "  ${GREEN}[OK]${NC} $CHECK_LABEL"
	else
		echo -e "  ${RED}[!!]${NC} $CHECK_LABEL"
		echo -e "    Fix: $CHECK_FIX"
		actions_needed=$((actions_needed + 1))
	fi

	# Check 2: Secret storage
	if check_secret_storage; then
		echo -e "  ${GREEN}[OK]${NC} $CHECK_LABEL"
	else
		echo -e "  ${RED}[!!]${NC} $CHECK_LABEL"
		echo -e "    Fix: $CHECK_FIX"
		actions_needed=$((actions_needed + 1))
	fi

	# Check 3: GitHub CLI auth
	if check_gh_auth; then
		echo -e "  ${GREEN}[OK]${NC} $CHECK_LABEL"
	else
		echo -e "  ${RED}[!!]${NC} $CHECK_LABEL"
		echo -e "    Fix: $CHECK_FIX"
		actions_needed=$((actions_needed + 1))
	fi

	# Check 3b: GitHub CLI workflow scope (t1540)
	if check_gh_workflow_scope; then
		echo -e "  ${GREEN}[OK]${NC} $CHECK_LABEL"
	else
		echo -e "  ${YELLOW}[!!]${NC} $CHECK_LABEL"
		echo -e "    Fix: $CHECK_FIX"
		actions_needed=$((actions_needed + 1))
	fi

	# Check 4: SSH key
	if check_ssh_key; then
		echo -e "  ${GREEN}[OK]${NC} $CHECK_LABEL"
	else
		echo -e "  ${RED}[!!]${NC} $CHECK_LABEL"
		echo -e "    Fix: $CHECK_FIX"
		actions_needed=$((actions_needed + 1))
	fi

	# Check 5: Git signing (optional)
	check_git_signing
	echo -e "  ${YELLOW}[--]${NC} $CHECK_LABEL"

	# Check 6: Secretlint
	if check_secretlint; then
		echo -e "  ${GREEN}[OK]${NC} $CHECK_LABEL"
	else
		echo -e "  ${RED}[!!]${NC} $CHECK_LABEL"
		echo -e "    Fix: $CHECK_FIX"
		actions_needed=$((actions_needed + 1))
	fi

	echo ""
	if [[ "$actions_needed" -eq 0 ]]; then
		echo -e "${GREEN}All protections active.${NC}"
		return 0
	fi

	local plural=""
	[[ "$actions_needed" -gt 1 ]] && plural="s"
	echo -e "${YELLOW}${actions_needed} action${plural} needed.${NC} Run: aidevops security setup"
	return 1
}

# Interactive guided setup — step helpers
# Each helper:
#   - Runs the corresponding check
#   - If failing: prompts user and attempts remediation
#   - Increments actions_fixed or actions_skipped (caller-owned vars)
#   - Returns 0 always (errors are user-visible, not fatal)

# Setup step 1: prompt guard patterns
# Requires caller to have declared: actions_fixed, actions_skipped, CHECK_LABEL, CHECK_FIX
_setup_prompt_guard() {
	if check_prompt_guard_patterns; then
		echo -e "${GREEN}[OK]${NC} $CHECK_LABEL"
		return 0
	fi

	echo -e "${YELLOW}[1]${NC} $CHECK_LABEL"
	echo "    $CHECK_FIX"
	echo ""
	local response
	read -r -p "    Run aidevops update now? [Y/n] " response
	response="${response:-y}"
	if [[ "$response" =~ ^[Yy]$ ]]; then
		echo ""
		if command -v aidevops &>/dev/null; then
			aidevops update
		else
			bash "$HOME/Git/aidevops/setup.sh" --non-interactive
		fi
		actions_fixed=$((actions_fixed + 1))
	else
		actions_skipped=$((actions_skipped + 1))
	fi
	echo ""
	return 0
}

# Setup step 2: secret storage backend
_setup_secret_storage() {
	if check_secret_storage; then
		echo -e "${GREEN}[OK]${NC} $CHECK_LABEL"
		return 0
	fi

	echo -e "${YELLOW}[2]${NC} $CHECK_LABEL"
	echo "    $CHECK_FIX"
	echo ""

	local response
	if command -v gopass &>/dev/null; then
		read -r -p "    Initialize gopass store now? [Y/n] " response
		response="${response:-y}"
		if [[ "$response" =~ ^[Yy]$ ]]; then
			echo ""
			local secret_helper="${AGENTS_DIR}/scripts/secret-helper.sh"
			if [[ -f "$secret_helper" ]]; then
				bash "$secret_helper" init
			else
				gopass init
			fi
			actions_fixed=$((actions_fixed + 1))
		else
			actions_skipped=$((actions_skipped + 1))
		fi
	elif [[ -f "$CREDENTIALS_FILE" ]]; then
		read -r -p "    Fix permissions on credentials.sh? [Y/n] " response
		response="${response:-y}"
		if [[ "$response" =~ ^[Yy]$ ]]; then
			chmod 600 "$CREDENTIALS_FILE"
			echo -e "    ${GREEN}Fixed.${NC}"
			actions_fixed=$((actions_fixed + 1))
		else
			actions_skipped=$((actions_skipped + 1))
		fi
	else
		echo "    Options:"
		echo "      1. Install gopass (recommended): brew install gopass && aidevops secret init"
		echo "      2. Create credentials.sh: touch $CREDENTIALS_FILE && chmod 600 $CREDENTIALS_FILE"
		echo ""
		read -r -p "    Skip for now? [Y/n] " _
		actions_skipped=$((actions_skipped + 1))
	fi
	echo ""
	return 0
}

# Setup step 3: GitHub CLI authentication
_setup_gh_auth() {
	if check_gh_auth; then
		echo -e "${GREEN}[OK]${NC} $CHECK_LABEL"
		return 0
	fi

	echo -e "${YELLOW}[3]${NC} $CHECK_LABEL"
	echo "    $CHECK_FIX"
	echo ""

	local response
	if command -v gh &>/dev/null; then
		read -r -p "    Run gh auth login now? [Y/n] " response
		response="${response:-y}"
		if [[ "$response" =~ ^[Yy]$ ]]; then
			echo ""
			gh auth login -s workflow
			actions_fixed=$((actions_fixed + 1))
		else
			actions_skipped=$((actions_skipped + 1))
		fi
	else
		echo "    Install GitHub CLI first: brew install gh"
		actions_skipped=$((actions_skipped + 1))
	fi
	echo ""
	return 0
}

# Setup step 3b: GitHub CLI workflow scope (t1540)
_setup_gh_workflow_scope() {
	if check_gh_workflow_scope; then
		echo -e "${GREEN}[OK]${NC} $CHECK_LABEL"
		return 0
	fi

	echo -e "${YELLOW}[3b]${NC} $CHECK_LABEL"
	echo "    $CHECK_FIX"
	echo "    Without this scope, pushes/merges of PRs with .github/workflows/ changes fail."
	echo ""

	local response
	if command -v gh &>/dev/null; then
		read -r -p "    Run gh auth refresh -s workflow now? [Y/n] " response
		response="${response:-y}"
		if [[ "$response" =~ ^[Yy]$ ]]; then
			echo ""
			gh auth refresh -s workflow
			actions_fixed=$((actions_fixed + 1))
		else
			actions_skipped=$((actions_skipped + 1))
		fi
	else
		actions_skipped=$((actions_skipped + 1))
	fi
	echo ""
	return 0
}

# Setup step 4: SSH key
_setup_ssh_key() {
	if check_ssh_key; then
		echo -e "${GREEN}[OK]${NC} $CHECK_LABEL"
		return 0
	fi

	echo -e "${YELLOW}[4]${NC} $CHECK_LABEL"
	echo "    $CHECK_FIX"
	echo ""

	local response
	read -r -p "    Generate an Ed25519 SSH key now? [Y/n] " response
	response="${response:-y}"
	if [[ "$response" =~ ^[Yy]$ ]]; then
		echo ""
		local git_email
		git_email=$(git config --global user.email || echo "")
		ssh-keygen -t ed25519 -C "$git_email"
		actions_fixed=$((actions_fixed + 1))
		echo ""
		echo "    Add to GitHub: gh ssh-key add ~/.ssh/id_ed25519.pub"
	else
		actions_skipped=$((actions_skipped + 1))
	fi
	echo ""
	return 0
}

# Setup step 5: secretlint
_setup_secretlint() {
	if check_secretlint; then
		echo -e "${GREEN}[OK]${NC} $CHECK_LABEL"
		return 0
	fi

	echo -e "${YELLOW}[5]${NC} $CHECK_LABEL"
	echo "    $CHECK_FIX"
	echo ""

	local response
	read -r -p "    Install secretlint now? [Y/n] " response
	response="${response:-y}"
	if [[ "$response" =~ ^[Yy]$ ]]; then
		echo ""
		npm install -g secretlint @secretlint/secretlint-rule-preset-recommend
		actions_fixed=$((actions_fixed + 1))
	else
		actions_skipped=$((actions_skipped + 1))
	fi
	echo ""
	return 0
}

# Interactive guided setup — orchestrator
cmd_setup() {
	echo -e "${BOLD}${CYAN}Security Setup${NC}"
	echo "==============="
	echo ""
	echo "Walking through pending security actions."
	echo ""

	local actions_fixed=0
	local actions_skipped=0
	local CHECK_LABEL="" CHECK_FIX=""

	_setup_prompt_guard
	_setup_secret_storage
	_setup_gh_auth
	_setup_gh_workflow_scope
	_setup_ssh_key
	_setup_secretlint

	# --- Summary ---
	echo ""
	echo "======================================="
	if [[ "$actions_fixed" -gt 0 ]]; then
		echo -e "${GREEN}Fixed: ${actions_fixed} action(s)${NC}"
	fi
	if [[ "$actions_skipped" -gt 0 ]]; then
		echo -e "${YELLOW}Skipped: ${actions_skipped} action(s)${NC}"
	fi
	if [[ "$actions_fixed" -eq 0 && "$actions_skipped" -eq 0 ]]; then
		echo -e "${GREEN}All protections already active!${NC}"
	fi
	echo "======================================="

	return 0
}
