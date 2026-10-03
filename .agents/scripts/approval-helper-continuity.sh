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

_approval_continuity_lifecycle_change_allowed() {
	local signed_lifecycle="$1"
	local current_snapshot="$2"
	local self_hosting="${3:-false}"

	# #aidevops:trust-boundary — deterministic tier backfill may only select a
	# canonical workload tier. Status labels remain workflow metadata, but every
	# resulting timeline mutation still requires authorization during replay.
	jq -e --argjson signed "$signed_lifecycle" --argjson self_hosting "$self_hosting" \
		--argjson tiers '["tier:simple","tier:standard","tier:thinking"]' '
		def tier_label: . as $label | $tiers | index($label) != null;
		def allowed_label: . == "needs-maintainer-review" or . == "auto-dispatch" or . == "status:available" or . == "status:queued" or . == "status:claimed" or . == "status:in-progress" or . == "status:in-review" or . == "status:done" or . == "status:blocked" or tier_label;
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
		and ([$added_labels[], $removed_labels[]] | unique | all(allowed_label))
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

_approval_verify_locked_issue_continuity() {
	local payload="$1"
	local current_snapshot="$2"
	local signed_digest="$3"
	local slug="$4"
	local target_number="$5"
	local issued_at="$6"
	local approval_comment_id="$7"
	local signed_lifecycle="" current_anchor="" signed_anchor="" candidate="" candidate_digest="" filtered_snapshot=""
	local timeline_pages="" mutation_rows="" event="" actor="" subject="" actor_id="" actor_type="" actor_rc=0
	local signed_has_status=0 auto_dispatch_active=0 current_auto_dispatch=0 saw_status_mutation=0 saw_status_default=0 saw_rename=0
	local content_changes="" title_changed=0 body_changed=0 body_rc=0

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
	if jq -e --arg auto "$_APPROVAL_AUTO_DISPATCH_LABEL" 'any(.lifecycle.labels[]?.name; . == $auto)' <<<"$current_snapshot" >/dev/null 2>&1; then
		current_auto_dispatch=1
	fi
	current_anchor=$(jq -c '.lifecycle.lock_anchor // empty' <<<"$current_snapshot") || return 1
	[[ -n "$current_anchor" && "$current_anchor" == "$signed_anchor" ]] || return 1
	if ! jq -e '.lifecycle.locked == true' <<<"$current_snapshot" >/dev/null 2>&1; then
		return 1
	fi

	# Replacing only lifecycle metadata and removing authority-equivalent
	# post-approval comments must recreate the signed digest. This proves title,
	# body, pre-approval comments, references, identity, and all other
	# scope-bearing bytes remain exactly as reviewed. GH#33097: payloads with
	# component digests may instead prove that only title/body changed; those
	# edits are then authenticated below (renamed events, userContentEdits).
	filtered_snapshot=$(_approval_continuity_drop_trusted_comments "$current_snapshot" "$slug" "$approval_comment_id") || return $?
	candidate=$(jq -cS --argjson lifecycle "$signed_lifecycle" '.lifecycle = $lifecycle' <<<"$filtered_snapshot") || return 1
	candidate_digest=$(approval_snapshot_v2_digest "$candidate") || return 2
	if [[ "$candidate_digest" != "$signed_digest" ]]; then
		content_changes=$(_approval_continuity_content_changes "$payload" "$candidate") || return 1
		[[ "$content_changes" != *title* ]] || title_changed=1
		[[ "$content_changes" != *body* ]] || body_changed=1
	fi
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
		assigned:* | unassigned:* | labeled:needs-maintainer-review | unlabeled:needs-maintainer-review | labeled:auto-dispatch | unlabeled:auto-dispatch | labeled:status:available | unlabeled:status:available | labeled:status:queued | unlabeled:status:queued | labeled:status:claimed | unlabeled:status:claimed | labeled:status:in-progress | unlabeled:status:in-progress | labeled:status:in-review | unlabeled:status:in-review | labeled:status:done | unlabeled:status:done | labeled:status:blocked | unlabeled:status:blocked | labeled:tier:simple | unlabeled:tier:simple | labeled:tier:standard | unlabeled:tier:standard | labeled:tier:thinking | unlabeled:tier:thinking) ;;
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
	[[ "$auto_dispatch_active" -eq "$current_auto_dispatch" ]] || return 1
	[[ "$title_changed" -eq 0 || "$saw_rename" -eq 1 ]] || return 1 # title edits need an authorized rename
	if [[ "$body_changed" -eq 1 ]]; then
		_approval_continuity_body_edits_authorized "$slug" "$target_number" "$timeline_pages" "$approval_comment_id" || body_rc=$?
		[[ "$body_rc" -eq 0 ]] || return "$body_rc"
	fi
	return 0
}

# Prints STABLE_MATCH or LEGACY_MATCH when an older linked-source profile
# reproduces the complete signed digest (the caller then accepts it), otherwise
# VERIFIED (proven lifecycle continuity), API_ERROR, or STALE_APPROVAL.
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
	local stable_snapshot_json="" stable_digest="" legacy_snapshot_json="" legacy_digest="" continuity_rc=0

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
		_approval_verify_locked_issue_continuity "$payload" "$snapshot_json" "$signed_digest" "$slug" "$target_number" "$issued_at" "$comment_id" || continuity_rc=$?
		# Approvals signed before GH#32455 used the stable linked-source profile;
		# their lifecycle continuity must be proven against that exact profile.
		if [[ "$continuity_rc" -eq 1 ]]; then
			continuity_rc=0
			_approval_verify_locked_issue_continuity "$payload" "$stable_snapshot_json" "$signed_digest" "$slug" "$target_number" "$issued_at" "$comment_id" || continuity_rc=$?
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
	fi
	printf 'APPROVAL_REASON: stale-or-unproven-continuity\n' >&2
	printf 'STALE_APPROVAL\n'
	return 0
}
