#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# secret-hygiene-helper.sh — Scan for plaintext secrets and supply chain IoCs
#
# Scans common locations where credentials are stored in plaintext on macOS/Linux,
# checks for Python supply chain attack indicators (.pth files), and reports
# findings with remediation guidance.
#
# CRITICAL: This script NEVER reads, prints, or exposes secret VALUES.
#           It only reports file existence, permissions, and key NAMES.
#           All remediation commands must be run in a SEPARATE TERMINAL,
#           never inside an AI chat session.
#
# Usage:
#   secret-hygiene-helper.sh scan           # Full scan, text output
#   secret-hygiene-helper.sh scan-secrets   # Plaintext secret locations only
#   secret-hygiene-helper.sh scan-pth       # Python .pth file audit only
#   secret-hygiene-helper.sh scan-deps      # Unpinned dependency check only
#   secret-hygiene-helper.sh startup-check  # One-line summary for greeting
#   secret-hygiene-helper.sh dismiss <id>   # Dismiss an advisory
#   secret-hygiene-helper.sh help           # Show usage
#
# Exit codes:
#   0 — No findings
#   1 — Findings detected (action needed)
#   2 — Error
#
# Related: security-posture-helper.sh (user-level security config)
#          security-audit-sweep.sh (per-repo security audit)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
readonly SCRIPT_DIR
readonly ADVISORIES_DIR="$HOME/.aidevops/advisories"
readonly DISMISSED_FILE="$ADVISORIES_DIR/dismissed.txt"
readonly VERSION="1.0.0"

# Colours — sourced from shared-constants.sh (Pattern A)
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"
# BOLD not in shared-constants.sh — Pattern B fallback
[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'

# Counters
FINDINGS_HIGH=0
FINDINGS_MEDIUM=0
FINDINGS_LOW=0
FINDINGS_TOTAL=0

# ============================================================
# ADVISORY MANAGEMENT
# ============================================================

ensure_advisories_dir() {
	mkdir -p "$ADVISORIES_DIR"
	[[ -f "$DISMISSED_FILE" ]] || touch "$DISMISSED_FILE"
	return 0
}

is_dismissed() {
	local advisory_id="$1"
	ensure_advisories_dir
	grep -qxF "$advisory_id" "$DISMISSED_FILE" 2>/dev/null
}

dismiss_advisory() {
	local advisory_id="$1"
	ensure_advisories_dir
	if is_dismissed "$advisory_id"; then
		echo "Advisory '$advisory_id' already dismissed."
		return 0
	fi
	echo "$advisory_id" >>"$DISMISSED_FILE"
	echo "Advisory '$advisory_id' dismissed."
	return 0
}

# ============================================================
# PLAINTEXT SECRET SCANNING
# ============================================================

report_finding() {
	local severity="$1"
	local location="$2"
	local description="$3"
	local remediation="$4"

	case "$severity" in
	high) FINDINGS_HIGH=$((FINDINGS_HIGH + 1)) ;;
	medium) FINDINGS_MEDIUM=$((FINDINGS_MEDIUM + 1)) ;;
	low) FINDINGS_LOW=$((FINDINGS_LOW + 1)) ;;
	esac
	FINDINGS_TOTAL=$((FINDINGS_TOTAL + 1))

	local color="$NC"
	# Bash 3.2 compat: no ${var^^} — use tr for uppercase
	local severity_upper
	severity_upper=$(printf '%s' "$severity" | tr '[:lower:]' '[:upper:]')
	case "$severity" in
	high) color="$RED" ;;
	medium) color="$YELLOW" ;;
	low) color="$BLUE" ;;
	esac

	echo -e "  ${color}[${severity_upper}]${NC} ${BOLD}${location}${NC}"
	echo -e "    ${description}"
	echo -e "    Fix (run in separate terminal): ${remediation}"
	echo ""
	return 0
}

get_perms() {
	local file="$1"
	if [[ "$(uname)" == "Darwin" ]]; then
		stat -f %Lp "$file" 2>/dev/null || echo "000"
	else
		stat -c %a "$file" 2>/dev/null || echo "000"
	fi
}

