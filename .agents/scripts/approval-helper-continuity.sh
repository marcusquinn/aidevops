#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# approval-helper-continuity.sh — Locked approval continuity verification.
# =============================================================================
# Sourced by approval-helper.sh after approval constants and snapshot helpers.
# Keeps lifecycle continuity checks separate from approval issuance and writes.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_APPROVAL_HELPER_CONTINUITY_LOADED:-}" ]] && return 0
_APPROVAL_HELPER_CONTINUITY_LOADED=1
_APPROVAL_LABELED_EVENT="labeled"
# Worker-observability classification (t3077); not scope-bearing.
_APPROVAL_OBSERVABILITY_LABEL="fix-the-fixer"
# GH#37762: dispatch hold toggled by signed permission requests/decisions.
_APPROVAL_PERMISSION_HOLD_LABEL="needs-maintainer-permissions"
# GH#37993: long-lived non-task marker; add-only after signing.
_APPROVAL_PERSISTENT_LABEL="persistent"
_APPROVAL_CONTINUITY_JSON_NUMBER="number"
_APPROVAL_CONTINUITY_JSON_STRING="string"

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_approval_continuity_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_approval_continuity_lib_path" == "${BASH_SOURCE[0]}" ]] && _approval_continuity_lib_path="."
	SCRIPT_DIR="$(cd "$_approval_continuity_lib_path" && pwd)"
	unset _approval_continuity_lib_path
fi

