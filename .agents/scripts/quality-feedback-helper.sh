#!/usr/bin/env bash
# quality-feedback-helper.sh - Retrieve code quality feedback via GitHub API
# Consolidates feedback from Codacy, CodeRabbit, SonarCloud, CodeFactor, etc.
#
# Usage:
#   quality-feedback-helper.sh [command] [options]
#
# Commands:
#   status       Show status of all quality checks for current commit/PR
#   failed       Show only failed checks with details
#   annotations  Get line-level annotations from all check runs
#   codacy       Get Codacy-specific feedback
#   coderabbit   Get CodeRabbit review comments
#   sonar        Get SonarCloud feedback
#   watch        Watch for check completion (polls every 30s)
#   scan-merged  Scan merged PRs for unactioned review feedback
#
# Examples:
#   quality-feedback-helper.sh status
#   quality-feedback-helper.sh failed --pr 4
#   quality-feedback-helper.sh annotations --commit abc123
#   quality-feedback-helper.sh watch --pr 4
#   quality-feedback-helper.sh scan-merged --repo owner/repo --batch 20
#   quality-feedback-helper.sh scan-merged --repo owner/repo --batch 20 --create-issues

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Common constants
# Get repository info
get_repo() {
	local repo
	repo="${GITHUB_REPOSITORY:-}"
	if [[ -z "$repo" ]]; then
		repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
			echo "Error: Not in a GitHub repository or gh CLI not configured" >&2
			exit 1
		}
	fi
	echo "$repo"
	return 0
}

# Get commit SHA (from PR or current HEAD)
get_sha() {
	local pr_number="${1:-}"
	if [[ -n "$pr_number" ]]; then
		gh pr view "$pr_number" --json headRefOid -q .headRefOid
	else
		git rev-parse HEAD
	fi
	return 0
}

# Show status of all checks
cmd_status() {
	local pr_number="${1:-}"
	local repo
	local sha

	repo=$(get_repo)
	sha=$(get_sha "$pr_number")

	echo -e "${BLUE}=== Quality Check Status ===${NC}"
	echo -e "Repository: ${repo}"
	echo -e "Commit: ${sha:0:8}"
	[[ -n "$pr_number" ]] && echo -e "PR: #${pr_number}"
	echo ""

	gh api "repos/${repo}/commits/${sha}/check-runs" \
		--jq '.check_runs[] | "\(.conclusion // .status)\t\(.name)"' |
		while IFS=$'\t' read -r conclusion name; do
			case "$conclusion" in
			success)
				echo -e "${GREEN}✓${NC} ${name}"
				;;
			failure | action_required)
				echo -e "${RED}✗${NC} ${name}"
				;;
			in_progress | queued | pending)
				echo -e "${YELLOW}○${NC} ${name} (${conclusion})"
				;;
			neutral | skipped)
				echo -e "${BLUE}–${NC} ${name} (${conclusion})"
				;;
			*)
				echo -e "? ${name} (${conclusion:-unknown})"
				;;
			esac
		done | sort
	return 0
}

# Show only failed checks with details
cmd_failed() {
	local pr_number="${1:-}"
	local repo
	local sha

	repo=$(get_repo)
	sha=$(get_sha "$pr_number")

	echo -e "${RED}=== Failed Quality Checks ===${NC}"
	echo -e "Commit: ${sha:0:8}"
	echo ""

	local failed_count=0

	while IFS=$'\t' read -r name summary url; do
		((++failed_count))
		echo -e "${RED}✗ ${name}${NC}"
		[[ -n "$summary" && "$summary" != "null" ]] && echo "  Summary: ${summary}"
		[[ -n "$url" && "$url" != "null" ]] && echo "  Details: ${url}"
		echo ""
	done < <(gh api "repos/${repo}/commits/${sha}/check-runs" \
		--jq '.check_runs[] | select(.conclusion == "failure" or .conclusion == "action_required") | "\(.name)\t\(.output.summary)\t\(.html_url)"')

	if [[ $failed_count -eq 0 ]]; then
		echo -e "${GREEN}No failed checks!${NC}"
	else
		echo -e "${RED}Total failed: ${failed_count}${NC}"
	fi
	return 0
}

# Get line-level annotations from all check runs
cmd_annotations() {
	local pr_number="${1:-}"
	local repo
	local sha

	repo=$(get_repo)
	sha=$(get_sha "$pr_number")

	echo -e "${BLUE}=== Annotations (Line-Level Issues) ===${NC}"
	echo -e "Commit: ${sha:0:8}"
	echo ""

	# Get all check run IDs
	local check_ids
	check_ids=$(gh api "repos/${repo}/commits/${sha}/check-runs" --jq '.check_runs[].id')

	local total_annotations=0

	for check_id in $check_ids; do
		local check_name
		check_name=$(gh api "repos/${repo}/check-runs/${check_id}" --jq '.name')

		local annotations
		annotations=$(gh api "repos/${repo}/check-runs/${check_id}/annotations" 2>/dev/null || echo "[]")

		local count
		count=$(echo "$annotations" | jq 'length')

		if [[ "$count" -gt 0 ]]; then
			echo -e "${YELLOW}--- ${check_name} (${count} annotations) ---${NC}"
			echo "$annotations" | jq -r '.[] | "  \(.path):\(.start_line) [\(.annotation_level)] \(.message)"'
			echo ""
			total_annotations=$((total_annotations + count))
		fi
	done

	if [[ $total_annotations -eq 0 ]]; then
		echo "No annotations found."
	else
		echo -e "${YELLOW}Total annotations: ${total_annotations}${NC}"
	fi
	return 0
}

