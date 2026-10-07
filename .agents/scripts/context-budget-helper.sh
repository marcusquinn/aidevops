#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
#
# context-budget-helper.sh — measure the first-prompt context OpenCode sends.
#
# capture  runs one probe through an isolated config home (the real config is
#          only read), loads the deployed or a checkout's aidevops plugin, and
#          saves provider request bodies (never headers) as 0600 JSON.
# analyze  breaks a capture into instruction files, skills, plugin additions,
#          tools and OAuth wire-shape invariants (characters).
# compare  prints per-section deltas between a control and a candidate capture.
# tokens   prints API-reported input + cache tokens from llm_requests.
#
# Reference: .agents/reference/context-budget.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "$SCRIPT_DIR/shared-constants.sh"

CB_ASSET_DIR="$SCRIPT_DIR/context-budget"
CB_WORKSPACE="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
CB_DEPLOYED_PLUGIN="$HOME/.aidevops/agents/plugins/opencode-aidevops"
CB_DB="${AIDEVOPS_OBS_DB_OVERRIDE:-$HOME/.aidevops/.agent-workspace/observability/llm-requests.db}"
CB_PROMPT_ONE_TURN='Context probe: reply with exactly OK and nothing else.'
CB_PROMPT_TWO_TURN='Call the Glob tool exactly once with pattern VERSION, then reply with exactly OK and nothing else.'
CB_PROBE_TIMEOUT="${AIDEVOPS_CONTEXT_BUDGET_TIMEOUT:-300}"
CB_SOURCE_DEPLOYED="deployed"

# Capture options (set by parse_capture_args).
CB_RUNTIME=""
CB_PLUGIN_SOURCE="$CB_SOURCE_DEPLOYED"
CB_LABEL=""
CB_HEADLESS=0
CB_TURNS=1
CB_MODEL="anthropic/claude-haiku-5-5"
CB_AGENT="Build+"
CB_OUT="$CB_WORKSPACE/context-budget"
CB_WORKDIR="$PWD"
CB_PROMPT=""

# Cleanup state: the temporary config home and a node_modules link we created.
_CB_ISO=""
_CB_LINK=""

cleanup_capture() {
	if [[ -n "$_CB_LINK" && -L "$_CB_LINK" ]]; then
		rm -f "$_CB_LINK"
	fi
	if [[ -n "$_CB_ISO" && -d "$_CB_ISO" ]]; then
		rm -rf "$_CB_ISO"
	fi
	return 0
}

usage() {
	cat <<'EOF'
Usage:
  context-budget-helper.sh capture <oc1|oc2> [options]
      --plugin deployed|<checkout>  plugin source (default: deployed); a checkout
                                    path loads <checkout>/.agents/plugins/opencode-aidevops
      --label <name>                capture label (default: control or candidate)
      --headless                    run as headless (AIDEVOPS_HEADLESS=1)
      --turns 1|2                   1 = reply OK; 2 = one Glob call, then OK (cache evidence)
      --prompt <text>               custom probe prompt (overrides --turns prompt)
      --model <provider/model>      default: anthropic/claude-haiku-5-5
      --agent <name>                default: Build+
      --dir <path>                  project directory for the probe (default: current)
      --out <dir>                   capture directory (default: $AIDEVOPS_TEMP_DIR/context-budget)
  context-budget-helper.sh analyze <capture.json> [--json]
  context-budget-helper.sh compare <control.json> <candidate.json> [--json]
  context-budget-helper.sh tokens --since <UTC ISO time> [--until <UTC ISO time>] [--model <substring>] [--new-sessions]
      --new-sessions keeps only sessions whose first request is inside the window (probes)

API-reported prompt tokens = input + cache_read + cache_write. Characters are not
tokens; compare token rows, not character estimates, before claiming a saving.
EOF
	return 0
}

parse_capture_args() {
	CB_RUNTIME="${1:-}"
	[[ "$CB_RUNTIME" == "oc1" || "$CB_RUNTIME" == "oc2" ]] || return 2
	shift
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--plugin) CB_PLUGIN_SOURCE="${2:?--plugin needs deployed or a checkout path}" ;;
		--label) CB_LABEL="${2:?--label needs a value}" ;;
		--turns) CB_TURNS="${2:?--turns needs 1 or 2}" ;;
		--prompt) CB_PROMPT="${2:?--prompt needs text}" ;;
		--model) CB_MODEL="${2:?--model needs provider/model}" ;;
		--agent) CB_AGENT="${2:?--agent needs a name}" ;;
		--dir) CB_WORKDIR="${2:?--dir needs a path}" ;;
		--out) CB_OUT="${2:?--out needs a directory}" ;;
		--headless) CB_HEADLESS=1 && shift && continue ;;
		*) print_error "Unknown capture option: $1" && return 2 ;;
		esac
		shift 2
	done
	[[ -n "$CB_LABEL" ]] || CB_LABEL=$([[ "$CB_PLUGIN_SOURCE" == "$CB_SOURCE_DEPLOYED" ]] && printf control || printf candidate)
	[[ "$CB_LABEL" =~ ^[a-z0-9-]{1,30}$ && "$CB_TURNS" =~ ^[12]$ ]] || return 2
	[[ -n "$CB_PROMPT" ]] || CB_PROMPT=$([[ "$CB_TURNS" == "2" ]] && printf '%s' "$CB_PROMPT_TWO_TURN" || printf '%s' "$CB_PROMPT_ONE_TURN")
	return 0
}

