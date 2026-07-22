#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression test for GH#28487: init-generated Markdown passes default lint.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
MODEL_SCRIPT="$REPO_ROOT/.agents/scripts/generate-models-md.sh"
METRICS_HELPER="$REPO_ROOT/.agents/scripts/repo-metrics-helper.sh"
TEST_ROOT=""
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"
[[ -x "$GIT_BIN" ]] || GIT_BIN=$(command -v git)

cleanup() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

print_info() { return 0; }
print_success() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }

assert_content() {
	local expected="$1"
	local file="$2"
	local actual
	actual=$(<"$file")
	if [[ "$actual" == "$expected" ]]; then
		return 0
	fi
	printf 'FAIL unexpected content in %s\n' "$file" >&2
	return 1
}

assert_contains() {
	local expected="$1"
	local file="$2"
	if grep -qF "$expected" "$file"; then
		return 0
	fi
	printf 'FAIL missing expected content in %s: %s\n' "$file" "$expected" >&2
	return 1
}

write_model_databases() {
	local registry_db="$1"
	local memory_db="$2"
	local scoring_db="$3"

	sqlite3 "$registry_db" <<'SQL'
CREATE TABLE models (model_id TEXT, provider TEXT, tier TEXT, context_window INTEGER, input_price REAL, output_price REAL);
CREATE TABLE subagent_models (tier TEXT, model_id TEXT);
INSERT INTO models VALUES ('fixture-model', 'Fixture', 'high', 200000, 1.0, 2.0);
INSERT INTO subagent_models VALUES ('opus', 'fixture-model');
SQL
	sqlite3 "$memory_db" <<'SQL'
CREATE TABLE learnings (type TEXT, project_path TEXT, tags TEXT, content TEXT, created_at TEXT);
INSERT INTO learnings VALUES ('SUCCESS_PATTERN', '/fixture/repo', 'model:thinking feature', 'fixture', '2026-07-22T00:00:00Z');
SQL
	sqlite3 "$scoring_db" <<'SQL'
CREATE TABLE responses (response_id TEXT, model_id TEXT, prompt_id TEXT, response_time REAL);
CREATE TABLE scores (response_id TEXT, criterion TEXT, score REAL);
CREATE TABLE comparisons (prompt_id TEXT, winner_id TEXT);
INSERT INTO responses VALUES ('response-1', 'fixture-model', 'prompt-1', 1.5);
INSERT INTO scores VALUES ('response-1', 'correctness', 5.0);
INSERT INTO scores VALUES ('response-1', 'completeness', 4.0);
INSERT INTO scores VALUES ('response-1', 'code_quality', 5.0);
INSERT INTO scores VALUES ('response-1', 'clarity', 4.0);
INSERT INTO comparisons VALUES ('prompt-1', 'response-1');
SQL
	return 0
}

write_metrics_repo() {
	local repo="$1"
	local with_dependencies="$2"
	mkdir -p "$repo"
	"$GIT_BIN" -C "$repo" init -q
	printf '# Fixture\n' >"$repo/README.md"
	if [[ "$with_dependencies" == "true" ]]; then
		mkdir -p "$repo/src"
		printf 'print("fixture")\n' >"$repo/src/app.py"
		printf '%s\n' '{"dependencies":{"fixture":"1.0.0"}}' >"$repo/package.json"
	fi
	"$GIT_BIN" -C "$repo" add .
	return 0
}

generate_pointer_files() {
	local output_root="$1"
	local existing_root="$2"
	local plain_content="Read AGENTS.md for all project context and instructions."
	local copilot_content=$'# GitHub Copilot instructions\n\nRead [AGENTS.md](../AGENTS.md) for all project context and instructions.'

	INSTALL_DIR="$REPO_ROOT"
	AGENTS_DIR="$TEST_ROOT/empty-agents"
	CONFIG_DIR="${HOME}/.config/aidevops"
	mkdir -p "$AGENTS_DIR" "$existing_root/.github"
	# shellcheck source=../aidevops-cli/aidevops-init-lib.sh
	source "$REPO_ROOT/.agents/scripts/aidevops-cli/aidevops-init-lib.sh"
	_scope_includes() { return 0; }
	_init_scaffold_design_md() { return 0; }
	scaffold_repo_courtesy_files() { return 0; }

	_init_scaffold_scope_gated_files "$output_root" standard fixture false
	assert_content "$plain_content" "$output_root/.cursorrules"
	assert_content "$plain_content" "$output_root/.windsurfrules"
	assert_content "$plain_content" "$output_root/.clinerules"
	assert_content "$copilot_content" "$output_root/.github/copilot-instructions.md"

	printf '# Existing instructions\n' >"$existing_root/.github/copilot-instructions.md"
	_init_scaffold_scope_gated_files "$existing_root" standard fixture false
	assert_content "# Existing instructions" "$existing_root/.github/copilot-instructions.md"
	return 0
}

