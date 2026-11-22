#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2016  # fixtures are literal jq, shell, Python and YAML text
# =============================================================================
# test-jq-binding-precedence-check.sh — fixtures for
# jq-binding-precedence-check.py (GH#35920).
#
# Every operator-class and term/pattern "flag" program gives different output
# under jq 1.7.1 and jq 1.8.2, and every runnable "clean" context agrees
# (verified with both binaries). Programs end in `| type` so the divergence is
# visible. File-type, override and incident fixtures exercise selection only.
# The checker only scans text, so this suite needs no jq.
#
# Usage: bash test-jq-binding-precedence-check.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CHECKER="${SCRIPT_DIR}/../jq-binding-precedence-check.py"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

pass_count=0
fail_count=0

_record() {
	local ok="$1" label="$2"
	if [[ "$ok" == true ]]; then
		pass_count=$((pass_count + 1))
		printf 'PASS %s\n' "$label"
	else
		fail_count=$((fail_count + 1))
		printf 'FAIL %s\n' "$label" >&2
	fi
	return 0
}

# Args: $1=expected exit (1 flag, 0 clean), $2=description, $3=fixture text,
#       $4=fixture suffix (default sh; empty for an extensionless file)
_check() {
	local expected="$1" desc="$2" body="$3" suffix="${4-sh}"
	local fixture="${WORK_DIR}/fixture-$((pass_count + fail_count))${suffix:+.${suffix}}"
	local status=0 ok=false
	printf '%s\n' "$body" >"$fixture"
	python3 "$CHECKER" "$fixture" >/dev/null 2>&1 || status=$?
	[[ "$status" -eq "$expected" ]] && ok=true
	_record "$ok" "exit ${expected}: ${desc} (got ${status})"
	return 0
}

_flag() {
	_check 1 "$@"
	return 0
}

_clean() {
	_check 0 "$@"
	return 0
}

test_operator_classes_flagged() {
	_flag "and" "jq -n 'true and (\"x\") as \$l | \$l | type'"
	_flag "or" "jq -n 'false or (\"x\") as \$l | \$l | type'"
	local operator=""
	for operator in '==' '!=' '<' '<=' '>' '>=' '+' '-' '*' '/' '%' '//'; do
		_flag "binary ${operator}" "jq -n '2 ${operator} 1 as \$x | \$x | type'"
	done
	for operator in '=' '|=' '+=' '-=' '*=' '/=' '%=' '//='; do
		_flag "assignment ${operator}" "jq -n '{a:1} | .a ${operator} 2 as \$x | \$x | type'"
	done
	_flag "unary minus" "jq -nc '[-1 as \$x | 1, \$x]'"
	_flag "try" "jq -n '[try 1 as \$x | error(\"boom\")]'"
	_flag "catch" "jq -n '[try 5 catch . as \$x | \$x + 1]'"
	_flag "keyword glued to term" "jq -n 'true and(.a) as \$x | \$x | type'"
	return 0
}

test_term_and_pattern_shapes_flagged() {
	local term=""
	for term in '.a' '.a?' '"s"' '$v' '@base64' '..' 'length' '[1]' '{a:1}' '1'; do
		_flag "term ${term}" "jq -n --argjson v 1 'true and ${term} as \$x | \$x | type'"
	done
	_flag "array destructuring" "jq -n 'true and [1,2] as [\$a, \$b] | \$a'"
	_flag "object destructuring" "jq -n 'true and {a:1} as {a: \$a} | \$a'"
	_flag "shell-escaped variable" 'jq -n "true and .a as \$x | \$x | type"'
	_flag "operator on the previous line" $'jq -n \'true and\n\t.a as $x | $x | type\''
	_flag "GH#35920 incident shape" $'\t\tdef blocked_by_runner:\n\t\t\tunedited and login == $runner and\n\t\t\t([body_lines | select(is_release)] | first // "") as $line |\n\t\t\t($line | field("reason")) == "blocked";'
	return 0
}