# Print the plugin directory for the chosen source; a checkout must contain the plugin.
resolve_plugin_dir() {
	local source="$1"
	local dir="$CB_DEPLOYED_PLUGIN"
	[[ "$source" == "$CB_SOURCE_DEPLOYED" ]] || dir="$source/.agents/plugins/opencode-aidevops"
	if [[ ! -f "$dir/index.mjs" ]]; then
		print_error "No aidevops plugin at $dir"
		return 1
	fi
	(cd "$dir" && pwd -P)
	return 0
}

# A checkout has no installed dependencies; borrow the deployed ones for this run only.
link_candidate_modules() {
	local plugin_dir="$1"
	[[ "$CB_PLUGIN_SOURCE" != "$CB_SOURCE_DEPLOYED" && ! -e "$plugin_dir/node_modules" && ! -L "$plugin_dir/node_modules" ]] || return 0
	if [[ ! -d "$CB_DEPLOYED_PLUGIN/node_modules" ]]; then
		print_warning "Deployed plugin dependencies not found; the candidate may fail to load."
		return 0
	fi
	ln -s "$CB_DEPLOYED_PLUGIN/node_modules" "$plugin_dir/node_modules"
	_CB_LINK="$plugin_dir/node_modules"
	print_info "Linked deployed node_modules into the candidate for this run (removed on exit)."
	return 0
}

# Mirror the runtime config directory as symlinks, except the config file we rewrite.
mirror_config_dir() {
	local real_dir="$1"
	local iso_dir="$2"
	local entry name
	mkdir -m 700 "$iso_dir"
	for entry in "$real_dir"/* "$real_dir"/.[!.]*; do
		[[ -e "$entry" || -L "$entry" ]] || continue
		name="${entry##*/}"
		case "$name" in
		opencode.json* | .DS_Store) continue ;;
		esac
		ln -s "$entry" "$iso_dir/$name"
	done
	return 0
}

run_probe() {
	local iso_root="$1"
	local tag="$2"
	local -a probe_env=(-u OPENCODE -u OPENCODE_PID -u OPENCODE_CONFIG_CONTENT
		-u AIDEVOPS_HEADLESS -u FULL_LOOP_HEADLESS -u OPENCODE_HEADLESS -u AIDEVOPS_DISPATCH_TIER
		AIDEVOPS_CONTEXT_BUDGET_OUT="$CB_OUT" AIDEVOPS_CONTEXT_BUDGET_TAG="$tag")
	if [[ "$CB_HEADLESS" == "1" ]]; then
		probe_env+=(AIDEVOPS_HEADLESS=1)
	fi
	local -a probe_cmd
	if [[ "$CB_RUNTIME" == "oc1" ]]; then
		probe_env+=(XDG_CONFIG_HOME="$iso_root")
		probe_cmd=("${AIDEVOPS_CONTEXT_BUDGET_OC1_BIN:-opencode}" run --agent "$CB_AGENT" -m "$CB_MODEL" --title "context-budget probe" "$CB_PROMPT")
	else
		probe_env+=(AIDEVOPS_OPENCODE_V2_CONFIG_HOME="$iso_root")
		probe_cmd=("${AIDEVOPS_CONTEXT_BUDGET_OC2_BIN:-$HOME/.local/bin/opencode2}" run --standalone --agent "$CB_AGENT" -m "$CB_MODEL" "$CB_PROMPT")
	fi
	# opencode run appends piped stdin to the message; the probe must not wait on it.
	(cd "$CB_WORKDIR" && timeout_sec "$CB_PROBE_TIMEOUT" env "${probe_env[@]}" "${probe_cmd[@]}" </dev/null)
	return $?
}

report_captures() {
	local tag="$1"
	local marker="$2"
	local since="$3"
	local found=0 file
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		found=$((found + 1))
		printf 'capture: %s\n' "$file"
	done < <(find "$CB_OUT" -maxdepth 1 -type f -name "${tag}-*.json" -newer "$marker" -print | sort)
	if [[ "$found" -eq 0 ]]; then
		print_error "No request body was captured (check the probe output above)."
		return 1
	fi
	printf 'next: context-budget-helper.sh analyze <capture.json>\n'
	if [[ "$CB_RUNTIME" == "oc1" ]]; then
		cmd_tokens --since "$since" --model "${CB_MODEL#*/}" --new-sessions
	else
		print_info "OpenCode 2 does not record llm_requests rows yet; compare OC2 captures in characters."
	fi
	return 0
}

