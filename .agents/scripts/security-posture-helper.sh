#!/usr/bin/env bash
# security-posture-helper.sh — Security posture assessment
#
# Two modes:
#   A. Per-repo audit (t1412.11) — scans a repository for security baseline issues
#   B. User-level startup check (t1412.6) — checks user's security configuration
#
# Per-repo audit commands:
#   security-posture-helper.sh check [repo-path]    # Run all repo checks, report findings
#   security-posture-helper.sh audit [repo-path]     # Alias for check
#   security-posture-helper.sh store [repo-path]     # Run checks and store in .aidevops.json
#   security-posture-helper.sh summary [repo-path]   # One-line summary for greeting
#
# User-level commands:
#   security-posture-helper.sh startup-check         # One-line summary for session greeting
#   security-posture-helper.sh setup                 # Interactive guided setup
#   security-posture-helper.sh status                # Detailed status report
#
#   security-posture-helper.sh help                  # Show usage
#
# Exit codes:
#   0 — All checks passed (or setup completed)
#   1 — Findings detected (non-zero issues / actions needed)
#   2 — Error (missing args, tool failure)
#
# t1412.6:  https://github.com/marcusquinn/aidevops/issues/3078
# t1412.11: https://github.com/marcusquinn/aidevops/issues/3087

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" || true

