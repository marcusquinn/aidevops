#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Verify Runtime -- verifier route for runtime-pending PRs (GH#39639)
# =============================================================================
# A runtime-pending PR (GH#39558) opens under hold-for-review because its runner
# could not exercise the change. Rerunning commit-and-pr only continues a PR for
# its author, so a maintainer verifying a worker PR had no supported route.
# `verify-runtime` records runtime-verified evidence bound to the exact PR head
# and lifts hold-for-review only when the hold scope recorded for the current
# label application is runtime-pending alone. The hold-scope record is written
# by _apply_pr_only_hold. Evidence is recorded even when the hold is kept, so a
# maintainer reviewing a PR-only scope does not have to repeat the runtime check.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-verify-runtime.sh"
#
# Dependencies:
#   - shared-constants.sh (print_*, detect_session_origin, gh_pr_edit_safe,
#     gh_pr_comment, _gh_current_user_allows_repo_write,
#     _gh_actor_has_repo_write_authority)
#   - full-loop-helper-risk.sh (_runtime_testing_metadata_from_body,
#     _runtime_testing_merge_refusal, _runtime_evidence_is_substantive,
#     _pr_body_inputs_reserve_runtime_section)
#   - full-loop-helper-merge.sh (_flm_gh_read, _merge_resolve_repo,
#     _merge_linked_issue_numbers, _merge_linked_cross_repo_references,
#     _issue_pr_only_contract_state)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_VERIFY_RUNTIME_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_VERIFY_RUNTIME_LIB_LOADED=1

_FULL_LOOP_HOLD_SCOPE_PREFIX="<!-- aidevops:hold-scope scopes="
_FULL_LOOP_HOLD_LABEL="hold-for-review"
_FULL_LOOP_RUNTIME_PENDING_SCOPE="runtime-pending"
_FULL_LOOP_OPS_START="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->"
# A hold-scope record is the first two lines of the producer's envelope. A
# marker quoted anywhere else (an audit comment, a merge summary) is not one.
_FULL_LOOP_HOLD_SCOPE_RE='\A<!-- ops:start[^\n]*-->\n<!-- aidevops:hold-scope scopes=(?<s>[a-z,-]+) -->(\n|\z)'

# --- Hold-scope record ---

