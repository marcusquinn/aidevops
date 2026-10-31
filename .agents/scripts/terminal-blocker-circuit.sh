#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Durable, cross-runner suppression for unchanged terminal worker blockers.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_TERMINAL_BLOCKER_CIRCUIT_LOADED:-}" ]] && return 0
_TERMINAL_BLOCKER_CIRCUIT_LOADED=1

# shellcheck source=terminal-blocker-github.sh
source "${BASH_SOURCE[0]%/*}/terminal-blocker-github.sh"

_TBC_OBSERVATION_MARKER='aidevops:terminal-blocker-observation'
_TBC_CIRCUIT_MARKER='aidevops:terminal-blocker-circuit'
_TBC_RETRY_MARKER='terminal-blocker-circuit:retry'
_TBC_FLEET_MARKER='aidevops:fleet-capability fingerprint='
_TBC_MISSING_SCOPE='missing_files_scope'
_TBC_UNKNOWN='unknown'
_TBC_RUNNER_CAPABILITY='runner_capability_unmet'
# GH#34223: workers report an unchanged external source denial (for example
# repeated HTTP 401 security verification) with this producer marker. It is a
# supported class so the denial cannot normalize to unknown and redispatch.
_TBC_SOURCE_ACCESS='source_access_blocked'
_TBC_RUNNER_RECOVERY_OWNER='runner-recovery'
_TBC_AUTHORITATIVE_ASSOCIATIONS='["OWNER","MEMBER"]'
# GH#34846: classes whose first-observation hold re-arms on a changed task
# revision or a trusted retry. Most track only the brief (plus linked
# dependencies), never default-branch HEAD, so unrelated merges cannot churn
# them. GH#35095: target_code_blocker is the deliberate exception: its task
# revision includes the default-branch HEAD, so any target-code change re-arms
# it (any-merge granularity was chosen over a narrower signal because the
# defect lives in code outside the brief and no linked-fix marker is reliable).
# GH#35745: unknown is held as status:blocked too (_hrff_blocked_exit_holds), so
# it needs the same wake conditions: a brief/dependency revision (its documented
# repair path) or a trusted retry. Without them the hold never released.
_TBC_REVISION_REARM_REASONS=' missing_files_scope files_scope_excluded input_required external_trigger_pending source_access_blocked target_code_blocker unknown '
# GH#35925: these first-observation holds require scheduling consent, never a
# revision change. Include legacy timeout observations without changing their hash.
_TBC_RETRY_ONLY_REARM_REASONS=' permission_required push_policy_timeout network_policy_timeout '
# GH#36232: a permission_required hold without a published permission request
# gives the maintainer nothing to approve. It re-arms once per backoff window,
# which mirrors the zero-attempt window (ZERO_OUTPUT_HOLD_WINDOW_SECONDS,
# GH#36214). worker-permission-helper.sh owns the request/decision markers.
_TBC_PERMISSION_REQUIRED='permission_required'
_TBC_PERMISSION_WINDOW_DEFAULT=43200
_TBC_PERMISSION_LABEL='needs-maintainer-permissions'
_TBC_PERMISSION_REQUEST_MARKER='<!-- aidevops-permission-request -->'
_TBC_PERMISSION_GRANT_MARKER='<!-- aidevops-signed-permission-grant -->'
_TBC_PERMISSION_WITHDRAWAL_MARKER='<!-- aidevops-signed-permission-withdrawal -->'

# IDs break same-second ties only when both are positive, exact JSON integers.
# Legacy/malformed IDs never let a tied retry clear evidence. For selection,
# unknown marker IDs sort last (conservative hold), unknown retry IDs first.
# shellcheck disable=SC2016 # Shared jq definitions, not shell expansions.
_TBC_ORDER_JQ='
def comment_id:
  .id | if type == "number" then
    if . > 0 and . <= 9007199254740991 and floor == . then . else null end
  else null end;
