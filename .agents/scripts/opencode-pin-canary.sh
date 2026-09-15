#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Bounded evaluator for the scoped OpenCode Linux-headless compatibility pin.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "$SCRIPT_DIR/shared-constants.sh"

OPENCODE_CANARY_PROFILE=$(aidevops_opencode_profile_id)
OPENCODE_CANARY_PACKAGE=$(aidevops_opencode_profile_value package "$OPENCODE_CANARY_PROFILE")
OPENCODE_CANARY_BINARY=$(aidevops_opencode_profile_value binary "$OPENCODE_CANARY_PROFILE")
OPENCODE_CANARY_PLUGIN_ENTRY=$(aidevops_opencode_profile_value pluginEntry "$OPENCODE_CANARY_PROFILE")
OPENCODE_CANARY_PLUGIN_TARGET=$(aidevops_opencode_profile_value pluginConfigTarget "$OPENCODE_CANARY_PROFILE")
OPENCODE_CANARY_PIN=$(aidevops_opencode_profile_value headlessPin "$OPENCODE_CANARY_PROFILE")
OPENCODE_CANARY_TESTED=$(aidevops_opencode_profile_value testedVersion "$OPENCODE_CANARY_PROFILE")
OPENCODE_CANARY_REASON=$(aidevops_opencode_profile_value pinReason "$OPENCODE_CANARY_PROFILE")
OPENCODE_CANARY_PLATFORM=$(aidevops_opencode_profile_value pinPlatform "$OPENCODE_CANARY_PROFILE")
OPENCODE_CANARY_RUNTIME_MODE=$(aidevops_opencode_profile_value pinRuntimeMode "$OPENCODE_CANARY_PROFILE")
OPENCODE_CANARY_INTRODUCED=$(aidevops_opencode_profile_value introducedDate "$OPENCODE_CANARY_PROFILE")
OPENCODE_CANARY_LAST_DATE=$(aidevops_opencode_profile_value lastCanaryDate "$OPENCODE_CANARY_PROFILE")
OPENCODE_CANARY_LAST_RESULT=$(aidevops_opencode_profile_value lastCanaryResult "$OPENCODE_CANARY_PROFILE")
OPENCODE_CANARY_REVIEW_DEADLINE=$(aidevops_opencode_profile_value reviewDeadline "$OPENCODE_CANARY_PROFILE")
OPENCODE_CANARY_PROVIDER_NAME='Canary'

_CANARY_TEMP_ROOT=""
_CANARY_MOCK_PID=""
_CANARY_PLUGIN_PATH=""

cleanup_canary() {
	if [[ -n "$_CANARY_MOCK_PID" ]]; then
		kill "$_CANARY_MOCK_PID" 2>/dev/null || true
		wait "$_CANARY_MOCK_PID" 2>/dev/null || true
	fi
	[[ -z "$_CANARY_TEMP_ROOT" ]] || rm -rf "$_CANARY_TEMP_ROOT"
}

usage() {
	printf 'Usage: opencode-pin-canary.sh status [--json]\n'
	printf '       opencode-pin-canary.sh canary [candidate-version] [--force]\n'
}

install_isolated_opencode() {
	local install_root="$1"
	local version="$2"
	local isolated_home="$3"
	local isolated_cache="$4"
	local -a install_args=(install --no-audit --no-fund --prefix "$install_root")
	# V2's package installs its platform binary in postinstall. V1 retains its
	# script-free installation and resolves the exact native optional dependency.
	[[ "$OPENCODE_CANARY_PROFILE" == "v2" ]] || install_args+=(--ignore-scripts)
	mkdir -p "$install_root" "$isolated_home" "$isolated_cache"
	env -i \
		HOME="$isolated_home" PATH="$PATH" \
		GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
		npm_config_userconfig=/dev/null npm_config_cache="$isolated_cache" \
		npm "${install_args[@]}" \
		"${OPENCODE_CANARY_PACKAGE}@${version}" >/dev/null
}

install_isolated_plugin() {
	local install_root="$1"
	local isolated_home="$2"
	local isolated_cache="$3"
	local source_root="$SCRIPT_DIR/../plugins/opencode-aidevops"
	mkdir -p "$install_root" "$isolated_home" "$isolated_cache"
	cp -R "$source_root/." "$install_root/" || return 1
	env -i \
		HOME="$isolated_home" PATH="$PATH" \
		GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
		npm_config_userconfig=/dev/null npm_config_cache="$isolated_cache" \
		npm ci --omit=peer --ignore-scripts --no-audit --no-fund --prefix "$install_root" >/dev/null || return 1
	_CANARY_PLUGIN_PATH="$install_root/${OPENCODE_CANARY_PLUGIN_TARGET}"
	return 0
}

