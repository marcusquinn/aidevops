#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Local-only convergence. Never source publisher authorization from this record.

_full_loop_release_adoption_refuse() {
	local reason="$1"
	printf 'Published adoption refused: %s\n' "$reason" >&2
	return 1
}

#aidevops:trust-boundary
_full_loop_release_adoption_operator() {
	local repo="$1"
	local permission=""
	[[ -t 0 && -t 1 ]] || { _full_loop_release_adoption_refuse 'an interactive terminal is required'; return 1; }
	if [[ "${FULL_LOOP_HEADLESS:-false}" != false && -n "${FULL_LOOP_HEADLESS:-}" ]] ||
		[[ -n "${WORKER_WORKTREE_PATH:-}${WORKER_ISSUE_NUMBER:-}${AIDEVOPS_ATTEMPT_ID:-}${AIDEVOPS_HEADLESS:-}${HEADLESS:-}${CI:-}${AIDEVOPS_WORKER_ID:-}${AIDEVOPS_HEADLESS_RUN_ID:-}" ]]; then
		_full_loop_release_adoption_refuse 'interactive maintainer intent is required; workers cannot adopt'
		return 1
	fi
	permission=$(gh api "repos/${repo}" --jq '.permissions | .admin == true or .maintain == true or .push == true') || return 1
	[[ "$permission" == true ]] || { _full_loop_release_adoption_refuse 'maintainer-equivalent repository permission is required'; return 1; }
	_FULL_LOOP_RELEASE_ADOPTION_OPERATOR=$(gh api user --jq '.login') || return 1
	[[ -n "$_FULL_LOOP_RELEASE_ADOPTION_OPERATOR" && "$_FULL_LOOP_RELEASE_ADOPTION_OPERATOR" != null ]] || return 1
	return 0
}

_full_loop_release_adoption_lane() {
	local repo="$1" source_pr="$2" tag="$3"
	release_lane_read "$repo" || return 1
	if ! jq -e --argjson pr "$source_pr" --arg tag "$tag" '
		.active == false and .phase == "terminal" and .terminal_receipt == "published"
		and .source_pr == $pr and .tag == $tag
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null; then
		printf 'Lane identity/status does not permit adoption; terminal tag=%s. Inspect aidevops release status %s; reconcile an active lane, or adopt its terminal published source/tag.\n' \
			"$(jq -r '.tag // "none"' <<<"$_AIDEVOPS_RELEASE_LANE_JSON")" "$source_pr" >&2
		return 1
	fi
	[[ "${_AIDEVOPS_RELEASE_LANE_HEAD:-}" =~ ^[0-9a-f]{40}$ ]] || return 1
	return 0
}

# Unlike the deferred-postflight shortcut, adoption always requires an actual
# successful exact-tag postflight run. This lookup never dispatches a workflow.
_full_loop_release_adoption_postflight() {
	local repo="$1" tag="$2"
	local runs=""
	runs=$(gh api --method GET "repos/${repo}/actions/workflows/postflight.yml/runs" \
		-f event=workflow_dispatch -f branch=main -F per_page=100 --paginate) || return 1
	_FULL_LOOP_RELEASE_ADOPTION_POSTFLIGHT=$(jq -ers --arg title "Postflight Verification ${tag}" '
		[.[].workflow_runs[] | select(.event == "workflow_dispatch" and .head_branch == "main"
		and .display_title == $title)] | sort_by(.created_at) | last
		| select(.status == "completed" and .conclusion == "success")
		| .id | select(type == "number" and . > 0 and floor == .)
	' <<<"$runs") || {
		_full_loop_release_adoption_refuse "missing, pending or failed exact-tag postflight for $tag; inspect postflight.yml (no workflow dispatched)"
		return 1
	}
	return 0
}