# Scan aidevops credentials.sh (check 1)
_scan_aidevops_creds() {
	local creds="$HOME/.config/aidevops/credentials.sh"
	[[ -f "$creds" ]] || return 0
	local perms
	perms=$(get_perms "$creds")
	if [[ "$perms" != "600" ]]; then
		report_finding "high" "$creds" \
			"Plaintext credentials with insecure permissions ($perms)" \
			"chmod 600 $creds && migrate to gopass: aidevops secret init"
	else
		report_finding "medium" "$creds" \
			"Plaintext credentials file (600 perms — OK but still plaintext on disk)" \
			"Migrate to gopass: aidevops secret init"
	fi
	return 0
}

# Scan cloud provider credentials: AWS, GCP, Azure (checks 2–4)
_scan_cloud_credentials() {
	# AWS credentials
	local aws_creds="$HOME/.aws/credentials"
	if [[ -f "$aws_creds" ]]; then
		local perms
		perms=$(get_perms "$aws_creds")
		local key_count
		key_count=$(grep -c "aws_access_key_id\|aws_secret_access_key\|aws_session_token" "$aws_creds" 2>/dev/null) || key_count=0
		report_finding "high" "$aws_creds" \
			"AWS credentials in plaintext ($key_count key entries, perms: $perms)" \
			"Use IAM Identity Center or SSO instead of long-lived keys"
	fi

	# GCP application default credentials
	local gcp_creds="$HOME/.config/gcloud/application_default_credentials.json"
	if [[ -f "$gcp_creds" ]]; then
		report_finding "high" "$gcp_creds" \
			"GCP application default credentials in plaintext" \
			"gcloud auth application-default revoke && gcloud auth application-default login"
	fi

	# Azure tokens
	local azure_tokens="$HOME/.azure/accessTokens.json"
	if [[ -f "$azure_tokens" ]]; then
		report_finding "high" "$azure_tokens" \
			"Azure access tokens in plaintext" \
			"az account clear && az login"
	fi
	return 0
}

# Scan infrastructure credentials: Kubernetes, Docker (checks 5–6)
_scan_infra_credentials() {
	# Kubernetes config
	local kube_config="$HOME/.kube/config"
	if [[ -f "$kube_config" ]]; then
		local perms
		perms=$(get_perms "$kube_config")
		local has_tokens
		has_tokens=$(grep -c "token:\|password:\|client-certificate-data:\|client-key-data:" "$kube_config" 2>/dev/null) || has_tokens=0
		if [[ "$has_tokens" -gt 0 ]]; then
			report_finding "high" "$kube_config" \
				"Kubernetes config with $has_tokens embedded credential entries (perms: $perms)" \
				"Use exec-based auth plugins or rotate tokens"
		fi
	fi

	# Docker config (may contain registry auth)
	local docker_config="$HOME/.docker/config.json"
	if [[ -f "$docker_config" ]]; then
		local has_auth=0
		has_auth=$(grep -c '"auth"' "$docker_config" 2>/dev/null) || has_auth=0
		if [[ "$has_auth" -gt 0 ]]; then
			local perms
			perms=$(get_perms "$docker_config")
			report_finding "medium" "$docker_config" \
				"Docker config with $has_auth registry auth entries (perms: $perms)" \
				"docker logout && docker login (uses credential helper)"
		fi
	fi
	return 0
}

