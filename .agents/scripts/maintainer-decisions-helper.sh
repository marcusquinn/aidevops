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
# and whether a maintainer already answered. The maintainer can then decide a
# batch of holds in one interactive session (/decisions) instead of opening
# each issue. The AI-side recovery queue is terminal-blocker-recovery-helper.sh.
#
# Read-only: this helper never writes to GitHub. Question text is untrusted
# issue data: print it, never execute it.
#
# Kinds (actionable first):
#   decide       a recorded question with no later maintainer answer
#   permission   needs-maintainer-permissions, unanswered
#   credentials  needs-credentials, unanswered
#   replied      an unmarked OWNER/MEMBER comment follows the newest request;
#                it may be a typed answer or app automation posted with the
#                owner's token, so the caller checks reply_excerpt
#   manual       a hold with no worker/supervisor request (maintainer-owned task)
#   no-question  held after a worker/supervisor request with no question text;
#                an AI-side gap: the recovery supervisor must publish one
#   answered     an explicit maintainer answer follows the newest request; the
#                recovery pass owns the next step
#   parked       a repo recovery-policy decision is newer than the newest
#                request; it waits on the decision's reopen conditions
#
# An explicit answer is an OWNER/MEMBER comment carrying the
# <!-- aidevops:maintainer-decision --> marker that /decisions writes, or a
# standalone terminal-blocker-circuit:retry directive. A comment with no
# aidevops signature or automation marker is only a reply: the same login can
# post typed answers and third-party automation.
#
# Usage:
#   maintainer-decisions-helper.sh list [--repo owner/repo] [--format tsv|json|md] [--max N]
#
# Env:
#   MAINTAINER_DECISIONS_REPOS_JSON  repos.json path (default ~/.config/aidevops/repos.json)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1

# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

MD_REPOS_JSON="${MAINTAINER_DECISIONS_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
MD_HOLD_LABELS="needs-maintainer-input,needs-maintainer-permissions,needs-credentials"
MD_SEARCH_PAGES=10
MD_FORMAT="tsv"
MD_REPO=""
MD_MAX=300