# Fallback colours if shared-constants.sh not loaded
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${CYAN+x}" ]] && CYAN='\033[0;36m'
[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# Paths
readonly AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
readonly CONFIG_DIR="$HOME/.config/aidevops"
readonly CREDENTIALS_FILE="$CONFIG_DIR/credentials.sh"

# ============================================================
# PER-REPO AUDIT (t1412.11)
# ============================================================

# Severity level constants (SonarCloud: avoid repeated string literals)
readonly SEVERITY_CRITICAL="critical"
readonly SEVERITY_WARNING="warning"
readonly SEVERITY_INFO="info"
readonly SEVERITY_PASS="pass"

# Category constants (SonarCloud: avoid repeated string literals)
readonly CAT_WORKFLOWS="workflows"
readonly CAT_BRANCH_PROTECTION="branch_protection"
readonly CAT_REVIEW_BOT_GATE="review_bot_gate"
readonly CAT_DEPENDENCIES="dependencies"
readonly CAT_COLLABORATORS="collaborators"
readonly CAT_REPO_SECURITY="repo_security"

# Counters
FINDINGS_CRITICAL=0
FINDINGS_WARNING=0
FINDINGS_INFO=0
FINDINGS_PASS=0

# Collected findings for JSON output
FINDINGS_JSON="[]"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_pass() {
	echo -e "${GREEN}[PASS]${NC} $1"
	((++FINDINGS_PASS))
}
print_warn() {
	echo -e "${YELLOW}[WARN]${NC} $1"
	((++FINDINGS_WARNING))
}
print_crit() {
	echo -e "${RED}[CRIT]${NC} $1"
	((++FINDINGS_CRITICAL))
}
print_skip() {
	echo -e "${CYAN}[SKIP]${NC} $1"
	((++FINDINGS_INFO))
}
print_header() { echo -e "\n${BOLD}${CYAN}$1${NC}"; }

# Add a finding to the JSON array
# Usage: add_finding <severity> <category> <message>
add_finding() {
	local severity="$1"
	local category="$2"
	local message="$3"

	FINDINGS_JSON=$(echo "$FINDINGS_JSON" | jq \
		--arg sev "$severity" \
		--arg cat "$category" \
		--arg msg "$message" \
		'. += [{"severity": $sev, "category": $cat, "message": $msg}]')
	return 0
}

# Resolve the GitHub slug for a repo path
# Usage: resolve_slug <repo-path>
resolve_slug() {
	local repo_path="$1"
	local remote_url
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null) || return 1
	local slug
	slug=$(echo "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')
	if [[ -n "$slug" && "$slug" == *"/"* ]]; then
		echo "$slug"
		return 0
	fi
	return 1
}

# Phase 1: Scan .github/workflows/ for unsafe AI patterns
# Checks for:
#   - shell + credentials + untrusted input (injection risk)
#   - allowed_non_write_users: "*" (overly permissive)
#   - cached long-lived tokens
check_workflow_security() {
	local repo_path="$1"
	local workflows_dir="$repo_path/.github/workflows"

	print_header "Phase 1: GitHub Actions Workflow Security"

	if [[ ! -d "$workflows_dir" ]]; then
		print_skip "No .github/workflows/ directory found"
		add_finding "$SEVERITY_INFO" "$CAT_WORKFLOWS" "No .github/workflows/ directory"
		return 0
	fi

	local workflow_files
	workflow_files=$(find "$workflows_dir" -name "*.yml" -o -name "*.yaml" 2>/dev/null)

	if [[ -z "$workflow_files" ]]; then
		print_skip "No workflow files found"
		add_finding "$SEVERITY_INFO" "$CAT_WORKFLOWS" "No workflow YAML files found"
		return 0
	fi

	local file_count
	file_count=$(echo "$workflow_files" | wc -l | tr -d ' ')
	print_info "Scanning $file_count workflow file(s)..."

	local unsafe_found=false

	while IFS= read -r wf; do
		[[ -z "$wf" ]] && continue
		local wf_name
		wf_name=$(basename "$wf")

		# Check 1: Shell commands using github.event context (injection vector)
		# Pattern: run: ... ${{ github.event.issue.title }} or similar
		if grep -qE '\$\{\{\s*github\.event\.(issue|pull_request|comment)\.' "$wf" 2>/dev/null; then
			if grep -qE '^\s*run:' "$wf" 2>/dev/null; then
				print_crit "$wf_name: Uses github.event context in shell run step (injection risk)"
				add_finding "$SEVERITY_CRITICAL" "$CAT_WORKFLOWS" "$wf_name: github.event context in shell run step"
				unsafe_found=true
			fi
		fi

		# Check 2: Overly permissive allowed_non_write_users or permissions
		if grep -qE 'allowed_non_write_users:\s*"\*"' "$wf" 2>/dev/null; then
			print_crit "$wf_name: allowed_non_write_users set to wildcard '*'"
			add_finding "$SEVERITY_CRITICAL" "$CAT_WORKFLOWS" "$wf_name: allowed_non_write_users wildcard"
			unsafe_found=true
		fi

		# Check 3: Workflow uses pull_request_target with checkout of PR head
		# This is the classic "pwn request" pattern
		if grep -qE 'pull_request_target' "$wf" 2>/dev/null; then
			if grep -qE 'ref:\s*\$\{\{\s*github\.event\.pull_request\.head\.(ref|sha)' "$wf" 2>/dev/null; then
				print_crit "$wf_name: pull_request_target with PR head checkout (pwn request risk)"
				add_finding "$SEVERITY_CRITICAL" "$CAT_WORKFLOWS" "$wf_name: pull_request_target with PR head checkout"
				unsafe_found=true
			else
				print_warn "$wf_name: Uses pull_request_target (review checkout refs carefully)"
				add_finding "$SEVERITY_WARNING" "$CAT_WORKFLOWS" "$wf_name: uses pull_request_target"
			fi
		fi

		# Check 4: Long-lived tokens cached or stored in artifacts
		if grep -qE 'actions/cache.*token|save-state.*token|GITHUB_TOKEN.*>>.*GITHUB_ENV' "$wf" 2>/dev/null; then
			print_warn "$wf_name: Possible token caching pattern detected"
			add_finding "$SEVERITY_WARNING" "$CAT_WORKFLOWS" "$wf_name: possible token caching"
		fi

		# Check 5: Overly broad permissions
		if grep -qE '^\s*permissions:\s*write-all' "$wf" 2>/dev/null; then
			print_warn "$wf_name: Uses write-all permissions (prefer least-privilege)"
			add_finding "$SEVERITY_WARNING" "$CAT_WORKFLOWS" "$wf_name: write-all permissions"
		fi

		# Check 6: Third-party actions pinned to branch instead of SHA
		local unpinned_actions
		unpinned_actions=$(grep -oE 'uses:\s+[a-zA-Z0-9_-]+/[a-zA-Z0-9_.-]+@(main|master|v[0-9]+)' "$wf" 2>/dev/null | head -5) || true
		if [[ -n "$unpinned_actions" ]]; then
			local unpinned_count
			unpinned_count=$(echo "$unpinned_actions" | wc -l | tr -d ' ')
			print_warn "$wf_name: $unpinned_count action(s) pinned to branch/tag instead of SHA"
			add_finding "$SEVERITY_WARNING" "$CAT_WORKFLOWS" "$wf_name: $unpinned_count actions not SHA-pinned"
		fi

	done <<<"$workflow_files"

	if [[ "$unsafe_found" == "false" ]]; then
		print_pass "No critical workflow security issues found"
		add_finding "$SEVERITY_PASS" "$CAT_WORKFLOWS" "No critical issues"
	fi

	return 0
}

# Phase 2: Check branch protection
check_branch_protection() {
	local repo_path="$1"

	print_header "Phase 2: Branch Protection"

	# Need gh CLI and a GitHub remote
	if ! command -v gh &>/dev/null; then
		print_skip "GitHub CLI (gh) not installed — cannot check branch protection"
		add_finding "$SEVERITY_INFO" "$CAT_BRANCH_PROTECTION" "gh CLI not available"
		return 0
	fi

	local slug
	if ! slug=$(resolve_slug "$repo_path"); then
		print_skip "No GitHub remote — branch protection check skipped"
		add_finding "$SEVERITY_INFO" "$CAT_BRANCH_PROTECTION" "No GitHub remote"
		return 0
	fi

	# Detect default branch
	local default_branch
	default_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || true
	if [[ -z "$default_branch" ]]; then
		default_branch="main"
	fi

	# Query branch protection rules via gh API
	local protection_json
	protection_json=$(gh api "repos/$slug/branches/$default_branch/protection" 2>/dev/null) || true

	if [[ -z "$protection_json" || "$protection_json" == *"Not Found"* || "$protection_json" == *"Branch not protected"* ]]; then
		print_crit "Default branch '$default_branch' has NO branch protection"
		add_finding "$SEVERITY_CRITICAL" "$CAT_BRANCH_PROTECTION" "No branch protection on $default_branch"
		return 0
	fi

	# Check: require PR reviews
	local required_reviews
	required_reviews=$(echo "$protection_json" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null) || required_reviews="0"

	if [[ "$required_reviews" -gt 0 ]]; then
		print_pass "PR reviews required ($required_reviews approving review(s))"
		add_finding "$SEVERITY_PASS" "$CAT_BRANCH_PROTECTION" "PR reviews required: $required_reviews"
	else
		print_warn "PR reviews not required on $default_branch"
		add_finding "$SEVERITY_WARNING" "$CAT_BRANCH_PROTECTION" "PR reviews not required"
	fi

	# Check: require status checks
	local required_checks
	required_checks=$(echo "$protection_json" | jq -r '.required_status_checks.contexts // [] | length' 2>/dev/null) || required_checks="0"

	if [[ "$required_checks" -gt 0 ]]; then
		print_pass "Required status checks configured ($required_checks check(s))"
		add_finding "$SEVERITY_PASS" "$CAT_BRANCH_PROTECTION" "Status checks configured: $required_checks"
	else
		print_warn "No required status checks on $default_branch"
		add_finding "$SEVERITY_WARNING" "$CAT_BRANCH_PROTECTION" "No required status checks"
	fi

	# Check: enforce for admins
	local enforce_admins
	enforce_admins=$(echo "$protection_json" | jq -r '.enforce_admins.enabled // false' 2>/dev/null) || enforce_admins="false"

	if [[ "$enforce_admins" == "true" ]]; then
		print_pass "Branch protection enforced for admins"
		add_finding "$SEVERITY_PASS" "$CAT_BRANCH_PROTECTION" "Enforced for admins"
	else
		print_info "Branch protection not enforced for admins (common for solo repos)"
		add_finding "$SEVERITY_INFO" "$CAT_BRANCH_PROTECTION" "Not enforced for admins"
	fi

	return 0
}

# Phase 3: Check review-bot-gate
check_review_bot_gate() {
	local repo_path="$1"

	print_header "Phase 3: Review Bot Gate"

	# Check if review-bot-gate workflow exists locally
	local gate_workflow="$repo_path/.github/workflows/review-bot-gate.yml"
	if [[ -f "$gate_workflow" ]]; then
		print_pass "review-bot-gate.yml workflow present"
		add_finding "$SEVERITY_PASS" "$CAT_REVIEW_BOT_GATE" "Workflow file present"
	else
		print_warn "No review-bot-gate.yml workflow — AI review bots may not be gated"
		add_finding "$SEVERITY_WARNING" "$CAT_REVIEW_BOT_GATE" "No review-bot-gate.yml workflow"
		print_info "  Suggestion: Copy from aidevops repo or add review-bot-gate as required check"
	fi

	# Check if review-bot-gate is a required status check (via branch protection)
	if ! command -v gh &>/dev/null; then
		return 0
	fi

	local slug
	if ! slug=$(resolve_slug "$repo_path"); then
		return 0
	fi

	local default_branch
	default_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || true
	default_branch="${default_branch:-main}"

	local check_contexts
	check_contexts=$(gh api "repos/$slug/branches/$default_branch/protection/required_status_checks" 2>/dev/null | jq -r '.contexts[]? // empty' 2>/dev/null) || true

	if echo "$check_contexts" | grep -q "review-bot-gate" 2>/dev/null; then
		print_pass "review-bot-gate is a required status check"
		add_finding "$SEVERITY_PASS" "$CAT_REVIEW_BOT_GATE" "Required status check configured"
	else
		if [[ -f "$gate_workflow" ]]; then
			print_warn "review-bot-gate workflow exists but is not a required status check"
			add_finding "$SEVERITY_WARNING" "$CAT_REVIEW_BOT_GATE" "Not configured as required status check"
			print_info "  Add 'review-bot-gate' to branch protection required checks"
		fi
	fi

	return 0
}

# Phase 4: Dependency scanning — helpers

# Check npm/Node.js dependencies via npm audit
# Usage: _check_npm_deps <repo-path>
# Sets has_deps=true if package.json found; emits findings directly.
_check_npm_deps() {
	local repo_path="$1"

	[[ -f "$repo_path/package.json" ]] || return 0
	# Signal to caller that at least one manifest was found
	has_deps=true
	print_info "Found package.json — checking npm dependencies..."

	if [[ ! -f "$repo_path/package-lock.json" ]]; then
		print_warn "package.json exists but no package-lock.json — cannot run npm audit"
		add_finding "$SEVERITY_WARNING" "$CAT_DEPENDENCIES" "Missing package-lock.json"
		return 0
	fi

	if ! command -v npm &>/dev/null; then
		print_skip "npm not installed — cannot audit Node.js dependencies"
		add_finding "$SEVERITY_INFO" "$CAT_DEPENDENCIES" "npm not available"
		return 0
	fi

	local audit_output
	audit_output=$(npm audit --json --prefix "$repo_path" 2>/dev/null) || true

	if [[ -z "$audit_output" ]]; then
		print_skip "npm audit returned no output"
		return 0
	fi

	local vuln_total vuln_critical vuln_high
	vuln_total=$(echo "$audit_output" | jq -r '.metadata.vulnerabilities.total // 0' 2>/dev/null) || vuln_total="0"
	vuln_critical=$(echo "$audit_output" | jq -r '.metadata.vulnerabilities.critical // 0' 2>/dev/null) || vuln_critical="0"
	vuln_high=$(echo "$audit_output" | jq -r '.metadata.vulnerabilities.high // 0' 2>/dev/null) || vuln_high="0"

	if [[ "$vuln_critical" -gt 0 ]]; then
		print_crit "npm audit: $vuln_critical critical, $vuln_high high ($vuln_total total vulnerabilities)"
		add_finding "$SEVERITY_CRITICAL" "$CAT_DEPENDENCIES" "npm: $vuln_critical critical, $vuln_high high vulnerabilities"
	elif [[ "$vuln_high" -gt 0 ]]; then
		print_warn "npm audit: $vuln_high high ($vuln_total total vulnerabilities)"
		add_finding "$SEVERITY_WARNING" "$CAT_DEPENDENCIES" "npm: $vuln_high high vulnerabilities"
	elif [[ "$vuln_total" -gt 0 ]]; then
		print_info "npm audit: $vuln_total low/moderate vulnerabilities"
		add_finding "$SEVERITY_INFO" "$CAT_DEPENDENCIES" "npm: $vuln_total low/moderate vulnerabilities"
	else
		print_pass "npm audit: no known vulnerabilities"
		add_finding "$SEVERITY_PASS" "$CAT_DEPENDENCIES" "npm: clean audit"
	fi

	return 0
}

# Check Python dependencies via pip-audit
# Usage: _check_pip_deps <repo-path>
_check_pip_deps() {
	local repo_path="$1"

	[[ -f "$repo_path/requirements.txt" ]] || [[ -f "$repo_path/pyproject.toml" ]] || return 0
	has_deps=true
	print_info "Found Python project — checking dependencies..."

	if ! command -v pip-audit &>/dev/null; then
		print_skip "pip-audit not installed — install with: pip install pip-audit"
		add_finding "$SEVERITY_INFO" "$CAT_DEPENDENCIES" "pip-audit not available"
		return 0
	fi

	local pip_output
	pip_output=$(pip-audit --requirement "$repo_path/requirements.txt" --format json 2>/dev/null) || true

	if [[ -z "$pip_output" ]]; then
		return 0
	fi

	local pip_vulns
	pip_vulns=$(echo "$pip_output" | jq 'length' 2>/dev/null) || pip_vulns="0"

	if [[ "$pip_vulns" -gt 0 ]]; then
		print_warn "pip-audit: $pip_vulns vulnerable package(s)"
		add_finding "$SEVERITY_WARNING" "$CAT_DEPENDENCIES" "pip: $pip_vulns vulnerable packages"
	else
		print_pass "pip-audit: no known vulnerabilities"
		add_finding "$SEVERITY_PASS" "$CAT_DEPENDENCIES" "pip: clean audit"
	fi

	return 0
}

# Check Rust dependencies via cargo audit
# Usage: _check_cargo_deps <repo-path>
_check_cargo_deps() {
	local repo_path="$1"

	[[ -f "$repo_path/Cargo.toml" ]] || return 0
	has_deps=true

	if ! command -v cargo-audit &>/dev/null; then
		print_skip "cargo-audit not installed — install with: cargo install cargo-audit"
		add_finding "$SEVERITY_INFO" "$CAT_DEPENDENCIES" "cargo-audit not available"
		return 0
	fi

	print_info "Found Cargo.toml — running cargo audit..."
	local cargo_output
	cargo_output=$(cargo audit --json 2>/dev/null) || true

	if [[ -z "$cargo_output" ]]; then
		return 0
	fi

	local cargo_vulns
	cargo_vulns=$(echo "$cargo_output" | jq '.vulnerabilities.found // 0' 2>/dev/null) || cargo_vulns="0"

	if [[ "$cargo_vulns" -gt 0 ]]; then
		print_warn "cargo audit: $cargo_vulns vulnerability(ies)"
		add_finding "$SEVERITY_WARNING" "$CAT_DEPENDENCIES" "cargo: $cargo_vulns vulnerabilities"
	else
		print_pass "cargo audit: no known vulnerabilities"
		add_finding "$SEVERITY_PASS" "$CAT_DEPENDENCIES" "cargo: clean audit"
	fi

	return 0
}

# Phase 4: Dependency scanning — orchestrator
check_dependencies() {
	local repo_path="$1"

	print_header "Phase 4: Dependency Security"

	local has_deps=false

	_check_npm_deps "$repo_path"
	_check_pip_deps "$repo_path"
	_check_cargo_deps "$repo_path"

	if [[ "$has_deps" == "false" ]]; then
		print_skip "No dependency manifests found (package.json, requirements.txt, Cargo.toml)"
		add_finding "$SEVERITY_INFO" "$CAT_DEPENDENCIES" "No dependency manifests found"
	fi

	return 0
}

# Phase 5: Check collaborators (per-repo, never cached globally)
check_collaborators() {
	local repo_path="$1"

	print_header "Phase 5: Collaborator Access"

	if ! command -v gh &>/dev/null; then
		print_skip "GitHub CLI (gh) not installed"
		add_finding "$SEVERITY_INFO" "$CAT_COLLABORATORS" "gh CLI not available"
		return 0
	fi

	local slug
	if ! slug=$(resolve_slug "$repo_path"); then
		print_skip "No GitHub remote"
		add_finding "$SEVERITY_INFO" "$CAT_COLLABORATORS" "No GitHub remote"
		return 0
	fi

	# Per-repo collaborator check — never use a global cache (t1412.11: must paginate)
	local collab_json
	collab_json=$(gh api --paginate "repos/$slug/collaborators?per_page=100" --jq '.[] | {login: .login, role: .role_name}' 2>/dev/null) || true

	if [[ -z "$collab_json" ]]; then
		print_skip "Cannot access collaborator list (may require admin permissions)"
		add_finding "$SEVERITY_INFO" "$CAT_COLLABORATORS" "Cannot access collaborator list"
		return 0
	fi

	local admin_count
	admin_count=$(echo "$collab_json" | jq -s '[.[] | select(.role == "admin")] | length' 2>/dev/null) || admin_count="0"
	local write_count
	write_count=$(echo "$collab_json" | jq -s '[.[] | select(.role == "write" or .role == "maintain")] | length' 2>/dev/null) || write_count="0"
	local total_count
	total_count=$(echo "$collab_json" | jq -s 'length' 2>/dev/null) || total_count="0"

	print_info "Collaborators: $total_count total ($admin_count admin, $write_count write)"
	add_finding "$SEVERITY_INFO" "$CAT_COLLABORATORS" "$total_count collaborators ($admin_count admin, $write_count write)"

	if [[ "$admin_count" -gt 5 ]]; then
		print_warn "High number of admin collaborators ($admin_count) — review access levels"
		add_finding "$SEVERITY_WARNING" "$CAT_COLLABORATORS" "High admin count: $admin_count"
	else
		print_pass "Admin collaborator count is reasonable ($admin_count)"
		add_finding "$SEVERITY_PASS" "$CAT_COLLABORATORS" "Admin count OK: $admin_count"
	fi

	return 0
}

# Phase 6: General repo security checks
check_repo_security() {
	local repo_path="$1"

	print_header "Phase 6: Repository Security"

	# Check for SECURITY.md
	if [[ -f "$repo_path/SECURITY.md" ]]; then
		print_pass "SECURITY.md present"
		add_finding "$SEVERITY_PASS" "$CAT_REPO_SECURITY" "SECURITY.md present"
	else
		print_warn "No SECURITY.md — add a security policy for vulnerability reporting"
		add_finding "$SEVERITY_WARNING" "$CAT_REPO_SECURITY" "Missing SECURITY.md"
	fi

	# Check for .gitignore with common secret patterns
	if [[ -f "$repo_path/.gitignore" ]]; then
		local missing_patterns=()
		for pattern in ".env" "*.pem" "*.key" "credentials.json"; do
			if ! grep -qF "$pattern" "$repo_path/.gitignore" 2>/dev/null; then
				missing_patterns+=("$pattern")
			fi
		done

		if [[ ${#missing_patterns[@]} -gt 0 ]]; then
			print_warn ".gitignore missing common secret patterns: ${missing_patterns[*]}"
			add_finding "$SEVERITY_WARNING" "$CAT_REPO_SECURITY" "gitignore missing: ${missing_patterns[*]}"
		else
			print_pass ".gitignore covers common secret file patterns"
			add_finding "$SEVERITY_PASS" "$CAT_REPO_SECURITY" "gitignore covers secret patterns"
		fi
	else
		print_warn "No .gitignore file"
		add_finding "$SEVERITY_WARNING" "$CAT_REPO_SECURITY" "No .gitignore"
	fi

	# Check for committed secrets (quick scan of tracked files)
	local secret_files
	secret_files=$(git -C "$repo_path" ls-files '*.env' '*.pem' '*.key' 'credentials.json' '.env.*' 2>/dev/null) || true

	if [[ -n "$secret_files" ]]; then
		local secret_count
		secret_count=$(echo "$secret_files" | wc -l | tr -d ' ')
		print_crit "$secret_count potential secret file(s) tracked by git"
		add_finding "$SEVERITY_CRITICAL" "$CAT_REPO_SECURITY" "$secret_count secret files tracked: $(echo "$secret_files" | head -3 | tr '\n' ', ')"
	else
		print_pass "No obvious secret files tracked by git"
		add_finding "$SEVERITY_PASS" "$CAT_REPO_SECURITY" "No secret files tracked"
	fi

	# Check for Dependabot or Renovate config
	if [[ -f "$repo_path/.github/dependabot.yml" ]] || [[ -f "$repo_path/.github/dependabot.yaml" ]]; then
		print_pass "Dependabot configured"
		add_finding "$SEVERITY_PASS" "$CAT_REPO_SECURITY" "Dependabot configured"
	elif [[ -f "$repo_path/renovate.json" ]] || [[ -f "$repo_path/.github/renovate.json" ]] || [[ -f "$repo_path/renovate.json5" ]]; then
		print_pass "Renovate configured"
		add_finding "$SEVERITY_PASS" "$CAT_REPO_SECURITY" "Renovate configured"
	else
		print_warn "No automated dependency update tool (Dependabot/Renovate)"
		add_finding "$SEVERITY_WARNING" "$CAT_REPO_SECURITY" "No dependency update automation"
	fi

	return 0
}

# Store security posture in .aidevops.json
store_posture() {
	local repo_path="$1"
	local config_file="$repo_path/.aidevops.json"

	if [[ ! -f "$config_file" ]]; then
		print_info "No .aidevops.json found — skipping posture storage"
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_warn "jq not installed — cannot store posture in .aidevops.json"
		return 0
	fi

	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	local total_findings
	total_findings=$((FINDINGS_CRITICAL + FINDINGS_WARNING + FINDINGS_INFO + FINDINGS_PASS))

	local posture_status="unknown"
	if [[ "$FINDINGS_CRITICAL" -gt 0 ]]; then
		posture_status="$SEVERITY_CRITICAL"
	elif [[ "$FINDINGS_WARNING" -gt 0 ]]; then
		posture_status="$SEVERITY_WARNING"
	elif [[ "$FINDINGS_INFO" -gt 0 && "$FINDINGS_PASS" -eq 0 ]]; then
		posture_status="partial"
	elif [[ "$total_findings" -gt 0 ]]; then
		posture_status="good"
	fi

	local temp_file="${config_file}.tmp"
	jq --arg status "$posture_status" \
		--arg ts "$timestamp" \
		--argjson critical "$FINDINGS_CRITICAL" \
		--argjson warnings "$FINDINGS_WARNING" \
		--argjson info "$FINDINGS_INFO" \
		--argjson passed "$FINDINGS_PASS" \
		--argjson findings "$FINDINGS_JSON" \
		'.security_posture = {
			"status": $status,
			"last_audit": $ts,
			"critical": $critical,
			"warnings": $warnings,
			"info": $info,
			"passed": $passed,
			"findings": $findings
		}' "$config_file" >"$temp_file" && mv "$temp_file" "$config_file"

	print_info "Security posture stored in .aidevops.json (status: $posture_status)"
	return 0
}

# Print summary (one-line for greeting — per-repo)
print_summary() {
	local repo_path="$1"

	# Try to read from stored posture first
	local config_file="$repo_path/.aidevops.json"
	if [[ -f "$config_file" ]] && command -v jq &>/dev/null; then
		local stored_status
		stored_status=$(jq -r '.security_posture.status // empty' "$config_file" 2>/dev/null) || true

		if [[ -n "$stored_status" ]]; then
			local stored_critical
			stored_critical=$(jq -r '.security_posture.critical // 0' "$config_file" 2>/dev/null) || stored_critical="0"
			local stored_warnings
			stored_warnings=$(jq -r '.security_posture.warnings // 0' "$config_file" 2>/dev/null) || stored_warnings="0"
			local stored_ts
			stored_ts=$(jq -r '.security_posture.last_audit // "unknown"' "$config_file" 2>/dev/null) || stored_ts="unknown"

			case "$stored_status" in
			critical)
				echo "Security: $stored_critical critical issue(s), $stored_warnings warning(s) — run \`aidevops security audit\` (last: $stored_ts)"
				;;
			warning)
				echo "Security: $stored_warnings warning(s) — run \`aidevops security audit\` for details (last: $stored_ts)"
				;;
			partial)
				echo "Security: audit completed with skipped checks — review findings (last: $stored_ts)"
				;;
			good)
				echo "Security: all checks passed (last: $stored_ts)"
				;;
			*)
				echo "Security: run \`aidevops security audit\` for baseline assessment"
				;;
			esac
			return 0
		fi
	fi

	echo "Security: not yet audited — run \`aidevops security audit\`"
	return 0
}

