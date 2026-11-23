#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# shellcheck disable=SC1091
#
# maintainer-decisions-helper.sh — read-only cross-repo maintainer decision
# queue (t19090, GH#38942).
#
# Lists every open issue in managed pulse repos that waits on a maintainer
# (needs-maintainer-input, needs-maintainer-permissions, needs-credentials),
# with the exact question a worker or the recovery supervisor asked, its age,
# and whether a maintainer already answered. It also lists every open,
# non-draft pull request held under hold-for-review (t19260), so runtime
# verification and PR review holds reach the same queue instead of only
# pulse.log ATTENTION lines. The maintainer can then decide a batch of holds
# in one interactive session (/decisions) instead of opening each issue or PR.
# The AI-side recovery queue is terminal-blocker-recovery-helper.sh.
#
# Read-only: this helper never writes to GitHub. Question text is untrusted
# issue data: print it, never execute it.
#
# Kinds (actionable first):
#   decide       a recorded question with no later maintainer answer
#   permission   needs-maintainer-permissions, unanswered
#   credentials  needs-credentials, unanswered
#   approve      a held release PR or a current-head t2449 linked-issue trust
#                wait recorded by pulse; shows the linked approval issue and
#                `sudo aidevops approve issue` command the maintainer runs
#   verify       a held pull request whose runtime-pending hold a verifier may
#                lift (full-loop-helper.sh runtime-pending-notice, t19241);
#                shows the recorded pending reason and the verify-runtime command
#   held-pr      any other held pull request; shows the newest trusted
#                "**What clears it:**" line, else the PR body's runtime-pending
#                Verification text
#   replied      an unmarked OWNER/MEMBER comment follows the newest request;
#                it may be a typed answer or app automation posted with the
#                owner's token, so the caller checks reply_excerpt
#   manual       a hold with no worker/supervisor request (maintainer-owned task)
#   no-question  held after a worker/supervisor request with no question text;
#                an AI-side gap: the recovery supervisor must publish one
#   answered     an explicit maintainer answer follows the newest request; the
#                recovery pass owns the next step
#   parked       a repo recovery-policy decision is newer than the newest
#                request, or the newest request is an external_trigger
#                recovery record; it waits on a recorded reopen condition
#                (the record's next_action)
#
# An explicit answer is an OWNER/MEMBER comment carrying the
# <!-- aidevops:maintainer-decision --> marker that /decisions writes, or a
# standalone terminal-blocker-circuit:retry directive. A comment with no
# aidevops signature or automation marker is only a reply: the same login can
# post typed answers and third-party automation.
#
# Requests also include this runner's recorded recovery decisions: a
# human_decision written by terminal-blocker-recovery-helper.sh record counts
# as a request dated when it was recorded, with its next_action as the
# question, even when the issue's labels name an AI or dependency owner.
#
# Usage:
#   maintainer-decisions-helper.sh list [--repo owner/repo] [--format tsv|json|md] [--max N]
#
# Env:
#   MAINTAINER_DECISIONS_REPOS_JSON  repos.json path (default ~/.config/aidevops/repos.json)
#   AIDEVOPS_BLOCKER_RECOVERY_DIR    recovery queue root holding decisions/
#                                    (default ~/.aidevops/.agent-workspace/terminal-blocker-recovery)
#   MAINTAINER_DECISIONS_FULL_LOOP_HELPER
#                                    full-loop-helper.sh used for the read-only
#                                    runtime-pending-notice (default: alongside this script)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

MD_REPOS_JSON="${MAINTAINER_DECISIONS_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
MD_RECOVERY_DIR="${AIDEVOPS_BLOCKER_RECOVERY_DIR:-${HOME}/.aidevops/.agent-workspace/terminal-blocker-recovery}"
MD_T2449_DIR="${PULSE_T2449_BLOCK_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/pulse-t2449-permanent-blocks}"
MD_HOLD_LABELS="needs-maintainer-input,needs-maintainer-permissions,needs-credentials,needs-source-access"
# Holds a supervisor may state with a canonical public ask; searched too, but
# kept only when a trusted comment carries that ask (see MD_CLASSIFY_JQ).
MD_ASK_LABELS='hold-for-review "status:blocked"'
MD_PR_HOLD_LABEL="hold-for-review"
MD_RELEASE_LABEL="release-approval-required"
MD_APPROVE_CLI_FALLBACK="sudo aidevops"
MD_FULL_LOOP_HELPER="${MAINTAINER_DECISIONS_FULL_LOOP_HELPER:-${SCRIPT_DIR}/full-loop-helper.sh}"
MD_SEARCH_PAGES=10
MD_FORMAT="tsv"
MD_REPO=""
MD_MAX=300