_full_loop_release_adoption_deployment() {
	local tag="$1" commit="$2"
	local deployed_version=""
	# shellcheck source=./runtime-bundle-verifier.sh
	source "${SCRIPT_DIR}/runtime-bundle-verifier.sh" || return 1
	IFS= read -r deployed_version <"$HOME/.aidevops/agents/VERSION" || return 1
	[[ "$deployed_version" == "${tag#v}" ]] || return 1
	verify_aidevops_runtime_bundle_convergence "$_FULL_LOOP_RELEASE_PATH" "$commit" || return 1
	return 0
}

# All checks are read-only, apart from disposable verification worktrees. The
# signed provenance verifier also checks merged source membership, not ancestry
# alone. Keep this independent of the active-lane publication finalizer.
_full_loop_release_adoption_verify() {
	local repo="$1" source_pr="$2" tag="$3"
	_FULL_LOOP_RELEASE_ADOPTION_SOURCE=""
	_full_loop_release_adoption_lane "$repo" "$source_pr" "$tag" || return 1
	_FULL_LOOP_RELEASE_ADOPTION_HEAD="$_AIDEVOPS_RELEASE_LANE_HEAD"
	_FULL_LOOP_RELEASE_ADOPTION_DIGEST=$(jq -cS . <<<"$_AIDEVOPS_RELEASE_LANE_JSON" | _full_loop_release_sha256_stream) || return 1
	_full_loop_release_verify_tag_provenance "$repo" "$tag" || {
		_full_loop_release_adoption_refuse "signed provenance/source membership failed for $tag"; return 1;
	}
	_FULL_LOOP_RELEASE_ADOPTION_SOURCE=$(_full_loop_release_source_json_from_tag "$tag") || return 1
	jq -e --argjson pr "$source_pr" '.source_pr == $pr' <<<"$_FULL_LOOP_RELEASE_ADOPTION_SOURCE" >/dev/null || return 1
	_FULL_LOOP_RELEASE_ADOPTION_OBJECT=$(git -C "$REPO_ROOT" rev-parse "refs/tags/$tag") || return 1
	_FULL_LOOP_RELEASE_ADOPTION_COMMIT=$(_full_loop_release_resolve_tag_commit "$tag") || return 1
	_full_loop_release_verify_channels "$repo" "$tag" || { _full_loop_release_adoption_refuse "channel integrity/provenance failed for $tag"; return 1; }
	_full_loop_release_find_workflow_run "$repo" "$tag" "$_FULL_LOOP_RELEASE_ADOPTION_COMMIT" || return 1
	_FULL_LOOP_RELEASE_ADOPTION_RUN=$(jq -er 'select(.status == "completed" and .conclusion == "success") | .id | select(type == "number" and . > 0)' <<<"$_FULL_LOOP_RELEASE_RUN_JSON") || return 1
	_full_loop_release_adoption_postflight "$repo" "$tag" || return 1
	_full_loop_release_adoption_deployment "$tag" "$_FULL_LOOP_RELEASE_ADOPTION_COMMIT" || {
		_full_loop_release_adoption_refuse "local exact-tag deployment is missing or invalid; run 'aidevops update' then retry"; return 1;
	}
	return 0
}

_full_loop_release_adoption_fence() {
	local repo="$1" source_pr="$2" tag="$3"
	local digest=""
	_full_loop_release_adoption_lane "$repo" "$source_pr" "$tag" || return 1
	digest=$(jq -cS . <<<"$_AIDEVOPS_RELEASE_LANE_JSON" | _full_loop_release_sha256_stream) || return 1
	[[ "$_AIDEVOPS_RELEASE_LANE_HEAD" == "$_FULL_LOOP_RELEASE_ADOPTION_HEAD" && "$digest" == "$_FULL_LOOP_RELEASE_ADOPTION_DIGEST" ]] || {
		_full_loop_release_adoption_refuse 'lane changed during verification; retry from current status'; return 1;
	}
	return 0
}