# Print final report
print_report() {
	echo ""
	echo -e "${BOLD}═══════════════════════════════════════${NC}"
	echo -e "${BOLD}  Security Posture Summary${NC}"
	echo -e "${BOLD}═══════════════════════════════════════${NC}"
	echo ""

	if [[ "$FINDINGS_CRITICAL" -gt 0 ]]; then
		echo -e "  ${RED}Critical:${NC}  $FINDINGS_CRITICAL"
	fi
	if [[ "$FINDINGS_WARNING" -gt 0 ]]; then
		echo -e "  ${YELLOW}Warnings:${NC}  $FINDINGS_WARNING"
	fi
	echo -e "  ${GREEN}Passed:${NC}    $FINDINGS_PASS"
	echo -e "  ${CYAN}Info/Skip:${NC} $FINDINGS_INFO"
	echo ""

	local total_issues=$((FINDINGS_CRITICAL + FINDINGS_WARNING))
	if [[ "$total_issues" -eq 0 ]]; then
		echo -e "  ${GREEN}${BOLD}Overall: GOOD${NC} — no critical or warning findings"
	elif [[ "$FINDINGS_CRITICAL" -gt 0 ]]; then
		echo -e "  ${RED}${BOLD}Overall: CRITICAL${NC} — $FINDINGS_CRITICAL critical issue(s) need attention"
	else
		echo -e "  ${YELLOW}${BOLD}Overall: WARNING${NC} — $FINDINGS_WARNING issue(s) to review"
	fi
	echo ""

	return 0
}