# jq definitions shared by the issue and pull request classifiers.
# shellcheck disable=SC2016 # jq program, variables bound with --arg
MD_JQ_LIB='
def trusted: (.authorAssociation // "") | IN("OWNER", "MEMBER", "COLLABORATOR");
def authoritative: (.authorAssociation // "") | IN("OWNER", "MEMBER");
def text: .body // "";
def automation: text | test("aidevops:origin:worker|<!-- ops:start|aidevops:terminal-blocker-|<!-- dispatch-|aidevops:ops |aidevops:dispatch |(?m)^(DISPATCH_CLAIM|DISPATCH_LEASE|CLAIM_RELEASED) ");
def first_capture($re; $name): [text | capture($re)? | .[$name]] | first // "";
def clean: gsub("[[:cntrl:]]"; " ") | gsub("\\s+"; " ") | ltrimstr(" ") | .[0:300];
def days($t): if $t == null or $t == "" then null
	else ((($now | tonumber) - ($t | fromdateiso8601)) / 86400 | floor) end;
'

# Classify one `gh issue view --json number,title,url,createdAt,labels,comments`
# object. Requests come from trusted runner/supervisor comments; answers only
# from OWNER/MEMBER (the recovery pass's authoritative associations).
# shellcheck disable=SC2016 # jq program, variables bound with --arg
MD_CLASSIFY_JQ="${MD_JQ_LIB}"'
def visible_lines:
	text | split("\n") | reduce .[] as $line ({fence: null, lines: []};
		($line | capture("^\\s*(?<marker>`{3,}|~{3,})(?<info>.*)$")? // null) as $f
		| (($f != null) and (($f.marker[0:1] == "~") or (($f.info | contains("`")) | not))) as $opens
		| (($f != null) and ($f.info | test("^[ \\t]*$"))) as $blank
		| if .fence == null then (if $opens then .fence = $f.marker else .lines += [$line] end)
		  elif $f != null and $blank and ($f.marker[0:1] == .fence[0:1]) and ($f.marker | length) >= (.fence | length) then .fence = null
		  else . end) | .lines;
# Every recognised request anchor in a comment; "" when it carries no question.
def supervisor_asks:
	visible_lines as $lines
	| [range(0; $lines | length) as $i
		| ([($lines[$i] | capture("(?i)^\\s*(?:[-*]\\s+)?\\*\\*(?:Still needed|Smallest (?:human )?input(?: needed)?|Missing input)(?: \\((?:owner: [^)]*|reply with one)\\))?[.:]?\\*\\*(?: \\(owner: [^)]*\\))?[,:.]?\\s*(?<q>.*)$")?),
			($lines[$i] | capture("(?i)\\*\\*Still needed \\(owner: [a-z]+\\)\\*\\*:?\\s*(?<q>.*)$")?)] | first // null) as $m
		| select($m != null and ($lines[$i] | test("(?i)owner: [a-z]+|Smallest input \\(reply with one\\)")))
		| ($m.q | clean) as $q
		| if $q == "" or ($q | test("(?i)^(either of|pick one|choose one|reply with one)[.:]?$")) then
			([$lines[$i+1:$i+4][] | select(test("^\\s*(?:[-*]\\s+|[0-9]+[.)]\\s+)")) | sub("^\\s*(?:[-*]\\s+|[0-9]+[.)]\\s+)"; "")] | join("; ") | clean)
		  else $q end];
[.labels[]?.name] as $labels
| [.comments[]? | select(trusted)] as $c
| [$c[] | select(text | test("Terminal blocker: reason=")) | {
	t: .createdAt, by: .author.login, src: "worker",
	reason: first_capture("Terminal blocker: reason=(?<r>[a-z_]+)"; "r"),
	q: (first_capture("(?m)^(?:Input requested|Trigger awaited): (?<q>[^\\n]+)$"; "q") | clean)}] as $holds
| [$c[] | (supervisor_asks) as $cands | select($cands | length > 0) | {
	t: .createdAt, by: .author.login, src: "supervisor", reason: "",
	q: ([$cands[] | select(. != "")] | first // ""), recommendation: ([visible_lines[] | capture("(?i)^\\s*(?:[-*]\\s+)?\\*\\*Recommended path:[*][*]\\s*(?<r>.*)$")? | .r | clean] | first // null)}] as $asks
| ([$c[] | select(text | test("<!-- aidevops:recovery-policy:[a-z_]+:")) | {
	t: .createdAt, action: first_capture("<!-- aidevops:recovery-policy:(?<a>[a-z_]+):"; "a")}] | max_by(.t)) as $park
| ([$c[] | select(authoritative) | select(
	(text | test("<!-- aidevops:maintainer-decision"))
	or (text | test("(?m)^terminal-blocker-circuit:retry[ \\t]*\\r?$")))
	| {t: .createdAt, by: .author.login}] | max_by(.t)) as $answer
| ([$c[] | select(authoritative) | select(((text | test("aidevops:sig")) | not) and (automation | not))
	| {t: .createdAt, by: .author.login, excerpt: (text | clean | .[0:200])}] | max_by(.t)) as $reply
| (if $local == null then [] else [{t: $local.t, by: $local.by, src: "recovery_record", reason: "",
	q: ($local.q | clean), recommendation: null, wake: ($local.wake // "")}] end) as $recorded
| (($holds + $asks + $recorded) | sort_by(.t)) as $requests
| ($requests | last) as $anchor
| ([$requests[] | select(.q != "" and ($answer == null or .t > $answer.t))] | last) as $question
| (if $anchor != null and $reply != null and $reply.t > $anchor.t then $reply else null end) as $fresh_reply
| (if ($labels | index("needs-maintainer-permissions")) then "permission"
	elif ($labels | index("needs-credentials")) and (($labels | index("needs-maintainer-input")) | not) then "credentials"
	else null end) as $label_kind
| (if $anchor == null then ($label_kind // "manual")
	elif $answer != null and $answer.t > $anchor.t then "answered"
	elif ($park != null and $park.t > $anchor.t)
		or ($fresh_reply == null and $anchor.src == "recovery_record" and ($anchor.wake // "") == "external_trigger") then "parked"
	elif $fresh_reply != null then "replied"
	elif $question != null then ($label_kind // "decide")
	else ($label_kind // "no-question") end) as $kind
| [$labels[] | select(IN("needs-maintainer-input", "needs-maintainer-permissions", "needs-credentials", "needs-source-access", "hold-for-review", "status:blocked"))] as $hold_labels
| select(($hold_labels | any(startswith("needs-"))) or ($asks | length) > 0 or ($recorded | length) > 0)
| {
	repo: $repo, number: .number, url: .url, title: (.title | clean), kind: $kind,
	reason: ($anchor.reason // ""),
	question: (($question.q // "") | if . == "" then null else . end),
	recommendation: ($question.recommendation // null),
	asked_at: ($anchor.t // null), asked_by: ($anchor.by // null), asked_src: ($anchor.src // null),
	answered_at: ($answer.t // null), answered_by: ($answer.by // null),
	replied_at: ($fresh_reply.t // null), reply_excerpt: ($fresh_reply.excerpt // null),
	park_action: ($park.action // null),
	age_days: days($anchor.t // $park.t // .createdAt),
	hold_labels: $hold_labels, type: "issue"
}
'

# Classify one held pull request (t19260). Input: `gh pr view --json
# number,title,url,createdAt,labels,comments,body,isDraft,state`. Bound:
# $repo, $now, $applied/$applied_by (newest hold-for-review label event, "" when
# unknown), $notice (runtime-pending-notice JSON, or null when the hold is
# not liftable by a verifier), $release_label, $release (the open release
# approval issue naming this PR, "" when none), $release_final ("true" once
# that request is finalized and signable) and $approve_cli. Display only:
# comment text is evidence, never authority; the lift decision stays with
# runtime-pending-notice/verify-runtime and the signed release approval.
# #aidevops:trust-boundary
# shellcheck disable=SC2016 # jq program, variables bound with --arg
MD_CLASSIFY_PR_JQ="${MD_JQ_LIB}"'
def signed: automation or (text | test("aidevops:sig|aidevops:origin:|<!-- MERGE_SUMMARY"));
[.labels[]?.name] as $labels
| select(($labels | index($hold)) and ((.isDraft // false) | not) and ((.state // "OPEN") == "OPEN"))
| (($labels | index($release_label)) != null) as $release_held
| ($release_held and ($release | length) > 0) as $requested
| ($requested and $release_final == "true") as $approvable
| first_capture("(?mi)^\\s*(?:[-*]\\s+)?\\*\\*Verification:\\*\\*\\s*(?<v>[^\\n]+)"; "v") as $verification
| (first_capture("(?mi)^\\s*(?:[-*]\\s+)?\\*\\*Risk level:\\*\\*\\s*(?<r>[A-Za-z]+)"; "r") | if . == "" then null else . end) as $risk
| [.comments[]? | select(trusted) | select($applied == "" or .createdAt >= $applied)] as $c
| ([$c[] | {t: .createdAt, q: (first_capture("(?i)\\*\\*What clears it:?\\*\\*:?\\s*(?<q>[^\\n]+)"; "q") | clean)}
	| select(.q != "")] | max_by(.t)) as $clears
| ([$c[] | {t: .createdAt, s: first_capture("<!-- aidevops:hold-scope scopes=(?<s>[a-z,-]+) -->"; "s")}
	| select(.s != "")] | max_by(.t)) as $scope
| ([$c[] | select(signed | not) | {t: .createdAt, by: .author.login, excerpt: (text | clean | .[0:200])}
	| select(.excerpt != "")] | max_by(.t)) as $note
| ($notice != null and ($release_held | not)) as $liftable
| (if $approvable then "sign the release approval on issue #\($release); routine r924 then merges the approved head"
	elif $requested then "release request #\($release) is not finalized yet, so do not sign it; routine r924 finalizes the request"
	elif $release_held then "release approval requested but no open release issue names this PR; routine r924 retries the request"
	elif $liftable then ($notice.reason // "")
	elif $clears != null then $clears.q
	elif ($verification | test("^runtime-pending"; "i")) then ($verification | clean)
	elif $scope != null then "hold scope \($scope.s): a maintainer reviews the scoped change"
	elif $note != null then "latest note: \($note.excerpt)"
	else "" end) as $question
| {
	repo: $repo, number: .number, url: .url, title: (.title | clean),
	kind: (if $approvable then "approve" elif $liftable then "verify" else "held-pr" end), type: "pr",
	reason: (if $release_held then $release_label elif $liftable then "runtime-pending" else ($scope.s // "") end),
	question: (if $question == "" then null else $question end),
	recommendation: null,
	asked_at: (if $applied == "" then null else $applied end),
	asked_by: (if $applied_by == "" then null else $applied_by end),
	asked_src: "hold_label",
	answered_at: null, answered_by: null, replied_at: null, reply_excerpt: null, park_action: null,
	age_days: days(if $applied == "" then .createdAt else $applied end),
	hold_labels: ([$hold] + (if $release_held then [$release_label] else [] end)), risk: $risk,
	command: (if $approvable then "\($approve_cli) approve issue \($release) \($repo)"
		elif $liftable then ($notice.command // null) else null end)
}
'

# Kinds in presentation order, with md headings. The only kind table.
# shellcheck disable=SC2016 # jq program
MD_KINDS_JQ='
def kinds: [
	["decide", "Needs your decision"],
	["permission", "Needs a permission decision"],
	["credentials", "Needs credentials"],
	["approve", "Needs your signed approval (held PRs)"],
	["verify", "Needs runtime verification (held PRs)"],
	["held-pr", "Held PRs awaiting maintainer review"],
	["replied", "Replied: check whether the reply answers the question"],
	["manual", "Maintainer-owned holds (no AI request recorded)"],
	["no-question", "AI-side gaps: held with no question recorded"],
	["answered", "Answered: waiting on the recovery pass"],
	["parked", "Parked: waits on a recorded reopen condition"],
	["error", "Unreadable"]];
def rank_of($k): ([kinds[][0]] | index($k)) // (kinds | length);
def heading_of($k): ([kinds[] | select(.[0] == $k) | .[1]] | first) // $k;
'
MD_ORDER_JQ="${MD_KINDS_JQ}"'sort_by(rank_of(.kind), -(.age_days // 0), .repo, .number)'

_md_usage() {
	cat <<EOF
Usage: $(basename "$0") list [--repo owner/repo] [--format tsv|json|md] [--max N]

Read-only cross-repo maintainer decision queue for managed pulse repos.
Lists open issues labelled ${MD_HOLD_LABELS//,/, }, plus hold-for-review and
status:blocked issues only when a trusted comment carries a canonical ask, and
open non-draft pull requests labelled ${MD_PR_HOLD_LABEL} (kinds approve, verify, held-pr),
and current-head t2449 linked-issue trust waits recorded by pulse (kind approve).

Options:
  --repo owner/repo   Limit to one repository
  --format tsv|json|md
                      tsv (default): kind, age_days, ref, reason, question or title, url
                      json: array of records (type: issue or pr)
                      md: counts plus numbered lists grouped by kind
  --max N             Maximum issues to classify (default: ${MD_MAX}); the cap is
                      shared round-robin across repos, oldest first per repo.
                      Held pull requests are capped separately by the same N.
EOF
	return 0
}

# Prints managed pulse slugs, one per line.
_md_managed_slugs() {
	[[ -f "$MD_REPOS_JSON" ]] || {
		print_error "repos.json not found: ${MD_REPOS_JSON}"
		return 1
	}
	jq -r '.initialized_repos[]? | select(.pulse == true and (.local_only // false) == false and (.slug // "") != "") | .slug' \
		"$MD_REPOS_JSON" | sort -u
	return 0
}

# Prints repo, PR number, head SHA and epoch for local signed-approval waits.
_md_t2449_refs() {
	local slugs="$MD_REPO"
	local file="" name="" repo="" number="" head="" block="" epoch="" rest=""
	[[ -d "$MD_T2449_DIR" ]] || return 0
	if [[ -z "$slugs" ]]; then
		slugs=$(_md_managed_slugs) || return 1
	fi
	for file in "$MD_T2449_DIR"/*; do
		[[ -f "$file" && ! -L "$file" ]] || continue
		name="${file##*/}"
		[[ "$name" =~ ^[A-Za-z0-9_.-]+--[A-Za-z0-9_.-]+--pr-[0-9]+$ ]] || continue
		rest="${name#*--}"
		repo="${name%%--*}/${rest%--pr-*}"
		number="${name##*--pr-}"
		grep -Fxq -- "$repo" <<<"$slugs" || continue
		IFS=$'\t' read -r head block epoch rest <"$file" || continue
		[[ "$head" =~ ^[[:xdigit:]]{40}$ && "$block" == untrusted_issue_author_no_crypto_approval && "$epoch" =~ ^[0-9]+$ ]] || continue
		printf '%s\t%s\t%s\t%s\n' "$repo" "$number" "$head" "$epoch"
	done
	return 0
}

# Prints "owner/repo<TAB>number" for open held issues (or, with type pr, open
# non-draft held pull requests) matching one search scope.
# Args: scope qualifier (user:<owner> or repo:<owner/repo>), managed slugs JSON
# array, type (issue|pr, default issue)
_md_search_scope() {
	local scope="$1"
	local slugs_json="$2"
	local type="${3:-issue}"
	local label=""
	local status=0
	if [[ "$type" == "pr" ]]; then
		_md_search_query "is:open is:pr draft:false label:${MD_PR_HOLD_LABEL} -label:parent-task ${scope}" "$slugs_json" || status=1
		return "$status"
	fi
	_md_search_query "is:open is:issue label:${MD_HOLD_LABELS} -label:parent-task ${scope}" "$slugs_json" || status=1
	# One query per ask label: quoted label names cannot join a comma list safely.
	for label in $MD_ASK_LABELS; do
		_md_search_query "is:open is:issue label:${label} -label:parent-task ${scope}" "$slugs_json" || status=1
	done
	return "$status"
}

# Prints "owner/repo<TAB>number" for every page of one search query.
# Args: full search query, managed slugs JSON array
_md_search_query() {
	local query="$1"
	local slugs_json="$2"
	local scope="$query"
	local page=1
	local page_json=""
	local count=0
	while [[ "$page" -le "$MD_SEARCH_PAGES" ]]; do
		page_json=$(gh api -X GET search/issues -f q="$query" -f per_page=100 -f page="$page") || {
			print_warning "search failed for ${scope} page ${page}"
			return 1
		}
		jq -r --argjson slugs "$slugs_json" '.items[]
			| (.repository_url | sub("^.*/repos/"; "")) as $repo
			| select($slugs | index($repo)) | "\($repo)\t\(.number)"' <<<"$page_json"
		count=$(jq '.items | length' <<<"$page_json")
		[[ "$count" -ge 100 ]] || break
		page=$((page + 1))
	done
	return 0
}

# Prints unique held issue (or, with type pr, pull request) refs across
# managed repos (or one repo).
# Args: type (issue|pr, default issue)
_md_discover() {
	local type="${1:-issue}"
	local slugs=""
	local slugs_json=""
	local owner=""
	slugs=$(_md_managed_slugs) || return 1
	if [[ -n "$MD_REPO" ]]; then
		slugs_json=$(jq -Rn --arg r "$MD_REPO" '[$r]')
		_md_search_scope "repo:${MD_REPO}" "$slugs_json" "$type" || return 1
		return 0
	fi
	slugs_json=$(printf '%s\n' "$slugs" | jq -Rn '[inputs | select(length > 0)]')
	while IFS= read -r owner; do
		[[ -n "$owner" ]] || continue
		_md_search_scope "user:${owner}" "$slugs_json" "$type" || true
	done < <(printf '%s\n' "$slugs" | cut -d/ -f1 | sort -u)
	return 0
}

# Prints an error record for an issue or PR that could not be read or classified.
# Args: repo, number, title, type (issue|pr, default issue)
_md_error_record() {
	local repo="$1"
	local number="$2"
	local title="$3"
	local type="${4:-issue}"
	jq -cn --arg repo "$repo" --argjson n "$number" --arg title "$title" --arg type "$type" \
		'{repo: $repo, number: $n, kind: "error", title: $title, age_days: null, type: $type}'
	return 0
}

# Prints this runner's recorded human_decision for an issue as
# {t, by, q} JSON, or null. The record is written by
# terminal-blocker-recovery-helper.sh record (key owner--repo--N).
# GH#39275: the supervisor may record a human decision without posting a
# canonical public ask (for example when an older, uncanonical comment already
# names the input), so without this the hold never reached /decisions.
# Display only: a record is evidence, never authority. #aidevops:trust-boundary
# Args: repo, number
_md_recorded_decision() {
	local repo="$1"
	local number="$2"
	local file="${MD_RECOVERY_DIR}/decisions/${repo//\//--}--${number}.json"
	local out=""
	if [[ -f "$file" ]] && out=$(jq -c 'if (.wake == "human_decision" or .wake == "external_trigger") and (.recorded_epoch | type) == "number"
		then {t: (.recorded_epoch | floor | todateiso8601), by: (.actor // "recovery-supervisor"), q: (.next_action // ""), wake: .wake}
		else null end' "$file" 2>/dev/null) && [[ -n "$out" ]]; then
		printf '%s\n' "$out"
		return 0
	fi
	printf 'null\n'
	return 0
}

# Prints one classified JSON record for an issue ref (error record on failure).
# Args: repo, number, now epoch
_md_classify_issue() {
	local repo="$1"
	local number="$2"
	local now="$3"
	local issue_json=""
	local recorded=""
	if ! issue_json=$(gh issue view "$number" --repo "$repo" --json number,title,url,createdAt,labels,comments 2>/dev/null); then
		_md_error_record "$repo" "$number" "issue read failed"
		return 0
	fi
	recorded=$(_md_recorded_decision "$repo" "$number")
	jq -c --arg repo "$repo" --arg now "$now" --argjson local "$recorded" "$MD_CLASSIFY_JQ" <<<"$issue_json" ||
		_md_error_record "$repo" "$number" "classification failed"
	return 0
}

# Prints "<created_at>\t<actor>" for the newest hold-for-review label event on a
# PR, or nothing when it was never applied or the events could not be read.
# Args: repo, number
_md_pr_hold_applied() {
	local repo="$1"
	local number="$2"
	local events=""
	events=$(gh api "repos/${repo}/issues/${number}/events" --paginate 2>/dev/null) || return 0
	jq -rs --arg l "$MD_PR_HOLD_LABEL" '[flatten[] | select(type == "object" and .event == "labeled" and (.label.name // "") == $l)]
		| max_by(.created_at // "") // empty | "\(.created_at // "")\t\(.actor.login // "")"' <<<"$events" 2>/dev/null || true
	return 0
}

# Prints the runtime-pending-notice JSON for a held PR (t19241), or null when a
# verifier cannot lift the hold. Read-only.
# Args: repo, number
_md_pr_runtime_notice() {
	local repo="$1"
	local number="$2"
	local notice=""
	if [[ -x "$MD_FULL_LOOP_HELPER" ]] &&
		notice=$("$MD_FULL_LOOP_HELPER" runtime-pending-notice "$number" "$repo" 2>/dev/null) &&
		jq -e 'type == "object" and (.command | type) == "string"' >/dev/null 2>&1 <<<"$notice"; then
		jq -c '.' <<<"$notice"
		return 0
	fi
	printf 'null\n'
	return 0
}

# Prints "<issue>\t<finalized>" for the open release approval issue whose
# request names this PR, or nothing. Mirrors cloudron-release-approval-helper.sh:
# exactly one schema-1 metadata line (release_metadata) names the repo and PR,
# and the body is signable only once its Publication boundary carries this
# issue's maintainer command and no "finalization pending" notice. A finalized
# request wins over an unfinished one.
# Args: repo, PR number
_md_pr_release_issue() {
	local repo="$1"
	local number="$2"
	local issues=""
	issues=$(gh issue list --repo "$repo" --label "$MD_RELEASE_LABEL" --state open --limit 50 --json number,body 2>/dev/null) || return 0
	jq -r --arg repo "$repo" --arg n "$number" '[.[] | (.body // "") as $b | .number as $i
		| ($b | split("\n") | map(fromjson? | select(type == "object" and .schema == 1))) as $meta
		| select(($meta | length) == 1 and $meta[0].repository == $repo and ($meta[0].pr | tostring) == $n)
		| ($b | split("\n### Publication boundary\n") | .[1] // "" | split("\n### Files Scope\n") | .[0]) as $pub
		| {i: $i, final: ((($b | contains("Request finalization pending.")) | not)
			and ($pub | split("\n") | any(startswith("Maintainer command: `") and endswith(" approve issue \($i) \($repo)`"))))}]
		| ((map(select(.final)) | first) // first) | select(. != null) | "\(.i)\t\(.final)"' <<<"$issues" 2>/dev/null || true
	return 0
}

# Prints one classified JSON record for a held PR ref (t19260), nothing when
# the PR is no longer an open, non-draft hold, or an error record on failure.
# Args: repo, number, now epoch
_md_classify_pr() {
	local repo="$1"
	local number="$2"
	local now="$3"
	local pr_json=""
	local applied=""
	local applied_at=""
	local applied_by=""
	local notice="null"
	local release=""
	local release_final=""
	local approve_cli="$MD_APPROVE_CLI_FALLBACK"
	if ! pr_json=$(gh pr view "$number" --repo "$repo" --json number,title,url,createdAt,labels,comments,body,isDraft,state 2>/dev/null); then
		_md_error_record "$repo" "$number" "pull request read failed" pr
		return 0
	fi
	applied=$(_md_pr_hold_applied "$repo" "$number")
	if [[ "$applied" == *$'\t'* ]]; then
		applied_at="${applied%%$'\t'*}"
		applied_by="${applied#*$'\t'}"
	fi
	# A release-approval hold is lifted only by a signed approval, so the
	# runtime-pending route is not consulted for it.
	if jq -e --arg l "$MD_RELEASE_LABEL" 'any(.labels[]?; .name == $l)' >/dev/null 2>&1 <<<"$pr_json"; then
		release=$(_md_pr_release_issue "$repo" "$number")
		if [[ "$release" == *$'\t'* ]]; then
			release_final="${release#*$'\t'}"
			release="${release%%$'\t'*}"
		fi
		if declare -F approval_cli_prefix >/dev/null 2>&1; then
			approve_cli=$(approval_cli_prefix) || approve_cli="$MD_APPROVE_CLI_FALLBACK"
		fi
	else
		notice=$(_md_pr_runtime_notice "$repo" "$number")
	fi
	jq -c --arg repo "$repo" --arg now "$now" --arg hold "$MD_PR_HOLD_LABEL" \
		--arg applied "$applied_at" --arg applied_by "$applied_by" --argjson notice "$notice" \
		--arg release_label "$MD_RELEASE_LABEL" --arg release "$release" --arg release_final "$release_final" \
		--arg approve_cli "$approve_cli" "$MD_CLASSIFY_PR_JQ" <<<"$pr_json" ||
		_md_error_record "$repo" "$number" "classification failed" pr
	return 0
}

# Prints one current-head t2449 trust wait; stale markers never become asks.
_md_classify_trust_pr() {
	local repo="$1" number="$2" head="$3" epoch="$4" now="$5"
	local pr_json="" approve_cli="$MD_APPROVE_CLI_FALLBACK"
	if ! pr_json=$(gh pr view "$number" --repo "$repo" --json number,title,url,state,isDraft,headRefOid,closingIssuesReferences 2>/dev/null); then
		_md_error_record "$repo" "$number" "pull request read failed" pr
		return 0
	fi
	jq -e --arg head "$head" --arg open OPEN '.state == $open and (.isDraft | not) and .headRefOid == $head' >/dev/null <<<"$pr_json" || return 0
	if ! jq -e '.closingIssuesReferences | length == 1' >/dev/null <<<"$pr_json"; then
		_md_error_record "$repo" "$number" "trust wait requires exactly one linked issue" pr
		return 0
	fi
	if declare -F approval_cli_prefix >/dev/null 2>&1; then
		approve_cli=$(approval_cli_prefix) || approve_cli="$MD_APPROVE_CLI_FALLBACK"
	fi
	jq -c --arg repo "$repo" --argjson epoch "$epoch" --argjson now "$now" --arg cli "$approve_cli" --arg kind approve '
		.closingIssuesReferences[0].number as $issue
		| {repo: $repo, number: .number, url: .url, title: (.title | gsub("[[:cntrl:]]"; " ")),
		kind: $kind, type: "pr", reason: "t2449_issue_trust", asked_src: "t2449_marker",
		question: "linked issue #\($issue) is not maintainer-authored; sign it so pulse can merge this PR",
		command: "\($cli) approve issue \($issue) \($repo)", age_days: (($now - $epoch) / 86400 | floor),
		asked_at: ($epoch | todateiso8601), asked_by: null, recommendation: null,
		answered_at: null, answered_by: null, replied_at: null, reply_excerpt: null, park_action: null, hold_labels: []}' <<<"$pr_json" ||
		_md_error_record "$repo" "$number" "trust classification failed" pr
	return 0
}

# Renders sorted records (JSON array on stdin) in the selected format.
_md_render() {
	case "$MD_FORMAT" in
	json)
		jq "$MD_ORDER_JQ"
		;;
	tsv)
		jq -r "${MD_ORDER_JQ}"' | .[] | [.kind, ((.age_days // "-") | tostring), "\(.repo)#\(.number)", (if .reason == "" then "-" else (.reason // "-") end), (.question // .title // "-"), (.url // "-")] | @tsv'
		;;
	md)
		jq -r "${MD_ORDER_JQ}"' as $all
			| def line: "\(.repo)#\(.number) (\(.age_days // "-")d\(if (.reason // "") != "" then ", " + .reason else "" end)\(if (.risk // null) != null then ", " + .risk + " risk" else "" end)): \(.question // .title)"
				+ (if .type == "pr" and .question != null then "\n   PR: \(.title)" else "" end)
				+ (if .recommendation != null then "\n   queue recommendation: \(.recommendation)" else "" end)
				+ (if .reply_excerpt != null then "\n   reply: \(.reply_excerpt)" else "" end)
				+ (if (.command // null) != null then "\n   \(.kind): \(.command)" else "" end)
				+ "\n   \(.url // "")";
			"# Maintainer decision queue",
			"",
			"Total: \($all | length). " + ([$all | group_by(.kind) | sort_by(rank_of(.[0].kind))[] | "\(.[0].kind)=\(length)"] | join(", ")),
			(($all | group_by(.kind) | sort_by(rank_of(.[0].kind)))[]
				| "", "## \(heading_of(.[0].kind)) (\(length))", "",
				(to_entries[] | "\(.key + 1). \(.value | line)"))'
		;;
	*)
		print_error "unknown format: ${MD_FORMAT}"
		return 1
		;;
	esac
	return 0
}

# Dedupes "owner/repo<TAB>number" refs on stdin and orders them round-robin
# across repos, oldest issue first within each repo. GH#39266: a plain sort let
# --max exhaust the alphabetically first repo, so other repos' holds were never
# classified or shown.
_md_interleave_refs() {
	# Malformed lines are dropped here, before ranking, so they never take a
	# --max slot that _md_list would later skip.
	awk -F'\t' 'NF == 2 && $1 ~ /^[^\/[:space:]]+\/[^\/[:space:]]+$/ && $2 ~ /^[0-9]+$/ && !seen[$0]++' |
		sort -t $'\t' -k1,1 -k2,2n |
		awk -F'\t' '{ print (++rank[$1]) "\t" $0 }' |
		sort -t $'\t' -k1,1n -k2,2 |
		cut -f2-
	return 0
}

_md_list() {
	local refs=""
	local pr_refs=""
	local records=""
	local repo=""
	local number=""
	local now=""
	local total=0
	local repo_count=0
	local status=0
	local head="" epoch="" pr_count=0
	refs=$(_md_discover issue | _md_interleave_refs) || return 1
	# t19260: held PRs use their own refs and cap, so the issue --max
	# round-robin is unchanged. A failed PR search still shows the issue
	# queue, but the exit status marks the PR queue incomplete.
	if ! pr_refs=$(_md_discover pr | _md_interleave_refs); then
		print_warning "held pull request discovery failed; the PR part of this queue is incomplete"
		status=1
	fi
	total=$(printf '%s\n' "$refs" | grep -c $'\t' || true)
	if [[ "$total" -gt "$MD_MAX" ]]; then
		repo_count=$(printf '%s\n' "$refs" | cut -f1 | sort -u | grep -c . || true)
		print_warning "classifying ${MD_MAX} of ${total} held issues across ${repo_count} repos (round-robin, oldest first per repo); use --repo owner/repo or a larger --max for the rest"
	fi
	total=$(printf '%s\n' "$pr_refs" | grep -c $'\t' || true)
	if [[ "$total" -gt "$MD_MAX" ]]; then
		print_warning "classifying ${MD_MAX} of ${total} held pull requests; use --repo owner/repo or a larger --max for the rest"
	fi
	now=$(date -u '+%s')
	records=$(mktemp)
	while IFS=$'\t' read -r repo number; do
		[[ -n "$repo" && "$number" =~ ^[0-9]+$ ]] || continue
		_md_classify_issue "$repo" "$number" "$now" >>"$records"
	done < <(printf '%s\n' "$refs" | awk -v max="$MD_MAX" 'NR <= max')
	while IFS=$'\t' read -r repo number; do
		[[ -n "$repo" && "$number" =~ ^[0-9]+$ ]] || continue
		_md_classify_pr "$repo" "$number" "$now" >>"$records"
		pr_count=$((pr_count + 1))
	done < <(printf '%s\n' "$pr_refs" | awk -v max="$MD_MAX" 'NR <= max')
	while IFS=$'\t' read -r repo number head epoch; do
		[[ "$pr_count" -lt "$MD_MAX" ]] || break
		grep -Fxq -- "${repo}"$'\t'"${number}" <<<"$pr_refs" && continue
		_md_classify_trust_pr "$repo" "$number" "$head" "$epoch" "$now" >>"$records"
		pr_count=$((pr_count + 1))
	done < <(_md_t2449_refs)
	jq -s '.' "$records" | _md_render
	rm -f "$records"
	return "$status"
}

main() {
	local command="${1:-help}"
	[[ $# -gt 0 ]] && shift
	while [[ $# -gt 0 ]]; do
		local opt="$1" value="${2:-}"
		case "$opt" in
		--repo | --format | --max)
			[[ $# -ge 2 ]] || {
				print_error "${opt} needs a value"
				return 1
			}
			shift 2
			;;
		*)
			print_error "unknown option: ${opt}"
			_md_usage
			return 1
			;;
		esac
		case "$opt" in
		--repo) MD_REPO="$value" ;;
		--format) MD_FORMAT="$value" ;;
		--max) MD_MAX="$value" ;;
		esac
	done
	[[ "$MD_MAX" =~ ^[0-9]+$ ]] || {
		print_error "--max must be a number"
		return 1
	}
	[[ -z "$MD_REPO" || "$MD_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
		print_error "--repo must be owner/repo"
		return 1
	}
	case "$command" in
	list) _md_list ;;
	help | --help | -h) _md_usage ;;
	*)
		print_error "unknown command: ${command}"
		_md_usage
		return 1
		;;
	esac
	return $?
}

main "$@"