# Print the producer envelope for a hold-scope record.
_hold_scope_marker_body() {
	local pr_number="$1"
	local repo="$2"
	local tokens="$3"
	cat <<EOF
${_FULL_LOOP_OPS_START}
${_FULL_LOOP_HOLD_SCOPE_PREFIX}${tokens} -->
\`${_FULL_LOOP_HOLD_LABEL}\` scope: \`${tokens}\`. When \`${_FULL_LOOP_RUNTIME_PENDING_SCOPE}\` is the only scope, a verifier lifts the hold with \`full-loop-helper.sh verify-runtime ${pr_number} ${repo} --testing "<evidence>"\` from the exact PR head.
<!-- ops:end -->
EOF
	return 0
}

# Print when hold-for-review was last applied to the PR.
# Returns 0 found, 1 never applied, 2 lookup failed.
_hold_label_applied_at() {
	local pr_number="$1"
	local repo="$2"
	local events="" applied_at=""
	events=$(_flm_gh_read gh api "repos/${repo}/issues/${pr_number}/events" --paginate) || return 2
	applied_at=$(printf '%s' "$events" | jq -rs --arg l "$_FULL_LOOP_HOLD_LABEL" '
		[flatten[] | select(type == "object" and .event == "labeled" and (.label.name // "") == $l)
		 | .created_at | strings] | max // ""' 2>/dev/null) || return 2
	[[ -n "$applied_at" ]] || return 1
	printf '%s\n' "$applied_at"
	return 0
}

# Print the scope tokens of the newest hold-scope record that follows the
# current hold-for-review application and whose author holds repository write
# permission. Returns 0 found, 1 none recorded, 2 lookup failed.
_latest_trusted_hold_scope() {
	local pr_number="$1"
	local repo="$2"
	local comments="" markers="" association="" login="" scopes="" authority_rc=0
	local applied_at="" applied_rc=0
	#aidevops:trust-boundary GH#39639 -- a record describes only the label
	# application it follows. A record left by an earlier, lifted hold must not
	# make a later manual hold liftable.
	applied_at=$(_hold_label_applied_at "$pr_number" "$repo") || applied_rc=$?
	case "$applied_rc" in
	0) ;;
	1) return 1 ;;
	*) return 2 ;;
	esac
	comments=$(_flm_gh_read gh api "repos/${repo}/issues/${pr_number}/comments" --paginate) || return 2
	markers=$(printf '%s' "$comments" | jq -rs --arg re "$_FULL_LOOP_HOLD_SCOPE_RE" --arg since "$applied_at" '
		flatten
		| map(select(type == "object" and (.body | type) == "string" and (.created_at | type) == "string"
			and .created_at >= $since and (.body | test($re))))
		| sort_by(.created_at) | reverse | .[]
		| [(.author_association // "NONE"), (.user.login // ""), (.body | capture($re).s)] | @tsv' 2>/dev/null) || return 2
	[[ -n "$markers" ]] || return 1
	#aidevops:trust-boundary GH#39639 -- only a write-permission author's record
	# describes a hold; a forged record must not turn a manual hold into a
	# liftable one. An unresolvable newer author fails closed instead of falling
	# back to an older record.
	while IFS=$'\t' read -r association login scopes <&3; do
		# MEMBER is organization membership, which can coexist with read-only
		# repository access: confirm the effective repository permission.
		if [[ "$association" == "MEMBER" ]]; then
			association="CONTRIBUTOR"
		fi
		authority_rc=0
		_gh_actor_has_repo_write_authority "$repo" "$login" "$association" || authority_rc=$?
		case "$authority_rc" in
		0)
			printf '%s\n' "$scopes"
			return 0
			;;
		1) ;;
		*) return 2 ;;
		esac
	done 3<<<"$markers"
	return 1
}

# Record why hold-for-review was applied so a verifier can tell which holds it
# may lift. Tokens: comma-separated subset of pr-only,runtime-pending.
_record_hold_scope_marker() {
	local pr_number="$1"
	local repo="$2"
	local tokens="$3"
	local existing="" existing_rc=0 body_file="" rc=0
	[[ "$tokens" =~ ^[a-z-]+(,[a-z-]+)*$ ]] || return 1
	existing=$(_latest_trusted_hold_scope "$pr_number" "$repo") || existing_rc=$?
	if [[ "$existing_rc" -eq 0 && "$existing" == "$tokens" ]]; then
		return 0
	fi
	body_file=$(mktemp) || return 1
	_hold_scope_marker_body "$pr_number" "$repo" "$tokens" >"$body_file"
	gh_pr_comment "$pr_number" --repo "$repo" --body-file "$body_file" >/dev/null || rc=$?
	rm -f "$body_file"
	return "$rc"
}

# --- verify-runtime ---

_verify_runtime_usage() {
	printf 'Usage: full-loop-helper.sh verify-runtime <PR> [REPO] --testing "<evidence>" [--repo owner/repo] [--dry-run]\n' >&2
	return 0
}

#aidevops:trust-boundary GH#39639 -- the verifier is a person or session that
# exercised the change; workers and CI never certify runtime evidence here.
_verify_runtime_session_is_interactive() {
	local on="${_FULL_LOOP_TRUE:-true}"
	if [[ "${HEADLESS:-false}" == "$on" || "${FULL_LOOP_HEADLESS:-}" == "$on" ||
		"${AIDEVOPS_HEADLESS:-}" == "$on" || "${OPENCODE_HEADLESS:-}" == "$on" ||
		"${CLAUDE_HEADLESS:-}" == "$on" || "${GITHUB_ACTIONS:-}" == "$on" ||
		-n "${WORKER_ISSUE_NUMBER:-}" || -n "${WORKER_REPO_SLUG:-}" ]]; then
		return 1
	fi
	declare -F detect_session_origin >/dev/null 2>&1 || return 1
	[[ "$(detect_session_origin)" == "interactive" ]] || return 1
	return 0
}

# Normalize free-text evidence the way commit-and-pr does and reject text that
# would change how the body parses or what it closes. Prints trimmed evidence.
_verify_runtime_normalize_evidence() {
	local evidence="$1"
	evidence=$(printf '%s' "$evidence" | sed -E 's/^-[[:space:]]+\*\*([^*]*)\*\*/- \1/') || return 1
	evidence="${evidence#"${evidence%%[![:space:]]*}"}"
	evidence="${evidence%"${evidence##*[![:space:]]}"}"
	_pr_body_inputs_reserve_runtime_section "$evidence" || return 1
	if grep -Eiq '(^|[^[:alnum:]_])(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]+([[:alnum:]_.-]+/[[:alnum:]_.-]+)?#[0-9]+' <<<"$evidence"; then
		print_error "Runtime evidence must not contain a closing keyword reference (it would link an issue for closing)"
		return 1
	fi
	if ! _runtime_evidence_is_substantive "$evidence"; then
		print_error "Runtime evidence must describe what was exercised and observed; a bare marker or placeholder is not evidence"
		return 1
	fi
	printf '%s\n' "$evidence"
	return 0
}

# Rewrite the single generated Verification line at level VR_FROM_LEVEL. Body
# on stdin, final evidence in VR_EVIDENCE. Exits 3 unless exactly one exists.
_verify_runtime_rewrite_body() {
	PYTHONIOENCODING=utf-8 python3 -c '
import os, re, sys
body = sys.stdin.read()
evidence = os.environ["VR_EVIDENCE"]
level = os.environ["VR_FROM_LEVEL"]
if len(re.findall(r"^## Runtime Testing[ \t]*$", body, re.M)) != 1:
    sys.exit(3)
section = re.search(r"^## Runtime Testing\s*\n(.*?)(?=^## |\Z)", body, re.M | re.S)
start, end = section.span(1)
text = body[start:end]
pattern = re.compile(r"^- \*\*Verification:\*\*[ \t]+" + re.escape(level) + r"[ \t]+—[ \t]*(.*?)"
                     r"(?=^- \*\*|^(?:Resolves|Fixes|Closes|For|Ref) #\d+\b|^<!-- aidevops:|\Z)", re.M | re.S)
matches = list(pattern.finditer(text))
if len(matches) != 1:
    sys.exit(3)
m = matches[0]
span = m.group(0)
trailing = span[len(span.rstrip()):] or "\n"
line = "- **Verification:** runtime-verified — " + evidence + trailing
sys.stdout.write(body[:start] + text[:m.start()] + line + text[m.end():] + body[end:])
'
	return $?
}

# Print every issue reference that can carry a PR-only contract, one
# owner/name#N per line: closing references in any repository plus For/Ref
# and keyword references written in the body.
_verify_runtime_linked_issue_refs() {
	local pr_number="$1"
	local repo="$2"
	local pr_json="$3"
	local same="" cross="" body="" text_refs=""
	same=$(_merge_linked_issue_numbers "$pr_number" "$repo" "$pr_json") || return 1
	cross=$(_merge_linked_cross_repo_references "$pr_number" "$repo" "$pr_json") || return 1
	body=$(printf '%s' "$pr_json" | jq -r '.body // ""') || return 1
	text_refs=$(printf '%s' "$body" |
		grep -oiE '(^|[^[:alnum:]_])(close[sd]?|fix(e[sd])?|resolve[sd]?|for|ref)[[:space:]]+([[:alnum:]_.-]+/[[:alnum:]_.-]+)?#[0-9]+' |
		grep -oE '([[:alnum:]_.-]+/[[:alnum:]_.-]+)?#[0-9]+' || true)
	{
		printf '%s\n' "$same" | grep -E '^[0-9]+$' | sed "s|^|${repo}#|"
		printf '%s\n' "$cross"
		printf '%s\n' "$text_refs" | sed "s|^#|${repo}#|"
	} | grep -E '^[[:alnum:]_.-]+/[[:alnum:]_.-]+#[0-9]+$' | sort -u || true
	return 0
}

# Decide whether hold-for-review may be lifted. Prints "lift", "absent" or
# "keep\t<why>".
_verify_runtime_hold_decision() {
	local pr_number="$1"
	local repo="$2"
	local pr_json="$3"
	local refs="" ref="" state_rc=0 scopes="" scope_rc=0
	if ! printf '%s' "$pr_json" | jq -e --arg l "$_FULL_LOOP_HOLD_LABEL" 'any(.labels[]?; .name == $l)' >/dev/null 2>&1; then
		printf 'absent\n'
		return 0
	fi
	scopes=$(_latest_trusted_hold_scope "$pr_number" "$repo") || scope_rc=$?
	case "$scope_rc" in
	0) ;;
	1)
		printf 'keep\tno hold scope was recorded for the current %s application (the PR predates GH#39639 or the hold was added by hand); a maintainer removes it after review\n' "$_FULL_LOOP_HOLD_LABEL"
		return 0
		;;
	*)
		printf 'keep\tthe recorded hold scope could not be read\n'
		return 0
		;;
	esac
	if [[ "$scopes" != "$_FULL_LOOP_RUNTIME_PENDING_SCOPE" ]]; then
		printf 'keep\tthe recorded hold scope is %s, not runtime-pending alone\n' "$scopes"
		return 0
	fi
	#aidevops:trust-boundary GH#34052 -- a trusted PR-only contract on any linked
	# issue, in this or another repository, keeps the hold even when the record
	# says runtime-pending. A lookup that cannot complete keeps it too.
	refs=$(_verify_runtime_linked_issue_refs "$pr_number" "$repo" "$pr_json") || {
		printf 'keep\tlinked issues could not be verified\n'
		return 0
	}
	while IFS= read -r ref; do
		[[ -n "$ref" ]] || continue
		state_rc=0
		_issue_pr_only_contract_state "${ref##*#}" "${ref%#*}" || state_rc=$?
		case "$state_rc" in
		0)
			printf 'keep\tissue %s has a trusted PR-only completion contract\n' "$ref"
			return 0
			;;
		1) ;;
		*)
			printf 'keep\tPR-only scope for issue %s could not be verified\n' "$ref"
			return 0
			;;
		esac
	done <<<"$refs"
	printf 'lift\n'
	return 0
}

_verify_runtime_parse_args() {
	local -a args=("$@")
	local index=0 arg="" value=""
	while [[ "$index" -lt "${#args[@]}" ]]; do
		arg="${args[$index]}"
		value=""
		if [[ "$arg" == "--testing" || "$arg" == "--repo" ]]; then
			value="${args[$((index + 1))]:-}"
			# An option in the value slot means the value is missing:
			# `--testing --dry-run` must not record "--dry-run" as evidence
			# and silently skip preview mode.
			if [[ $((index + 1)) -ge ${#args[@]} || "$value" == --* ]]; then
				print_error "${arg} requires a value"
				return 1
			fi
		fi
		case "$arg" in
		--testing)
			vr_evidence="$value"
			index=$((index + 2))
			;;
		--repo)
			vr_repo="$value"
			index=$((index + 2))
			;;
		--dry-run)
			vr_dry_run=1
			index=$((index + 1))
			;;
		-*)
			print_error "Unknown verify-runtime option: $arg"
			_verify_runtime_usage
			return 1
			;;
		*)
			if [[ -z "$vr_pr" ]]; then
				vr_pr="$arg"
			elif [[ -z "$vr_repo" ]]; then
				vr_repo="$arg"
			else
				_verify_runtime_usage
				return 1
			fi
			index=$((index + 1))
			;;
		esac
	done
	if [[ ! "$vr_pr" =~ ^[1-9][0-9]*$ || -z "$vr_evidence" ]]; then
		_verify_runtime_usage
		return 1
	fi
	return 0
}

# Decide what to do with the body's current Verification line. Sets
# vr_from_level and vr_rewrite; returns 1 when there is nothing to verify.
_verify_runtime_select_level() {
	local metadata="$1"
	local level="" existing="" refusal_rc=0
	level=$(printf '%s' "$metadata" | jq -r '.level // ""')
	existing=$(printf '%s' "$metadata" | jq -r '.evidence // ""')
	vr_from_level="$level"
	vr_rewrite=1
	_runtime_testing_merge_refusal "$metadata" >/dev/null || refusal_rc=$?
	# shellcheck disable=SC2154 # initialized by full-loop-helper-risk.sh
	case "$level" in
	"$_full_loop_runtime_pending_marker") return 0 ;;
	"$_full_loop_runtime_verified_marker")
		#aidevops:trust-boundary GH#39639 -- reuse a verified line only when it is
		# this verifier's evidence for this head; evidence for another head, a
		# hand-written attribution or evidence merge refuses is re-recorded.
		if [[ "$refusal_rc" -eq 0 && "$existing" == "$vr_final_evidence" ]]; then
			vr_rewrite=0
			print_info "PR #${vr_pr} body already records this evidence for head ${vr_head:0:12}; leaving it unchanged"
			return 0
		fi
		print_info "PR #${vr_pr} body records other ${level} evidence; recording fresh evidence for head ${vr_head:0:12}"
		return 0
		;;
	self-assessed)
		# High/Critical self-assessed bodies are refused at merge until a
		# verifier records runtime evidence, so this route repairs them too.
		[[ "$refusal_rc" -ne 0 ]] && return 0
		;;
	esac
	print_error "PR #${vr_pr} does not need runtime evidence (verification level: ${level:-none}, and merge accepts it); nothing to verify"
	return 1
}

# Validate the PR, checkout and body before any write. Sets vr_head,
# vr_final_evidence, vr_new_body, vr_previous_evidence, vr_from_level and
# vr_rewrite in the caller's scope.
_verify_runtime_prepare() {
	local repo="$1"
	local pr_json="$2"
	local evidence="$3"
	local login="$4"
	local state="" cross="" local_head="" body="" metadata="" sections="" risk=""
	local new_metadata="" refusal="" parsed_evidence=""

	state=$(printf '%s' "$pr_json" | jq -r '.state // ""')
	# tostring, not `// "unknown"`: jq's alternative operator treats false as absent.
	cross=$(printf '%s' "$pr_json" | jq -r '.isCrossRepository | tostring')
	vr_head=$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""')
	if [[ "$state" != "OPEN" ]]; then
		print_error "PR #${vr_pr} is ${state:-unreadable}; verify-runtime only records evidence on an open PR"
		return 1
	fi
	if [[ "$cross" != "false" ]]; then
		print_error "PR #${vr_pr} head is not in ${repo}; fork heads are verified by re-publishing from a same-repo branch"
		return 1
	fi
	#aidevops:trust-boundary GH#39639 -- evidence binds to the exact tested head.
	local_head=$(git rev-parse HEAD 2>/dev/null) || local_head=""
	if [[ ! "$vr_head" =~ ^[0-9a-f]{40}$ || "$local_head" != "$vr_head" ]]; then
		print_error "Local HEAD (${local_head:-none}) is not PR #${vr_pr} head (${vr_head:-unknown}); check out the exact PR head, exercise it, then rerun"
		return 1
	fi
	if ! git diff --quiet HEAD -- 2>/dev/null; then
		print_error "The checkout has uncommitted tracked changes, so the exercised tree is not the PR head; stash or commit them, then rerun"
		return 1
	fi

	body=$(printf '%s' "$pr_json" | jq -r '.body // ""')
	metadata=$(printf '%s' "$body" | _runtime_testing_metadata_from_body) || return 1
	sections=$(printf '%s' "$metadata" | jq -r '.sections // 0')
	risk=$(printf '%s' "$metadata" | jq -r '.risk // ""')
	vr_previous_evidence=$(printf '%s' "$metadata" | jq -r '.evidence // ""')
	if [[ "$sections" != "1" ]]; then
		print_error "PR #${vr_pr} body has ${sections} Runtime Testing sections; verify-runtime needs exactly the one generated section"
		return 1
	fi
	vr_final_evidence="${evidence} (verified at head ${vr_head:0:12} by @${login})"
	_verify_runtime_select_level "$metadata" || return 1
	if [[ "$vr_rewrite" -eq 0 ]]; then
		vr_new_body="$body"
		return 0
	fi

	vr_new_body=$(printf '%s' "$body" |
		VR_EVIDENCE="$vr_final_evidence" VR_FROM_LEVEL="$vr_from_level" _verify_runtime_rewrite_body) || {
		print_error "PR #${vr_pr} body has no single generated ${vr_from_level} Verification line to rewrite"
		return 1
	}
	# Re-parse with the merge-time parser: the rewritten body must be accepted
	# by the same recheck merge runs, keep its risk, and carry the evidence whole.
	new_metadata=$(printf '%s' "$vr_new_body" | _runtime_testing_metadata_from_body) || return 1
	parsed_evidence=$(printf '%s' "$new_metadata" | jq -r '.evidence // ""')
	if [[ "$(printf '%s' "$new_metadata" | jq -r '.level // ""')" != "$_full_loop_runtime_verified_marker" ||
		"$(printf '%s' "$new_metadata" | jq -r '.risk // ""')" != "$risk" ||
		"$parsed_evidence" != "$vr_final_evidence" ]]; then
		print_error "The rewritten body does not parse back to the supplied evidence; remove markdown headings, bullets or markers from --testing"
		return 1
	fi
	if ! refusal=$(_runtime_testing_merge_refusal "$new_metadata"); then
		print_error "The rewritten body would still be refused at merge: ${refusal}"
		return 1
	fi
	return 0
}