def valid_time: try (.created_at | fromdateiso8601 | . > 0) catch false;
def retry_after($event):
  . as $retry | ($retry.created_at // "") as $at
  | ($event.created_at // "") as $before
  | ($retry | valid_time) and ($event | valid_time) and
    ($at > $before or ($at == $before and
      ($retry | comment_id) != null and ($event | comment_id) != null and
      ($retry | comment_id) > ($event | comment_id)));
'

# GH#33025 #aidevops:trust-boundary — hold evidence (observations, circuits,
# blocked releases) may also come from this runner's own authenticated login
# whatever association GitHub reports, including CONTRIBUTOR/NONE on app-routed
# or private-org reads (GH#35090, GH#35569). Otherwise its circuit never opens and identical
# blockers redispatch forever. This only strengthens holds: other
# collaborators stay ignored, and clearing a hold (retry) remains OWNER/MEMBER.
# shellcheck disable=SC2016 # Shared jq definitions, not shell expansions.
_TBC_HOLD_EVIDENCE_JQ='
def authoritative_author($authoritative):
  .author_association as $a | $authoritative | index($a) != null;
def hold_evidence($authoritative; $self):
  authoritative_author($authoritative)
  or ($self != "" and ((.author // .user.login // "") == $self));
def hold_shaped:
  (.body // "") | test("(?m)^CLAIM_RELEASED reason=blocked |aidevops:terminal-blocker-(observation|circuit) ");
'

# A dispatch claim supersedes earlier blocked attempts, never later lease noise.
# Reuse hold_shaped so audit and both unblockers share the producer vocabulary.
terminal_blocker_has_current_hold() {
	local comments_json="$1"
	local self_login=""
	self_login=$(_terminal_blocker_self_login)
	jq -e --arg self "$self_login" --argjson authoritative "$_TBC_AUTHORITATIVE_ASSOCIATIONS" \
		"${_TBC_HOLD_EVIDENCE_JQ}"'
		map(select(hold_evidence($authoritative; $self)))
		| sort_by([.created_at // "", .id // 0]) | to_entries
		| ([.[] | select(.value | hold_shaped) | .key] | max // -1) as $hold
		| ([.[] | select((.value.body // "")
		    | test("(?m)^DISPATCH_CLAIM ")) | .key] | max // -1) as $claim
		| $hold >= 0 and $hold > $claim
	' <<<"$comments_json" >/dev/null 2>&1
	return $?
}

# Callers set TERMINAL_BLOCKER_SELF_LOGIN to the login that posts this runner's
# releases. Anything that is not a plain GitHub user login is ignored.
_terminal_blocker_self_login() {
	local login="${TERMINAL_BLOCKER_SELF_LOGIN:-}"
	[[ "$login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]] || login=""
	printf '%s' "$login"
	return 0
}

# Emit one stderr diagnostic when hold-shaped comments were dropped for trust
# reasons, so an inert circuit is visible instead of silently retrying.
_terminal_blocker_report_ignored_evidence() {
	local comments_json="$1"
	local self_login="" ignored=""
	self_login=$(_terminal_blocker_self_login)
	ignored=$(printf '%s' "$comments_json" | jq -r --arg self "$self_login" \
		--argjson authoritative "$_TBC_AUTHORITATIVE_ASSOCIATIONS" "${_TBC_HOLD_EVIDENCE_JQ}"'
		[.[]? | select(hold_shaped) | select(hold_evidence($authoritative; $self) | not)] | length
	' 2>/dev/null) || ignored=0
	[[ "$ignored" =~ ^[0-9]+$ && "$ignored" -gt 0 ]] || return 0
	printf 'TERMINAL_BLOCKER_EVIDENCE_IGNORED count=%s reason=non_authoritative_author self_login=%s\n' \
		"$ignored" "$([[ -n "$self_login" ]] && printf set || printf unset)" >&2
	return 0
}

_terminal_blocker_retry_after() {
	local retry="$1"
	local event="$2"
	[[ -n "$retry" && -n "$event" ]] || return 1
	printf '%s' "$retry" | jq -e --argjson event "$event" \
		"${_TBC_ORDER_JQ}"'retry_after($event)' >/dev/null 2>&1
	return $?
}

_terminal_blocker_hash() {
	local value="$1"
	local digest=""
	if command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$value" | shasum -a 256 2>/dev/null | cut -c1-24) || digest=""
	elif command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$value" | sha256sum 2>/dev/null | cut -c1-24) || digest=""
	fi
	[[ "$digest" =~ ^[a-f0-9]{24}$ ]] || return 1
	printf '%s\n' "$digest"
	return 0
}

# GH#33332: input_required names who must supply the missing input. Only these
# roles are public owners; the fingerprint is v2:input_required:<owner>.
_TBC_INPUT_OWNERS='user contributor maintainer admin'

# Versioned, allowlisted classes are the only public identities. Never hash prose
# into a durable hold. Models may interpret a dossier with an exact standalone
# TERMINAL_BLOCKER_REASON=<class> line; unclassified evidence remains retryable.
_terminal_blocker_reason() {
	local fingerprint="$1"
	local reason=""
	for reason in missing_files_scope files_scope_excluded target_code_blocker external_trigger_pending permission_required "$_TBC_SOURCE_ACCESS" push_policy_timeout network_policy_timeout runner_capability_unmet unknown; do
		if [[ "$fingerprint" == "$(_terminal_blocker_hash "v2:${reason}")" ]]; then
			printf '%s\n' "$reason"
			return 0
		fi
	done
	if _terminal_blocker_input_owner "$fingerprint" >/dev/null; then
		printf 'input_required\n'
		return 0
	fi
	printf 'unknown\n'
	return 0
}

# Print the input owner (user|contributor|maintainer|admin) for an
# input_required fingerprint; return 1 for every other fingerprint.
_terminal_blocker_input_owner() {
	local fingerprint="$1"
	local owner=""
	[[ "$fingerprint" =~ ^[a-f0-9]{24}$ ]] || return 1
	for owner in $_TBC_INPUT_OWNERS; do
		if [[ "$fingerprint" == "$(_terminal_blocker_hash "v2:input_required:${owner}")" ]]; then
			printf '%s\n' "$owner"
			return 0
		fi
	done
	return 1
}

# Capture only final assistant text, not tool output. A missing canonical scope
# can also be established from the current brief, without interpreting prose.
# Optional $3 is the anchored line pattern that classified the exit as BLOCKED
# (headless-runtime-model.sh). Judging the final part with that same pattern
# stops a classified exit such as "**BLOCKED — ...**" losing its evidence.
_terminal_blocker_capture_json() {
	local output_file="$1"
	local live_blocked="${2:-false}"
	local blocked_line_pattern="${3:-}"
	python3 - "$output_file" "$live_blocked" "$blocked_line_pattern" <<'PY'
import json
import re
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_text(errors="ignore")
parts = []
results = []
text_field = "text"
result_field = "result"
for raw_line in raw.splitlines():
    line = raw_line.strip()
    if not line.startswith("{"):
        continue
    try:
        event = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue
    if not isinstance(event, dict):
        continue
    # Claude CLI stream-json carries the final report in its `result` event,
    # which the classifier also reads; tool output never appears there.
    final_report = event.get(result_field)
    if event.get("type") == result_field and isinstance(final_report, str):
        results.append(final_report)
        continue
    if event.get("type") != text_field:
        continue
    part = event.get("part") if isinstance(event.get("part"), dict) else {}
    # GH#33274: runtime-injected parts are not model output.
    if part.get("synthetic") is True:
        continue
    text = event.get(text_field) or part.get(text_field) or ""
    if text:
        parts.append(text)

marker = re.compile(r"(^|\n)\s*BLOCKED(?:\s*:|\s*$)", re.IGNORECASE)
classifier = re.compile(sys.argv[3], re.MULTILINE) if sys.argv[3] else None
if parts:
    candidate = parts[-1]
elif results:
    candidate = results[-1]
else:
    candidate = raw if not raw.lstrip().startswith('{') else ''
blocked = marker.search(candidate) or (classifier is not None and classifier.search(candidate))
if not blocked and sys.argv[2] != 'true':
    raise SystemExit(1)

reasons = re.findall(r"^TERMINAL_BLOCKER_REASON=(.*)$", candidate, re.M)
allowed = {'missing_files_scope', 'files_scope_excluded', 'target_code_blocker', 'external_trigger_pending', 'permission_required', 'source_access_blocked', 'push_policy_timeout', 'network_policy_timeout', 'runner_capability_unmet'}
input_owners = {'user', 'contributor', 'maintainer', 'admin'}
reason = reasons[0] if len(reasons) == 1 else 'unknown'
def emit(value):
    # Only explicit name declarations from final assistant text, never values
    # or tool output. Bounded and validated before any public projection.
    declarations = re.findall(r'^TERMINAL_BLOCKER_MISSING_SECRETS=([A-Z0-9_, ]+)$', candidate, re.M)
    names = re.split(r'[, ]+', declarations[0]) if len(declarations) == 1 else []
    if len(names) > 32 or not all(re.fullmatch(r'[A-Z][A-Z0-9_]{0,127}', n) for n in names):
        names = []
    rejected = re.findall(r'^TERMINAL_BLOCKER_REJECTED_SECRETS=([A-Z0-9_, ]+)$', candidate, re.M)
    rejected_names = re.split(r'[, ]+', rejected[0]) if len(rejected) == 1 else []
    if (value != 'runner_capability_unmet' or len(rejected_names) > 32
            or not all(re.fullmatch(r'[A-Z][A-Z0-9_]{0,127}', n) for n in rejected_names)):
        rejected_names = []
    print(json.dumps({'reason': value, 'explicit_reason': bool(reasons),
                     'missing_secrets': sorted(set(names)),
                     'rejected_secrets': sorted(set(rejected_names)), 'detail': candidate[:2000]}))

if reason == 'verification_environment_missing_prerequisites':
    # GH#35037: exact legacy spelling, not a prose/substring classifier.
    emit('runner_capability_unmet')
elif reason == 'affected_host_reproduction_unavailable':
    # GH#34259: legacy workers named the missing affected-runner prerequisite
    # directly. Treat it as maintainer-owned input, not an unknown code blocker
    # that unrelated merges can re-arm. Use the existing fingerprint so a prior
    # input_required hold remains effective across both producer spellings.
    emit('input_required:maintainer')
elif reason == 'input_required':
    # GH#33332: the hold must name exactly one accountable role; otherwise the
    # evidence stays unclassified and retryable.
    owners = re.findall(r"^TERMINAL_BLOCKER_INPUT_OWNER=(.*)$", candidate, re.M)
    emit('input_required:' + owners[0] if len(owners) == 1 and owners[0] in input_owners else 'unknown')
else:
    emit(reason if reason in allowed else 'unknown')
PY
	return $?
}

terminal_blocker_capture_output() {
	local output_file="$1"
	local live_blocked="${2:-false}"
	local blocked_line_pattern="${3:-}"
	local normalized="" fingerprint="" issue_json="" captured=""
	AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT=""
	AIDEVOPS_TERMINAL_BLOCKER_EXPLICIT_REASON=""
	AIDEVOPS_TERMINAL_BLOCKER_MISSING_SECRETS=""
	AIDEVOPS_TERMINAL_BLOCKER_REJECTED_SECRETS=""
	[[ -f "$output_file" ]] || return 1
	captured=$(_terminal_blocker_capture_json "$output_file" "$live_blocked" "$blocked_line_pattern") || captured=""
	[[ -n "$captured" ]] || return 1
	normalized=$(printf '%s' "$captured" | jq -r '.reason') || return 1
	AIDEVOPS_TERMINAL_BLOCKER_EXPLICIT_REASON=$(printf '%s' "$captured" | jq -r '.explicit_reason') || return 1
	AIDEVOPS_TERMINAL_BLOCKER_MISSING_SECRETS=$(jq -r '.missing_secrets[]' <<<"$captured") || return 1
	AIDEVOPS_TERMINAL_BLOCKER_REJECTED_SECRETS=$(jq -r '.rejected_secrets[]' <<<"$captured") || return 1
	[[ -n "$normalized" ]] || return 1
	# Do not infer a missing heading from words such as "Files Scope excludes".
	# Verify the structural condition independently against the issue itself.
	# Access denials keep their evidenced class; a scope edit cannot grant access.
	# Verified admin/owner input and external-trigger holds likewise keep their class.
	if [[ "$normalized" != "permission_required" && "$normalized" != "$_TBC_RUNNER_CAPABILITY" &&
		"$normalized" != "$_TBC_SOURCE_ACCESS" && "$normalized" != input_required:* &&
		"$normalized" != "external_trigger_pending" && "${WORKER_ISSUE_NUMBER:-}" =~ ^[0-9]+$ &&
		"${DISPATCH_REPO_SLUG:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		issue_json=$(gh api "repos/${DISPATCH_REPO_SLUG}/issues/${WORKER_ISSUE_NUMBER}" 2>/dev/null) || issue_json=""
		if printf '%s' "$issue_json" | jq -e '.body | type == "string"' >/dev/null 2>&1 &&
			! printf '%s' "$issue_json" | jq -e '.body | test("(?m)^#{2,3} Files Scope[ \\t]*\\r?$")' >/dev/null 2>&1; then
			normalized="$_TBC_MISSING_SCOPE"
		elif [[ "$normalized" == "$_TBC_MISSING_SCOPE" ]]; then
			normalized="$_TBC_UNKNOWN"
		fi
	elif [[ "$normalized" == "$_TBC_MISSING_SCOPE" ]]; then
		normalized="$_TBC_UNKNOWN"
	fi
	fingerprint=$(_terminal_blocker_hash "v2:${normalized}") || return 1
	AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT="$fingerprint"
	_terminal_blocker_log_capture "$captured" "$normalized" "$fingerprint"
	return 0
}

_terminal_blocker_log_capture() {
	local captured="$1" normalized="$2" fingerprint="$3"
	# Retain only final-assistant classification evidence before the runtime deletes
	# its transient output. The existing logger redacts and bounds this private log.
	# This is historical evidence, not proof of a currently blocked issue.
	local logger="${BASH_SOURCE[0]%/*}/worker-blocker-log.mjs" detail=""
	detail=$(printf '%s' "$captured" | jq -r '.detail') || detail=""
	if [[ -f "$logger" ]] && command -v node >/dev/null 2>&1; then
		node "$logger" append --event terminal_blocker_captured --status observed \
			--reason "$normalized" --blocking false --source terminal-blocker-circuit \
			--blocker-fingerprint "$fingerprint" --request-id "terminal:${AIDEVOPS_ATTEMPT_ID:-$fingerprint}" \
			--detail "$detail" >/dev/null 2>&1 || true
	fi
	return 0
}

_terminal_blocker_dependency_signature() {
	local repo_slug="$1"
	local issue_number="$2"
	local owner="${repo_slug%%/*}"
	local repo_name="${repo_slug#*/}"
	local response="" signature=""
	[[ "$repo_slug" == */* && "$issue_number" =~ ^[0-9]+$ ]] || return 1
	# shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub.
	response=$(gh api graphql \
		-f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){blockedBy(first:50){nodes{number state}pageInfo{hasNextPage}}}}}' \
		-F owner="$owner" -F name="$repo_name" -F number="$issue_number" 2>/dev/null) || return 1
	signature=$(printf '%s' "$response" | jq -c '
		.data.repository.issue.blockedBy as $blocked
		| {truncated: ($blocked.pageInfo.hasNextPage // true),
		   nodes: ([($blocked.nodes // [])[] | {number, state}] | sort_by(.number))}
	' 2>/dev/null) || return 1
	[[ -n "$signature" && "$signature" != "null" ]] || return 1
	printf '%s\n' "$signature"
	return 0
}

_terminal_blocker_target_revision() {
	local repo_path="$1"
	local revision="" remote_head=""
	[[ -d "$repo_path" ]] || return 1
	remote_head=$(git -C "$repo_path" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) || remote_head=""
	if [[ -n "$remote_head" ]]; then
		revision=$(git -C "$repo_path" rev-parse "${remote_head}^{commit}" 2>/dev/null) || revision=""
	fi
	if [[ -z "$revision" ]]; then
		revision=$(git -C "$repo_path" rev-parse 'origin/main^{commit}' 2>/dev/null) || revision=""
	fi
	if [[ -z "$revision" ]]; then
		revision=$(git -C "$repo_path" rev-parse 'origin/master^{commit}' 2>/dev/null) || revision=""
	fi
	[[ "$revision" =~ ^[a-f0-9]{40,64}$ ]] || return 1
	printf '%s\n' "$revision"
	return 0
}

terminal_blocker_task_revision() {
	local issue_json="$1"
	local repo_slug="$2"
	local issue_number="$3"
	local repo_path="$4"
	local reason="${5:-}"
	local task_json="" dependency_signature="" target_revision="" canonical="" named_unknown=false
	[[ -n "$reason" ]] || reason=$(_terminal_blocker_reason "${AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT:-}")
	# GH#35745: only a named unknown class (explicit reason, or the producer's
	# exact v2:unknown fingerprint) is brief-bound. An absent or unrecognised
	# fingerprint also maps to unknown and keeps the conservative default below.
	if [[ "$reason" == "$_TBC_UNKNOWN" ]] && [[ "${5:-}" == "$_TBC_UNKNOWN" ||
		"${AIDEVOPS_TERMINAL_BLOCKER_FINGERPRINT:-}" == "$(_terminal_blocker_hash "v2:${_TBC_UNKNOWN}")" ]]; then
		named_unknown=true
	fi
	# A brief edit, unrelated merge or GraphQL outage cannot satisfy a permission
	# prerequisite. Explicit retry only schedules a new check; it grants nothing.
	if [[ "$reason" == "permission_required" ]]; then
		[[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$issue_number" =~ ^[0-9]+$ ]] || return 1
		_terminal_blocker_hash "v2:${reason}:${repo_slug}:${issue_number}"
		return $?
	fi
	task_json=$(printf '%s' "$issue_json" | jq -c '{title: (.title // ""), body: (.body // "")}' 2>/dev/null) || return 1
	# Runner-local prerequisites re-arm on a changed brief, not unrelated merges.
	if [[ "$reason" == "$_TBC_RUNNER_CAPABILITY" ]]; then
		_terminal_blocker_hash "v3:${reason}:${repo_slug}:${issue_number}:${task_json}"
		return $?
	fi
	if [[ "$reason" == "$_TBC_MISSING_SCOPE" || "$reason" == "files_scope_excluded" ]]; then
		_terminal_blocker_hash "v2:${reason}:${task_json}"
		return $?
	fi
	dependency_signature=$(_terminal_blocker_dependency_signature "$repo_slug" "$issue_number") || return 1
	# An external publication or other trigger is not changed by unrelated merges.
	# Keep dependency changes and brief corrections as independent wake conditions.
	# Missing input (GH#33332) is likewise supplied through the brief, not code.
	# A source denial (GH#34223) re-arms on verified access recorded through a
	# brief/dependency change or trusted retry, never on unrelated merges.
	# An unknown blocker (GH#35745) is repaired through the brief; tracking
	# default-branch HEAD would release its hold on every unrelated merge.
	if [[ "$reason" == "external_trigger_pending" || "$reason" == "input_required" ||
		"$reason" == "$_TBC_SOURCE_ACCESS" || "$named_unknown" == true ]]; then
		canonical=$(jq -nc --arg reason "$reason" --argjson task "$task_json" \
			--argjson dependencies "$dependency_signature" \
			'{reason: $reason, task: $task, dependencies: $dependencies}') || return 1
		_terminal_blocker_hash "$canonical"
		return $?
	fi
	target_revision=$(_terminal_blocker_target_revision "$repo_path") || return 1
	canonical=$(jq -nc --argjson task "$task_json" --argjson dependencies "$dependency_signature" \
		--arg target "$target_revision" '{task: $task, dependencies: $dependencies, target_revision: $target}') || return 1
	_terminal_blocker_hash "$canonical"
	return $?
}

# Optional $3: this runner's authenticated login. Its own comments are kept
# whatever association GitHub reports (see the observation epoch below).
terminal_blocker_fetch_trusted_comments() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="${3:-}"
	local raw=""
	[[ "$self_login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]] || self_login=""
	raw=$(terminal_blocker_fetch_comments "$repo_slug" "$issue_number") || return 1
	printf '%s' "$raw" | jq -c --arg self "$self_login" '
		def trusted: . == "OWNER" or . == "MEMBER" or . == "COLLABORATOR";
		[(if type == "array" and ((.[0]? | type) == "array") then .[] else . end)[]
		| {id: .id, author: (.user.login // ""), body: (.body // ""), created_at: .created_at,
		   author_association: (.author_association // "")}
		| select((.author_association | trusted) or ($self != "" and .author == $self))]
	' 2>/dev/null || return 1
	return 0
}

# GH#35037: return the original observation time, never a refreshed timestamp.
# aidevops:trust-boundary — only this authenticated runner's latest
# observation may suppress local dispatch; other runners remain eligible.
# GH#35090: GitHub authenticates user.login, so the runner's own comment is
# self-evidence whatever association it reports. App-routed or private-org
# reads label org members CONTRIBUTOR/NONE (GH#34598, GH#34703); requiring
# OWNER/MEMBER/COLLABORATOR here dropped the observation and the same login
# redispatched an unchanged brief every cycle. Suppression stays login-local
# and clearing it (retry) still requires OWNER/MEMBER.
terminal_blocker_runner_capability_observation_epoch() {
	local comments_json="$1" issue_json="$2" repo="$3" issue="$4"
	local self='' observation='' revision='' blocker='' retry=''
	self=$(_terminal_blocker_self_login)
	[[ -n "$self" ]] || return 1
	observation=$(jq -c --arg self "$self" --arg marker "$_TBC_OBSERVATION_MARKER revision=" "${_TBC_ORDER_JQ}"'
		[.[] | select((.author // .user.login // "") == $self)
		| select((.body // "") | contains($marker))]
		| sort_by(.created_at, (comment_id // 9007199254740992), .body) | last // empty
	' <<<"$comments_json" 2>/dev/null) || return 1
	[[ -n "$observation" ]] || return 1
	revision=$(terminal_blocker_task_revision "$issue_json" "$repo" "$issue" "" "$_TBC_RUNNER_CAPABILITY") || return 1
	blocker=$(_terminal_blocker_hash "v2:${_TBC_RUNNER_CAPABILITY}") || return 1
	retry=$(_terminal_blocker_latest_retry_comment "$comments_json") || retry=""
	_terminal_blocker_retry_after "$retry" "$observation" && return 1
	jq -er --arg self "$self" --arg marker "<!-- $_TBC_OBSERVATION_MARKER revision=${revision} blocker=${blocker} -->" '
		select((.author // .user.login // "") == $self)
		| select((.body // "") | contains($marker))
		| .created_at | fromdateiso8601 | select(. > 0)
	' <<<"$observation" 2>/dev/null
	return $?
}

_terminal_blocker_latest_marker() {
	local comments_json="$1"
	local marker="$2"
	local self_login=""
	self_login=$(_terminal_blocker_self_login)
	# aidevops:trust-boundary — a deterministic marker is not a signature.
	# OWNER/MEMBER (or this runner's own login, GH#33025) open holds; only
	# OWNER/MEMBER retry directives clear them.
	printf '%s' "$comments_json" | jq -c --arg marker "$marker" --arg self "$self_login" \
		--argjson authoritative "$_TBC_AUTHORITATIVE_ASSOCIATIONS" "${_TBC_ORDER_JQ}${_TBC_HOLD_EVIDENCE_JQ}"'
		[.[] | select(hold_evidence($authoritative; $self))
		| select((.body // "") | contains($marker))]
		| sort_by(.created_at, (comment_id // 9007199254740992), .body) | last // empty
	' 2>/dev/null
	return $?
}

_terminal_blocker_latest_retry_comment() {
	local comments_json="$1"
	# aidevops:trust-boundary — retry affects scheduling, not source authority;
	# ambiguous collaborators and quoted recovery prose cannot authorize it.
	printf '%s' "$comments_json" | jq -c --arg marker "$_TBC_RETRY_MARKER" \
		--argjson authoritative "$_TBC_AUTHORITATIVE_ASSOCIATIONS" \
		--arg circuit_marker "$_TBC_CIRCUIT_MARKER" "${_TBC_ORDER_JQ}"'
		[.[] | select(.author_association as $a | $authoritative | index($a) != null)
		| select(valid_time)
		| select((.body // "") as $body
		| ($body | test("(?m)^" + $marker + "[ \\t]*\\r?$")) and (($body | contains($circuit_marker)) | not))
		]
		| sort_by(.created_at, (comment_id // 0), .body) | last // empty
	' 2>/dev/null
	return $?
}

# Compatibility for timestamp-only callers; scheduling uses the full comment.
_terminal_blocker_latest_retry_at() {
	local comments_json="$1"
	local retry=""
	retry=$(_terminal_blocker_latest_retry_comment "$comments_json") || return 1
	printf '%s' "${retry:-null}" | jq -r '.created_at // ""'
	return $?
}

terminal_blocker_release_mode() {
	local comments_json="$1"
	local task_revision="$2"
	local blocker_fingerprint="$3"
	local retry="" circuit="" observation="" circuit_at="" observation_at=""
	# Host contention is transient, not an unchanged-code/brief hold. Preserve
	# recovery evidence without opening a durable circuit on repeated timeouts.
	local transient_reason=""
	transient_reason=$(_terminal_blocker_reason "$blocker_fingerprint")
	case "$transient_reason" in
	push_policy_timeout | network_policy_timeout | "$_TBC_RUNNER_CAPABILITY")
		printf 'first\n'
		return 0
		;;
	esac
	_terminal_blocker_report_ignored_evidence "$comments_json"
	retry=$(_terminal_blocker_latest_retry_comment "$comments_json") || retry=""
	circuit=$(_terminal_blocker_latest_marker "$comments_json" "$_TBC_CIRCUIT_MARKER revision=${task_revision} blocker=${blocker_fingerprint}") || circuit=""
	observation=$(_terminal_blocker_latest_marker "$comments_json" "$_TBC_OBSERVATION_MARKER revision=${task_revision} blocker=${blocker_fingerprint}") || observation=""
	circuit_at=$(printf '%s' "$circuit" | jq -r '.created_at // ""' 2>/dev/null) || circuit_at=""
	observation_at=$(printf '%s' "$observation" | jq -r '.created_at // ""' 2>/dev/null) || observation_at=""
	# Unknown dossiers can have one safe observation, never a durable circuit.
	# Preserve each new CLAIM_RELEASED audit event, but omit repeated explanations.
	if [[ "$(_terminal_blocker_reason "$blocker_fingerprint")" == "$_TBC_UNKNOWN" ]]; then
		if [[ -n "$observation_at" ]] && ! _terminal_blocker_retry_after "$retry" "$observation"; then
			printf 'normal\n'
		else
			printf 'first\n'
		fi
		return 0
	fi
	if [[ -n "$circuit_at" ]] && ! _terminal_blocker_retry_after "$retry" "$circuit"; then
		printf 'open\n'
	elif [[ -n "$observation_at" ]] && ! _terminal_blocker_retry_after "$retry" "$observation"; then
		printf 'circuit\n'
	else
		printf 'first\n'
	fi
	return 0
}

# Args: task_revision blocker_fingerprint [release_mode] [projected_state]
# The release path passes the label it will actually apply (GH#34846).
terminal_blocker_observation_fragment() {
	local task_revision="$1"
	local blocker_fingerprint="$2"
	local release_mode="${3:-first}"
	local projected_state="${4:-}"
	printf '\n<!-- %s revision=%s blocker=%s -->\n\n' \
		"$_TBC_OBSERVATION_MARKER" "$task_revision" "$blocker_fingerprint"
	_terminal_blocker_recovery "$blocker_fingerprint" "$release_mode" "$projected_state"
	return 0
}

# True for classes whose hold re-arms on a brief/dependency revision only.
terminal_blocker_rearms_on_revision() {
	local reason="$1"
	[[ -n "$reason" && "$_TBC_REVISION_REARM_REASONS" == *" ${reason} "* ]]
	return $?
}

# Retry authorizes scheduling only; permission and policy guards still run.
terminal_blocker_rearms_on_retry_only() {
	local reason="$1"
	[[ -n "$reason" && "$_TBC_RETRY_ONLY_REARM_REASONS" == *" ${reason} "* ]]
	return $?
}

# Both sets need recovery intake for a held first observation.
terminal_blocker_observation_recoverable() {
	local reason="$1"
	terminal_blocker_rearms_on_revision "$reason" || terminal_blocker_rearms_on_retry_only "$reason"
	return $?
}

_terminal_blocker_permission_window_seconds() {
	local window="${ZERO_OUTPUT_HOLD_WINDOW_SECONDS:-}"
	[[ "$window" =~ ^[1-9][0-9]{0,8}$ ]] || window="$_TBC_PERMISSION_WINDOW_DEFAULT"
	printf '%s\n' "$window"
	return 0
}

# GH#36232 #aidevops:trust-boundary — returns 0 while a permission request is
# published and undecided: the issue carries needs-maintainer-permissions, or
# the newest trusted worker-permission-helper.sh request has no later
# OWNER/MEMBER signed grant/withdrawal or retry directive. Returns 1 when no
# actionable request exists. Unreadable input returns 0 (fail closed: hold).
# Request evidence only strengthens a hold, so OWNER/MEMBER/COLLABORATOR or
# this runner's own login qualify; clearing evidence stays OWNER/MEMBER.
# Args: comments_json issue_json (labels optional)
terminal_blocker_permission_request_evidenced() {
	local comments_json="$1"
	local issue_json="${2:-}"
	local labelled="" request="" self_login=""
	local retry="" decided=""
	[[ -n "$issue_json" ]] || issue_json='{}'
	labelled=$(jq -r --arg label "$_TBC_PERMISSION_LABEL" '
		[(.labels // [])[]? | if type == "object" then (.name // "") else . end] | index($label) != null
	' <<<"$issue_json" 2>/dev/null) || return 0
	[[ "$labelled" == false ]] || return 0
	self_login=$(_terminal_blocker_self_login)
	request=$(jq -c --arg marker "$_TBC_PERMISSION_REQUEST_MARKER" --arg self "$self_login" \
		--argjson authoritative "$_TBC_AUTHORITATIVE_ASSOCIATIONS" "${_TBC_ORDER_JQ}"'
		[.[] | select(((.author_association // "") as $a | ($authoritative + ["COLLABORATOR"]) | index($a) != null)
			or ($self != "" and (.author // .user.login // "") == $self))
		| select(valid_time) | select((.body // "") | ltrimstr("\n") | startswith($marker))]
		| sort_by(.created_at, (comment_id // 9007199254740992), .body) | last // empty
	' <<<"$comments_json" 2>/dev/null) || return 0
	[[ -n "$request" ]] || return 1
	retry=$(_terminal_blocker_latest_retry_comment "$comments_json") || return 0
	_terminal_blocker_retry_after "$retry" "$request" && return 1
	decided=$(jq -r --argjson request "$request" --argjson authoritative "$_TBC_AUTHORITATIVE_ASSOCIATIONS" \
		--arg grant "$_TBC_PERMISSION_GRANT_MARKER" --arg withdrawal "$_TBC_PERMISSION_WITHDRAWAL_MARKER" \
		"${_TBC_ORDER_JQ}${_TBC_HOLD_EVIDENCE_JQ}"'
		([($request.body // "") | scan("perm-[0-9a-f]{16}")] | first) as $rid
		| any(.[]; authoritative_author($authoritative) and retry_after($request)
			and ((.body // "") | (contains($grant) or contains($withdrawal))
				and ($rid == null or contains($rid))))
	' <<<"$comments_json" 2>/dev/null) || return 0
	[[ "$decided" == true ]] && return 1
	return 0
}

# GH#36232 #aidevops:trust-boundary — re-arming schedules a new attempt only;
# it never grants a permission. A worker that meets the real guard again must
# publish a request (worker-permission-helper.sh request) and is then held.
# Prints the elapsed window index (>= 1) and returns 0 when an unevidenced
# permission_required hold event (observation or circuit comment) is at least
# one window old; returns 1 while it holds (inside the window, evidenced, or an
# unreadable/future event time).
# Args: comments_json issue_json evidence_comment_json
terminal_blocker_permission_window_expired() {
	local comments_json="$1"
	local issue_json="$2"
	local evidence="$3"
	local now_epoch="${TERMINAL_BLOCKER_NOW_EPOCH:-}" window="" observed="" index=0
	[[ -n "$evidence" ]] || return 1
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=$(date -u '+%s')
	terminal_blocker_permission_request_evidenced "$comments_json" "$issue_json" && return 1
	observed=$(jq -r 'try (.created_at | fromdateiso8601 | floor) catch 0' <<<"$evidence" 2>/dev/null) || return 1
	[[ "$observed" =~ ^[0-9]+$ && "$observed" -gt 0 && "$observed" -le "$now_epoch" ]] || return 1
	window=$(_terminal_blocker_permission_window_seconds)
	index=$(((now_epoch - observed) / window))
	[[ "$index" -ge 1 ]] || return 1
	printf '%s\n' "$index"
	return 0
}

# Next epoch at which the newest unevidenced permission_required hold event
# crosses a window boundary, so mechanical recovery can skip unchanged issue
# snapshots until then. Prints nothing (returns 1) when not applicable.
# Args: comments_json issue_json
terminal_blocker_permission_rearm_after() {
	local comments_json="$1"
	local issue_json="$2"
	local fingerprint="" evidence="" observation="" circuit="" observed="" window=""
	local now_epoch="${TERMINAL_BLOCKER_NOW_EPOCH:-}"
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=$(date -u '+%s')
	observation=$(_terminal_blocker_latest_marker "$comments_json" "$_TBC_OBSERVATION_MARKER revision=") || return 1
	circuit=$(_terminal_blocker_latest_marker "$comments_json" "$_TBC_CIRCUIT_MARKER revision=") || return 1
	evidence=$(jq -nc --argjson observation "${observation:-null}" --argjson circuit "${circuit:-null}" \
		"${_TBC_ORDER_JQ}"'[$observation, $circuit] | map(select(. != null))
		| sort_by(.created_at, (comment_id // 9007199254740992), .body) | last // empty' 2>/dev/null) || return 1
	[[ -n "$evidence" ]] || return 1
	fingerprint=$(jq -r '.body | capture("<!-- aidevops:terminal-blocker-(?:observation|circuit) revision=[a-f0-9]{24} blocker=(?<f>[a-f0-9]{24}) -->").f' <<<"$evidence" 2>/dev/null) || return 1
	[[ "$(_terminal_blocker_reason "$fingerprint")" == "$_TBC_PERMISSION_REQUIRED" ]] || return 1
	terminal_blocker_permission_request_evidenced "$comments_json" "$issue_json" && return 1
	observed=$(jq -r 'try (.created_at | fromdateiso8601 | floor) catch 0' <<<"$evidence" 2>/dev/null) || return 1
	[[ "$observed" =~ ^[0-9]+$ && "$observed" -gt 0 && "$observed" -le "$now_epoch" ]] || return 1
	window=$(_terminal_blocker_permission_window_seconds)
	printf '%s\n' "$((observed + ((now_epoch - observed) / window + 1) * window))"
	return 0
}

# GH#34846: a runtime-owned blocked exit projects status:blocked from the first
# observation, which has no circuit for the recovery owner to re-arm. Report
# whether the newest trusted observation still holds a recoverable class.
# Returns 0 (prints a summary) while the observed task revision is current and
# no later OWNER/MEMBER retry exists; 1 when re-armed or not applicable; 2 when
# the current revision cannot be computed (fail closed: keep the hold).
terminal_blocker_observation_hold_active() {
	local comments_json="$1"
	local issue_json="$2"
	local repo_slug="$3"
	local issue_number="$4"
	local repo_path="$5"
	local fingerprint=""
	local observation="" marker="" observed_revision="" reason="" retry="" current_revision=""
	observation=$(_terminal_blocker_latest_marker "$comments_json" "$_TBC_OBSERVATION_MARKER revision=") || observation=""
	[[ -n "$observation" ]] || return 1
	marker=$(printf '%s' "$observation" | jq -r --arg marker "$_TBC_OBSERVATION_MARKER" '
		.body | capture("<!-- " + $marker + " revision=(?<revision>[a-f0-9]{24}) blocker=(?<blocker>[a-f0-9]{24}) -->")
		| "\(.revision) \(.blocker)"' 2>/dev/null) || return 1
	read -r observed_revision fingerprint <<<"$marker"
	[[ "$observed_revision" =~ ^[a-f0-9]{24}$ && "$fingerprint" =~ ^[a-f0-9]{24}$ ]] || return 1
	reason=$(_terminal_blocker_reason "$fingerprint")
	terminal_blocker_observation_recoverable "$reason" || return 1
	retry=$(_terminal_blocker_latest_retry_comment "$comments_json") || retry=""
	if _terminal_blocker_retry_after "$retry" "$observation"; then
		return 1
	fi
	if terminal_blocker_rearms_on_retry_only "$reason"; then
		# GH#36232: an unpublished permission request re-arms once per window.
		if [[ "$reason" == "$_TBC_PERMISSION_REQUIRED" ]] &&
			terminal_blocker_permission_window_expired "$comments_json" "$issue_json" "$observation" >/dev/null; then
			return 1
		fi
		printf 'TERMINAL_BLOCKER_OBSERVATION_HOLD reason=%s task_revision=%s\n' "$reason" "$observed_revision"
		return 0
	fi
	current_revision=$(terminal_blocker_task_revision "$issue_json" "$repo_slug" "$issue_number" "$repo_path" "$reason") || return 2
	[[ "$current_revision" == "$observed_revision" ]] || return 1
	printf 'TERMINAL_BLOCKER_OBSERVATION_HOLD reason=%s task_revision=%s\n' "$reason" "$current_revision"
	return 0
}

_terminal_blocker_recovery() {
	local fingerprint="$1"
	local release_mode="${2:-first}"
	local requested_state="${3:-}"
	local reason="" owner="" action="" attempt="" issue="${WORKER_ISSUE_NUMBER:-unknown}"
	local projected_state="status:blocked"
	reason=$(_terminal_blocker_reason "$fingerprint")
	case "$reason" in
	runner_capability_unmet)
		owner="runner-recovery"
		action='Release for a capable runner. Recheck declared secret and local-data requirements before claiming; do not impose a global issue hold or publish secret values.'
		;;
	push_policy_timeout)
		owner="runner-recovery"
		action='Retry policy evaluation and publication of the recorded local branch/HEAD on the same runner after host contention clears. Preserve all policy and publication guards.'
		;;
	network_policy_timeout)
		owner="$_TBC_RUNNER_RECOVERY_OWNER"
		action='Retry the same outbound HTTPS command on the same runner after host contention clears. The policy guard timed out; it was not a policy denial. Preserve all policy guards.'
		;;
	missing_files_scope)
		owner="brief-author"
		action='Add a canonical ### Files Scope (or legacy ## Files Scope) section listing the permitted paths in the issue body.'
		;;
	files_scope_excluded)
		owner="brief-author"
		action='The AI brief owner must review the protected integration dossier, check concurrent ownership and correct the permitted paths before resuming the existing checkpoint. Preserve explicit hard boundaries and security guarantees; do not retry an unchanged brief.'
		;;
	target_code_blocker)
		owner="target-maintainer"
		action='Review the protected blocker dossier and correct the target code or task dependencies before retrying.'
		;;
	external_trigger_pending)
		owner="dependency-owner"
		action='Wait for the specified external trigger. When it is verified, correct the brief or post an authorized retry directive; unrelated repository merges do not clear this hold.'
		;;
	permission_required)
		owner="permission-maintainer"
		action='Resolve the evidenced permission prerequisite through the human-owned approval flow, then post the explicit retry directive. Retry is scheduling consent only: the original permission guard must independently verify the exact context. Do not regenerate requests or bypass the guard.'
		;;
	source_access_blocked)
		owner="access-owner"
		action='Verify access to the denied source through its approved human-owned flow, or supply the required source evidence in the brief or a linked dependency. A brief or dependency change, or an explicit retry after verified access, re-arms dispatch; unrelated merges do not. Never bypass source verification or source-access guards.'
		;;
	input_required)
		owner=$(_terminal_blocker_input_owner "$fingerprint") || owner="maintainer"
		action='Supply the specific input named in the protected dossier in the issue brief; a brief or dependency change re-arms dispatch. The recovery supervisor first decides anything AI can resolve within delegated authority.'
		;;
	*)
		owner="worker-triage"
		action='Interpret the protected dossier and record a known blocker class or repair the brief. A brief or dependency change, or an OWNER/MEMBER retry directive, re-arms dispatch.'
		;;
	esac
	[[ "$issue" =~ ^[0-9]+$ ]] || issue="$_TBC_UNKNOWN"
	# GH#33294: a legacy first observation restores status:available, so the
	# projected state must not claim a hold that is not in effect.
	# GH#34846: the full runtime holds most first observations as
	# status:blocked (GH#34775); its release path passes the applied state.
	[[ "$release_mode" == "first" ]] && projected_state="status:available"
	case "$requested_state" in
	status:blocked | status:available) projected_state="$requested_state" ;;
	esac
	# Correlate attempts without publishing runner names or arbitrary env text.
	attempt=$(_terminal_blocker_hash "${AIDEVOPS_ATTEMPT_ID:-${WORKER_SESSION_KEY:-unknown}}") || attempt="$_TBC_UNKNOWN"
	printf 'Terminal blocker: reason=%s owner=%s task=%s attempt=%s.\nProjected state: %s.\nNext action: %s\nRaw evidence remains in protected worker telemetry.\n' \
		"$reason" "$owner" "$issue" "$attempt" "$projected_state" "$action"
	return 0
}

terminal_blocker_circuit_comment() {
	local machine_readable_release="$1"
	local task_revision="$2"
	local blocker_fingerprint="$3"
	[[ "$(_terminal_blocker_reason "$blocker_fingerprint")" != "$_TBC_RUNNER_CAPABILITY" ]] || return 1
	[[ "$(_terminal_blocker_reason "$blocker_fingerprint")" != "$_TBC_UNKNOWN" ]] || return 1
	printf '<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->\n%s\n<!-- %s revision=%s blocker=%s -->\nTERMINAL_BLOCKER_CIRCUIT active=true observations=2 task_revision=%s blocker=%s\n\nAutomatic redispatch is held for the repeated known blocker. See the preceding recovery observation.\n\nAn OWNER/MEMBER can retry without deleting history by posting %s as a standalone line. Relevant revisions re-arm code/brief blockers, but never permission blockers. Retry schedules verification only and grants no access.\n<!-- ops:end -->\n' \
		"$machine_readable_release" "$_TBC_CIRCUIT_MARKER" "$task_revision" \
		"$blocker_fingerprint" "$task_revision" "$blocker_fingerprint" \
		"$_TBC_RETRY_MARKER"
	return 0
}

# Unknown/legacy BLOCKED results remain retryable, but not on every pulse. Use
# shared GitHub evidence, independent of local counters, model prose, target
# revisions and comment-bloat mode. Expiry or an explicit trusted retry re-arms
# dispatch; no labels or comments are written by this gate.
terminal_blocker_backoff_active() {
	local comments_json="$1"
	local now_epoch="${TERMINAL_BLOCKER_NOW_EPOCH:-}"
	local evidence="" count=0 last_epoch=0 delay=900 steps=0 self_login=""
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=$(date -u '+%s')
	self_login=$(_terminal_blocker_self_login)
	# aidevops:trust-boundary — bare COLLABORATOR is not proof of write access.
	# Accept OWNER/MEMBER releases, or this runner's own login (GH#33025), whose
	# runner matches the API author. Only OWNER/MEMBER retries clear evidence;
	# a retry must be a standalone directive, not quoted recovery instructions.
	evidence=$(printf '%s' "$comments_json" | jq -r --argjson now "$now_epoch" --arg self "$self_login" \
		--argjson associations "$_TBC_AUTHORITATIVE_ASSOCIATIONS" "${_TBC_ORDER_JQ}${_TBC_HOLD_EVIDENCE_JQ}"'
		def epoch: try (.created_at | fromdateiso8601) catch 0;
		[.[] | select(epoch > 0 and epoch <= $now)] as $timely
		| ([$timely[] | select(authoritative_author($associations))
			| select((.body // "") | test("(?m)^terminal-blocker-circuit:retry[ \\t]*\\r?$"))
			| select((.body // "") | contains("aidevops:terminal-blocker-circuit") | not)]
			| sort_by(.created_at, (comment_id // 0), .body) | last) as $retry
		| [$timely[] | select(hold_evidence($associations; $self))
			| select((.body // "") | contains("Terminal blocker: reason=runner_capability_unmet ") | not)
			| . as $event | select(($retry | retry_after($event)) | not)
			| . as $comment
			| ((.body // "") | try capture("(?m)^CLAIM_RELEASED reason=blocked runner=(?<runner>[A-Za-z0-9-]+) ") catch null) as $release
			| select($release != null and $release.runner == ($comment.author // $comment.user.login // ""))
			| epoch] | [length, (max // 0)] | @tsv
	' 2>/dev/null) || return 2
	IFS=$'\t' read -r count last_epoch <<<"$evidence"
	[[ "$count" =~ ^[0-9]+$ && "$last_epoch" =~ ^[0-9]+$ && "$count" -ge 2 ]] || return 1
	# Two failures: 15 minutes; each further failure doubles the delay, capped
	# at 24 hours. Cap before arithmetic so even very long histories stay safe.
	steps=$((count - 2))
	[[ "$steps" -le 7 ]] || steps=7
	while [[ "$steps" -gt 0 ]]; do
		delay=$((delay * 2))
		steps=$((steps - 1))
	done
	[[ "$delay" -le 86400 ]] || delay=86400
	[[ "$((now_epoch - last_epoch))" -lt "$delay" ]] || return 1
	printf 'TERMINAL_BLOCKER_BACKOFF failures=%s retry_after=%s\n' "$count" "$((last_epoch + delay))"
	return 0
}

# GH#35788: the issue's immutable release observations are the durable fleet
# hold. A local cooldown expiring cannot erase them. Require two *different*
# authenticated runners on this exact task revision, not two attempts/devices.
_terminal_blocker_fleet_authorize() {
	local comments="$1" repo="$2"
	local login="" permission=""
	# aidevops:trust-boundary — association alone does not prove a collaborator
	# can write. Verify actual repository permission before fleet aggregation.
	while IFS= read -r login; do
		[[ "$login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]] || continue
		permission=$(gh api "repos/${repo}/collaborators/${login}/permission" --jq '.permission' 2>/dev/null) || continue
		case "$permission" in
		admin | maintain | write)
			comments=$(jq -c --arg login "$login" 'map(if (.author // .user.login // "") == $login then .author_association="MEMBER" else . end)' <<<"$comments") || return 1
			;;
		esac
	done < <(jq -r --argjson authoritative "$_TBC_AUTHORITATIVE_ASSOCIATIONS" "${_TBC_HOLD_EVIDENCE_JQ}"'
		[.[] | select(authoritative_author($authoritative) | not)
		| select(.body // empty | test("aidevops:terminal-blocker-observation|^<!-- aidevops:fleet-capability"))
		| (.author // .user.login // "")] | unique[]' <<<"$comments")
	printf '%s\n' "$comments"
	return 0
}

_terminal_blocker_fleet_observations() {
	local comments="$1" revision="$2" fingerprint="$3"
	jq -c --argjson authoritative "$_TBC_AUTHORITATIVE_ASSOCIATIONS" \
		--arg marker "<!-- $_TBC_OBSERVATION_MARKER revision=${revision} blocker=${fingerprint} -->" "${_TBC_HOLD_EVIDENCE_JQ}"'
		[.[] | select(authoritative_author($authoritative))
		| . as $comment
		| select((.body // "") | contains($marker))
		| ((.body // "") | try capture("(?m)^CLAIM_RELEASED reason=blocked runner=(?<runner>[A-Za-z0-9-]+) ") catch null) as $release
		| select($release != null and $release.runner == ($comment.author // $comment.user.login // ""))
		| {runner:$release.runner, at:.created_at, id:.id}]
		| group_by(.runner) | map(max_by(.at))
	' <<<"$comments"
	return $?
}

# This is a fresh read-only probe, never an install or an approval. A current
# approved bootstrap policy also qualifies: the normal worktree prepare path
# will perform its frozen, script-free install before the worker starts.
_terminal_blocker_fleet_ready() {
	local path="$1" brief="$2"
	local helpers="${BASH_SOURCE[0]%/*}" probe="" policy=""
	[[ -d "$path" ]] || return 1
	# shellcheck source=runner-capability-helper.sh
	source "${helpers}/runner-capability-helper.sh"
	runner_capability_check "$path" "$brief" fresh >/dev/null 2>&1 || return 1
	probe=$(bash "${helpers}/worktree-js-readiness-helper.sh" probe "$path" --json --no-cache 2>/dev/null) || return 1
	if jq -e '.state == "ready" or (.state | startswith("not-applicable:"))' <<<"$probe" >/dev/null; then
		return 0
	fi
	policy=$(bash "${helpers}/worktree-js-readiness-helper.sh" status "$path" 2>/dev/null) || return 1
	[[ "$policy" == JS_DEPENDENCY_POLICY=current$'\n'* ]]
	return $?
}

# Resolve a single repository-wide supervisor dashboard, independent of the
# observing runner. Never create escalation comments on implementation issues.
_terminal_blocker_fleet_dashboard() {
	local repo="$1"
	gh api "repos/${repo}/issues?state=open&labels=supervisor&per_page=100" --paginate --slurp 2>/dev/null |
		jq -er '[.[][] | select(.pull_request == null)
		| select(.title | startswith("[Supervisor:"))] | sort_by(.number) | first.number // empty'
	return $?
}

# Upsert one safe, structured escalation per repository/fingerprint. Preserve
# the accumulated issue list across observations. Readiness is task-specific:
# the legacy fingerprint names a class, not an exact secret/tool requirement.
_terminal_blocker_fleet_update() {
	local repo="$1" dashboard="$2" fingerprint="$3" issue="$4" state="$5" existing="$6"
	local checkpoint="${7:-}" id="" body="" held="" old_body="" ready=""
	id=$(jq -r '.id // empty' <<<"$existing")
	old_body=$(jq -r '.body // ""' <<<"$existing")
	held=$(jq -rn --arg old "$old_body" --arg issue "$issue" '
		[($old | scan("(?m)^Held issues: ([0-9,]+)$")[] | split(",")[]), $issue]
		| unique | sort_by(tonumber) | join(",")') || return 1
	ready=$(jq -rn --arg old "$old_body" --arg key "$checkpoint" --arg state "$state" '
		[($old | scan("(?m)^Ready checkpoints: ([a-f0-9,]+)$")[] | split(",")[]),
		 ($key | select($state == "ready" and test("^[a-f0-9]{24}$")))] | unique | join(",")') || return 1
	body="<!-- ${_TBC_FLEET_MARKER}${fingerprint} -->
Fleet capability circuit (readiness is checked per task before launch)
Wake condition: capability:${fingerprint}
Held issues: ${held}
Ready checkpoints: ${ready}

Runner owners: inspect the protected blocker dossier for the exact missing prerequisite. For node-modules-missing (tsc), run \`worktree-js-readiness-helper.sh approve <worktree> --track-default-branch\` interactively. A fresh readiness probe or current approved frozen-install policy on a capable runner releases the hold automatically. No brief change is needed. Do not install without approval, bypass hooks, or publish secret values."
	[[ "$body" != "$old_body" ]] || return 0
	if [[ "$id" =~ ^[1-9][0-9]*$ ]]; then
		gh api "repos/${repo}/issues/comments/${id}" --method PATCH --raw-field body="$body" >/dev/null || return 1
	else
		gh api "repos/${repo}/issues/${dashboard}/comments" --method POST --raw-field body="$body" >/dev/null || return 1
	fi
	return 0
}

# Reconcile concurrent creators on the next observation (and immediately after
# creation). Merge both lists before removing duplicate generated comments;
# never delete ordinary dashboard comments or untrusted marker lookalikes.
_terminal_blocker_fleet_existing() {
	local repo="$1" dashboard="$2" fingerprint="$3"
	local shared="" matches="" existing="" duplicate="" merged=""
	shared=$(terminal_blocker_fetch_trusted_comments "$dashboard" "$repo") || return 1
	shared=$(_terminal_blocker_fleet_authorize "$shared" "$repo") || return 1
	# aidevops:trust-boundary — a copied marker does not authorize edits/deletes.
	matches=$(jq -c --argjson authoritative "$_TBC_AUTHORITATIVE_ASSOCIATIONS" \
		--arg marker "<!-- ${_TBC_FLEET_MARKER}${fingerprint} -->" "${_TBC_HOLD_EVIDENCE_JQ}"'
		[.[] | select(authoritative_author($authoritative))
		| select((.body // "") | startswith($marker))] | sort_by(.id)' <<<"$shared") || return 1
	existing=$(jq -c 'first // {}' <<<"$matches")
	if [[ "$(jq 'length' <<<"$matches")" -gt 1 ]]; then
		merged=$(jq -r 'map(.body) | join("\n")' <<<"$matches")
		# Feed all structured rows to the normal formatter, preserving union.
		existing=$(jq -c --arg body "$merged" '.body=$body' <<<"$existing")
		_terminal_blocker_fleet_update "$repo" "$dashboard" "$fingerprint" \
			"$(jq -r '[.[].body | scan("(?m)^Held issues: ([0-9,]+)$")[] | split(",")[]] | first' <<<"$matches")" held "$existing" || return 1
		while IFS= read -r duplicate; do
			[[ "$duplicate" =~ ^[1-9][0-9]*$ ]] || continue
			gh api "repos/${repo}/issues/comments/${duplicate}" --method DELETE >/dev/null || return 1
		done < <(jq -r '.[1:][].id' <<<"$matches")
		# Return the newly formatted canonical body, not the merged raw rows.
		shared=$(terminal_blocker_fetch_trusted_comments "$dashboard" "$repo") || return 1
		existing=$(jq -c --argjson id "$(jq '.id' <<<"$existing")" '[.[] | select(.id == $id)] | first // {}' <<<"$shared")
	fi
	printf '%s\n' "$existing"
	return 0
}

terminal_blocker_fleet_hold_active() {
	local comments="$1" brief="$2" repo="$3" issue="$4" path="$5"
	local fingerprint=""
	local revision="" observations="" dashboard="" checkpoint="" existing='{}'
	fingerprint=$(_terminal_blocker_hash "v2:${_TBC_RUNNER_CAPABILITY}") || return 1
	# Avoid dependency/API work on issues without capability observations.
	[[ "$comments" == *"blocker=${fingerprint}"* ]] || return 1
	# The dispatch admission metadata deliberately omits body. Fetch the brief
	# before hashing; a title-only hash can never match worker observations.
	if ! jq -e '[.body,.title] | all(type == "string")' <<<"$brief" >/dev/null 2>&1; then
		brief=$(gh api "repos/${repo}/issues/${issue}" 2>/dev/null) || return 1
	fi
	revision=$(terminal_blocker_task_revision "$brief" "$repo" "$issue" "$path" "$_TBC_RUNNER_CAPABILITY") || return 1
	comments=$(_terminal_blocker_fleet_authorize "$comments" "$repo") || return 1
	observations=$(_terminal_blocker_fleet_observations "$comments" "$revision" "$fingerprint") || return 1
	[[ "$(jq 'length' <<<"$observations")" -ge 2 ]] || return 1
	checkpoint=$(_terminal_blocker_hash "${revision}:${observations}") || return 1
	dashboard=$(_terminal_blocker_fleet_dashboard "$repo") || dashboard=""
	if [[ "$dashboard" =~ ^[1-9][0-9]*$ ]]; then
		# An unreadable collection is not an empty collection: never POST a
		# replacement escalation after a failed read.
		existing=$(_terminal_blocker_fleet_existing "$repo" "$dashboard" "$fingerprint") || {
			printf 'TERMINAL_BLOCKER_FLEET_HOLD escalation=unreadable wake=capability:%s\n' "$fingerprint"
			return 0
		}
	fi
	# Every runner probes before *launch*, including a runner that has never
	# failed this issue. A new capable runner/approved policy therefore wakes
	# it without spending a worker attempt. Receipts cover only these exact
	# observations and this revision, never another issue or a later failure.
	if jq -e --arg key "$checkpoint" '.body // "" | [scan("(?m)^Ready checkpoints: ([a-f0-9,]+)$")[] | split(",")[]] | index($key) != null' <<<"$existing" >/dev/null; then
		return 1
	fi
	if _terminal_blocker_fleet_ready "$path" "$brief"; then
		[[ -z "$dashboard" ]] || _terminal_blocker_fleet_update "$repo" "$dashboard" "$fingerprint" "$issue" ready "$existing" "$checkpoint" || true
		[[ -z "$dashboard" ]] || _terminal_blocker_fleet_existing "$repo" "$dashboard" "$fingerprint" >/dev/null || true
		return 1
	fi
	[[ -z "$dashboard" ]] || _terminal_blocker_fleet_update "$repo" "$dashboard" "$fingerprint" "$issue" held "$existing" || true
	[[ -z "$dashboard" ]] || _terminal_blocker_fleet_existing "$repo" "$dashboard" "$fingerprint" >/dev/null || true
	printf 'TERMINAL_BLOCKER_FLEET_HOLD task_revision=%s wake=capability:%s\n' "$revision" "$fingerprint"
	return 0
}

terminal_blocker_circuit_active() {
	local comments_json="$1"
	local issue_json="$2"
	local repo_slug="$3"
	local issue_number="$4"
	local repo_path="$5"
	local circuit="" retry="" current_revision="" fingerprint="" reason=""
	_terminal_blocker_report_ignored_evidence "$comments_json"
	if terminal_blocker_fleet_hold_active "$comments_json" "$issue_json" "$repo_slug" "$issue_number" "$repo_path"; then
		return 0
	fi
	if terminal_blocker_backoff_active "$comments_json"; then
		return 0
	fi
	circuit=$(_terminal_blocker_latest_marker "$comments_json" "$_TBC_CIRCUIT_MARKER revision=") || circuit=""
	[[ -n "$circuit" ]] || return 1
	fingerprint=$(printf '%s' "$circuit" | jq -r '.body | capture("<!-- aidevops:terminal-blocker-circuit revision=[a-f0-9]{24} blocker=(?<id>[a-f0-9]{24}) -->").id' 2>/dev/null) || return 1
	reason=$(_terminal_blocker_reason "$fingerprint")
	[[ "$reason" != "$_TBC_UNKNOWN" ]] || return 1
	current_revision=$(terminal_blocker_task_revision "$issue_json" "$repo_slug" "$issue_number" "$repo_path" "$reason") || return 1
	circuit=$(_terminal_blocker_latest_marker "$comments_json" "$_TBC_CIRCUIT_MARKER revision=${current_revision} blocker=${fingerprint}") || circuit=""
	[[ -n "$circuit" ]] || return 1
	retry=$(_terminal_blocker_latest_retry_comment "$comments_json") || retry=""
	if _terminal_blocker_retry_after "$retry" "$circuit"; then
		return 1
	fi
	# GH#36232: a repeated permission blocker without a published request
	# re-arms once per backoff window, like its first observation.
	if [[ "$reason" == "$_TBC_PERMISSION_REQUIRED" ]] &&
		terminal_blocker_permission_window_expired "$comments_json" "$issue_json" "$circuit" >/dev/null; then
		return 1
	fi
	printf 'TERMINAL_BLOCKER_CIRCUIT task_revision=%s\n' "$current_revision"
	return 0
}