# Run all per-repo checks
run_all_checks() {
	local repo_path="$1"

	echo -e "${CYAN}"
	echo "╔═══════════════════════════════════════════════════════════╗"
	echo "║         Per-Repo Security Posture Assessment             ║"
	echo "╚═══════════════════════════════════════════════════════════╝"
	echo -e "${NC}"

	print_info "Repository: $repo_path"

	check_workflow_security "$repo_path"
	check_branch_protection "$repo_path"
	check_review_bot_gate "$repo_path"
	check_dependencies "$repo_path"
	check_collaborators "$repo_path"
	check_repo_security "$repo_path"
	print_report

	return 0
}

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

	# Check staleness (>30 days old)
	local file_age_days=0
	if [[ "$(uname)" == "Darwin" ]]; then
		local file_mod
		file_mod=$(stat -f %m "$yaml_file" || echo "0")
		local now
		now=$(date +%s)
		file_age_days=$(((now - file_mod) / 86400))
	else
		file_age_days=$((($(date +%s) - $(stat -c %Y "$yaml_file" || echo "0")) / 86400))
	fi

	if [[ "$file_age_days" -gt 30 ]]; then
		CHECK_LABEL="$label: ${file_age_days}d old (>30d)"
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

# ============================================================
# HELP & MAIN
# ============================================================