# Scan developer tool credentials: NPM, PyPI, Netrc, GitHub CLI (checks 7–10)
_scan_dev_credentials() {
	# NPM token
	local npmrc="$HOME/.npmrc"
	if [[ -f "$npmrc" ]]; then
		local has_token
		has_token=$(grep -c "_authToken\|_auth\|//registry" "$npmrc" 2>/dev/null) || has_token=0
		if [[ "$has_token" -gt 0 ]]; then
			report_finding "medium" "$npmrc" \
				"NPM config with $has_token auth token entries" \
				"npm token revoke <token> && npm login"
		fi
	fi

	# PyPI credentials (this is how litellm maintainer was compromised)
	local pypirc="$HOME/.pypirc"
	if [[ -f "$pypirc" ]]; then
		report_finding "high" "$pypirc" \
			"PyPI credentials in plaintext (PyPI account compromise was the LiteLLM attack vector)" \
			"rm ~/.pypirc && use trusted publishers or API tokens with limited scope"
	fi

	# Netrc
	local netrc="$HOME/.netrc"
	if [[ -f "$netrc" ]]; then
		local perms
		perms=$(get_perms "$netrc")
		local entry_count
		entry_count=$(grep -c "^machine\|^login\|^password" "$netrc" 2>/dev/null) || entry_count=0
		report_finding "medium" "$netrc" \
			"Netrc with $entry_count entries (perms: $perms)" \
			"Review and remove unused entries; chmod 600 ~/.netrc"
	fi

	# GitHub CLI hosts
	local gh_hosts="$HOME/.config/gh/hosts.yml"
	if [[ -f "$gh_hosts" ]]; then
		local perms
		perms=$(get_perms "$gh_hosts")
		if [[ "$perms" != "600" ]]; then
			report_finding "medium" "$gh_hosts" \
				"GitHub CLI token file with insecure permissions ($perms)" \
				"chmod 600 $gh_hosts"
		fi
	fi
	return 0
}

# Scan SSH keys, .env files, and Stripe CLI config (checks 11–13)
_scan_ssh_and_env() {
	# SSH keys without passphrase
	local ssh_dir="$HOME/.ssh"
	if [[ -d "$ssh_dir" ]]; then
		local unprotected=0
		for key in "$ssh_dir"/id_*; do
			[[ -f "$key" ]] || continue
			[[ "$key" == *.pub ]] && continue
			# Check if key has a passphrase — ssh-keygen -y -P "" succeeds only
			# if the key has no passphrase. The if guards against set -e.
			if ssh-keygen -y -f "$key" -P "" >/dev/null 2>&1; then
				unprotected=$((unprotected + 1))
			fi
		done
		if [[ "$unprotected" -gt 0 ]]; then
			report_finding "high" "$ssh_dir/id_*" \
				"$unprotected SSH private key(s) without passphrase protection" \
				"ssh-keygen -p -f <key_file> (adds passphrase to existing key)"
		fi
	fi

	# .env files in Git repos
	local env_count=0
	if command -v fd &>/dev/null; then
		env_count=$(fd -g ".env" "$HOME/Git/" --max-depth 3 --type f 2>/dev/null | wc -l | tr -d ' ') || env_count=0
	fi
	if [[ "${env_count:-0}" -gt 0 ]]; then
		report_finding "medium" "$HOME/Git/**/.env" \
			"$env_count .env file(s) found in Git project directories" \
			"Ensure .env is in .gitignore; migrate secrets to gopass: aidevops secret set NAME"
	fi

	# Stripe CLI config
	local stripe_config="$HOME/.config/stripe"
	if [[ -d "$stripe_config" ]]; then
		report_finding "medium" "$stripe_config" \
			"Stripe CLI config directory (may contain API keys)" \
			"stripe login (refreshes token via browser)"
	fi
	return 0
}

scan_plaintext_secrets() {
	echo -e "${BOLD}Plaintext Secret Locations${NC}"
	echo "=========================="
	echo ""
	echo "WARNING: Never paste secret values into AI chat sessions."
	echo "Run all remediation commands in a SEPARATE TERMINAL."
	echo ""

	_scan_aidevops_creds
	_scan_cloud_credentials
	_scan_infra_credentials
	_scan_dev_credentials
	_scan_ssh_and_env

	return 0
}

# ============================================================
# PYTHON .PTH FILE AUDIT (supply chain IoC detection)
# ============================================================