# Get Codacy-specific feedback
cmd_codacy() {
	local pr_number="${1:-}"
	local repo
	local sha

	repo=$(get_repo)
	sha=$(get_sha "$pr_number")

	echo -e "${BLUE}=== Codacy Feedback ===${NC}"

	local codacy_check
	codacy_check=$(gh api "repos/${repo}/commits/${sha}/check-runs" \
		--jq '.check_runs[] | select(.app.slug == "codacy-production" or .name | contains("Codacy"))' 2>/dev/null)

	if [[ -z "$codacy_check" ]]; then
		echo "No Codacy check found for this commit."
		return
	fi

	local conclusion
	local summary
	local url
	local check_id

	conclusion=$(echo "$codacy_check" | jq -r '.conclusion // .status')
	summary=$(echo "$codacy_check" | jq -r '.output.summary // "No summary"')
	url=$(echo "$codacy_check" | jq -r '.html_url')
	check_id=$(echo "$codacy_check" | jq -r '.id')

	echo "Status: ${conclusion}"
	echo "Summary: ${summary}"
	echo "Details: ${url}"
	echo ""

	# Get annotations if available
	local annotations
	annotations=$(gh api "repos/${repo}/check-runs/${check_id}/annotations" 2>/dev/null || echo "[]")
	local count
	count=$(echo "$annotations" | jq 'length')

	if [[ "$count" -gt 0 ]]; then
		echo -e "${YELLOW}Issues found:${NC}"
		echo "$annotations" | jq -r '.[] | "  \(.path):\(.start_line) [\(.annotation_level)] \(.message)"'
	fi
	return 0
}

# Get CodeRabbit review comments
cmd_coderabbit() {
	local pr_number="${1:-}"
	local repo

	repo=$(get_repo)

	if [[ -z "$pr_number" ]]; then
		pr_number=$(gh pr view --json number -q .number 2>/dev/null) || {
			echo "Error: Please specify a PR number with --pr" >&2
			exit 1
		}
	fi

	echo -e "${BLUE}=== CodeRabbit Review Comments ===${NC}"
	echo -e "PR: #${pr_number}"
	echo ""

	# Get review comments from CodeRabbit
	local comments
	comments=$(gh api "repos/${repo}/pulls/${pr_number}/comments" \
		--jq '[.[] | select(.user.login | contains("coderabbit"))]' 2>/dev/null || echo "[]")

	local count
	count=$(echo "$comments" | jq 'length')

	if [[ "$count" -eq 0 ]]; then
		echo "No CodeRabbit comments found."

		# Check for review body
		local reviews
		reviews=$(gh api "repos/${repo}/pulls/${pr_number}/reviews" \
			--jq '[.[] | select(.user.login | contains("coderabbit"))]' 2>/dev/null || echo "[]")

		local review_count
		review_count=$(echo "$reviews" | jq 'length')

		if [[ "$review_count" -gt 0 ]]; then
			echo ""
			echo -e "${YELLOW}CodeRabbit Reviews:${NC}"
			echo "$reviews" | jq -r '.[] | "State: \(.state)\n\(.body)\n---"'
		fi
	else
		echo -e "${YELLOW}Inline Comments (${count}):${NC}"
		echo "$comments" | jq -r '.[] | "\(.path):\(.line // .original_line)\n  \(.body)\n"'
	fi
	return 0
}

# Get SonarCloud feedback
cmd_sonar() {
	local pr_number="${1:-}"
	local repo
	local sha

	repo=$(get_repo)
	sha=$(get_sha "$pr_number")

	echo -e "${BLUE}=== SonarCloud Feedback ===${NC}"

	local sonar_check
	sonar_check=$(gh api "repos/${repo}/commits/${sha}/check-runs" \
		--jq '.check_runs[] | select(.name | contains("SonarCloud") or .name | contains("sonar"))' 2>/dev/null)

	if [[ -z "$sonar_check" ]]; then
		echo "No SonarCloud check found for this commit."
		return
	fi

	local conclusion
	local summary
	local details_url

	conclusion=$(echo "$sonar_check" | jq -r '.conclusion // .status')
	summary=$(echo "$sonar_check" | jq -r '.output.summary // "No summary"')
	details_url=$(echo "$sonar_check" | jq -r '.details_url // .html_url')

	echo "Status: ${conclusion}"
	echo "Summary: ${summary}"
	echo "Dashboard: ${details_url}"
	return 0
}

# Watch for check completion
cmd_watch() {
	local pr_number="${1:-}"
	local repo
	local sha
	local interval="${2:-30}"

	repo=$(get_repo)
	sha=$(get_sha "$pr_number")

	echo -e "${BLUE}=== Watching Quality Checks ===${NC}"
	echo -e "Commit: ${sha:0:8}"
	echo -e "Polling every ${interval} seconds..."
	echo ""

	while true; do
		local pending
		pending=$(gh api "repos/${repo}/commits/${sha}/check-runs" \
			--jq '[.check_runs[] | select(.status == "in_progress" or .status == "queued" or .status == "pending")] | length')

		local failed
		failed=$(gh api "repos/${repo}/commits/${sha}/check-runs" \
			--jq '[.check_runs[] | select(.conclusion == "failure")] | length')

		local total
		total=$(gh api "repos/${repo}/commits/${sha}/check-runs" --jq '.check_runs | length')

		local completed
		completed=$((total - pending))

		echo -e "[$(date '+%H:%M:%S')] Completed: ${completed}/${total}, Pending: ${pending}, Failed: ${failed}"

		if [[ "$pending" -eq 0 ]]; then
			echo ""
			if [[ "$failed" -eq 0 ]]; then
				echo -e "${GREEN}All checks passed!${NC}"
			else
				echo -e "${RED}${failed} check(s) failed.${NC}"
				cmd_failed "$pr_number"
			fi
			break
		fi

		sleep "$interval"
	done
	return 0
}