# Re-verification is required before a successor receipt can settle a predecessor.
_full_loop_release_verify_adoption_evidence() {
	local repo="$1" source_pr="$2" tag="$3"
	local path="" authorization=""
	path=$(_full_loop_release_evidence_path "$repo" "$source_pr" adoption) || return 1
	authorization=$(_full_loop_release_evidence_path "$repo" "$source_pr" adoption-authorization) || return 1
	[[ -f "$path" && ! -L "$path" && -f "$authorization" && ! -L "$authorization" ]] || return 1
	_full_loop_release_adoption_verify "$repo" "$source_pr" "$tag" || return 1
	jq -e --arg repo "$repo" --argjson pr "$source_pr" --arg tag "$tag" --arg status "$_FULL_LOOP_RELEASE_PUBLISHED" \
		--arg object "$_FULL_LOOP_RELEASE_ADOPTION_OBJECT" --arg commit "$_FULL_LOOP_RELEASE_ADOPTION_COMMIT" \
		--argjson source "$_FULL_LOOP_RELEASE_ADOPTION_SOURCE" --arg authorization "$authorization" \
		--argjson run "$_FULL_LOOP_RELEASE_ADOPTION_RUN" --argjson postflight "$_FULL_LOOP_RELEASE_ADOPTION_POSTFLIGHT" \
		--arg digest "$_FULL_LOOP_RELEASE_ADOPTION_DIGEST" --arg head "$_FULL_LOOP_RELEASE_ADOPTION_HEAD" --slurpfile auth "$authorization" '
		.type == "cross-host-adoption/v1" and .repository == $repo and .source_pr == $pr
		and .status == $status and .tag == $tag and .tag_object == $object and .tag_commit == $commit
		and .sources == $source and .authorization == $authorization
		and .publication_run == $run and .postflight_run == $postflight and .lane_digest == $digest and .lane_head == $head
		and .channels == {github:true,npm_integrity:true,npm_provenance:true,homebrew:true}
		and .deployment == {status:"deployed",tag:$tag,active_sha:$commit}
		and $auth[0].type == .type and $auth[0].repository == $repo and $auth[0].source_pr == $pr
		and $auth[0].tag == $tag and $auth[0].tag_object == $object and $auth[0].sources == $source
		and $auth[0].operator == .operator and $auth[0].recorded_at == .recorded_at
		and ($auth[0].operator | type == "string" and length > 0)
		and ($auth[0].recorded_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
	' "$path" >/dev/null || return 1
	_full_loop_release_adoption_fence "$repo" "$source_pr" "$tag" || return 1
	return 0
}

# Never replace existing evidence, including on recovery of an interrupted write.
_full_loop_release_adoption_install() {
	local path="$1" json="$2"
	[[ ! -L "$path" ]] || return 1
	if [[ -e "$path" ]]; then
		cmp -s "$path" <(printf '%s\n' "$json") || return 1
	else
		(set -o noclobber; printf '%s\n' "$json" >"$path") || return 1
	fi
	return 0
}

# Called under a per-receipt local lock. Existing terminal files are immutable;
# publication authorization is neither read nor written here.
_full_loop_release_adoption_write() {
	local repo="$1" source_pr="$2" tag="$3" receipt="$4"
	local evidence="" authorization="" now="" auth_json="" evidence_json=""
	evidence=$(_full_loop_release_evidence_path "$repo" "$source_pr" adoption) || return 1
	authorization=$(_full_loop_release_evidence_path "$repo" "$source_pr" adoption-authorization) || return 1
	if [[ -e "$receipt" || -L "$receipt" ]]; then
		[[ ! -L "$receipt" ]] || return 1
		cmp -s "$receipt" <(printf 'published\ncross-host-adoption/v1\n') || return 1
		_full_loop_release_verify_adoption_evidence "$repo" "$source_pr" "$tag" || return 1
		return 0
	fi
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	auth_json=$(jq -cn --arg repo "$repo" --argjson pr "$source_pr" --arg tag "$tag" \
		--arg object "$_FULL_LOOP_RELEASE_ADOPTION_OBJECT" --argjson source "$_FULL_LOOP_RELEASE_ADOPTION_SOURCE" \
		--arg operator "$_FULL_LOOP_RELEASE_ADOPTION_OPERATOR" --arg now "$now" '
		{type:"cross-host-adoption/v1",repository:$repo,source_pr:$pr,tag:$tag,tag_object:$object,
		sources:$source,operator:$operator,recorded_at:$now}') || return 1
	# A crash may leave only authorization. Reuse it only when all intent fields
	# match this freshly verified command; retain its original operator/time.
	if [[ -e "$authorization" ]]; then
		[[ ! -L "$authorization" ]] || return 1
		jq -e --argjson expected "$auth_json" '
			(del(.recorded_at) == ($expected | del(.recorded_at)))
			and (.recorded_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
		' "$authorization" >/dev/null || return 1
		auth_json=$(jq -c . "$authorization") || return 1
	fi
	evidence_json=$(jq -cn --argjson auth "$auth_json" --arg authorization "$authorization" \
		--arg commit "$_FULL_LOOP_RELEASE_ADOPTION_COMMIT" --arg digest "$_FULL_LOOP_RELEASE_ADOPTION_DIGEST" \
		--arg head "$_FULL_LOOP_RELEASE_ADOPTION_HEAD" --argjson run "$_FULL_LOOP_RELEASE_ADOPTION_RUN" \
		--argjson postflight "$_FULL_LOOP_RELEASE_ADOPTION_POSTFLIGHT" '
		$auth + {status:"published",tag_commit:$commit,publication_run:$run,postflight_run:$postflight,
		lane_head:$head,lane_digest:$digest,authorization:$authorization,
		deployment:{status:"deployed",tag:$auth.tag,active_sha:$commit},
		channels:{github:true,npm_integrity:true,npm_provenance:true,homebrew:true}}') || return 1
	_full_loop_release_adoption_fence "$repo" "$source_pr" "$tag" || return 1
	_full_loop_release_adoption_install "$authorization" "$auth_json" || return 1
	_full_loop_release_adoption_install "$evidence" "$evidence_json" || return 1
	# Evidence may survive a detected drift, but a consumable terminal receipt
	# must not. Commit the receipt only after this final read-only fence.
	_full_loop_release_adoption_fence "$repo" "$source_pr" "$tag" || return 1
	_full_loop_write_release_receipt_locked "$repo" "$source_pr" "$_FULL_LOOP_RELEASE_PUBLISHED" cross-host-adoption/v1 || return 1
	return 0
}

_full_loop_release_cmd_adopt_published() {
	local source_pr="$1" tag="$2"
	local repo="" receipt="" rc=0
	[[ "$source_pr" =~ ^[1-9][0-9]*$ && "$tag" =~ $_FULL_LOOP_RELEASE_VERSION_TAG_REGEX ]] || return 1
	_full_loop_release_bind_repo_context || return 1
	repo=$(_full_loop_resolve_repo "${AIDEVOPS_FULL_LOOP_REPO:-}") || return 1
	_full_loop_release_adoption_operator "$repo" || return 1
	_full_loop_release_adoption_verify "$repo" "$source_pr" "$tag" || return 1
	receipt=$(_full_loop_release_receipt_path "$repo" "$source_pr") || return 1
	mkdir -p "${receipt%/*}" || return 1
	mkdir "${receipt}.lock" || { _full_loop_release_adoption_refuse 'local receipt lock is held; inspect the other operation'; return 1; }
	_full_loop_release_adoption_write "$repo" "$source_pr" "$tag" "$receipt" || rc=$?
	rmdir "${receipt}.lock" || rc=1
	[[ "$rc" -eq 0 ]] || { _full_loop_release_adoption_refuse 'local receipt/evidence conflict or failed verification; existing evidence was not overwritten'; return "$rc"; }
	printf 'release:published local-adoption source_pr=%s tag=%s\n' "$source_pr" "$tag"
	return 0
}