scan_pth_files() {
	echo -e "${BOLD}Python .pth File Audit${NC}"
	echo "======================"
	echo ""
	echo "(.pth files execute on EVERY Python startup — primary supply chain attack vector)"
	echo ""

	local found_suspicious=0

	# Find all Python site-packages directories
	for py in /opt/homebrew/opt/python@*/bin/python3.* /usr/local/bin/python3.*; do
		[[ -x "$py" ]] || continue
		local sp
		sp=$("$py" -c "import site; print(site.getsitepackages()[0])" 2>/dev/null) || continue
		[[ -d "$sp" ]] || continue

		for pth in "$sp"/*.pth; do
			[[ -f "$pth" ]] || continue
			local basename_pth
			basename_pth=$(basename "$pth")

			# Known-safe .pth files
			case "$basename_pth" in
			distutils-precedence.pth | easy-install.pth | setuptools.pth | pip.pth)
				continue
				;;
			esac

			# Specific IoC: litellm_init.pth
			if [[ "$basename_pth" == "litellm_init.pth" ]]; then
				report_finding "high" "$pth" \
					"KNOWN MALWARE: litellm_init.pth (LiteLLM supply chain attack IoC)" \
					"IMMEDIATELY: rm '$pth' && rotate ALL credentials on this machine"
				found_suspicious=1
				continue
			fi

			# Check for suspicious content (NEVER print the actual content)
			if grep -qE "subprocess|exec\(|base64|urllib|requests\.|socket\.|http" "$pth" 2>/dev/null; then
				report_finding "high" "$pth" \
					"Suspicious .pth file with code execution patterns" \
					"Investigate: review the file content manually in your terminal"
				found_suspicious=1
			else
				report_finding "low" "$pth" \
					"Non-standard .pth file (review recommended)" \
					"Check if this file is expected for your Python environment"
			fi
		done
	done

	# Check uv/pipx caches for compromised versions
	for cache_dir in "$HOME/.cache/uv" "$HOME/.local/share/uv" "$HOME/Library/Caches/uv"; do
		[[ -d "$cache_dir" ]] || continue
		local malicious_versions
		malicious_versions=$(find "$cache_dir" -path "*litellm*1.82.7*" -o -path "*litellm*1.82.8*" 2>/dev/null | head -5)
		if [[ -n "$malicious_versions" ]]; then
			report_finding "high" "$cache_dir" \
				"Compromised LiteLLM version (1.82.7 or 1.82.8) found in uv cache" \
				"IMMEDIATELY: uv cache clean && rotate ALL credentials"
		fi
	done

	# Check for malicious domain references
	if grep -rq "models.litellm.cloud" /etc/hosts "$HOME/.zshrc" "$HOME/.bashrc" 2>/dev/null; then
		report_finding "high" "DNS/config" \
			"Reference to malicious domain models.litellm.cloud found" \
			"Investigate immediately — this machine may be compromised"
	fi

	if [[ "$found_suspicious" -eq 0 && "$FINDINGS_HIGH" -eq 0 ]]; then
		echo -e "  ${GREEN}[OK]${NC} No suspicious .pth files found"
		echo ""
	fi

	return 0
}

# ============================================================
# UNPINNED DEPENDENCY CHECK
# ============================================================

scan_unpinned_deps() {
	echo -e "${BOLD}Dependency Pinning Check${NC}"
	echo "========================"
	echo ""

	local repo_root
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

	if [[ -z "$repo_root" ]]; then
		echo "  Not in a git repository — skipping dependency check"
		echo ""
		return 0
	fi

	# Check requirements.txt for unpinned deps
	local req_file="$repo_root/requirements.txt"
	if [[ -f "$req_file" ]]; then
		local unpinned=0
		while IFS= read -r line; do
			[[ "$line" =~ ^[[:space:]]*# ]] && continue
			[[ -z "$line" ]] && continue
			if echo "$line" | grep -qE '>=' && ! echo "$line" | grep -qE '=='; then
				unpinned=$((unpinned + 1))
			fi
		done <"$req_file"

		if [[ "$unpinned" -gt 0 ]]; then
			report_finding "high" "$req_file" \
				"$unpinned dependencies with unpinned upper bounds (>=)" \
				"Pin to exact versions (==) to prevent supply chain attacks"
		else
			echo -e "  ${GREEN}[OK]${NC} All Python dependencies pinned to exact versions"
		fi
	fi

	# Check package.json for unpinned deps
	local pkg_file="$repo_root/package.json"
	if [[ -f "$pkg_file" ]] && command -v jq &>/dev/null; then
		local unpinned_npm=0
		unpinned_npm=$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | to_entries[] | select(.value | test("^[\\^~]")) | .key' "$pkg_file" 2>/dev/null | wc -l | tr -d ' ')
		if [[ "${unpinned_npm:-0}" -gt 0 ]]; then
			report_finding "medium" "$pkg_file" \
				"$unpinned_npm npm dependencies with ^ or ~ version ranges" \
				"Consider pinning exact versions or using npm shrinkwrap / package-lock.json"
		fi
	fi

	echo ""
	return 0
}

# ============================================================
# MCP SERVER DEPENDENCY AUDIT
# ============================================================

scan_mcp_configs() {
	echo -e "${BOLD}MCP Server Dependency Audit${NC}"
	echo "==========================="
	echo ""

	local found_risk=0

	# Build config list from registry (t1665.5), fallback to hardcoded
	local -a _sh_configs=()
	if type rt_detect_configured &>/dev/null; then
		local _sh_rt_id _sh_cfg
		while IFS= read -r _sh_rt_id; do
			_sh_cfg=$(rt_config_path "$_sh_rt_id") || continue
			[[ -n "$_sh_cfg" && -f "$_sh_cfg" ]] && _sh_configs+=("$_sh_cfg")
		done < <(rt_detect_configured)
	fi
	# Fallback if registry not loaded or no configs found
	if [[ ${#_sh_configs[@]} -eq 0 ]]; then
		[[ -f "$HOME/.config/Claude/claude_desktop_config.json" ]] && _sh_configs+=("$HOME/.config/Claude/claude_desktop_config.json")
		[[ -f "$HOME/.cursor/mcp.json" ]] && _sh_configs+=("$HOME/.cursor/mcp.json")
	fi
	for config in "${_sh_configs[@]}"; do
		[[ -f "$config" ]] || continue

		local uvx_count=0 npx_count=0
		uvx_count=$(grep -c '"uvx"' "$config" 2>/dev/null) || uvx_count=0
		npx_count=$(grep -c '"npx"' "$config" 2>/dev/null) || npx_count=0

		if [[ "${uvx_count:-0}" -gt 0 ]]; then
			report_finding "medium" "$config" \
				"$uvx_count MCP server(s) using uvx (auto-downloads latest Python packages)" \
				"Pin versions in MCP config or switch to local installs"
			found_risk=1
		fi

		if [[ "${npx_count:-0}" -gt 0 ]]; then
			report_finding "low" "$config" \
				"$npx_count MCP server(s) using npx (auto-downloads latest npm packages)" \
				"Pin versions or use locally installed packages"
			found_risk=1
		fi
	done

	if [[ "$found_risk" -eq 0 ]]; then
		echo -e "  ${GREEN}[OK]${NC} No auto-downloading MCP server configurations found"
	fi

	echo ""
	return 0
}

# ============================================================
# REMOTE URL CREDENTIAL AUDIT (t2458)
# ============================================================
#
# Walks repos.json and checks each repo's git remote for embedded credentials
# in the URL (e.g., https://gho_…@github.com/owner/repo.git).
#
# NEVER prints the URL itself — only the repo slug/path and the remediation.
# On findings, writes an advisory file so the next greeting surfaces the
# problem in case the user dismissed the immediate output.

scan_remote_urls() {
	echo -e "${BOLD}Git Remote URL Credential Audit${NC}"
	echo "==============================="
	echo ""

	local repos_json="$HOME/.config/aidevops/repos.json"
	if [[ ! -f "$repos_json" ]]; then
		echo -e "  ${BLUE}[SKIP]${NC} $repos_json not found"
		echo ""
		return 0
	fi

	if ! command -v jq >/dev/null 2>&1; then
		echo -e "  ${YELLOW}[SKIP]${NC} jq not installed — cannot parse repos.json"
		echo ""
		return 0
	fi

	local found=0
	local dirty_slugs=()
	local path slug url
	# Iterate paths from repos.json. `local_only: true` entries have no remote
	# by design, so we skip them up front.
	while IFS=$'\t' read -r path slug; do
		[[ -z "$path" ]] && continue
		# Expand ~
		path="${path/#~/$HOME}"
		[[ -d "$path/.git" || -f "$path/.git" ]] || continue

		url=$(git -C "$path" remote get-url origin 2>/dev/null || echo "")
		[[ -z "$url" ]] && continue

		# Match credential authority component: scheme://<user>:<pass>@host
		# or scheme://<token>@host. git@host:… SSH form is NOT a credential.
		if [[ "$url" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://[^@/]+@ ]]; then
			found=$((found + 1))
			dirty_slugs+=("$slug")
			local label="${slug:-$path}"
			report_finding "high" "$label" \
				"Git remote URL contains embedded credentials — leaks on every echo of \$(git remote get-url origin)" \
				"git -C ${path/#$HOME/~} remote set-url origin <clean-url>"
		fi
	done < <(jq -r '.initialized_repos[]? | select(.local_only != true)
		| [(.path // ""), (.slug // "")] | @tsv' "$repos_json" 2>/dev/null)

	if [[ "$found" -eq 0 ]]; then
		echo -e "  ${GREEN}[OK]${NC} No git remotes with embedded credentials found"
	else
		# Also write an advisory so the next greeting surfaces it.
		ensure_advisories_dir
		local advisory_id
		advisory_id="remote-credentials-$(date +%Y-%m-%d)"
		local advisory_path="$ADVISORIES_DIR/${advisory_id}.advisory"
		{
			printf '[HIGH] Git remote URLs contain embedded credentials\n'
			printf '  %d repo(s) affected:\n' "$found"
			printf '    %s\n' "${dirty_slugs[@]}"
			printf '\n  Each git remote get-url echo in your helpers leaks the token.\n'
			printf '  Fix (run in SEPARATE terminal, one per repo):\n'
			printf '    git -C <repo-path> remote set-url origin <clean-url>\n'
			printf '\n  Use SSH (git@github.com:owner/repo.git) or HTTPS without a token\n'
			printf '  and authenticate via gh CLI / SSH agent instead.\n'
		} >"$advisory_path"
	fi

	echo ""
	return 0
}

# ============================================================
# STARTUP CHECK (one-line for greeting)
# ============================================================

cmd_startup_check() {
	local findings=0

	# Quick .pth check (most critical — active malware indicator)
	for py in /opt/homebrew/opt/python@*/bin/python3.* /usr/local/bin/python3.*; do
		[[ -x "$py" ]] || continue
		local sp
		sp=$("$py" -c "import site; print(site.getsitepackages()[0])" 2>/dev/null) || continue
		[[ -d "$sp" ]] || continue
		if [[ -f "$sp/litellm_init.pth" ]]; then
			echo "CRITICAL: LiteLLM supply chain malware detected! Run in your terminal: aidevops security"
			return 1
		fi
		for pth in "$sp"/*.pth; do
			[[ -f "$pth" ]] || continue
			local bn
			bn=$(basename "$pth")
			case "$bn" in
			distutils-precedence.pth | easy-install.pth | setuptools.pth | pip.pth) continue ;;
			esac
			if grep -qE "subprocess|exec\(|base64" "$pth" 2>/dev/null; then
				findings=$((findings + 1))
			fi
		done
	done

	# Quick plaintext secret check (count locations, not values)
	local plaintext_count=0
	[[ -f "$HOME/.aws/credentials" ]] && plaintext_count=$((plaintext_count + 1))
	[[ -f "$HOME/.pypirc" ]] && plaintext_count=$((plaintext_count + 1))
	[[ -f "$HOME/.config/gcloud/application_default_credentials.json" ]] && plaintext_count=$((plaintext_count + 1))
	[[ -f "$HOME/.azure/accessTokens.json" ]] && plaintext_count=$((plaintext_count + 1))

	if [[ "$findings" -gt 0 ]]; then
		echo "WARNING: $findings suspicious .pth file(s) found. Run in your terminal: aidevops security"
		return 1
	fi

	if [[ "$plaintext_count" -gt 0 ]]; then
		echo "Secret hygiene: $plaintext_count high-risk plaintext credential location(s). Run in your terminal: aidevops security"
		return 1
	fi

	# All clear — no output (keeps greeting clean)
	return 0
}

# ============================================================
# FULL SCAN
# ============================================================

cmd_scan() {
	echo -e "${BOLD}${BLUE}Secret Hygiene & Supply Chain Scan${NC}"
	echo "==================================="
	echo ""
	echo "WARNING: Never paste secret values into AI chat sessions."
	echo "Run ALL remediation commands in a SEPARATE TERMINAL."
	echo ""

	scan_plaintext_secrets
	scan_pth_files
	scan_unpinned_deps
	scan_mcp_configs
	scan_remote_urls

	# Show active advisories
	local has_advisories=0
	ensure_advisories_dir
	for advisory in "$ADVISORIES_DIR"/*.advisory; do
		[[ -f "$advisory" ]] || continue
		local advisory_id
		advisory_id=$(basename "$advisory" .advisory)
		if is_dismissed "$advisory_id"; then
			continue
		fi
		if [[ "$has_advisories" -eq 0 ]]; then
			echo -e "${BOLD}${RED}Active Security Advisories${NC}"
			echo "=========================="
			echo ""
			has_advisories=1
		fi
		cat "$advisory"
		echo ""
		echo -e "  Dismiss after taking action: aidevops security dismiss $advisory_id"
		echo ""
	done

	# Summary
	echo -e "${BOLD}Summary${NC}"
	echo "======="
	if [[ "$FINDINGS_TOTAL" -eq 0 ]]; then
		echo -e "  ${GREEN}All clear — no findings.${NC}"
	else
		[[ "$FINDINGS_HIGH" -gt 0 ]] && echo -e "  ${RED}High: $FINDINGS_HIGH${NC}"
		[[ "$FINDINGS_MEDIUM" -gt 0 ]] && echo -e "  ${YELLOW}Medium: $FINDINGS_MEDIUM${NC}"
		[[ "$FINDINGS_LOW" -gt 0 ]] && echo -e "  ${BLUE}Low: $FINDINGS_LOW${NC}"
		echo ""
		echo "Run remediation commands in a SEPARATE TERMINAL — not in AI chat."
		echo "After rotating credentials, dismiss advisories:"
		echo "  aidevops security dismiss <advisory-id>"
	fi

	if [[ "$FINDINGS_TOTAL" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# ============================================================
# HELP
# ============================================================

print_usage() {
	cat <<'EOF'
Usage: aidevops security [command]

Secret hygiene scanner and supply chain IoC detector.
NEVER exposes secret values — only reports locations and key names.
Run ALL remediation commands in a SEPARATE TERMINAL, not in AI chat.

Commands:
  aidevops security              Full scan (posture + secrets + supply chain)
  aidevops security scan         Secret hygiene & supply chain scan
  aidevops security scan-pth     Python .pth file audit only (supply chain IoC)
  aidevops security scan-secrets Plaintext secret locations only
  aidevops security scan-deps    Unpinned dependency check only
  aidevops security scan-remotes Git remote URL credential audit (t2458)
  aidevops security posture      Interactive security posture setup
  aidevops security dismiss <id> Dismiss a security advisory after taking action

Advisory System:
  Advisories are delivered via aidevops updates as files in:
    ~/.aidevops/advisories/<id>.advisory

  They appear in the session greeting until dismissed.
  Dismiss after taking action: aidevops security dismiss <id>

Examples:
  aidevops security                        # Full scan (recommended)
  aidevops security scan-pth               # Check for .pth malware
  aidevops security dismiss litellm-2026-03  # Dismiss after rotating creds
EOF
	return 0
}

# ============================================================
# MAIN
# ============================================================

main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	scan)
		cmd_scan "$@"
		;;
	scan-secrets)
		scan_plaintext_secrets "$@"
		;;
	scan-pth)
		scan_pth_files "$@"
		;;
	scan-deps)
		scan_unpinned_deps "$@"
		;;
	scan-remotes)
		scan_remote_urls "$@"
		;;
	startup-check)
		cmd_startup_check "$@"
		;;
	dismiss)
		local advisory_id="${1:-}"
		if [[ -z "$advisory_id" ]]; then
			echo "Usage: $(basename "$0") dismiss <advisory-id>"
			return 2
		fi
		dismiss_advisory "$advisory_id"
		;;
	help | --help | -h)
		print_usage
		;;
	*)
		echo "Unknown command: $cmd"
		print_usage
		return 2
		;;
	esac
}

main "$@"