# Comparable form of a PR body: CRs and the signature/origin footer lines the
# write wrapper may add or re-place are ignored; any other difference counts.
_verify_runtime_body_key() {
	local body="$1"
	printf '%s\n' "$body" | tr -d '\r' |
		grep -Ev '^<!-- aidevops:(sig|origin:[a-z-]+) -->$' || true
	return 0
}

_verify_runtime_put_body() {
	local repo="$1"
	local body="$2"
	local body_file="" rc=0
	body_file=$(mktemp) || return 1
	printf '%s\n' "$body" >"$body_file"
	gh_pr_edit_safe "$vr_pr" --repo "$repo" --body-file "$body_file" >/dev/null || rc=$?
	rm -f "$body_file"
	return "$rc"
}

# Write the body only over the snapshot it was built from, then verify the
# observed body is the one written, still passes the merge recheck, and sits
# on the same head. A moved head restores the previous body only while the
# observed body is still this write; another edit is reported, never replaced.
_verify_runtime_write_body() {
	local repo="$1"
	local original_body="$2"
	local live_json="" after_json="" after_head="" after_body="" after_metadata="" refusal=""
	#aidevops:trust-boundary GH#39639 -- never overwrite an edit made after the read.
	live_json=$(_flm_gh_read gh pr view "$vr_pr" --repo "$repo" --json headRefOid,body) || {
		print_error "Could not re-read PR #${vr_pr} before writing; nothing was changed"
		return 1
	}
	if [[ "$(_verify_runtime_body_key "$(printf '%s' "$live_json" | jq -r '.body // ""')")" != "$(_verify_runtime_body_key "$original_body")" ]]; then
		print_error "PR #${vr_pr} body changed after it was read; nothing was written. Rerun verify-runtime against the current body"
		return 1
	fi
	if ! _verify_runtime_put_body "$repo" "$vr_new_body"; then
		print_error "Could not update PR #${vr_pr} body; nothing else was changed"
		return 1
	fi
	after_json=$(_flm_gh_read gh pr view "$vr_pr" --repo "$repo" --json headRefOid,body) || after_json=""
	after_head=$(printf '%s' "$after_json" | jq -r '.headRefOid // ""' 2>/dev/null) || after_head=""
	after_body=$(printf '%s' "$after_json" | jq -r '.body // ""' 2>/dev/null) || after_body=""
	if [[ -z "$after_json" || "$(_verify_runtime_body_key "$after_body")" != "$(_verify_runtime_body_key "$vr_new_body")" ]]; then
		print_error "PR #${vr_pr} body is unreadable or differs from the verified body just written (a concurrent edit?); ${_FULL_LOOP_HOLD_LABEL} is unchanged and the body was not restored. Review the body, then rerun verify-runtime"
		return 1
	fi
	if [[ "$after_head" != "$vr_head" ]]; then
		print_error "PR #${vr_pr} head moved during verification (${vr_head:0:12} -> ${after_head:-unknown}); restoring the previous body"
		_verify_runtime_put_body "$repo" "$original_body" ||
			print_error "Restore failed: PR #${vr_pr} body claims evidence for a superseded head; set its Verification line back to ${vr_from_level}"
		return 1
	fi
	after_metadata=$(printf '%s' "$after_body" | _runtime_testing_metadata_from_body) || after_metadata=""
	if ! refusal=$(_runtime_testing_merge_refusal "$after_metadata") ||
		[[ "$(printf '%s' "$after_metadata" | jq -r '.evidence // ""' 2>/dev/null)" != "$vr_final_evidence" ]]; then
		print_error "PR #${vr_pr} body did not reach the ${_full_loop_runtime_verified_marker} postcondition (${refusal:-evidence mismatch}); ${_FULL_LOOP_HOLD_LABEL} is unchanged"
		return 1
	fi
	return 0
}