test_file_types() {
	_flag ".jq file" 'def f: .a and .b as $x | $x;' jq
	_flag ".py file" 'subprocess.run(["jq", "-n", "true and .a as $x | $x"], check=True)' py
	_flag ".yml file" $'steps:\n  - run: jq -n \'true and .a as $x | $x\'' yml
	_flag "extensionless bash script" $'#!/usr/bin/env bash\njq -n \'true and .a as $x | $x\'' ''
	_flag "extensionless python script" $'#!/usr/bin/env python3\nPROGRAM = "true and .a as $x | $x"' ''
	_clean "extensionless file without a script shebang" "jq -n 'true and .a as \$x | \$x'" ''
	_clean ".md file is not scanned" "jq -n 'true and .a as \$x | \$x'" md
	local status=0 ok=false
	python3 "$CHECKER" "${WORK_DIR}/missing.sh" >/dev/null 2>&1 || status=$?
	[[ "$status" -eq 0 ]] && ok=true
	_record "$ok" "exit 0: missing path is skipped (got ${status})"
	return 0
}

test_override() {
	_clean "override with a reason" $'# jq-binding-precedence: ignore next -- prose, not jq\necho "x - $a as $b"'
	_flag "override without a reason" $'# jq-binding-precedence: ignore next\necho "x - $a as $b"'
	_flag "override applies only to the next line" $'# jq-binding-precedence: ignore next -- prose\n\necho "x - $a as $b"'
	return 0
}

test_unaffected_contexts_clean() {
	_clean "program start" "jq -n '. as \$x | \$x'"
	_clean "after pipe" "jq -n '.a | .b as \$x | \$x'"
	_clean "after comma" "jq -nc '[1, 2 as \$x | \$x + 10]'"
	_clean "after semicolon" "jq -n 'limit(1; .a as \$x | \$x)'"
	_clean "parenthesized after and" "jq -n 'true and (.a as \$x | \$x)'"
	_clean "parenthesized source" "jq -n 'true and ((.a) as \$x | \$x)'"
	_clean "object value" "jq -n '{k: (.a as \$x | \$x)}'"
	_clean "then and else" "jq -n 'if true then .a as \$x | \$x else .b as \$y | \$y end'"
	_clean "reduce and foreach" "jq -n 'reduce .[] as \$x (0; . + \$x), foreach .[] as \$y (0; . + \$y)'"
	_clean "def body" "jq -n 'def f: .a as \$x | \$x; f'"
	_clean "label" "jq -n 'label \$out | .a as \$x | \$x'"
	_clean "alternative destructuring" "jq -n '. as [\$a] ?// \$a | \$a'"
	_clean "comment" "# true and .a as \$x | \$x"
	_clean "operator word inside a longer identifier" "jq -n 'def band: .; band as \$x | \$x'"
	_clean "printf conversion before shell prose" 'printf "Using %s as $TARGET\n" "$HOME"'
	_clean "string containing an operator" "jq -n 'select(.t == \"a and\") | .a as \$x | \$x'"
	return 0
}

test_report_format() {
	local flagged="${WORK_DIR}/report.sh" clean="${WORK_DIR}/report-clean.sh"
	local output="" status=0 ok=false
	printf '%s\n' '#!/usr/bin/env bash' "jq -n 'true and .a as \$x | \$x'" >"$flagged"
	printf '%s\n' "jq -n '.a as \$x | \$x'" >"$clean"
	output=$(printf '%s\n' "$clean" "$flagged" | python3 "$CHECKER" -) || status=$?
	[[ "$status" -eq 1 && "$output" == "${flagged}:2: binding after 'and': "* &&
		"$output" != *"$clean"* ]] && ok=true
	_record "$ok" "stdin path list reports file:line and operator only for the ambiguous file"
	return 0
}

main() {
	test_operator_classes_flagged
	test_term_and_pattern_shapes_flagged
	test_file_types
	test_override
	test_unaffected_contexts_clean
	test_report_format
	printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"
	[[ "$fail_count" -eq 0 ]] || return 1
	return 0
}

main "$@"