generate_model_outputs() {
	local output_root="$1"
	local registry_db="$TEST_ROOT/model-registry.db"
	local memory_dir="$TEST_ROOT/memory"
	local scoring_db="$TEST_ROOT/response-scoring.db"
	local mode
	mkdir -p "$memory_dir"
	write_model_databases "$registry_db" "$memory_dir/memory.db" "$scoring_db"

	for mode in all global performance; do
		MODEL_REGISTRY_DB="$registry_db" \
			AIDEVOPS_MEMORY_DIR="$memory_dir" \
			SCORING_DB_OVERRIDE="$scoring_db" \
			"$MODEL_SCRIPT" --mode "$mode" \
			--output "$output_root/MODELS-$mode.md" \
			--repo-path /fixture/repo --quiet
	done
	assert_contains "| fixture-model | Fixture | opus | 200K | \$1.00 | \$2.00 |" \
		"$output_root/MODELS-all.md"
	assert_contains "| fixture-model | Fixture | opus | 200K | \$1.00 | \$2.00 |" \
		"$output_root/MODELS-global.md"
	assert_contains '| fixture-model | 1 | 4.55/5.0 | 1.5 |' \
		"$output_root/MODELS-performance.md"

	MODEL_REGISTRY_DB="$TEST_ROOT/missing-registry.db" \
		AIDEVOPS_MEMORY_DIR="$TEST_ROOT/missing-memory" \
		SCORING_DB_OVERRIDE="$TEST_ROOT/missing-scoring.db" \
		"$MODEL_SCRIPT" --mode performance \
		--output "$output_root/MODELS-performance-empty.md" \
		--repo-path /fixture/repo --quiet
	return 0
}

generate_metrics_outputs() {
	local output_root="$1"
	local populated_repo="$TEST_ROOT/metrics-populated"
	local empty_repo="$TEST_ROOT/metrics-empty"
	write_metrics_repo "$populated_repo" true
	write_metrics_repo "$empty_repo" false
	bash "$METRICS_HELPER" generate \
		--output-dir "$output_root/metrics-populated" \
		--badge-dir "$output_root/metrics-populated/badges" \
		"$populated_repo" >/dev/null
	bash "$METRICS_HELPER" generate \
		--output-dir "$output_root/metrics-empty" \
		--badge-dir "$output_root/metrics-empty/badges" \
		"$empty_repo" >/dev/null
	assert_contains '| Direct dependencies | 1 |' \
		"$output_root/metrics-populated/repo-metrics.md"
	assert_contains '| none detected | — | 0 | 0 |' \
		"$output_root/metrics-empty/repo-metrics.md"
	return 0
}

run_default_markdownlint() {
	local output_root="$1"
	local lint_files=(
		"$output_root/.github/copilot-instructions.md"
		"$output_root/TODO.md"
		"$output_root/todo/PLANS.md"
		"$output_root/MODELS-all.md"
		"$output_root/MODELS-global.md"
		"$output_root/MODELS-performance.md"
		"$output_root/MODELS-performance-empty.md"
		"$output_root/metrics-populated/repo-metrics.md"
		"$output_root/metrics-empty/repo-metrics.md"
	)
	(
		cd "$TEST_ROOT" || exit 1
		npx --yes markdownlint-cli2@0.22.0 "${lint_files[@]}"
	)
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	local output_root="$TEST_ROOT/generated"
	local existing_root="$TEST_ROOT/existing"
	mkdir -p "$output_root/todo"

	generate_pointer_files "$output_root" "$existing_root"
	cp "$REPO_ROOT/.agents/templates/todo-template.md" "$output_root/TODO.md"
	cp "$REPO_ROOT/.agents/templates/plans-template.md" "$output_root/todo/PLANS.md"
	generate_model_outputs "$output_root"
	generate_metrics_outputs "$output_root"
	run_default_markdownlint "$output_root"
	printf 'PASS init-generated Markdown is default-markdownlint clean\n'
	return 0
}

main "$@"