# Re-read the PR and rerun the hold decision immediately before removing the
# label; after removal, reapply it if the head moved. The removal call itself
# is not conditional on the head, so this narrows the window, not closes it.
_verify_runtime_lift_hold() {
	local repo="$1"
	local fresh_json="" fresh_head="" decision="" labels="" after_head=""
	fresh_json=$(_flm_gh_read gh pr view "$vr_pr" --repo "$repo" \
		--json state,isCrossRepository,headRefOid,body,labels,closingIssuesReferences) || fresh_json=""
	fresh_head=$(printf '%s' "$fresh_json" | jq -r '.headRefOid // ""' 2>/dev/null) || fresh_head=""
	#aidevops:trust-boundary GH#39639 -- the hold is lifted only for the verified head.
	if [[ "$fresh_head" != "$vr_head" ]]; then
		print_error "PR #${vr_pr} head is ${fresh_head:-unreadable}, not the verified ${vr_head:0:12}; ${_FULL_LOOP_HOLD_LABEL} kept"
		return 1
	fi
	decision=$(_verify_runtime_hold_decision "$vr_pr" "$repo" "$fresh_json") || decision=""
	case "$decision" in
	lift) ;;
	absent)
		print_info "${_FULL_LOOP_HOLD_LABEL} was already removed from PR #${vr_pr}"
		return 0
		;;
	*)
		print_error "The hold decision changed before removal (${decision#*$'\t'}); ${_FULL_LOOP_HOLD_LABEL} kept"
		return 1
		;;
	esac
	if ! gh_pr_edit_safe "$vr_pr" --repo "$repo" --remove-label "$_FULL_LOOP_HOLD_LABEL" >/dev/null; then
		print_error "Could not remove ${_FULL_LOOP_HOLD_LABEL} from PR #${vr_pr}; the body is verified, so rerunning verify-runtime retries the label only"
		return 1
	fi
	after_head=$(_flm_gh_read gh pr view "$vr_pr" --repo "$repo" --json headRefOid --jq '.headRefOid') || after_head=""
	if [[ "$after_head" != "$vr_head" ]]; then
		print_error "PR #${vr_pr} head moved (${after_head:-unreadable}) while ${_FULL_LOOP_HOLD_LABEL} was removed; reapplying it"
		if gh_pr_edit_safe "$vr_pr" --repo "$repo" --add-label "$_FULL_LOOP_HOLD_LABEL" >/dev/null; then
			_record_hold_scope_marker "$vr_pr" "$repo" "$_FULL_LOOP_RUNTIME_PENDING_SCOPE" ||
				print_warning "PR #${vr_pr} hold scope was not re-recorded; verify-runtime will keep the hold for a maintainer"
		else
			print_error "Reapply failed: add ${_FULL_LOOP_HOLD_LABEL} to PR #${vr_pr} before any merge"
		fi
		return 1
	fi
	labels=$(_flm_gh_read gh pr view "$vr_pr" --repo "$repo" --json labels --jq '[.labels[].name] | join(",")') || labels="unreadable"
	if [[ ",${labels}," == *",${_FULL_LOOP_HOLD_LABEL},"* || "$labels" == "unreadable" ]]; then
		print_error "PR #${vr_pr} did not reach the label-removed postcondition; rerun verify-runtime"
		return 1
	fi
	return 0
}