cmd_capture() {
	parse_capture_args "$@" || {
		usage >&2
		return 2
	}
	local plugin_dir real_dir key plugin_url capture_url
	plugin_dir=$(resolve_plugin_dir "$CB_PLUGIN_SOURCE") || return 1
	if [[ "$CB_RUNTIME" == "oc1" ]]; then
		real_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
		key="plugin"
		plugin_url="file://$plugin_dir/index.mjs"
		capture_url="file://$CB_ASSET_DIR/capture-oc1.mjs"
	else
		real_dir="${AIDEVOPS_OPENCODE_V2_CONFIG_HOME:-$HOME/.aidevops/runtimes/opencode-v2/config}/opencode"
		key="plugins"
		plugin_url="file://$plugin_dir/v2-plugin"
		capture_url="file://$CB_ASSET_DIR/capture-v2"
	fi
	[[ -f "$real_dir/opencode.json" ]] || {
		print_error "No opencode.json in $real_dir"
		return 1
	}
	mkdir -p "$CB_WORKSPACE"
	if [[ ! -d "$CB_OUT" ]]; then
		mkdir -p "$CB_OUT"
		chmod 700 "$CB_OUT"
	fi
	trap cleanup_capture EXIT
	_CB_ISO=$(mktemp -d "$CB_WORKSPACE/context-budget-iso.XXXXXX")
	chmod 700 "$_CB_ISO"
	mirror_config_dir "$real_dir" "$_CB_ISO/opencode"
	node "$CB_ASSET_DIR/isolate-config.mjs" "$real_dir/opencode.json" "$_CB_ISO/opencode/opencode.json" "$key" "$plugin_url" "$capture_url"
	link_candidate_modules "$plugin_dir"
	local tag="${CB_RUNTIME}-${CB_LABEL}" since
	: >"$_CB_ISO/.start"
	since=$(date -u +%Y-%m-%dT%H:%M:%S)
	print_info "Probe: $CB_RUNTIME, plugin=$CB_PLUGIN_SOURCE, label=$CB_LABEL, headless=$CB_HEADLESS, turns=$CB_TURNS, model=$CB_MODEL"
	run_probe "$_CB_ISO" "$tag" || print_warning "Probe exited non-zero; checking for captures anyway."
	report_captures "$tag" "$_CB_ISO/.start" "$since"
	return $?
}

cmd_tokens() {
	local since="" until="" model="" new_sessions=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--since) since="${2:-}" ;;
		--until) until="${2:-}" ;;
		--model) model="${2:-}" ;;
		--new-sessions) new_sessions=1 && shift && continue ;;
		*) print_error "Unknown tokens option: $1" && return 2 ;;
		esac
		shift 2 || break
	done
	local iso_time='^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}(:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?)?Z?)?$'
	if [[ ! "$since" =~ $iso_time || (-n "$until" && ! "$until" =~ $iso_time) || ! "$model" =~ ^[A-Za-z0-9._/-]*$ ]]; then
		print_error "tokens needs --since <UTC ISO time>; --until must be ISO; --model must be a plain substring"
		return 2
	fi
	[[ -f "$CB_DB" ]] || {
		print_error "No observability database at $CB_DB"
		return 1
	}
	local where="timestamp >= '$since'"
	[[ -z "$until" ]] || where="$where AND timestamp <= '$until'"
	[[ -z "$model" ]] || where="$where AND model_id LIKE '%$model%'"
	# Probe sessions start inside the window; this excludes concurrent long-lived sessions.
	[[ "$new_sessions" -eq 0 ]] || where="$where AND session_id IN (SELECT session_id FROM llm_requests GROUP BY session_id HAVING min(timestamp) >= '$since')"
	sqlite3 -readonly -header -column "$CB_DB" "SELECT substr(timestamp, 1, 19) AS utc, substr(session_id, 1, 16) AS session, model_id AS model, routing_population AS population, tokens_input AS input, tokens_cache_read AS cache_read, tokens_cache_write AS cache_write, tokens_input + tokens_cache_read + tokens_cache_write AS prompt_tokens, tokens_output AS output FROM llm_requests WHERE $where ORDER BY timestamp LIMIT 50;"
	return 0
}

main() {
	local command="${1:-help}"
	[[ $# -eq 0 ]] || shift
	case "$command" in
	capture) cmd_capture "$@" ;;
	analyze | compare) node "$CB_ASSET_DIR/analyze.mjs" "$command" "$@" ;;
	tokens) cmd_tokens "$@" ;;
	help | --help | -h) usage ;;
	*)
		usage >&2
		return 2
		;;
	esac
	return $?
}

main "$@"