#######################################
# Scan merged PRs for unactioned review feedback
#
# Fetches recently merged PRs, extracts review comments and review
# bodies from bots (CodeRabbit, Gemini Code Assist) and humans,
# filters by severity, checks if affected files still exist on HEAD,
# and optionally creates GitHub issues with label "quality-debt".
#
# State tracking: scanned PR numbers are stored in a JSON state file
# so subsequent runs skip already-processed PRs.
#
# Arguments (parsed from flags):
#   --repo SLUG       Repository slug (owner/repo). Default: auto-detect.
#   --batch N         Max PRs to scan per run (default: 20)
#   --create-issues   Actually create GitHub issues for findings
#   --min-severity    Minimum severity to report: critical|high|medium (default: medium)
#   --json            Output findings as JSON instead of human-readable
#
# Returns: 0 on success, 1 on error
#######################################
cmd_scan_merged() {
	local repo_slug=""
	local batch_size=20
	local create_issues=false
	local min_severity="medium"
	local json_output=false
	local backfill=false
	local tag_actioned=false

	# Parse flags
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			repo_slug="${2:-}"
			shift 2
			;;
		--batch)
			batch_size="${2:-20}"
			shift 2
			;;
		--create-issues)
			create_issues=true
			shift
			;;
		--min-severity)
			min_severity="${2:-medium}"
			shift 2
			;;
		--json)
			json_output=true
			shift
			;;
		--backfill)
			backfill=true
			shift
			;;
		--tag-actioned)
			tag_actioned=true
			shift
			;;
		*)
			echo "Unknown option for scan-merged: $1" >&2
			return 1
			;;
		esac
	done

	# Validate batch_size is a positive integer (prevents command injection via arithmetic)
	if ! [[ "$batch_size" =~ ^[0-9]+$ ]] || [[ "$batch_size" -eq 0 ]]; then
		echo "Error: --batch must be a positive integer, got: ${batch_size}" >&2
		return 1
	fi

	# Auto-detect repo if not specified
	if [[ -z "$repo_slug" ]]; then
		repo_slug=$(get_repo) || return 1
	fi

	# State file for tracking scanned PRs
	local state_dir="${HOME}/.aidevops/logs"
	mkdir -p "$state_dir"
	local slug_safe="${repo_slug//\//-}"
	local state_file="${state_dir}/review-scan-state-${slug_safe}.json"

	# Initialize state file if missing
	if [[ ! -f "$state_file" ]]; then
		echo '{"scanned_prs":[],"last_run":"","issues_created":0}' >"$state_file"
	fi

	# Fetch merged PRs — backfill uses gh api pagination for ALL PRs,
	# normal mode uses gh pr list with a limited window (t1413)
	local merged_prs
	if [[ "$backfill" == true ]]; then
		echo "Backfill mode: fetching ALL merged PRs for ${repo_slug}..." >&2
		merged_prs=$(gh api "repos/${repo_slug}/pulls?state=closed&per_page=100&sort=updated&direction=desc" \
			--paginate --jq '.[] | select(.merged_at != null) | .number') || {
			echo "Error: Failed to fetch merged PRs from ${repo_slug}" >&2
			return 1
		}
	else
		merged_prs=$(gh pr list --repo "$repo_slug" --state merged \
			--limit "$((batch_size * 2))" \
			--json number,title,mergedAt,headRefName \
			--jq 'sort_by(.mergedAt) | reverse | .[].number') || {
			echo "Error: Failed to fetch merged PRs from ${repo_slug}" >&2
			return 1
		}
	fi

	if [[ -z "$merged_prs" ]]; then
		if [[ "$json_output" == "true" ]]; then
			echo '{"scanned":0,"findings":0,"issues_created":0,"details":[]}'
		else
			echo "No merged PRs found in ${repo_slug}."
		fi
		return 0
	fi

	# Filter out already-scanned PRs, limit to batch_size
	# In backfill mode, process ALL unscanned PRs in batches with rate limiting
	local prs_to_scan=()
	local count=0
	while IFS= read -r pr_num; do
		[[ -z "$pr_num" ]] && continue
		# Skip if already scanned (use jq for reliable lookup)
		if jq -e --argjson pr "$pr_num" '.scanned_prs | index($pr) != null' "$state_file" >/dev/null 2>&1; then
			continue
		fi
		prs_to_scan+=("$pr_num")
		count=$((count + 1))
		# In normal mode, cap at batch_size. In backfill mode, collect all.
		if [[ "$backfill" != true ]] && [[ "$count" -ge "$batch_size" ]]; then
			break
		fi
	done <<<"$merged_prs"

	if [[ ${#prs_to_scan[@]} -eq 0 ]]; then
		if [[ "$json_output" == "true" ]]; then
			echo '{"scanned":0,"findings":0,"issues_created":0,"details":[]}'
		else
			echo "All merged PRs already scanned for ${repo_slug}."
		fi
		# Even if nothing to scan, tag actioned PRs if requested
		if [[ "$tag_actioned" == true ]]; then
			_tag_actioned_prs "$repo_slug" "$state_file"
		fi
		return 0
	fi

	local total_to_scan=${#prs_to_scan[@]}
	if [[ "$json_output" != "true" ]]; then
		echo -e "${BLUE:-}=== Scanning ${total_to_scan} merged PRs for unactioned review feedback ===${NC:-}"
		echo "Repository: ${repo_slug}"
		if [[ "$backfill" == true ]]; then
			echo "Mode: backfill (processing in batches of ${batch_size} with rate limiting)"
		fi
		echo ""
	fi

	local total_findings=0
	local total_issues_created=0
	local all_findings_json="[]"
	local newly_scanned=()
	local batch_count=0

	for pr_num in "${prs_to_scan[@]}"; do
		# Rate limiting: sleep between batches to stay within GitHub API limits
		# ~3 API calls per PR (comments, reviews, tree). At batch_size=20,
		# that's ~60 calls per batch. GitHub allows 5,000/hour.
		# Sleep 5s every batch_size PRs to spread the load.
		if [[ "$backfill" == true ]] && [[ "$batch_count" -gt 0 ]] && [[ $((batch_count % batch_size)) -eq 0 ]]; then
			echo "  Rate limit pause (${batch_count}/${total_to_scan} scanned, sleeping 5s)..." >&2
			sleep 5
			# Save progress incrementally so we don't lose work on interruption
			if [[ ${#newly_scanned[@]} -gt 0 ]]; then
				local progress_json
				progress_json=$(printf '%s\n' "${newly_scanned[@]}" | jq -R 'tonumber' | jq -s '.')
				local progress_iso
				progress_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
				jq --argjson new_prs "$progress_json" \
					--arg last_run "$progress_iso" \
					--argjson created "$total_issues_created" \
					'.scanned_prs = (.scanned_prs + $new_prs | unique) | .last_run = $last_run | .issues_created = (.issues_created + $created)' \
					"$state_file" >"${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
				newly_scanned=()
			fi
		fi

		local findings
		findings=$(_scan_single_pr "$repo_slug" "$pr_num" "$min_severity") || {
			newly_scanned+=("$pr_num")
			batch_count=$((batch_count + 1))
			continue
		}
		newly_scanned+=("$pr_num")
		batch_count=$((batch_count + 1))

		local finding_count
		finding_count=$(echo "$findings" | jq 'length' 2>/dev/null || echo "0")

		if [[ "$finding_count" -eq 0 || "$finding_count" == "0" ]]; then
			continue
		fi

		total_findings=$((total_findings + finding_count))

		# Merge into all_findings_json (skip in backfill to save memory)
		if [[ "$backfill" != true ]]; then
			all_findings_json=$(echo "$all_findings_json" "$findings" | jq -s '.[0] + .[1]')
		fi

		# Create issues if requested
		if [[ "$create_issues" == "true" ]]; then
			local created
			created=$(_create_quality_debt_issues "$repo_slug" "$pr_num" "$findings")
			total_issues_created=$((total_issues_created + created))
		fi
	done

	# Update state file with newly scanned PRs (final save)
	if [[ ${#newly_scanned[@]} -gt 0 ]]; then
		local new_scanned_json
		new_scanned_json=$(printf '%s\n' "${newly_scanned[@]}" | jq -R 'tonumber' | jq -s '.')
		local now_iso
		now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
		jq --argjson new_prs "$new_scanned_json" \
			--arg last_run "$now_iso" \
			--argjson created "$total_issues_created" \
			'.scanned_prs = (.scanned_prs + $new_prs | unique) | .last_run = $last_run | .issues_created = (.issues_created + $created)' \
			"$state_file" >"${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
	fi

	# Tag actioned PRs if requested (t1413)
	if [[ "$tag_actioned" == true ]]; then
		_tag_actioned_prs "$repo_slug" "$state_file"
	fi

	# Output
	if [[ "$json_output" == "true" ]]; then
		local details_json="$all_findings_json"
		[[ "$backfill" == true ]] && details_json="[]"
		jq -n \
			--argjson scanned "$batch_count" \
			--argjson findings "$total_findings" \
			--argjson issues_created "$total_issues_created" \
			--argjson details "$details_json" \
			'{scanned: $scanned, findings: $findings, issues_created: $issues_created, details: $details}'
	else
		echo ""
		echo -e "${BLUE:-}=== Scan Summary ===${NC:-}"
		echo "PRs scanned: ${batch_count}"
		echo "Findings: ${total_findings}"
		echo "Issues created: ${total_issues_created}"
	fi
	return 0
}

#######################################
# Scan a single merged PR for review feedback
#
# Fetches both inline review comments and review bodies from all
# reviewers (bots and humans). Extracts severity from known patterns
# (Gemini SVG markers, CodeRabbit labels). Checks if affected files
# still exist on HEAD.
#
# Arguments:
#   $1 - repo slug
#   $2 - PR number
#   $3 - minimum severity (critical|high|medium)
# Output: JSON array of findings to stdout
# Returns: 0 on success
#######################################
_scan_single_pr() {
	local repo_slug="$1"
	local pr_num="$2"
	local min_severity="$3"

	echo -e "  Scanning PR #${pr_num}..." >&2

	local findings="[]"

	# --- Fetch inline review comments (file-level) ---
	local comments
	comments=$(gh api "repos/${repo_slug}/pulls/${pr_num}/comments" \
		--paginate --jq '.' 2>/dev/null) || comments="[]"

	# --- Fetch review bodies (top-level reviews) ---
	local reviews
	reviews=$(gh api "repos/${repo_slug}/pulls/${pr_num}/reviews" \
		--paginate --jq '.' 2>/dev/null) || reviews="[]"

	# Process inline comments
	local inline_findings
	inline_findings=$(echo "$comments" | jq --arg pr "$pr_num" --arg min_sev "$min_severity" '
		[.[] |
		# Determine reviewer type
		(.user.login) as $login |
		(if ($login | test("coderabbit"; "i")) then "coderabbit"
		 elif ($login | test("gemini|google"; "i")) then "gemini"
		 elif ($login | test("codacy"; "i")) then "codacy"
		 elif ($login | test("sonar"; "i")) then "sonarcloud"
		 else "human"
		 end) as $reviewer |

		# Extract severity from body
		(.body) as $body |
		(if ($body | test("security-critical\\.svg|🔴.*critical|CRITICAL"; "i")) then "critical"
		 elif ($body | test("critical\\.svg|severity:.*critical"; "i")) then "critical"
		 elif ($body | test("high-priority\\.svg|severity:.*high|HIGH"; "i")) then "high"
		 elif ($body | test("medium-priority\\.svg|severity:.*medium|MEDIUM"; "i")) then "medium"
		 elif ($body | test("low-priority\\.svg|severity:.*low|LOW|nit"; "i")) then "low"
		 else "medium"
		 end) as $severity |

		# Severity filter
		({"critical":4,"high":3,"medium":2,"low":1}[$severity] // 2) as $sev_num |
		({"critical":4,"high":3,"medium":2,"low":1}[$min_sev] // 2) as $min_num |

		select($sev_num >= $min_num) |

		# Skip resolved/outdated comments
		select(.position != null or .line != null or .original_line != null) |

		{
			pr: ($pr | tonumber),
			type: "inline",
			reviewer: $reviewer,
			reviewer_login: $login,
			severity: $severity,
			file: .path,
			line: (.line // .original_line),
			body: (.body | split("\n") | map(select(length > 0)) | first // .body),
			body_full: .body,
			url: .html_url,
			created_at: .created_at
		}]
	' 2>/dev/null) || inline_findings="[]"

	# Process review bodies (for substantive reviews with body content)
	local review_findings
	review_findings=$(echo "$reviews" | jq --arg pr "$pr_num" --arg min_sev "$min_severity" '
		[.[] |
		select(.body != null and .body != "" and (.body | length) > 50) |

		(.user.login) as $login |
		(if ($login | test("coderabbit"; "i")) then "coderabbit"
		 elif ($login | test("gemini|google"; "i")) then "gemini"
		 elif ($login | test("codacy"; "i")) then "codacy"
		 else "human"
		 end) as $reviewer |

		(.body) as $body |
		(if ($body | test("security-critical\\.svg|🔴.*critical|CRITICAL"; "i")) then "critical"
		 elif ($body | test("critical\\.svg|severity:.*critical"; "i")) then "critical"
		 elif ($body | test("high-priority\\.svg|severity:.*high|HIGH"; "i")) then "high"
		 elif ($body | test("medium-priority\\.svg|severity:.*medium|MEDIUM"; "i")) then "medium"
		 elif ($body | test("low-priority\\.svg|severity:.*low|LOW|nit"; "i")) then "low"
		 else "medium"
		 end) as $severity |

		({"critical":4,"high":3,"medium":2,"low":1}[$severity] // 2) as $sev_num |
		({"critical":4,"high":3,"medium":2,"low":1}[$min_sev] // 2) as $min_num |

		select($sev_num >= $min_num) |

		# Filter out review-body summaries that do not contain concrete fixes.
		# Bots frequently post high-level walkthroughs that mention suggestions
		# but do not include actionable details tied to a file/line.
		($body | test(
			"\\bshould\\b|\\bconsider\\b|\\binstead\\b|\\bsuggest|\\brecommend|" +
			"\\bwarning\\b|\\bcaution\\b|\\bavoid\\b|\\b(don ?'"'"'?t|do not)\\b|" +
			"\\bvulnerab|\\binsecure|\\binjection\\b|\\bxss\\b|\\bcsrf\\b|" +
			"\\bbug\\b|\\berror\\b|\\bproblem\\b|\\bfail\\b|\\bincorrect\\b|\\bwrong\\b|\\bmissing\\b|\\bbroken\\b|" +
			"\\bnit:|\\btodo:|\\bfixme|\\bhardcoded|\\bdeprecated|" +
			"\\brace.condition|\\bdeadlock|\\bleak|\\boverflow|" +
			"\\bworkaround\\b|\\bhack\\b|" +
			"```\\s*(suggestion|diff)"; "i")) as $actionable |
		(if $reviewer == "human" then
			true
		 elif .state == "APPROVED" then
			$actionable
		 else
			($actionable and ($body | test(
				"\\*\\*File\\*\\*|```\\s*(suggestion|diff)|" +
				"\\bline\\s+[0-9]+\\b|\\bL[0-9]+\\b"; "i")))
		 end) |
		select(.) |

		{
			pr: ($pr | tonumber),
			type: "review_body",
			reviewer: $reviewer,
			reviewer_login: $login,
			severity: $severity,
			file: null,
			line: null,
			body: (.body | split("\n") | map(select(length > 0)) | first // .body),
			body_full: .body,
			url: .html_url,
			created_at: .submitted_at
		}]
	' 2>/dev/null) || review_findings="[]"

	# Merge and deduplicate
	findings=$(echo "$inline_findings" "$review_findings" | jq -s '.[0] + .[1]')

	# Filter: check if affected files still exist on HEAD
	local filtered="[]"
	local item_count
	item_count=$(echo "$findings" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$item_count" -gt 0 ]]; then
		# Get list of files in the repo at HEAD
		local head_files
		head_files=$(gh api "repos/${repo_slug}/git/trees/HEAD?recursive=1" \
			--jq '[.tree[].path]' 2>/dev/null) || head_files="[]"

		filtered=$(echo "$findings" | jq --argjson head_files "$head_files" '
			[.[] |
			if .file == null then .  # review bodies without file refs — keep
			elif (.file as $f | $head_files | any(. == $f)) then .  # file still exists
			else empty  # file was removed/renamed — skip
			end]
		')
	fi

	echo "$filtered"
	return 0
}

#######################################
# Tag scanned PRs where all review feedback has been actioned (t1413)
#
# For each scanned PR, checks if any quality-debt issues reference it.
# If all such issues are closed (or none were created because the PR
# had no actionable findings), labels the PR as "code-reviews-actioned".
#
# This provides a clear signal of which PRs have been fully reviewed
# and resolved, vs which still have outstanding feedback.
#
# Arguments:
#   $1 - repo slug
#   $2 - state file path
# Returns: 0 on success
#######################################
_tag_actioned_prs() {
	local repo_slug="$1"
	local state_file="$2"

	echo "Tagging actioned PRs for ${repo_slug}..." >&2

	# Ensure label exists
	gh label create "code-reviews-actioned" --repo "$repo_slug" --color "0E8A16" \
		--description "All review feedback has been actioned" --force 2>/dev/null || true

	# Get all scanned PR numbers
	local scanned_prs
	scanned_prs=$(jq -r '.scanned_prs[]' "$state_file" 2>/dev/null) || return 0

	# Get all OPEN quality-debt issues with their titles (to extract PR numbers)
	local open_debt_titles
	open_debt_titles=$(gh issue list --repo "$repo_slug" \
		--label "quality-debt" --state open --limit 500 \
		--json title --jq '.[].title' 2>/dev/null || echo "")

	# Get PRs that already have the label (avoid redundant API calls)
	local already_tagged
	already_tagged=$(gh pr list --repo "$repo_slug" --state merged \
		--label "code-reviews-actioned" --limit 500 \
		--json number --jq '.[].number' 2>/dev/null || echo "")

	local tagged_count=0
	local batch_count=0

	while IFS= read -r pr_num; do
		[[ -z "$pr_num" ]] && continue

		# Skip if already tagged
		if echo "$already_tagged" | grep -qx "$pr_num" 2>/dev/null; then
			continue
		fi

		# Check if this PR has any OPEN quality-debt issues
		# Quality-debt issue titles contain "PR #NNN" — check for open ones
		local has_open_debt=false
		if [[ -n "$open_debt_titles" ]]; then
			if echo "$open_debt_titles" | grep -qF "PR #${pr_num}" 2>/dev/null; then
				has_open_debt=true
			fi
		fi

		if [[ "$has_open_debt" == false ]]; then
			# No open debt for this PR — tag it as actioned
			gh pr edit "$pr_num" --repo "$repo_slug" \
				--add-label "code-reviews-actioned" 2>/dev/null || true
			tagged_count=$((tagged_count + 1))
		fi

		# Rate limiting: sleep every 50 labels to avoid API abuse
		batch_count=$((batch_count + 1))
		if [[ $((batch_count % 50)) -eq 0 ]]; then
			echo "  Tagged ${tagged_count} PRs so far (${batch_count} checked), sleeping 3s..." >&2
			sleep 3
		fi
	done <<<"$scanned_prs"

	echo "  Tagged ${tagged_count} PRs as code-reviews-actioned" >&2

	# Backfill priority labels on existing open quality-debt issues (t1413)
	# Issues created before the priority label feature won't have them.
	# Parse severity from the title "(critical)", "(high)", "(medium)" and add
	# the corresponding priority:* label if missing.
	_backfill_priority_labels "$repo_slug"

	return 0
}

#######################################
# Backfill priority labels on open quality-debt issues (t1413)
#
# Parses severity from issue titles and adds priority:critical,
# priority:high, or priority:medium labels to issues that don't
# have them yet. Enables the supervisor to sort quality-debt
# issues by severity when deciding dispatch order.
#
# Arguments:
#   $1 - repo slug
# Returns: 0 on success
#######################################
_backfill_priority_labels() {
	local repo_slug="$1"

	# Ensure priority labels exist on the repo
	gh label create "priority:critical" --repo "$repo_slug" --color "B60205" \
		--description "Critical severity — security or data loss risk" --force 2>/dev/null || true
	gh label create "priority:high" --repo "$repo_slug" --color "D93F0B" \
		--description "High severity — significant quality issue" --force 2>/dev/null || true
	gh label create "priority:medium" --repo "$repo_slug" --color "FBCA04" \
		--description "Medium severity — moderate quality issue" --force 2>/dev/null || true

	# Get open quality-debt issues — extract number, title, and whether
	# a priority label already exists, in a single jq pass
	local issues_to_label
	issues_to_label=$(gh issue list --repo "$repo_slug" \
		--label "quality-debt" --state open --limit 500 \
		--json number,title,labels \
		--jq '.[] | select([.labels[].name] | any(startswith("priority:")) | not) | "\(.number)|\(.title)"' \
		2>/dev/null || echo "")

	[[ -z "$issues_to_label" ]] && return 0

	local labelled_count=0

	while IFS='|' read -r issue_num title; do
		[[ -z "$issue_num" ]] && continue

		# Extract severity from title: "(critical)", "(high)", "(medium)"
		local severity=""
		case "$title" in
		*"(critical)"*) severity="critical" ;;
		*"(high)"*) severity="high" ;;
		*"(medium)"*) severity="medium" ;;
		esac

		if [[ -n "$severity" ]]; then
			gh issue edit "$issue_num" --repo "$repo_slug" \
				--add-label "priority:${severity}" 2>/dev/null || true
			labelled_count=$((labelled_count + 1))
		fi
	done <<<"$issues_to_label"

	[[ "$labelled_count" -gt 0 ]] && echo "  Added priority labels to ${labelled_count} quality-debt issues" >&2
	return 0
}

#######################################
# Create GitHub issues for quality-debt findings
#
# Groups findings by file, creates one issue per file (or per PR
# if findings span many files). Labels with "quality-debt" and
# the severity level.
#
# Arguments:
#   $1 - repo slug
#   $2 - PR number
#   $3 - JSON array of findings
# Output: number of issues created (integer) to stdout
# Returns: 0 on success
#######################################
_create_quality_debt_issues() {
	local repo_slug="$1"
	local pr_num="$2"
	local findings="$3"

	local finding_count
	finding_count=$(echo "$findings" | jq 'length' 2>/dev/null || echo "0")

	if [[ "$finding_count" -eq 0 ]]; then
		echo "0"
		return 0
	fi

	# Ensure labels exist (quality-debt + priority labels for dispatch ordering, t1413)
	gh label create "quality-debt" --repo "$repo_slug" --color "D93F0B" \
		--description "Unactioned review feedback from merged PRs" --force 2>/dev/null || true
	gh label create "priority:critical" --repo "$repo_slug" --color "B60205" \
		--description "Critical severity — security or data loss risk" --force 2>/dev/null || true
	gh label create "priority:high" --repo "$repo_slug" --color "D93F0B" \
		--description "High severity — significant quality issue" --force 2>/dev/null || true
	gh label create "priority:medium" --repo "$repo_slug" --color "FBCA04" \
		--description "Medium severity — moderate quality issue" --force 2>/dev/null || true

	# Check existing quality-debt issues to avoid duplicates.
	# Fetch both title and number so we can append to existing file-level issues (t1411).
	local existing_issues_json
	existing_issues_json=$(gh issue list --repo "$repo_slug" \
		--label "quality-debt" --state open --limit 1000 \
		--json title,number || echo "[]")

	# Group findings by file (null files grouped as "general")
	local files
	files=$(echo "$findings" | jq -r '[.[].file // "general"] | unique | .[]')

	local created=0

	while IFS= read -r file; do
		[[ -z "$file" ]] && continue

		# Get findings for this file
		local file_findings
		if [[ "$file" == "general" ]]; then
			file_findings=$(echo "$findings" | jq '[.[] | select(.file == null)]')
		else
			file_findings=$(echo "$findings" | jq --arg f "$file" '[.[] | select(.file == $f)]')
		fi

		local file_finding_count
		file_finding_count=$(echo "$file_findings" | jq 'length')
		[[ "$file_finding_count" -eq 0 ]] && continue

		# Get highest severity for this file
		local max_severity
		max_severity=$(echo "$file_findings" | jq -r '
			[.[].severity] |
			if any(. == "critical") then "critical"
			elif any(. == "high") then "high"
			elif any(. == "medium") then "medium"
			else "low"
			end
		')

		# Build issue title
		local issue_title
		if [[ "$file" == "general" ]]; then
			issue_title="quality-debt: PR #${pr_num} review feedback (${max_severity})"
		else
			issue_title="quality-debt: ${file} — PR #${pr_num} review feedback (${max_severity})"
		fi

		# Build finding details (shared between new issue and comment append)
		local reviewers
		reviewers=$(echo "$file_findings" | jq -r '[.[].reviewer] | unique | join(", ")')

		local finding_details
		finding_details=$(echo "$file_findings" | jq -r '.[] |
			"### \(.severity | ascii_upcase): \(.reviewer) (\(.reviewer_login))\n" +
			(if .file != null and .line != null then "**File**: `\(.file):\(.line)`\n" else "" end) +
			"\(.body_full)\n\n" +
			(if .url != null then "[View comment](\(.url))\n" else "" end) +
			"---\n"
		')

		# Skip if exact duplicate (same PR + file combination)
		local exact_title_match
		exact_title_match=$(echo "$existing_issues_json" | jq -r --arg t "$issue_title" \
			'.[] | select(.title == $t) | .number' | head -1 || echo "")
		if [[ -n "$exact_title_match" ]]; then
			echo "  Skipping duplicate: ${issue_title}" >&2
			continue
		fi

		# Cross-PR file dedup (t1411): check if there's an existing open
		# quality-debt issue for the same FILE from a different PR. If so,
		# append findings as a comment instead of creating a new issue.
		# This batches all outstanding feedback for a file into one issue,
		# saving worker sessions (one worker fixes all feedback for a file).
		local existing_file_issue=""
		if [[ "$file" != "general" ]]; then
			existing_file_issue=$(echo "$existing_issues_json" | jq -r --arg f "$file" \
				'[.[] | select(.title | startswith("quality-debt: \($f) —"))] | .[0].number // empty' ||
				echo "")
		fi

		if [[ -n "$existing_file_issue" ]]; then
			# Append findings as a comment on the existing issue
			local comment_body="## Additional Review Feedback (PR #${pr_num})

**Reviewers**: ${reviewers}
**Findings**: ${file_finding_count}
**Max severity**: ${max_severity}

---

${finding_details}

---
_Appended by \`quality-feedback-helper.sh scan-merged\` (cross-PR file dedup, t1411)._"

			gh issue comment "$existing_file_issue" --repo "$repo_slug" \
				--body "$comment_body" >/dev/null || true
			echo "  Appended to existing #${existing_file_issue} for ${file} (PR #${pr_num})" >&2
			created=$((created + 1))
			continue
		fi

		# No existing issue for this file — create a new one
		local issue_body
		issue_body="## Unactioned Review Feedback

**Source PR**: #${pr_num}
**File**: \`${file}\`
**Reviewers**: ${reviewers}
**Findings**: ${file_finding_count}
**Max severity**: ${max_severity}

---

${finding_details}

---
_Auto-generated by \`quality-feedback-helper.sh scan-merged\`. Review each finding and either fix the code or dismiss with a reason._"

		# Map severity to priority label for dispatch ordering (t1413)
		local priority_label=""
		case "$max_severity" in
		critical) priority_label="priority:critical" ;;
		high) priority_label="priority:high" ;;
		medium) priority_label="priority:medium" ;;
		*) priority_label="" ;;
		esac

		# Create the issue with severity-based priority label
		local label_args="quality-debt"
		[[ -n "$priority_label" ]] && label_args="${label_args},${priority_label}"

		local new_issue
		new_issue=$(gh issue create --repo "$repo_slug" \
			--title "$issue_title" \
			--body "$issue_body" \
			--label "$label_args" | grep -oE '[0-9]+$' || echo "")

		if [[ -n "$new_issue" ]]; then
			echo "  Created issue #${new_issue}: ${issue_title}" >&2
			created=$((created + 1))
		fi
	done <<<"$files"

	echo "$created"
	return 0
}

# Show help
show_help() {
	cat <<'EOF'
Quality Feedback Helper - Retrieve code quality feedback via GitHub API

Usage: quality-feedback-helper.sh [command] [options]

Commands:
  status         Show status of all quality checks
  failed         Show only failed checks with details
  annotations    Get line-level annotations from all check runs
  codacy         Get Codacy-specific feedback
  coderabbit     Get CodeRabbit review comments
  sonar          Get SonarCloud feedback
  watch          Watch for check completion (polls every 30s)
  scan-merged    Scan merged PRs for unactioned review feedback
  help           Show this help message

Options:
  --pr NUMBER    Specify PR number (otherwise uses current commit)
  --commit SHA   Specify commit SHA (otherwise uses HEAD)

scan-merged options:
  --repo SLUG       Repository slug (owner/repo). Default: auto-detect.
  --batch N         Max PRs to scan per run (default: 20)
  --create-issues   Create GitHub issues for findings (label: quality-debt)
  --min-severity    Minimum severity: critical|high|medium (default: medium)
  --json            Output findings as JSON
  --backfill        Scan ALL merged PRs (paginated), not just recent ones.
                    Processes in batches with rate limiting. Saves progress
                    incrementally so interrupted runs can resume.
  --tag-actioned    Label scanned PRs as "code-reviews-actioned" when all
                    quality-debt issues for that PR are closed (or none exist).

Examples:
  quality-feedback-helper.sh status
  quality-feedback-helper.sh failed --pr 4
  quality-feedback-helper.sh annotations
  quality-feedback-helper.sh coderabbit --pr 4
  quality-feedback-helper.sh watch --pr 4
  quality-feedback-helper.sh scan-merged --repo owner/repo --batch 20
  quality-feedback-helper.sh scan-merged --repo owner/repo --create-issues
  quality-feedback-helper.sh scan-merged --repo owner/repo --backfill --create-issues --tag-actioned

Requirements:
  - GitHub CLI (gh) installed and authenticated
  - jq for JSON parsing
  - Inside a Git repository linked to GitHub
EOF
	return 0
}

# Parse arguments
main() {
	local command="${1:-status}"
	shift || true

	# scan-merged handles its own flags — pass remaining args through
	if [[ "$command" == "scan-merged" ]]; then
		cmd_scan_merged "$@"
		return $?
	fi

	local pr_number=""
	local commit_sha=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pr)
			pr_number="${2:-}"
			shift 2
			;;
		--commit)
			commit_sha="${2:-}"
			shift 2
			;;
		--help | -h)
			show_help
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			show_help
			exit 1
			;;
		esac
	done

	# If commit SHA provided, use it directly
	if [[ -n "$commit_sha" ]]; then
		get_sha() {
			echo "$commit_sha"
			return 0
		}
	fi

	case "$command" in
	status)
		cmd_status "$pr_number"
		;;
	failed)
		cmd_failed "$pr_number"
		;;
	annotations)
		cmd_annotations "$pr_number"
		;;
	codacy)
		cmd_codacy "$pr_number"
		;;
	coderabbit)
		cmd_coderabbit "$pr_number"
		;;
	sonar)
		cmd_sonar "$pr_number"
		;;
	watch)
		cmd_watch "$pr_number"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		echo "$ERROR_UNKNOWN_COMMAND $command" >&2
		show_help
		exit 1
		;;
	esac
	return 0
}

main "$@"