_verify_runtime_audit_comment() {
	local repo="$1"
	local login="$2"
	local evidence="$3"
	local hold_line="$4"
	local body_file="" rc=0
	body_file=$(mktemp) || return 1
	cat >"$body_file" <<EOF
${_FULL_LOOP_OPS_START}
<!-- aidevops:verify-runtime head=${vr_head} -->
**Runtime verified** by @${login} at head \`${vr_head}\` (\`full-loop-helper.sh verify-runtime\`, GH#39639).

- Evidence: ${evidence}
- Previous ${vr_from_level:-verification} evidence: ${vr_previous_evidence:-not recorded}
- Hold: ${hold_line}
<!-- ops:end -->
EOF
	gh_pr_comment "$vr_pr" --repo "$repo" --body-file "$body_file" >/dev/null || rc=$?
	rm -f "$body_file"
	return "$rc"
}

# runtime-pending-notice <PR> [REPO]
# Read-only (t19241/GH#39645). Pulse routes a held runtime-pending PR to a live
# interactive verifier. Prints one JSON object {pr, repo, head, held_since,
# reason, command} and exits 0 only when the PR is open, carries a hold whose
# recorded scope is runtime-pending alone with no PR-only contract (decision
# "lift"), and its body declares runtime-pending or runtime-verified evidence.
# GH#39795: the recorded hold scope, not the body level, decides liftability;
# an author who later rewrites the body to runtime-verified still needs a
# verifier, and verify-runtime accepts that body. Exits 1 with no output
# otherwise, so a caller never notifies for a hold a verifier cannot lift.
cmd_runtime_pending_notice() {
	local pr="${1:-}" repo_arg="${2:-}"
	local repo="" pr_json="" metadata="" level="" reason="" head="" held_since="" command=""
	local hold_decision
	[[ "$pr" =~ ^[1-9][0-9]*$ ]] || return 1
	repo=$(_merge_resolve_repo "$repo_arg") || return 1
	pr_json=$(_flm_gh_read gh pr view "$pr" --repo "$repo" \
		--json state,headRefOid,body,labels,closingIssuesReferences) || return 1
	printf '%s' "$pr_json" | jq -e '.state == "OPEN"' >/dev/null 2>&1 || return 1
	hold_decision=$(_verify_runtime_hold_decision "$pr" "$repo" "$pr_json") || return 1
	[[ "$hold_decision" == "lift" ]] || return 1
	metadata=$(printf '%s' "$pr_json" | jq -r '.body // ""' | _runtime_testing_metadata_from_body) || return 1
	level=$(printf '%s' "$metadata" | jq -r '.level // ""') || return 1
	# shellcheck disable=SC2154 # initialized by full-loop-helper-risk.sh
	case "$level" in
	"$_FULL_LOOP_RUNTIME_PENDING_SCOPE" | "$_full_loop_runtime_verified_marker") ;;
	*) return 1 ;;
	esac
	reason=$(printf '%s' "$metadata" | jq -r '.evidence // ""') || return 1
	head=$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""') || return 1
	[[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
	held_since=$(_hold_label_applied_at "$pr" "$repo") || held_since=""
	command="full-loop-helper.sh verify-runtime ${pr} ${repo} --testing \"<evidence>\""
	jq -nc --argjson pr "$pr" --arg repo "$repo" --arg head "$head" --arg since "$held_since" \
		--arg reason "$reason" --arg command "$command" \
		'{pr: $pr, repo: $repo, head: $head, held_since: $since, reason: $reason, command: $command}'
	return 0
}

# verify-runtime <PR> [REPO] --testing "<evidence>" [--repo R] [--dry-run]
# Exit 0 on recorded evidence (VERIFY_RUNTIME_HOLD=lifted|keep|absent on
# stdout); 1 on refusal or failed write. Every refusal precedes every write.
cmd_verify_runtime() {
	local vr_pr="" vr_repo="" vr_evidence="" vr_dry_run=0
	local vr_head="" vr_new_body="" vr_previous_evidence="" vr_rewrite=0
	local vr_from_level="" vr_final_evidence=""
	local repo="" evidence="" login="" pr_json="" decision="" hold_action="" hold_reason="" hold_line=""
	# Mutation-sensitive reads: never answer a head or body recheck from cache.
	local -x AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1

	_verify_runtime_parse_args "$@" || return 1
	if ! _verify_runtime_session_is_interactive; then
		print_error "verify-runtime is restricted to interactive maintainer sessions; workers hand runtime-pending PRs off with POST_PR_HANDOFF"
		return 1
	fi
	repo=$(_merge_resolve_repo "$vr_repo") || return 1
	evidence=$(_verify_runtime_normalize_evidence "$vr_evidence") || return 1
	#aidevops:trust-boundary GH#39639 -- authenticated write permission, never
	# login text, authorizes a verifier; any author's PR is then eligible.
	if ! declare -F _gh_current_user_allows_repo_write >/dev/null 2>&1 ||
		! _gh_current_user_allows_repo_write "$repo"; then
		print_error "verify-runtime requires write, maintain or admin permission on ${repo} (${AIDEVOPS_GH_WRITE_PERMISSION_REASON:-unknown})"
		return 1
	fi
	login="${AIDEVOPS_GH_WRITE_PERMISSION_USER:-}"
	[[ -n "$login" ]] || { print_error "Could not resolve the verifier login"; return 1; }

	pr_json=$(_flm_gh_read gh pr view "$vr_pr" --repo "$repo" \
		--json state,isCrossRepository,headRefOid,author,body,labels,closingIssuesReferences) || {
		print_error "Could not read PR #${vr_pr} in ${repo}"
		return 1
	}
	_verify_runtime_prepare "$repo" "$pr_json" "$evidence" "$login" || return 1

	decision=$(_verify_runtime_hold_decision "$vr_pr" "$repo" "$pr_json") || return 1
	hold_action="${decision%%$'\t'*}"
	[[ "$decision" == *$'\t'* ]] && hold_reason="${decision#*$'\t'}"
	case "$hold_action" in
	lift) hold_line="${_FULL_LOOP_HOLD_LABEL} removed (recorded scope: runtime-pending only)" ;;
	absent) hold_line="no ${_FULL_LOOP_HOLD_LABEL} label present" ;;
	*)
		hold_action="keep"
		hold_line="${_FULL_LOOP_HOLD_LABEL} kept: ${hold_reason:-scope not verified}"
		;;
	esac

	if [[ "$vr_dry_run" -eq 1 ]]; then
		print_info "Dry run for PR #${vr_pr} at head ${vr_head:0:12}, verifier @${login}"
		if [[ "$vr_rewrite" -eq 1 ]]; then
			printf -- '- **Verification:** %s — %s\n+ %s\n' "$vr_from_level" "$vr_previous_evidence" \
				"$(printf '%s' "$vr_new_body" | _runtime_testing_metadata_from_body |
					jq -r '"- **Verification:** " + .level + " — " + .evidence')"
		fi
		printf 'VERIFY_RUNTIME_HOLD=%s (%s)\n' "$hold_action" "$hold_line"
		return 0
	fi

	# A kept hold still records the evidence: the maintainer reviewing the
	# remaining scope then does not repeat the runtime check (GH#39639).
	if [[ "$vr_rewrite" -eq 1 ]]; then
		_verify_runtime_write_body "$repo" "$(printf '%s' "$pr_json" | jq -r '.body // ""')" || return 1
	fi
	if [[ "$hold_action" == "lift" ]]; then
		_verify_runtime_lift_hold "$repo" || return 1
		hold_action="lifted"
	fi
	if [[ "$vr_rewrite" -eq 1 || "$hold_action" == "lifted" ]]; then
		_verify_runtime_audit_comment "$repo" "$login" "$evidence" "$hold_line" ||
			print_warning "Audit comment for PR #${vr_pr} was not posted; the body still records the verified head and verifier"
	fi
	print_success "PR #${vr_pr} runtime-verified at head ${vr_head:0:12} by @${login}; ${hold_line}"
	printf 'VERIFY_RUNTIME_HOLD=%s\n' "$hold_action"
	return 0
}