# Print usage
print_usage() {
	cat <<EOF
Usage: $(basename "$0") <command> [repo-path]

Per-repo audit commands:
  check [path]         Run all security posture checks (default: current dir)
  audit [path]         Alias for check
  store [path]         Run checks and store results in .aidevops.json
  summary [path]       Print one-line summary (for session greeting)

User-level commands:
  startup-check        One-line user security posture for session greeting
  setup                Interactive guided security setup
  status               Detailed user security posture report

  help                 Show this help message

Per-repo checks (check/audit/store):
  1. GitHub Actions workflows for unsafe AI patterns
  2. Branch protection (PR reviews required)
  3. Review-bot-gate as required status check
  4. Dependency vulnerabilities (npm/pip/cargo audit)
  5. Collaborator access levels (per-repo, never cached)
  6. Repository security basics (SECURITY.md, .gitignore, secrets)

User-level checks (startup-check/setup/status):
  1. Prompt injection patterns (YAML file present and <30d old)
  2. Secret storage backend (gopass or credentials.sh with 600 perms)
  3. GitHub CLI authentication (gh auth status)
  4. SSH key (id_ed25519 or id_rsa)
  5. Git commit signing (optional, informational only)
  6. Secret scanning tool (secretlint installed)

Examples:
  $(basename "$0") check                    # Audit current repo
  $(basename "$0") check ~/Git/myproject    # Audit specific repo
  $(basename "$0") store                    # Audit and store in .aidevops.json
  $(basename "$0") startup-check            # Quick user posture for greeting
  $(basename "$0") setup                    # Walk through user security fixes

Exit codes:
  0 — All checks passed
  1 — Findings detected / actions needed
  2 — Error
EOF
}