_approval_continuity_actor_authorized() {
	local slug="$1"
	local login="$2"
	local permission=""
	[[ "$login" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
	permission=$(gh api "repos/${slug}/collaborators/${login}/permission" --jq '.permission // "none"' 2>/dev/null) || return 2
	case "$permission" in
	admin | maintain | write) return 0 ;;
	esac
	return 1
}

_approval_continuity_is_repository_status_default() {
	local event="$1"
	local subject="$2"
	local actor="$3"
	local actor_id="$4"
	local actor_type="$5"
	[[ "$event" == "$_APPROVAL_LABELED_EVENT" && "$subject" == "$_APPROVAL_AVAILABLE_LABEL" ]] || return 1
	[[ "$actor" == "github-actions[bot]" ]] || return 1
	[[ "$actor_id" == "$_APPROVAL_GITHUB_ACTIONS_BOT_ID" ]] || return 1
	[[ "$actor_type" == "Bot" ]] || return 1
	return 0
}

_approval_continuity_ordered_mutation_rows() {
	local timeline_pages="$1"
	local issued_at="$2"
	local approval_comment_id="$3"

	# #aidevops:trust-boundary — the signed approval comment is the stable
	# timeline anchor. Flatten every page, validate the complete mutation stream,
	# and sort by GitHub's stable (created_at, id) key before authorization.
	jq -r --arg issued "$issued_at" --argjson approval_id "$approval_comment_id" \
		--arg number_type "$_APPROVAL_CONTINUITY_JSON_NUMBER" --arg string_type "$_APPROVAL_CONTINUITY_JSON_STRING" '
		def valid_id:
			type == $number_type and . >= 0 and floor == .;
		def valid_timestamp:
			type == $string_type
			and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
			and ((try (fromdateiso8601 | todateiso8601) catch "") == .);
		def lifecycle_mutation:
			(.event // "") as $event
			| ["assigned","unassigned","labeled","unlabeled","milestoned","demilestoned","closed","reopened","renamed","locked","unlocked","connected","disconnected","added_to_project","moved_columns_in_project","removed_from_project","transferred","converted_to_discussion","marked_as_duplicate","unmarked_as_duplicate","pinned","unpinned"]
			| index($event) != null;
		[.[][]?] as $events
		| [$events[] | select((.event // "") == "commented" and (.id // null) == $approval_id)] as $anchors
		| [$events[] | select(lifecycle_mutation)] as $mutations
		| if (($issued | valid_timestamp) | not)
			or ($anchors | length) != 1
			or (($anchors[0].id | valid_id) | not)
			or (($anchors[0].created_at | valid_timestamp) | not)
			or $anchors[0].created_at < $issued
			or any($mutations[]; ((.id // null) | valid_id) | not)
			or any($mutations[]; ((.created_at // "") | valid_timestamp) | not)
			or (($mutations + $anchors) | sort_by(.created_at, .id) | group_by([.created_at, .id]) | any(length > 1))
		then error("timeline ordering evidence is incomplete or ambiguous")
		else
			$anchors[0] as $anchor
			| $mutations
			| map(select(.created_at > $anchor.created_at or (.created_at == $anchor.created_at and .id > $anchor.id)))
			| sort_by(.created_at, .id)
			| .[]
			# Renames have no label/assignee; a fixed subject keeps the TSV
			# columns aligned because read collapses adjacent tab separators.
			| [(.event // ""), (.actor.login // ""), (.label.name // .assignee.login // (if .event == "renamed" then "title" else "" end)), ((.actor.id // "") | tostring), (.actor.type // "")]
			| @tsv
		end
	' <<<"$timeline_pages"
	return $?
}

# #aidevops:trust-boundary — GH#37762: an allowlisted hold label must be
# explained by the visible replay, as auto-dispatch is. Rebuild its state from
# the signed lifecycle plus visible labeled/unlabeled events and require it to
# equal the current state, so a timeline that omits a toggle (visibility lag or
# truncation) fails continuity instead of verifying on other mutations.
_approval_continuity_label_replay_matches() {
	local signed_lifecycle="$1"
	local current_snapshot="$2"
	local mutation_rows="$3"
	local label="$4"
	local active=0 current=0 event="" _actor="" subject="" _rest=""
	if jq -e --arg label "$label" 'any(.labels[]?.name; . == $label)' <<<"$signed_lifecycle" >/dev/null 2>&1; then
		active=1
	fi
	if jq -e --arg label "$label" 'any(.lifecycle.labels[]?.name; . == $label)' <<<"$current_snapshot" >/dev/null 2>&1; then
		current=1
	fi
	while IFS=$'\t' read -r event _actor subject _rest; do
		[[ "$subject" == "$label" ]] || continue
		case "$event" in
		"$_APPROVAL_LABELED_EVENT") active=1 ;;
		unlabeled) active=0 ;;
		esac
	done <<<"$mutation_rows"
	[[ "$active" -eq "$current" ]] || return 1
	return 0
}

# Tier and fix-the-fixer labels retain their separate backfill/observability
# rules; their legitimate pre-anchor transitions are not necessarily visible.
_approval_continuity_reconciled_labels_match() {
	local signed="$1" snapshot="$2" rows="$3" label=""
	for label in auto-dispatch needs-maintainer-permissions needs-maintainer-review "$_APPROVAL_PERSISTENT_LABEL" \
		status:available status:queued status:claimed status:in-progress status:in-review status:done status:blocked; do
		_approval_continuity_label_replay_matches "$signed" "$snapshot" "$rows" "$label" || return 1
	done
	return 0
}

_approval_continuity_lifecycle_change_allowed() {
	local signed_lifecycle="$1"
	local current_snapshot="$2"
	local self_hosting="${3:-false}"

	# #aidevops:trust-boundary — deterministic tier backfill may only select a
	# canonical workload tier. Status labels remain workflow metadata, but every
	# resulting timeline mutation still requires authorization during replay.
	# GH#36746: the fix-the-fixer classification only enables worker
	# observability; it never widens scope or grants authority.
	# GH#37762: needs-maintainer-permissions is a dispatch hold toggled by
	# separately signed permission requests/decisions; it never widens scope.
	# GH#37993: persistent may only be added. It marks a long-lived non-task
	# record and only restricts automation; removing it stays approval-bound,
	# so a removal (revocation path) stales the signature.
	jq -e --argjson signed "$signed_lifecycle" --argjson self_hosting "$self_hosting" \
		--arg observability "$_APPROVAL_OBSERVABILITY_LABEL" \
		--arg persistent "$_APPROVAL_PERSISTENT_LABEL" \
		--argjson tiers '["tier:simple","tier:standard","tier:thinking"]' '
		def tier_label: . as $label | $tiers | index($label) != null;
		def allowed_label: . == "needs-maintainer-review" or . == "needs-maintainer-permissions" or . == "auto-dispatch" or . == "status:available" or . == "status:queued" or . == "status:claimed" or . == "status:in-progress" or . == "status:in-review" or . == "status:done" or . == "status:blocked" or . == $observability or tier_label;
		def allowed_added_label: allowed_label or . == $persistent;
		.lifecycle as $current |
		($current.labels | map(.name)) as $current_labels |
		($signed.labels | map(.name)) as $signed_labels |
		($current_labels - $signed_labels) as $added_labels |
		($signed_labels - $current_labels) as $removed_labels |
		([$added_labels[] | select(tier_label)] | length) as $added_tiers |
		([$removed_labels[] | select(tier_label)] | length) as $removed_tiers |
		([$signed_labels[] | select(tier_label)] | length) as $signed_tiers |
		([$current_labels[] | select(tier_label)] | length) as $current_tiers |
		$current.state == $signed.state
		and $current.state_reason == $signed.state_reason
		and $current.locked == $signed.locked
		and $current.active_lock_reason == $signed.active_lock_reason
		and $current.milestone == $signed.milestone
		and $current.lock_anchor == $signed.lock_anchor
		and ($added_labels | all(allowed_added_label))
		and ($removed_labels | all(allowed_label))
		and (if ($added_tiers + $removed_tiers) > 0 then
			($signed_tiers == 0 and $current_tiers == 1 and $added_tiers == 1 and $removed_tiers == 0)
			or ($self_hosting and $signed_tiers == 1 and $current_tiers == 1
				and $added_tiers == 1 and $removed_tiers == 1
				and ($added_labels | index($tiers[2])) != null
				and any($removed_labels[]; . == $tiers[0] or . == $tiers[1]))
		else true end)
		and ($current.assignees != $signed.assignees or $current.labels != $signed.labels)
	' <<<"$current_snapshot" >/dev/null 2>&1
	return $?
}

_approval_continuity_self_hosting_audit() {
	local slug="$1" number="$2" issued="$3" timeline="$4"
	local pages="" audits="" actor=""
	pages=$(_approval_snapshot_v2_fetch_pages "repos/${slug}/issues/${number}/comments?per_page=100") || return 2
	# Reuse the exact canonical matcher, not a second hand-copied writer regex.
	# #aidevops:trust-boundary — an audit is evidence, never authority by itself;
	# the normal ordered timeline replay still authenticates every mutation.
	audits=$(_approval_snapshot_v2_comments_json "$pages" "" conversation "$issued" "$number" "$slug" self-hosting-audit) || return 2
	actor=$(jq -er --arg string_type "$_APPROVAL_CONTINUITY_JSON_STRING" 'select(length == 1) | .[0].actor | select(type == $string_type and length > 0)' <<<"$audits") || return 1
	jq -e --arg actor "$actor" --arg issued "$issued" --arg added "$_APPROVAL_LABELED_EVENT" --arg removed "unlabeled" \
		--argjson tiers '["tier:simple","tier:standard","tier:thinking"]' '
		[.[][]? | select(.created_at > $issued)
		| select((.event == $added or .event == $removed) and ((.label.name // "") | startswith("tier:")))] as $changes
		| ($changes | length) == 2
		and all($changes[]; .actor.login == $actor)
		and any($changes[]; .event == $added and .label.name == $tiers[2])
		and any($changes[]; .event == $removed and (.label.name == $tiers[0] or .label.name == $tiers[1]))
	' <<<"$timeline" >/dev/null 2>&1
	return $?
}

# #aidevops:trust-boundary — GH#33089: the approval locks the issue, so only
# collaborators can comment after it. A comment created after the approval
# comment (higher ID) by a User whose live repository permission is
# admin/maintain/write is authority-equivalent: that author could file the same
# text as a maintainer issue needing no approval. Drop only those comments from
# the continuity candidate. Pre-approval comments (including later edits),
# read/triage or unverifiable authors, and author_association alone stay bound.
# Prints the filtered snapshot; returns 2 on permission API uncertainty.
_approval_continuity_drop_trusted_comments() {
	local current_snapshot="$1"
	local slug="$2"
	local approval_comment_id="$3"
	local logins="" login="" trusted_logins="" login_rc=0
	[[ "$approval_comment_id" =~ ^[0-9]+$ ]] || return 1
	logins=$(jq -r --argjson anchor "$approval_comment_id" --arg number_type "$_APPROVAL_CONTINUITY_JSON_NUMBER" '
		[.comments[]? | select((.id | type) == $number_type and .id > $anchor and .author.type == "User") | .author.login]
		| unique | .[]
	' <<<"$current_snapshot") || return 1
	while IFS= read -r login; do
		[[ -n "$login" ]] || continue
		login_rc=0
		_approval_continuity_actor_authorized "$slug" "$login" || login_rc=$?
		case "$login_rc" in
		0) trusted_logins="${trusted_logins}${login}"$'\n' ;;
		1) ;;
		*) return 2 ;;
		esac
	done <<<"$logins"
	jq -cS --argjson anchor "$approval_comment_id" --arg trusted "$trusted_logins" --arg number_type "$_APPROVAL_CONTINUITY_JSON_NUMBER" '
		($trusted | split("\n") | map(select(length > 0))) as $trusted_logins
		| if has("comments") then
			.comments |= map(select(
				(.id | type) == $number_type and .id > $anchor and .author.type == "User"
				and (.author.login as $login | any($trusted_logins[]; . == $login))
				| not))
		else . end
	' <<<"$current_snapshot"
	return $?
}

# #aidevops:trust-boundary — GH#33097: new issue payloads carry per-component
# digests. Prove the candidate differs from the signed snapshot only in title
# and/or body: the frame (everything else, lifecycle already replaced by the
# signed lifecycle) must reproduce the signed frame digest exactly. Legacy
# payloads without component digests keep exact whole-snapshot binding.
# Prints "title" and/or "body" (one per line) for the changed components.
_approval_continuity_content_changes() {
	local payload="$1"
	local candidate="$2"
	local signed_digests="" current_digests=""
	signed_digests=$(jq -c --arg sha "^[0-9a-f]{64}$" --arg object "$APPROVAL_JSON_OBJECT" --arg string_type "$_APPROVAL_CONTINUITY_JSON_STRING" '
		.issue.content_digests
		| select(type == $object and all(.title, .body, .frame; type == $string_type and test($sha)))
	' <<<"$payload" 2>/dev/null) || return 1
	[[ -n "$signed_digests" ]] || return 1
	current_digests=$(approval_snapshot_v2_content_digests "$candidate") || return 1
	jq -er --argjson signed "$signed_digests" '
		select(.frame == $signed.frame and (.title != $signed.title or .body != $signed.body))
		| (if .title != $signed.title then "title" else empty end), (if .body != $signed.body then "body" else empty end)
	' <<<"$current_digests" 2>/dev/null || return 1
	return 0
}

# #aidevops:trust-boundary — GH#33097: REST exposes no editor identity for
# issue bodies, so read GraphQL userContentEdits. Every edit at or after the
# approval anchor must name a live admin/maintain/write User. A missing or
# deleted (ghost) editor, missing post-approval history, a second page, or any
# GraphQL error is uncertainty (return 2); an untrusted editor returns 1.
# Args: slug, issue number, timeline pages JSON, approval comment ID.
_approval_continuity_body_edits_authorized() {
	local slug="$1"
	local number="$2"
	local timeline_pages="$3"
	local approval_comment_id="$4"
	local owner="${slug%%/*}" name="${slug#*/}" anchor_created_at="" response="" editors="" editor="" editor_rc=0
	# shellcheck disable=SC2016 # GraphQL variables, not shell expansions.
	local query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){userContentEdits(first:100){pageInfo{hasNextPage} nodes{editedAt editor{__typename login}}}}}}'
	[[ "$number" =~ ^[0-9]+$ && "$approval_comment_id" =~ ^[0-9]+$ && -n "$owner" && -n "$name" ]] || return 2
	# The approval comment's timeline entry is the edit-history cutoff.
	anchor_created_at=$(jq -er --argjson id "$approval_comment_id" --arg string_type "$_APPROVAL_CONTINUITY_JSON_STRING" '
		[.[][]? | select((.event // "") == "commented" and (.id // null) == $id)]
		| select(length == 1) | .[0].created_at | select(type == $string_type)
	' <<<"$timeline_pages" 2>/dev/null) || return 2
	response=$(gh api graphql -f query="$query" -f owner="$owner" -f name="$name" -F number="$number" 2>/dev/null) || return 2
	editors=$(jq -r --arg anchor "$anchor_created_at" --arg object "$APPROVAL_JSON_OBJECT" --arg string_type "$_APPROVAL_CONTINUITY_JSON_STRING" '
		def valid_timestamp:
			type == $string_type and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$");
		(.data.repository.issue.userContentEdits // null) as $edits
		| if (.errors // null) != null
			or ($edits | type) != $object
			or ($edits.pageInfo | type) != $object
			or $edits.pageInfo.hasNextPage != false
			or ($edits.nodes | type) != "array"
			or any($edits.nodes[]; (.editedAt | valid_timestamp) | not)
		then error("edit history is incomplete")
		else
			[$edits.nodes[] | select(.editedAt[0:19] >= $anchor[0:19])] as $post
			| if ($post | length) == 0
				or any($post[]; (.editor | type) != $object
					or .editor.__typename != "User"
					or ((.editor.login // "") | test("^[A-Za-z0-9_.-]+$") | not)
					or .editor.login == "ghost")
			then error("post-approval editor identity is unavailable")
			else [$post[].editor.login] | unique | .[] end
		end
	' <<<"$response" 2>/dev/null) || return 2
	while IFS= read -r editor; do
		[[ -n "$editor" ]] || continue
		editor_rc=0
		_approval_continuity_actor_authorized "$slug" "$editor" || editor_rc=$?
		[[ "$editor_rc" -eq 0 ]] || return "$editor_rc"
	done <<<"$editors"
	return 0
}

# GH#38006: review-bot body blocks live beside the review-bot identity config.
_APPROVAL_REVIEW_BOT_BLOCKS_FILE="${SCRIPT_DIR}/../configs/review-bot-body-blocks.conf"
_APPROVAL_TRUSTED_REVIEW_BOTS_FILE="${SCRIPT_DIR}/../configs/trusted-code-quality-bots.txt"

# Prints the review-bot block rules as a JSON array of {login, start, end}.
# #aidevops:trust-boundary — a rule needs an exact App login that is also in
# the trusted review-bot identity allowlist plus distinct HTML comment
# markers. A missing file yields no rules; any malformed line returns 1 so the
# caller disables every rule (fail closed).
_approval_continuity_review_bot_rules() {
	local login="" rules='[]' line="" start_marker="" end_marker="" extra=""
	[[ -f "$_APPROVAL_REVIEW_BOT_BLOCKS_FILE" ]] || {
		printf '%s\n' "$rules"
		return 0
	}
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "$line" || "$line" == \#* ]] && continue
		IFS='|' read -r login start_marker end_marker extra <<<"$line"
		[[ -z "$extra" && "$login" =~ ^[A-Za-z0-9_.-]+\[bot\]$ ]] || return 1
		[[ "$start_marker" == '<!--'*'-->' && "$end_marker" == '<!--'*'-->' && "$start_marker" != "$end_marker" ]] || return 1
		[[ -f "$_APPROVAL_TRUSTED_REVIEW_BOTS_FILE" ]] || return 1
		grep -Fxq -- "$login" "$_APPROVAL_TRUSTED_REVIEW_BOTS_FILE" || return 1
		rules=$(jq -c --arg login "$login" --arg start "$start_marker" --arg end "$end_marker" '. + [{login: $login, start: $start, end: $end}]' <<<"$rules") || return 1
	done <"$_APPROVAL_REVIEW_BOT_BLOCKS_FILE"
	printf '%s\n' "$rules"
	return 0
}

# Reads one linked source's GraphQL body history (Issue or PullRequest node).
_approval_continuity_source_edit_history() {
	local node_id="$1"
	# shellcheck disable=SC2016 # GraphQL variables, not shell expansions.
	local query='query($id:ID!){node(id:$id){__typename ... on Issue{id userContentEdits(first:100){pageInfo{hasNextPage} nodes{editedAt diff editor{__typename login}}}} ... on PullRequest{id userContentEdits(first:100){pageInfo{hasNextPage} nodes{editedAt diff editor{__typename login}}}}}}'
	[[ "$node_id" =~ ^[A-Za-z0-9_=-]+$ ]] || return 1
	gh api graphql -f query="$query" -f id="$node_id" 2>/dev/null || return 1
	return 0
}

# jq program: restore one linked source body to its revision at signing time.
# Inputs (stdin): the candidate snapshot, then the GraphQL history response.
# Prints {changed:false} or {changed:true, candidate, edits}. Errors mean the
# history cannot explain the current body (uncertainty).
_approval_continuity_linked_restore_program() {
	cat <<'JQ'
def valid_timestamp:
	type == $string_type and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$");
def body_bound: (.source | type) == $object and (.source | has("body"));
def blank_block($rule):
	split($rule.start) as $parts
	| $parts[0] + ([$parts[1:][] | split($rule.end) as $tail
		| if ($tail | length) < 2 then error("unterminated review-bot block")
		else $rule.start + $rule.end + ($tail[1:] | join($rule.end)) end] | join(""));
def blank_blocks($bot_rules): reduce $bot_rules[] as $rule (.; blank_block($rule));
def edit_entry($before; $after):
	if (.editor | type) != $object
		or (.editor.login | type) != $string_type
		or (.editor.login | test("^[A-Za-z0-9_.-]+$") | not)
		or .editor.login == "ghost"
	then error("linked source editor identity is unavailable")
	elif .editor.__typename == "User" then {type: "User", login: .editor.login}
	elif .editor.__typename == "Bot" then
		(.editor.login + "[bot]") as $app
		| [$rules[] | select(.login == $app)] as $bot_rules
		| {type: "Bot", login: $app,
			block_only: (($bot_rules | length) > 0
				and (try (($before | blank_blocks($bot_rules)) == ($after | blank_blocks($bot_rules))) catch false))}
	else {type: (.editor.__typename // "unknown"), login: .editor.login} end;
input as $candidate | input as $response | ($issued[0:19]) as $cutoff
| ([$candidate.linked_references[]? | select(body_bound and .source.node_id == $id) | .source.body] | unique) as $bodies
| ($response.data.node // null) as $node
| ($node.userContentEdits // null) as $edits
| if ($bodies | length) != 1 or ($bodies[0] | type) != $string_type then error("linked source body is ambiguous")
elif ($response.errors // null) != null
	or ($node | type) != $object or ($node.id // null) != $id
	or ($edits | type) != $object or ($edits.pageInfo | type) != $object
	or $edits.pageInfo.hasNextPage != false
	or ($edits.nodes | type) != "array"
	or any($edits.nodes[]; (.editedAt | valid_timestamp) | not)
then error("linked source edit history is incomplete")
else
	($edits.nodes | sort_by(.editedAt[0:19])) as $revisions
	| ($revisions | length) as $count
	| if $count == 0 or $revisions[-1].editedAt[0:19] < $cutoff then {changed: false}
	elif ($revisions | map(.editedAt[0:19]) | unique | length) != $count then error("linked source edit order is ambiguous")
	elif $revisions[-1].diff != $bodies[0] then error("edit history does not explain the current body")
	else
		([range(0; $count) | select($revisions[.].editedAt[0:19] < $cutoff)] | last // null) as $base
		| if $base == null or any($revisions[$base:][]; (.diff | type) != $string_type)
		then error("signed linked source revision is unavailable")
		elif $revisions[$base].diff == $bodies[0] then {changed: false}
		else {
			changed: true,
			edits: [range($base + 1; $count) as $index
				| $revisions[$index] | edit_entry($revisions[$index - 1].diff; .diff)],
			candidate: ($candidate | .linked_references |= map(
				if body_bound and .source.node_id == $id then .source.body = $revisions[$base].diff else . end))
		} end
	end
end
JQ
	return 0
}

# #aidevops:trust-boundary — GH#38006: a content-bound linked source (an
# external issue/PR) binds its body. Restore each changed source body to its
# GraphQL userContentEdits revision live at issued_at so the caller can prove
# the restored candidate reproduces the signed digest/frame. Payloads with
# linked digests name the changed sources and must keep linked_frame; older
# payloads try every body-bound source. Prints {candidate, edits} where edits
# lists every post-signing editor for _approval_continuity_linked_edits_authorized.
# Returns 1 when no linked body change can explain the drift, 2 on uncertainty
# about a named changed source (GraphQL error, second page, missing/ghost
# editor or unexplained history); older payloads map that uncertainty to 1.
_approval_continuity_linked_source_candidate() {
	local payload="$1"
	local candidate="$2"
	local issued_at="$3"
	local source_profile="${4:-}"
	local signed_linked="" node_ids="" node_id="" current_frame="" current_bodies="" rules="" history="" result=""
	local edits='[]' changed=0 named_sources=0 uncertain_rc=2
	[[ "$issued_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
	# #aidevops:trust-boundary — GH#38006: trusted-sources and stable profiles
	# keep exact-match linked-body behaviour; never restore their linked bodies.
	if [[ "$source_profile" == "$APPROVAL_SNAPSHOT_PROFILE_TRUSTED_SOURCES" || "$source_profile" == "$APPROVAL_SNAPSHOT_PROFILE_STABLE" ]]; then
		return 1
	fi
	signed_linked=$(jq -c --arg sha "^[0-9a-f]{64}$" --arg object "$APPROVAL_JSON_OBJECT" --arg string_type "$_APPROVAL_CONTINUITY_JSON_STRING" '
		.issue.content_digests
		| select(type == $object and (.linked_frame | type) == $string_type and (.linked_frame | test($sha))
			and (.linked_bodies | type) == $object and all(.linked_bodies[]; type == $string_type and test($sha)))
		| {linked_frame, linked_bodies}
	' <<<"$payload" 2>/dev/null) || signed_linked=""
	if [[ -n "$signed_linked" ]]; then
		named_sources=1
		current_frame=$(approval_snapshot_v2_linked_frame_digest "$candidate") || return 1
		current_bodies=$(approval_snapshot_v2_linked_body_digests "$candidate") || return 1
		node_ids=$(jq -er --argjson signed "$signed_linked" --arg frame "$current_frame" '
			select($signed.linked_frame == $frame and keys == ($signed.linked_bodies | keys))
			| to_entries[] | select(.value != $signed.linked_bodies[.key]) | .key
		' <<<"$current_bodies" 2>/dev/null) || return 1
	else
		node_ids=$(jq -er "[(.linked_references // [])[] | select($(_approval_snapshot_v2_body_bound_source_filter)) | .source.node_id // \"\"] | unique | .[]" <<<"$candidate" 2>/dev/null) || return 1
	fi
	# Named (GH#38006+) sources changed for certain, so unreadable history is
	# uncertainty. Older payloads only guess which source changed; unreadable
	# history there keeps their prior stale outcome instead of API_ERROR.
	uncertain_rc=$((named_sources == 1 ? 2 : 1))
	rules=$(_approval_continuity_review_bot_rules) || rules='[]'
	while IFS= read -r node_id; do
		[[ "$node_id" =~ ^[A-Za-z0-9_=-]+$ ]] || return 1
		history=$(_approval_continuity_source_edit_history "$node_id") || return "$uncertain_rc"
		result=$(printf '%s\n%s\n' "$candidate" "$history" | jq -c -n --arg id "$node_id" --arg issued "$issued_at" \
			--arg object "$APPROVAL_JSON_OBJECT" --arg string_type "$_APPROVAL_CONTINUITY_JSON_STRING" --argjson rules "$rules" "$(_approval_continuity_linked_restore_program)" 2>/dev/null) || return "$uncertain_rc"
		if ! jq -e '.changed == true' <<<"$result" >/dev/null 2>&1; then
			# A named digest change with no post-signing history is unexplained.
			[[ "$named_sources" -eq 0 ]] || return 2
			continue
		fi
		changed=1
		candidate=$(jq -cS '.candidate' <<<"$result") || return 1
		edits=$(printf '%s\n%s\n' "$edits" "$result" | jq -c -n 'input as $edits | input | $edits + .edits') || return 1
	done <<<"$node_ids"
	[[ "$changed" -eq 1 ]] || return 1
	printf '%s\n%s\n' "$candidate" "$edits" | jq -c -n 'input as $candidate | input as $edits | {candidate: $candidate, edits: $edits}'
	return $?
}

# #aidevops:trust-boundary — GH#38006: every post-signing linked-source edit
# must come from a live admin/maintain/write User, or from an allowlisted
# review bot whose edit changed bytes only inside its configured blocks.
# External/non-write editors, unknown bots and other actor types return 1;
# permission API uncertainty returns 2.
_approval_continuity_linked_edits_authorized() {
	local slug="$1"
	local edits="$2"
	local login="" rows="" kind="" block_only="" login_rc=0
	rows=$(jq -r '[.[] | [.type, .login, ((.block_only // false) | tostring)]] | unique | .[] | @tsv' <<<"$edits") || return 2
	while IFS=$'\t' read -r kind login block_only; do
		[[ -n "$kind" ]] || continue
		case "$kind" in
		User)
			login_rc=0
			_approval_continuity_actor_authorized "$slug" "$login" || login_rc=$?
			[[ "$login_rc" -eq 0 ]] || return "$login_rc"
			;;
		Bot) [[ "$block_only" == "true" ]] || return 1 ;;
		*) return 1 ;;
		esac
	done <<<"$rows"
	return 0
}

# Replacing only lifecycle metadata and removing authority-equivalent
# post-approval comments must recreate the signed digest. This proves title,
# body, pre-approval comments, references, identity, and all other
# scope-bearing bytes remain exactly as reviewed. GH#33097: payloads with
# component digests may instead prove that only title/body changed; those
# edits are then authenticated by the caller (renamed events, userContentEdits).
# GH#38006: content-bound linked-source bodies may also be restored to their
# signed revisions; the caller authenticates their post-signing edits.
# Prints {changes: "title\nbody" subset, linked_edits: [...] | null}.
_approval_continuity_content_proof() {
	local payload="$1"
	local current_snapshot="$2"
	local signed_lifecycle="$3"
	local signed_digest="$4"
	local slug="$5"
	local approval_comment_id="$6"
	local issued_at="$7"
	local source_profile="${8:-}"
	local filtered_snapshot="" candidate="" candidate_digest="" content_changes="" linked_result="" linked_edits="null"
	filtered_snapshot=$(_approval_continuity_drop_trusted_comments "$current_snapshot" "$slug" "$approval_comment_id") || return $?
	candidate=$(jq -cS --argjson lifecycle "$signed_lifecycle" '.lifecycle = $lifecycle' <<<"$filtered_snapshot") || return 1
	candidate_digest=$(approval_snapshot_v2_digest "$candidate") || return 2
	if [[ "$candidate_digest" != "$signed_digest" ]] && ! content_changes=$(_approval_continuity_content_changes "$payload" "$candidate"); then
		linked_result=$(_approval_continuity_linked_source_candidate "$payload" "$candidate" "$issued_at" "$source_profile") || return $?
		candidate=$(jq -cS '.candidate' <<<"$linked_result") || return 1
		linked_edits=$(jq -c '.edits' <<<"$linked_result") || return 1
		candidate_digest=$(approval_snapshot_v2_digest "$candidate") || return 2
		content_changes=""
		if [[ "$candidate_digest" != "$signed_digest" ]]; then
			content_changes=$(_approval_continuity_content_changes "$payload" "$candidate") || return 1
		fi
	fi
	jq -cn --arg changes "$content_changes" --argjson linked_edits "$linked_edits" '{changes: $changes, linked_edits: $linked_edits}'
	return $?
}

_approval_verify_locked_issue_continuity() {
	local payload="$1"
	local current_snapshot="$2"
	local signed_digest="$3"
	local slug="$4"
	local target_number="$5"
	local issued_at="$6"
	local approval_comment_id="$7"
	local source_profile="${8:-}"
	local signed_lifecycle="" current_anchor="" signed_anchor="" content_proof=""
	local timeline_pages="" mutation_rows="" event="" actor="" subject="" actor_id="" actor_type="" actor_rc=0
	local signed_has_status=0 auto_dispatch_active=0 saw_status_mutation=0 saw_status_default=0 saw_rename=0
	local content_changes="" title_changed=0 body_changed=0 body_rc=0 linked_edits="" linked_rc=0

	# #aidevops:trust-boundary — no embedded lifecycle proof means this is a
	# legacy exact-snapshot approval, never continuity authority.
	signed_lifecycle=$(jq -c '.issue.lifecycle // empty' <<<"$payload" 2>/dev/null) || return 1
	[[ -n "$signed_lifecycle" ]] || return 1
	if ! jq -e --arg object "$APPROVAL_JSON_OBJECT" '.locked == true and (.lock_anchor | type == $object)' <<<"$signed_lifecycle" >/dev/null 2>&1; then
		return 1
	fi
	signed_anchor=$(jq -c '.lock_anchor' <<<"$signed_lifecycle") || return 1
	if jq -e '[.labels[]?.name | select(startswith("status:"))] | length > 0' <<<"$signed_lifecycle" >/dev/null 2>&1; then
		signed_has_status=1
	fi
	if jq -e --arg auto "$_APPROVAL_AUTO_DISPATCH_LABEL" 'any(.labels[]?.name; . == $auto)' <<<"$signed_lifecycle" >/dev/null 2>&1; then
		auto_dispatch_active=1
	fi
	current_anchor=$(jq -c '.lifecycle.lock_anchor // empty' <<<"$current_snapshot") || return 1
	[[ -n "$current_anchor" && "$current_anchor" == "$signed_anchor" ]] || return 1
	if ! jq -e '.lifecycle.locked == true' <<<"$current_snapshot" >/dev/null 2>&1; then
		return 1
	fi

	content_proof=$(_approval_continuity_content_proof "$payload" "$current_snapshot" "$signed_lifecycle" "$signed_digest" "$slug" "$approval_comment_id" "$issued_at" "$source_profile") || return $?
	content_changes=$(jq -r '.changes' <<<"$content_proof") || return 1
	linked_edits=$(jq -c '.linked_edits // empty' <<<"$content_proof") || return 1
	[[ "$content_changes" != *title* ]] || title_changed=1
	[[ "$content_changes" != *body* ]] || body_changed=1
	timeline_pages=$(_approval_snapshot_v2_fetch_pages "repos/${slug}/issues/${target_number}/timeline?per_page=100") || return 2
	mutation_rows=$(_approval_continuity_ordered_mutation_rows "$timeline_pages" "$issued_at" "$approval_comment_id" 2>/dev/null) || return 2
	if ! jq -e --argjson signed "$signed_lifecycle" '.lifecycle == $signed' <<<"$current_snapshot" >/dev/null 2>&1; then
		[[ -n "$mutation_rows" ]] || return 1
		if ! _approval_continuity_lifecycle_change_allowed "$signed_lifecycle" "$current_snapshot"; then
			# Only the existing canonical self-hosting escalation can replace a
			# signed workload tier; arbitrary tier changes remain approval-bound.
			_approval_continuity_lifecycle_change_allowed "$signed_lifecycle" "$current_snapshot" true || return 1
			_approval_continuity_self_hosting_audit "$slug" "$target_number" "$issued_at" "$timeline_pages" || return $?
		fi
	fi

	while IFS=$'\t' read -r event actor subject actor_id actor_type; do
		[[ -n "$event" ]] || continue
		case "$event:$subject" in
		renamed:title) [[ "$title_changed" -eq 1 ]] || return 1 ;;
		labeled:"$_APPROVAL_OBSERVABILITY_LABEL" | unlabeled:"$_APPROVAL_OBSERVABILITY_LABEL") ;;
		labeled:"$_APPROVAL_PERSISTENT_LABEL") ;; # GH#37993: add-only; unlabeled stays stale
		assigned:* | unassigned:* | labeled:needs-maintainer-review | unlabeled:needs-maintainer-review | labeled:needs-maintainer-permissions | unlabeled:needs-maintainer-permissions | labeled:auto-dispatch | unlabeled:auto-dispatch | labeled:status:available | unlabeled:status:available | labeled:status:queued | unlabeled:status:queued | labeled:status:claimed | unlabeled:status:claimed | labeled:status:in-progress | unlabeled:status:in-progress | labeled:status:in-review | unlabeled:status:in-review | labeled:status:done | unlabeled:status:done | labeled:status:blocked | unlabeled:status:blocked | labeled:tier:simple | unlabeled:tier:simple | labeled:tier:standard | unlabeled:tier:standard | labeled:tier:thinking | unlabeled:tier:thinking) ;;
		*) return 1 ;;
		esac
		# #aidevops:trust-boundary — GitHub's official Actions bot has no
		# collaborator permission. Accept its single non-scope-bearing default only
		# for the expected no-status handoff sequence: an authorized maintainer first
		# exposed auto-dispatch and no status mutation has occurred. The immutable
		# bot ID/type prevents lookalikes; this grants no generic workflow authority.
		if _approval_continuity_is_repository_status_default "$event" "$subject" "$actor" "$actor_id" "$actor_type"; then
			[[ "$signed_has_status" -eq 0 && "$auto_dispatch_active" -eq 1 && "$saw_status_mutation" -eq 0 && "$saw_status_default" -eq 0 ]] || return 1
			saw_status_default=1
			saw_status_mutation=1
			continue
		fi
		actor_rc=0
		_approval_continuity_actor_authorized "$slug" "$actor" || actor_rc=$?
		[[ "$actor_rc" -eq 0 ]] || {
			[[ "$actor_rc" -eq 2 ]] && return 2
			return 1
		}
		[[ "$event:$subject" == "labeled:$_APPROVAL_AUTO_DISPATCH_LABEL" ]] && auto_dispatch_active=1
		[[ "$event:$subject" == "unlabeled:$_APPROVAL_AUTO_DISPATCH_LABEL" ]] && auto_dispatch_active=0
		[[ "$subject" == status:* ]] && saw_status_mutation=1
		[[ "$event" == renamed ]] && saw_rename=1
	done <<<"$mutation_rows"
	[[ "$title_changed" -eq 0 || "$saw_rename" -eq 1 ]] || return 1 # title edits need an authorized rename
	if [[ "$body_changed" -eq 1 ]]; then
		_approval_continuity_body_edits_authorized "$slug" "$target_number" "$timeline_pages" "$approval_comment_id" || body_rc=$?
		[[ "$body_rc" -eq 0 ]] || return "$body_rc"
	fi
	if [[ -n "$linked_edits" ]]; then
		_approval_continuity_linked_edits_authorized "$slug" "$linked_edits" || linked_rc=$?
		[[ "$linked_rc" -eq 0 ]] || return "$linked_rc"
	fi
	# A distinct result permits a single fresh snapshot/timeline read, but only
	# after every content and actor authorization check has passed.
	_approval_continuity_reconciled_labels_match "$signed_lifecycle" "$current_snapshot" "$mutation_rows" || return 3
	return 0
}

# Retry only a replay mismatch, rebuilding the same snapshot profile and
# repeating all authorization checks. A second mismatch remains stale.
_approval_continuity_with_retry() {
	local payload="$1" snapshot="$2" digest="$3" slug="$4" number="$5" issued="$6" comment="$7" profile="$8" lifecycle_profile="$9"
	local rc=0
	_approval_verify_locked_issue_continuity "$payload" "$snapshot" "$digest" "$slug" "$number" "$issued" "$comment" "$profile" || rc=$?
	if [[ "$rc" -eq 3 ]]; then
		snapshot=$(approval_snapshot_v2_build "$APPROVAL_TARGET_ISSUE" "$number" "$slug" "$comment" "$issued" "$profile" "$lifecycle_profile") || return 2
		rc=0
		_approval_verify_locked_issue_continuity "$payload" "$snapshot" "$digest" "$slug" "$number" "$issued" "$comment" "$profile" || rc=$?
	fi
	[[ "$rc" -ne 3 ]] || return 1
	return "$rc"
}

# Prints TRUSTED_SOURCES_MATCH, STABLE_MATCH or LEGACY_MATCH when an older
# linked-source profile reproduces the complete signed digest (the caller then
# accepts it), otherwise VERIFIED (proven lifecycle continuity), API_ERROR, or
# STALE_APPROVAL.
_approval_classify_digest_mismatch() {
	local target_type="$1"
	local target_number="$2"
	local slug="$3"
	local comment_id="$4"
	local issued_at="$5"
	local issue_lifecycle_profile="$6"
	local payload="$7"
	local snapshot_json="$8"
	local signed_digest="$9"
	local trusted_snapshot_json="" trusted_digest=""
	local stable_snapshot_json="" stable_digest="" legacy_snapshot_json="" legacy_digest="" continuity_rc=0

	# #aidevops:trust-boundary — approvals issued before GH#34266 also bind
	# content-bound linked-source state (trusted-sources profile); exact match only.
	trusted_snapshot_json=$(approval_snapshot_v2_build "$target_type" "$target_number" "$slug" "$comment_id" "$issued_at" "$APPROVAL_SNAPSHOT_PROFILE_TRUSTED_SOURCES" "$issue_lifecycle_profile") || {
		printf 'API_ERROR\n'
		return 0
	}
	trusted_digest=$(approval_snapshot_v2_digest "$trusted_snapshot_json") || {
		printf 'API_ERROR\n'
		return 0
	}
	if [[ "$trusted_digest" == "$signed_digest" ]]; then
		printf 'TRUSTED_SOURCES_MATCH\n'
		return 0
	fi
	# #aidevops:trust-boundary — approvals issued before GH#32455 bind all
	# linked-source content (stable profile); accept only an exact match.
	stable_snapshot_json=$(approval_snapshot_v2_build "$target_type" "$target_number" "$slug" "$comment_id" "$issued_at" "$APPROVAL_SNAPSHOT_PROFILE_STABLE" "$issue_lifecycle_profile") || {
		printf 'API_ERROR\n'
		return 0
	}
	stable_digest=$(approval_snapshot_v2_digest "$stable_snapshot_json") || {
		printf 'API_ERROR\n'
		return 0
	}
	if [[ "$stable_digest" == "$signed_digest" ]]; then
		printf 'STABLE_MATCH\n'
		return 0
	fi
	legacy_snapshot_json=$(approval_snapshot_v2_build "$target_type" "$target_number" "$slug" "$comment_id" "$issued_at" "$APPROVAL_SNAPSHOT_PROFILE_LEGACY" "$issue_lifecycle_profile") || {
		printf 'API_ERROR\n'
		return 0
	}
	legacy_digest=$(approval_snapshot_v2_digest "$legacy_snapshot_json") || {
		printf 'API_ERROR\n'
		return 0
	}
	if [[ "$legacy_digest" == "$signed_digest" ]]; then
		printf 'LEGACY_MATCH\n'
		return 0
	fi
	if [[ "$target_type" == "$APPROVAL_TARGET_ISSUE" ]]; then
		_approval_continuity_with_retry "$payload" "$snapshot_json" "$signed_digest" "$slug" "$target_number" "$issued_at" "$comment_id" "$APPROVAL_SNAPSHOT_PROFILE_SOURCE_STATE_UNBOUND" "$issue_lifecycle_profile" || continuity_rc=$?
		# Approvals signed before GH#34266 / GH#32455 used the trusted-sources /
		# stable linked-source profiles; prove continuity against that exact profile.
		if [[ "$continuity_rc" -eq 1 ]]; then
			continuity_rc=0
			_approval_continuity_with_retry "$payload" "$trusted_snapshot_json" "$signed_digest" "$slug" "$target_number" "$issued_at" "$comment_id" "$APPROVAL_SNAPSHOT_PROFILE_TRUSTED_SOURCES" "$issue_lifecycle_profile" || continuity_rc=$?
		fi
		if [[ "$continuity_rc" -eq 1 ]]; then
			continuity_rc=0
			_approval_continuity_with_retry "$payload" "$stable_snapshot_json" "$signed_digest" "$slug" "$target_number" "$issued_at" "$comment_id" "$APPROVAL_SNAPSHOT_PROFILE_STABLE" "$issue_lifecycle_profile" || continuity_rc=$?
		fi
		if [[ "$continuity_rc" -eq 0 ]]; then
			printf 'APPROVAL_REASON: proven-locked-continuity\n' >&2
			printf 'VERIFIED\n'
			return 0
		fi
		if [[ "$continuity_rc" -eq 2 ]]; then
			printf 'APPROVAL_REASON: continuity-api-uncertain\n' >&2
			printf 'API_ERROR\n'
			return 0
		fi
		# GH#34554: a signature over locked=true without a lock anchor can never
		# prove continuity. Name it so operators do not re-sign the same issue.
		if jq -e '.issue.lifecycle.locked == true and .issue.lifecycle.lock_anchor == null' <<<"$payload" >/dev/null 2>&1; then
			printf 'APPROVAL_REASON: unanchored-lock-signature\n' >&2
			printf 'STALE_APPROVAL\n'
			return 0
		fi
	fi
	printf 'APPROVAL_REASON: stale-or-unproven-continuity\n' >&2
	printf 'STALE_APPROVAL\n'
	return 0
}

# GH#34554: issue approvals must start from an authoritative lock anchor.
_APPROVAL_LOCK_ANCHOR_ATTEMPTS="${AIDEVOPS_APPROVAL_LOCK_ANCHOR_ATTEMPTS:-3}"
_APPROVAL_LOCK_ANCHOR_RETRY_SECONDS="${AIDEVOPS_APPROVAL_LOCK_ANCHOR_RETRY_SECONDS:-3}"
[[ "$_APPROVAL_LOCK_ANCHOR_ATTEMPTS" =~ ^[1-9][0-9]?$ ]] || _APPROVAL_LOCK_ANCHOR_ATTEMPTS=3
[[ "$_APPROVAL_LOCK_ANCHOR_RETRY_SECONDS" =~ ^[0-9]{1,2}$ ]] || _APPROVAL_LOCK_ANCHOR_RETRY_SECONDS=3
# GitHub stopped exposing lifecycle events at 310 on an observed issue; treat
# counts at or above this as a saturated timeline that cannot prove continuity.
_APPROVAL_TIMELINE_SATURATION_EVENTS=300

# Returns 0 only when an issue approval payload binds locked=true with an
# object lock anchor. Malformed payloads fail closed.
_approval_payload_lock_anchored() {
	local payload="$1"
	jq -e --arg object "$APPROVAL_JSON_OBJECT" \
		'.issue.lifecycle.locked == true and (.issue.lifecycle.lock_anchor | type == $object)' \
		<<<"$payload" >/dev/null 2>&1 || return 1
	return 0
}

# #aidevops:trust-boundary — build an issue approval payload only once the
# REST timeline exposes the uninterrupted lock interval the payload must bind.
# Re-reads a bounded number of times for event visibility lag; never
# synthesizes an anchor. Prints the payload. Returns 1 when the anchor stays
# absent and 2 when the snapshot itself cannot be built.
_approval_build_anchored_issue_payload() {
	local target_number="$1"
	local slug="$2"
	local attempt=1 timestamp="" payload=""
	while :; do
		timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
		payload=$(approval_snapshot_v2_payload "$APPROVAL_TARGET_ISSUE" "$target_number" "$slug" "$timestamp") || return 2
		if _approval_payload_lock_anchored "$payload"; then
			printf '%s\n' "$payload"
			return 0
		fi
		[[ "$attempt" -lt "$_APPROVAL_LOCK_ANCHOR_ATTEMPTS" ]] || return 1
		attempt=$((attempt + 1))
		sleep "$_APPROVAL_LOCK_ANCHOR_RETRY_SECONDS"
	done
}

# Prints the REST timeline's lifecycle event count for saturation diagnostics.
_approval_issue_lifecycle_event_count() {
	local slug="$1"
	local target_number="$2"
	local pages=""
	pages=$(_approval_snapshot_v2_fetch_pages "repos/${slug}/issues/${target_number}/timeline?per_page=100") || return 1
	jq '[.[][]? | select((.event // "") | test("^((un)?(labeled|assigned|locked)|(de)?milestoned|renamed|closed|reopened)$"))] | length' <<<"$pages" || return 1
	return 0
}

# Explains an unanchored-lock refusal with one bounded recovery route.
_approval_report_unanchored_lock() {
	local target_number="$1"
	local slug="$2"
	local count=""
	_print_error "Approval refused: issue #${target_number} is locked, but GitHub's timeline exposes no uninterrupted lock event to anchor approval continuity (${_APPROVAL_LOCK_ANCHOR_ATTEMPTS} reads). Nothing was signed or posted; needs-maintainer-review was not cleared."
	count=$(_approval_issue_lifecycle_event_count "$slug" "$target_number" 2>/dev/null) || count=""
	if [[ "$count" =~ ^[0-9]+$ && "$count" -ge "$_APPROVAL_TIMELINE_SATURATION_EVENTS" ]]; then
		_print_error "GitHub returns ${count} lifecycle events for #${target_number}; its timeline appears saturated, so newer lock/label events are not exposed and continuity can never be proven on this issue. Re-signing it will fail the same way."
		_print_error "Recovery: open a replacement issue with the same reviewed body and 'Ref #${target_number}', close #${target_number} as superseded, then approve the replacement."
		return 0
	fi
	_print_error "Recovery: retry approval once after a minute. If it is refused again, inspect the newest locked/unlocked event with: gh api --paginate repos/${slug}/issues/${target_number}/timeline"
	return 0
}