resolve_installed_opencode_binary() {
	local install_root="$1"
	local expected_version="${2:-}"
	[[ -n "$expected_version" ]] || return 1
	local package_binary="$install_root/node_modules/.bin/${OPENCODE_CANARY_BINARY}"
	local version_output=""
	if [[ -x "$package_binary" ]]; then
		version_output=$("$package_binary" --version 2>/dev/null || true)
	fi
	if [[ "$version_output" =~ (^|[^0-9])${expected_version//./\.}([^0-9]|$) ]]; then
		printf '%s\n' "$package_binary"
		return 0
	fi
	local machine_arch="${AIDEVOPS_TEST_UNAME_M:-}"
	if [[ -z "$machine_arch" ]]; then
		machine_arch=$(uname -m)
	fi
	local package_arch=""
	case "$machine_arch" in
	x86_64 | amd64) package_arch="x64" ;;
	aarch64 | arm64) package_arch="arm64" ;;
	*) return 1 ;;
	esac
	local base="opencode-linux-${package_arch}"
	local suffix_baseline="-baseline"
	local suffix_musl="-musl"
	local suffix_baseline_musl="-baseline-musl"
	local suffixes=("")
	local has_avx2=1
	if [[ "$package_arch" == "x64" ]] && ! grep -qE '(^|[[:space:]])avx2([[:space:]]|$)' /proc/cpuinfo 2>/dev/null; then
		has_avx2=0
		suffixes=("$suffix_baseline" "")
	fi
	if ldd --version 2>&1 | grep -qi musl; then
		if [[ "$package_arch" == "x64" ]]; then
			if [[ "$has_avx2" -eq 1 ]]; then
				suffixes=("$suffix_musl" "$suffix_baseline_musl" "" "$suffix_baseline")
			else
				suffixes=("$suffix_baseline_musl" "$suffix_musl" "$suffix_baseline" "")
			fi
		else
			suffixes=("$suffix_musl" "")
		fi
	fi
	local suffix
	for suffix in "${suffixes[@]}"; do
		local binary="$install_root/node_modules/${base}${suffix}/bin/opencode"
		version_output=""
		if [[ -x "$binary" ]]; then
			version_output=$("$binary" --version 2>/dev/null || true)
		fi
		if [[ "$version_output" =~ (^|[^0-9])${expected_version//./\.}([^0-9]|$) ]]; then
			printf '%s\n' "$binary"
			return 0
		fi
	done
	return 1
}

start_mock_provider() {
	local canary_root="$1"
	local port_file="$canary_root/mock-provider.port"
	local request_file="$canary_root/mock-provider.requests"
	python3 - "$port_file" "$request_file" <<'PY' &
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port_file, request_file = sys.argv[1:]
CANARY = "canary"
CONTENT_LENGTH = "Content-Length"
CREATED = "created"
DELTA = "delta"
FOUR = "Four"
MESSAGE_ID = "msg_canary"
MODEL = "model"
OBJECT = "object"
STATUS = "status"
TYPE = "type"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        payload = json.dumps({
            OBJECT: "list",
            "data": [{"id": CANARY, OBJECT: MODEL, CREATED: 0, "owned_by": CANARY}],
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header(CONTENT_LENGTH, str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        with open(request_file, "a", encoding="utf-8") as requests:
            requests.write(self.path + "\n")
        now = int(time.time())
        if self.path.endswith("/responses"):
            chunks = [
                {TYPE: "response.output_item.added",
                 "item": {TYPE: "message", "id": MESSAGE_ID}},
                {TYPE: "response.output_text.delta", "item_id": MESSAGE_ID, DELTA: FOUR},
                {TYPE: "response.completed", "response": {
                    "id": "resp_canary",
                    STATUS: "completed",
                    "output": [{TYPE: "message", "id": MESSAGE_ID, "role": "assistant",
                                STATUS: "completed", "content": [{TYPE: "output_text", "text": FOUR}]}],
                    "usage": {"input_tokens": 4, "output_tokens": 1, "total_tokens": 5,
                              "input_tokens_details": {"cached_tokens": 0},
                              "output_tokens_details": {"reasoning_tokens": 0}},
                }},
            ]
        else:
            chunks = [
                {"id": CANARY, OBJECT: "chat.completion.chunk", CREATED: now,
                 MODEL: CANARY, "choices": [{"index": 0,
                 DELTA: {"role": "assistant", "content": FOUR}, "finish_reason": None}]},
                {"id": CANARY, OBJECT: "chat.completion.chunk", CREATED: now,
                 MODEL: CANARY, "choices": [{"index": 0, DELTA: {}, "finish_reason": "stop"}]},
            ]
        payload = "".join("data: " + json.dumps(chunk) + "\n\n" for chunk in chunks)
        payload += "data: [DONE]\n\n"
        encoded = payload.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header(CONTENT_LENGTH, str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as destination:
    destination.write(str(server.server_port))
server.serve_forever()
PY
	_CANARY_MOCK_PID=$!
	local attempt=0
	while [[ ! -s "$port_file" && "$attempt" -lt 50 ]]; do
		sleep 0.1
		attempt=$((attempt + 1))
	done
	[[ -s "$port_file" ]] || return 1
	MOCK_PROVIDER_PORT=$(<"$port_file")
	MOCK_PROVIDER_REQUEST_FILE="$request_file"
}

run_isolated_probe() {
	local label="$1"
	local binary="$2"
	local canary_root="$3"
	local port="$4"
	local request_file="$5"
	local probe_root="$canary_root/probe-$label"
	local output_file="$canary_root/$label.output"
	local plugin_path="${_CANARY_PLUGIN_PATH:-$SCRIPT_DIR/../plugins/opencode-aidevops/${OPENCODE_CANARY_PLUGIN_TARGET}}"
	local plugin_url=""
	local canary_id="canary"
	local provider_id="$canary_id"
	local model_id="$canary_id"
	[[ "$OPENCODE_CANARY_PROFILE" != "v2" ]] || provider_id="openai"
	local model_ref="${provider_id}/${model_id}"
	local request_count_before=0
	local request_count_after=0
	local probe_timeout_seconds=120
	mkdir -p "$probe_root/home" "$probe_root/config/opencode" "$probe_root/data" "$probe_root/cache"
	if [[ -e "$plugin_path" ]]; then
		plugin_url=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve().as_uri())' "$plugin_path")
	fi
	if [[ "$OPENCODE_CANARY_PROFILE" == "v2" ]]; then
		jq -n --arg api "http://127.0.0.1:${port}/v1" --arg plugin "$plugin_url" \
			--arg provider "$provider_id" --arg model "$model_id" --arg model_ref "$model_ref" --arg provider_name "$OPENCODE_CANARY_PROVIDER_NAME" \
			'{model:$model_ref,providers:{($provider):{name:$provider_name,
			settings:{baseURL:$api,apiKey:"unused-canary-value"},models:{($model):{name:"Canary"}}}}}
			+ (if $plugin == "" then {} else {plugins:[$plugin]} end)' \
			>"$probe_root/config/opencode/opencode.json"
	else
	jq -n --arg api "http://127.0.0.1:${port}/v1" --arg plugin "$plugin_url" \
		--arg provider "$provider_id" --arg model "$model_id" --arg model_ref "$model_ref" --arg provider_name "$OPENCODE_CANARY_PROVIDER_NAME" \
		'{model:$model_ref,small_model:$model_ref,
		provider:{($provider):{npm:"@ai-sdk/openai-compatible@3.0.31",name:$provider_name,
		options:{baseURL:$api,apiKey:"canary-local-only"},models:{($model):{name:"Canary"}}}}}
		+ (if $plugin == "" then {} else {plugin:[$plugin]} end)' \
		>"$probe_root/config/opencode/opencode.json"
	fi
	local routing_file="$probe_root/config/model-routing.json"
	jq -n --arg model "$model_ref" \
		'{tiers:{simple:{models:[$model]},standard:{models:[$model]},thinking:{models:[$model]}},
		escalation_order:["simple","standard","thinking"]}' >"$routing_file"
	[[ -f "$request_file" ]] && request_count_before=$(wc -l <"$request_file" | tr -d ' ')

	local timeout_command=(timeout --kill-after=5s "${probe_timeout_seconds}s")
	if ! command -v timeout >/dev/null 2>&1; then
		timeout_command=(perl -e "alarm ${probe_timeout_seconds}; exec @ARGV" --)
	fi
	local probe_rc=0
	local -a probe_args=(run "What is two plus two? Answer with the single word: Four" \
		-m "$model_ref" --agent build --print-logs)
	if [[ "$OPENCODE_CANARY_PROFILE" == "v2" ]]; then
		probe_args+=(--standalone --log-level debug)
	else
		probe_args+=(--dir "$probe_root/home" --log-level DEBUG)
	fi
	(
		cd "$probe_root/home" || exit 1
		env -i \
			HOME="$probe_root/home" PATH="$PATH" \
			XDG_CONFIG_HOME="$probe_root/config" XDG_DATA_HOME="$probe_root/data" \
			XDG_CACHE_HOME="$probe_root/cache" AIDEVOPS_HEADLESS=1 AIDEVOPS_PLUGIN_DEBUG=1 \
			AIDEVOPS_OPENCODE_PROFILE="$OPENCODE_CANARY_PROFILE" \
			AIDEVOPS_MODEL_ROUTING_TABLE="$routing_file" \
			GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
			"${timeout_command[@]}" "$binary" "${probe_args[@]}"
	) >"$output_file" 2>&1 || probe_rc=$?
	[[ -f "$request_file" ]] && request_count_after=$(wc -l <"$request_file" | tr -d ' ')
	if [[ "$probe_rc" -eq 0 && "$request_count_after" -gt "$request_count_before" ]] && grep -q 'Four' "$output_file"; then
		printf 'PASS: %s completed the isolated Linux-headless probe\n' "$label"
		return 0
	fi
	printf 'FAIL: %s isolated probe exited %s (provider requests: %s -> %s)\n' \
		"$label" "$probe_rc" "$request_count_before" "$request_count_after" >&2
	command tail -n 20 "$output_file" >&2 || true
	local log_file
	for log_file in "$probe_root/data/opencode/log/"*.log; do
		[[ -f "$log_file" ]] || continue
		printf '%s\n' "OpenCode log: $log_file" >&2
		command tail -n 80 "$log_file" >&2 || true
	done
	return 1
}

pin_age_days() {
	python3 - "$OPENCODE_CANARY_INTRODUCED" <<'PY'
from datetime import date
import sys
print((date.today() - date.fromisoformat(sys.argv[1])).days)
PY
}

cmd_status() {
	local format="${1:-text}"
	local registry_latest="unknown"
	registry_latest=$(npm view "$OPENCODE_CANARY_PACKAGE" version 2>/dev/null || printf 'unknown')
	local installed="not-installed"
	if command -v "$OPENCODE_CANARY_BINARY" >/dev/null 2>&1; then
		installed=$("$OPENCODE_CANARY_BINARY" --version 2>/dev/null | command head -n 1 || printf 'unknown')
	fi
	local age
	age=$(pin_age_days)
	if [[ "$format" == "--json" ]]; then
		printf '{"profile":"%s","installed":"%s","pinned":"%s","registry_latest":"%s","plugin_tested":"%s","pin_age_days":%s,"reason":"%s","platform":"%s","runtime_mode":"%s","introduced":"%s","last_canary_date":"%s","last_canary_result":"%s","review_deadline":"%s"}\n' \
			"$OPENCODE_CANARY_PROFILE" "$installed" "$OPENCODE_CANARY_PIN" "$registry_latest" "$OPENCODE_CANARY_TESTED" "$age" "$OPENCODE_CANARY_REASON" \
			"$OPENCODE_CANARY_PLATFORM" "$OPENCODE_CANARY_RUNTIME_MODE" "$OPENCODE_CANARY_INTRODUCED" \
			"$OPENCODE_CANARY_LAST_DATE" "$OPENCODE_CANARY_LAST_RESULT" "$OPENCODE_CANARY_REVIEW_DEADLINE"
		return 0
	fi
	printf 'profile=%s installed=%s pinned=%s registry-latest=%s pin-age=%sd\n' "$OPENCODE_CANARY_PROFILE" "$installed" "$OPENCODE_CANARY_PIN" "$registry_latest" "$age"
	printf 'scope=%s/%s plugin-tested=%s last-canary=%s (%s) review-deadline=%s\n' \
		"$OPENCODE_CANARY_PLATFORM" "$OPENCODE_CANARY_RUNTIME_MODE" "$OPENCODE_CANARY_TESTED" "$OPENCODE_CANARY_LAST_DATE" \
		"$OPENCODE_CANARY_LAST_RESULT" "$OPENCODE_CANARY_REVIEW_DEADLINE"
}

cmd_canary() {
	local candidate="${1:-}"
	local force="${2:-}"
	[[ -z "$force" || "$force" == "--force" ]] || {
		printf 'RESULT=inconclusive\nINCONCLUSIVE: unsupported canary option %s\n' "$force" >&2
		return 2
	}
	[[ "$(uname -s)" == "$OPENCODE_CANARY_PLATFORM" ]] || {
		printf 'RESULT=inconclusive\nINCONCLUSIVE: candidate canary requires %s\n' "$OPENCODE_CANARY_PLATFORM" >&2
		return 2
	}
	local required_command
	for required_command in npm python3 jq; do
		command -v "$required_command" >/dev/null 2>&1 || {
			printf 'RESULT=inconclusive\nINCONCLUSIVE: %s is unavailable\n' "$required_command" >&2
			return 2
		}
	done
	if [[ -z "$candidate" || "$candidate" == "latest" ]]; then
		candidate=$(npm view "$OPENCODE_CANARY_PACKAGE" version 2>/dev/null || true)
	fi
	[[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || {
		printf 'RESULT=inconclusive\nINCONCLUSIVE: invalid candidate version %s\n' "${candidate:-empty}" >&2
		return 2
	}
	if [[ "$candidate" == "$OPENCODE_CANARY_PIN" && "$force" != "--force" ]]; then
		printf 'RESULT=skip\nSKIP: registry candidate equals pin %s\n' "$candidate"
		return 0
	fi

	local temp_parent="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$temp_parent"
	_CANARY_TEMP_ROOT=$(mktemp -d "${temp_parent}/opencode-pin-canary-XXXXXX")
	trap cleanup_canary EXIT INT TERM
	if ! install_isolated_opencode "$_CANARY_TEMP_ROOT/baseline" "$OPENCODE_CANARY_PIN" \
		"$_CANARY_TEMP_ROOT/install-home-baseline" "$_CANARY_TEMP_ROOT/npm-cache-baseline"; then
		printf 'RESULT=inconclusive\nINCONCLUSIVE: pinned baseline installation failed\n' >&2
		return 2
	fi
	if ! install_isolated_opencode "$_CANARY_TEMP_ROOT/candidate" "$candidate" \
		"$_CANARY_TEMP_ROOT/install-home-candidate" "$_CANARY_TEMP_ROOT/npm-cache-candidate"; then
		printf 'RESULT=inconclusive\nINCONCLUSIVE: candidate installation failed\n' >&2
		return 2
	fi
	if ! install_isolated_plugin "$_CANARY_TEMP_ROOT/plugin" \
		"$_CANARY_TEMP_ROOT/install-home-plugin" "$_CANARY_TEMP_ROOT/npm-cache-plugin"; then
		printf 'RESULT=inconclusive\nINCONCLUSIVE: locked plugin installation failed\n' >&2
		return 2
	fi
	local baseline_bin=""
	local candidate_bin=""
	baseline_bin=$(resolve_installed_opencode_binary "$_CANARY_TEMP_ROOT/baseline" "$OPENCODE_CANARY_PIN" || true)
	candidate_bin=$(resolve_installed_opencode_binary "$_CANARY_TEMP_ROOT/candidate" "$candidate" || true)
	[[ -n "$baseline_bin" && -n "$candidate_bin" ]] || {
		printf 'RESULT=inconclusive\nINCONCLUSIVE: baseline or candidate binary was not installed\n' >&2
		return 2
	}
	start_mock_provider "$_CANARY_TEMP_ROOT" || {
		printf 'RESULT=inconclusive\nINCONCLUSIVE: local mock provider failed to start\n' >&2
		return 2
	}
	local mock_provider_port="$MOCK_PROVIDER_PORT"
	local mock_provider_request_file="$MOCK_PROVIDER_REQUEST_FILE"
	local revision="unknown"
	revision=$(git -C "$SCRIPT_DIR/../.." rev-parse HEAD 2>/dev/null || printf 'unknown')

	printf 'Evaluating pinned baseline %s and candidate %s at repository revision %s\n' \
		"$OPENCODE_CANARY_PIN" "$candidate" "$revision"
	if ! run_isolated_probe "baseline-$OPENCODE_CANARY_PIN" "$baseline_bin" "$_CANARY_TEMP_ROOT" \
		"$mock_provider_port" "$mock_provider_request_file"; then
		printf 'RESULT=inconclusive\nINCONCLUSIVE: pinned baseline failed; retaining %s\n' \
			"$OPENCODE_CANARY_PIN" >&2
		return 2
	fi
	if ! run_isolated_probe "candidate-$candidate" "$candidate_bin" "$_CANARY_TEMP_ROOT" \
		"$mock_provider_port" "$mock_provider_request_file"; then
		printf 'RESULT=fail\nFAIL: candidate failed while the same-revision pinned baseline passed; retaining %s\n' \
			"$OPENCODE_CANARY_PIN" >&2
		return 1
	fi
	printf 'RESULT=pass\nPASS: OpenCode %s passed the Linux-headless compatibility canary\n' "$candidate"
}

case "${1:-}" in
status) cmd_status "${2:-}" ;;
canary) cmd_canary "${2:-latest}" "${3:-}" ;;
*)
	usage >&2
	exit 2
	;;
esac