# Main
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	# Per-repo audit commands (t1412.11)
	check | audit)
		local repo_path="${1:-.}"
		if git -C "$repo_path" rev-parse --is-inside-work-tree &>/dev/null; then
			repo_path=$(git -C "$repo_path" rev-parse --show-toplevel)
		fi
		run_all_checks "$repo_path"
		store_posture "$repo_path"
		local exit_code=0
		if [[ "$FINDINGS_CRITICAL" -gt 0 || "$FINDINGS_WARNING" -gt 0 ]]; then
			exit_code=1
		fi
		return "$exit_code"
		;;
	store)
		local repo_path="${1:-.}"
		if git -C "$repo_path" rev-parse --is-inside-work-tree &>/dev/null; then
			repo_path=$(git -C "$repo_path" rev-parse --show-toplevel)
		fi
		run_all_checks "$repo_path"
		store_posture "$repo_path"
		if [[ "$FINDINGS_CRITICAL" -gt 0 || "$FINDINGS_WARNING" -gt 0 ]]; then
			return 1
		fi
		return 0
		;;
	summary)
		local repo_path="${1:-.}"
		if git -C "$repo_path" rev-parse --is-inside-work-tree &>/dev/null; then
			repo_path=$(git -C "$repo_path" rev-parse --show-toplevel)
		fi
		print_summary "$repo_path"
		return 0
		;;
	# User-level commands (t1412.6)
	startup-check)
		cmd_startup_check
		;;
	setup)
		cmd_setup
		;;
	status)
		cmd_status
		;;
	help | --help | -h)
		print_usage
		return 0
		;;
	*)
		echo "Unknown command: $command" >&2
		print_usage >&2
		return 2
		;;
	esac
}

main "$@"