# Classify one `gh issue view --json number,title,url,createdAt,labels,comments`
# object. Requests come from trusted runner/supervisor comments; answers only
# from OWNER/MEMBER (the recovery pass's authoritative associations).
# shellcheck disable=SC2016 # jq program, variables bound with --arg
MD_CLASSIFY_JQ='
def trusted: (.authorAssociation // "") | IN("OWNER", "MEMBER", "COLLABORATOR");
def authoritative: (.authorAssociation // "") | IN("OWNER", "MEMBER");
def text: .body // "";
def automation: text | test("aidevops:origin:worker|<!-- ops:start|aidevops:terminal-blocker-|<!-- dispatch-|aidevops:ops |aidevops:dispatch |(?m)^(DISPATCH_CLAIM|DISPATCH_LEASE|CLAIM_RELEASED) ");
def first_capture($re; $name): [text | capture($re)? | .[$name]] | first // "";
def clean: gsub("[[:cntrl:]]"; " ") | gsub("\\s+"; " ") | ltrimstr(" ") | .[0:300];
def visible_lines:
	text | split("\n") | reduce .[] as $line ({fence: null, lines: []};
		($line | capture("^\\s*(?<marker>`{3,}|~{3,})")? // null) as $f
		| if $f != null and .fence == null then .fence = $f.marker
		  elif $f != null and .fence != null and ($f.marker[0:1] == .fence[0:1]) and ($f.marker | length) >= (.fence | length) then .fence = null
		  elif .fence == null then .lines += [$line] else . end) | .lines;
def supervisor_ask:
	visible_lines as $lines
	| [range(0; $lines | length) as $i
		| ($lines[$i] | capture("(?i)^\\s*(?:[-*]\\s+)?\\*\\*(?:Still needed|Smallest (?:human )?input(?: needed)?|Missing input)(?: \\((?:owner: [^)]*|reply with one)\\))?[.:]?\\*\\*(?: \\(owner: [^)]*\\))?[,:.]?\\s*(?<q>.*)$")? // null) as $m
		| select($m != null and ($lines[$i] | test("(?i)owner: [a-z]+|Smallest input \\(reply with one\\)")))
		| ($m.q | clean) as $q
		| if $q == "" or ($q | test("(?i)^(either of|pick one|choose one|reply with one)[.:]?$")) then
			([$lines[$i+1:$i+4][] | select(test("^\\s*(?:[-*]\\s+|[0-9]+[.)]\\s+)")) | sub("^\\s*(?:[-*]\\s+|[0-9]+[.)]\\s+)"; "")] | join("; ") | clean)
		  else $q end] | first // "";
def days($t): if $t == null or $t == "" then null
	else ((($now | tonumber) - ($t | fromdateiso8601)) / 86400 | floor) end;
[.labels[]?.name] as $labels
| [.comments[]? | select(trusted)] as $c
| [$c[] | select(text | test("Terminal blocker: reason=")) | {
	t: .createdAt, by: .author.login, src: "worker",
	reason: first_capture("Terminal blocker: reason=(?<r>[a-z_]+)"; "r"),
	q: (first_capture("(?m)^(?:Input requested|Trigger awaited): (?<q>[^\\n]+)$"; "q") | clean)}] as $holds
| [$c[] | (supervisor_ask) as $ask | select($ask != "") | {
	t: .createdAt, by: .author.login, src: "supervisor", reason: "",
	q: $ask, recommendation: ([visible_lines[] | capture("(?i)^\\s*(?:[-*]\\s+)?\\*\\*Recommended path:[*][*]\\s*(?<r>.*)$")? | .r | clean] | first // null)}] as $asks
| ([$c[] | select(text | test("<!-- aidevops:recovery-policy:[a-z_]+:")) | {
	t: .createdAt, action: first_capture("<!-- aidevops:recovery-policy:(?<a>[a-z_]+):"; "a")}] | max_by(.t)) as $park
| ([$c[] | select(authoritative) | select(
	(text | test("<!-- aidevops:maintainer-decision"))
	or (text | test("(?m)^terminal-blocker-circuit:retry[ \\t]*\\r?$")))
	| {t: .createdAt, by: .author.login}] | max_by(.t)) as $answer
| ([$c[] | select(authoritative) | select(((text | test("aidevops:sig")) | not) and (automation | not))
	| {t: .createdAt, by: .author.login, excerpt: (text | clean | .[0:200])}] | max_by(.t)) as $reply
| (($holds + $asks) | sort_by(.t)) as $requests
| ($requests | last) as $anchor
| ([$requests[] | select(.q != "" and ($answer == null or .t > $answer.t))] | last) as $question
| (if $anchor != null and $reply != null and $reply.t > $anchor.t then $reply else null end) as $fresh_reply
| (if ($labels | index("needs-maintainer-permissions")) then "permission"
	elif ($labels | index("needs-credentials")) and (($labels | index("needs-maintainer-input")) | not) then "credentials"
	else null end) as $label_kind
| (if $anchor == null then ($label_kind // "manual")
	elif $answer != null and $answer.t > $anchor.t then "answered"
	elif $park != null and $park.t > $anchor.t then "parked"
	elif $fresh_reply != null then "replied"
	elif $question != null then ($label_kind // "decide")
	else ($label_kind // "no-question") end) as $kind
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
	hold_labels: [$labels[] | select(IN("needs-maintainer-input", "needs-maintainer-permissions", "needs-credentials", "hold-for-review", "status:blocked"))]
}
'

# Kinds in presentation order, with md headings. The only kind table.
# shellcheck disable=SC2016 # jq program
MD_KINDS_JQ='
def kinds: [
	["decide", "Needs your decision"],
	["permission", "Needs a permission decision"],
	["credentials", "Needs credentials"],
	["replied", "Replied: check whether the reply answers the question"],
	["manual", "Maintainer-owned holds (no AI request recorded)"],
	["no-question", "AI-side gaps: held with no question recorded"],
	["answered", "Answered: waiting on the recovery pass"],
	["parked", "Parked by repo recovery policy"],
	["error", "Unreadable"]];
def rank_of($k): ([kinds[][0]] | index($k)) // (kinds | length);
def heading_of($k): ([kinds[] | select(.[0] == $k) | .[1]] | first) // $k;
'
MD_ORDER_JQ="${MD_KINDS_JQ}"'sort_by(rank_of(.kind), -(.age_days // 0), .repo, .number)'

_md_usage() {
	cat <<EOF
Usage: $(basename "$0") list [--repo owner/repo] [--format tsv|json|md] [--max N]

Read-only cross-repo maintainer decision queue for managed pulse repos.
Lists open issues labelled ${MD_HOLD_LABELS//,/, }.

Options:
  --repo owner/repo   Limit to one repository
  --format tsv|json|md
                      tsv (default): kind, age_days, ref, reason, question or title, url
                      json: array of records
                      md: counts plus numbered lists grouped by kind
  --max N             Maximum issues to classify (default: ${MD_MAX})
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

# Prints "owner/repo<TAB>number" for open held issues matching one search scope.
# Args: scope qualifier (user:<owner> or repo:<owner/repo>), managed slugs JSON array
_md_search_scope() {
	local scope="$1"
	local slugs_json="$2"
	local query="is:open is:issue label:${MD_HOLD_LABELS} -label:parent-task ${scope}"
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

# Prints unique held issue refs across managed repos (or one repo).
_md_discover() {
	local slugs=""
	local slugs_json=""
	local owner=""
	slugs=$(_md_managed_slugs) || return 1
	if [[ -n "$MD_REPO" ]]; then
		slugs_json=$(jq -Rn --arg r "$MD_REPO" '[$r]')
		_md_search_scope "repo:${MD_REPO}" "$slugs_json" || return 1
		return 0
	fi
	slugs_json=$(printf '%s\n' "$slugs" | jq -Rn '[inputs | select(length > 0)]')
	while IFS= read -r owner; do
		[[ -n "$owner" ]] || continue
		_md_search_scope "user:${owner}" "$slugs_json" || true
	done < <(printf '%s\n' "$slugs" | cut -d/ -f1 | sort -u)
	return 0
}

# Prints an error record for an issue that could not be read or classified.
# Args: repo, number, title
_md_error_record() {
	local repo="$1"
	local number="$2"
	local title="$3"
	jq -cn --arg repo "$repo" --argjson n "$number" --arg title "$title" \
		'{repo: $repo, number: $n, kind: "error", title: $title, age_days: null}'
	return 0
}

# Prints one classified JSON record for an issue ref (error record on failure).
# Args: repo, number, now epoch
_md_classify_issue() {
	local repo="$1"
	local number="$2"
	local now="$3"
	local issue_json=""
	if ! issue_json=$(gh issue view "$number" --repo "$repo" --json number,title,url,createdAt,labels,comments 2>/dev/null); then
		_md_error_record "$repo" "$number" "issue read failed"
		return 0
	fi
	jq -c --arg repo "$repo" --arg now "$now" "$MD_CLASSIFY_JQ" <<<"$issue_json" ||
		_md_error_record "$repo" "$number" "classification failed"
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
			| def line: "\(.repo)#\(.number) (\(.age_days // "-")d\(if (.reason // "") != "" then ", " + .reason else "" end)): \(.question // .title)"
				+ (if .reply_excerpt != null then "\n   reply: \(.reply_excerpt)" else "" end)
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

_md_list() {
	local refs=""
	local records=""
	local repo=""
	local number=""
	local now=""
	local total=0
	refs=$(_md_discover | sort -u) || return 1
	now=$(date -u '+%s')
	records=$(mktemp)
	while IFS=$'\t' read -r repo number; do
		[[ -n "$repo" && "$number" =~ ^[0-9]+$ ]] || continue
		total=$((total + 1))
		if [[ "$total" -gt "$MD_MAX" ]]; then
			print_warning "stopped at --max ${MD_MAX}; more held issues exist"
			break
		fi
		_md_classify_issue "$repo" "$number" "$now" >>"$records"
	done <<<"$refs"
	jq -s '.' "$records" | _md_render
	rm -f "$records"
	return 0
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
