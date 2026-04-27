#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-case-chase.sh — Tests for case-chase-helper.sh (t2858)
#
# Tests:
#   1. Helper and email_send.py files exist
#   2. Python syntax valid
#   3. help exits 0, unknown command exits 1
#   4. Template listing
#   5. Opt-in gate: chasers_enabled: false → exit 1
#   6. Opt-in gate: chasers_enabled: true → passes
#   7. Dry-run: substitution output, no SMTP call
#   8. Missing field → exit 1 with explicit list
#   9. Template test command (dry-run substitution)
#  10. Failure records error status in sent.jsonl
#  11. Credentials never logged in any file
#  12. email_send.py dry-run outputs template content
#  13. email_send.py field substitution works
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../scripts/case-chase-helper.sh"
EMAIL_SEND="${SCRIPT_DIR}/../scripts/email_send.py"
SHARED="${SCRIPT_DIR}/../scripts/shared-constants.sh"

# =============================================================================
# Test framework
# =============================================================================

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

_pass() {
	local name="$1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '[PASS] %s\n' "$name"
	return 0
}

_fail() {
	local name="$1" reason="${2:-}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '[FAIL] %s%s\n' "$name" "${reason:+ — ${reason}}"
	return 0
}

_assert_exit() {
	local name="$1" expected_exit="$2"
	shift 2
	local actual_exit=0
	"$@" >/dev/null 2>&1 || actual_exit=$?
	if [[ "$actual_exit" -eq "$expected_exit" ]]; then
		_pass "$name"
	else
		_fail "$name" "expected exit ${expected_exit}, got ${actual_exit}"
	fi
	return 0
}

# =============================================================================
# Test setup — create a temporary repo with _cases/ plane
# =============================================================================

_setup_test_repo() {
	local tmpdir
	tmpdir=$(mktemp -d)

	mkdir -p "${tmpdir}/_cases"
	mkdir -p "${tmpdir}/_cases/case-2026-0001-test"
	mkdir -p "${tmpdir}/_cases/case-2026-0001-test/comms"

	cat > "${tmpdir}/_cases/case-2026-0001-test/dossier.toon" <<'EOF'
{
  "id": "case-2026-0001-test",
  "slug": "test",
  "kind": "general",
  "opened_at": "2026-04-27T00:00:00Z",
  "status": "open",
  "outcome": "",
  "outcome_summary": "",
  "parties": [
    {"name": "Test Client", "role": "client", "email": "client@example.com"},
    {"name": "Test Sender", "role": "self", "email": "sender@example.com"}
  ],
  "deadlines": [{"label": "payment", "date": "2026-05-31"}],
  "related_cases": [],
  "related_repos": [],
  "chasers_enabled": false
}
EOF

	printf '' > "${tmpdir}/_cases/case-2026-0001-test/timeline.jsonl"
	printf '[]\n' > "${tmpdir}/_cases/case-2026-0001-test/sources.toon"

	mkdir -p "${tmpdir}/_config/case-chase-templates"
	cat > "${tmpdir}/_config/case-chase-templates/test-template.eml.tmpl" <<'EOF'
# Test template
From: {{sender_email}}
To: {{recipient_email}}
Subject: Test chase

Dear {{recipient_name}},

This is a test chase. Case: {{case_id}}.

Regards,
{{sender_name}}
EOF

	mkdir -p "${tmpdir}/_config"
	cat > "${tmpdir}/_config/mailboxes.json" <<'EOF'
{
  "mailboxes": {
    "default": {
      "id": "default",
      "email": "sender@example.com",
      "display_name": "Test Sender",
      "smtp_host": "smtp.example.com",
      "smtp_port": 587,
      "smtp_user": "sender@example.com",
      "gopass_path": ""
    }
  }
}
EOF

	echo "$tmpdir"
	return 0
}

_enable_chasers() {
	local repo="$1"
	local dossier="${repo}/_cases/case-2026-0001-test/dossier.toon"
	python3 -c "
import json
with open('${dossier}') as f: d = json.load(f)
d['chasers_enabled'] = True
with open('${dossier}', 'w') as f: json.dump(d, f, indent=2)
"
	return 0
}

# =============================================================================
# Tests
# =============================================================================

_test_helper_exists() {
	if [[ -f "$HELPER" ]]; then
		_pass "helper exists: case-chase-helper.sh"
	else
		_fail "helper exists: case-chase-helper.sh" "file not found: ${HELPER}"
	fi
	return 0
}

_test_email_send_exists() {
	if [[ -f "$EMAIL_SEND" ]]; then
		_pass "helper exists: email_send.py"
	else
		_fail "helper exists: email_send.py" "file not found: ${EMAIL_SEND}"
	fi
	return 0
}

_test_python_syntax() {
	local exit_code=0
	python3 -m py_compile "$EMAIL_SEND" 2>/dev/null || exit_code=$?
	if [[ $exit_code -eq 0 ]]; then
		_pass "email_send.py: syntax valid"
	else
		_fail "email_send.py: syntax valid" "py_compile failed"
	fi
	return 0
}

_test_help_exits_zero() {
	_assert_exit "help: exits 0" 0 bash "$HELPER" help
	return 0
}

_test_unknown_command_exits_nonzero() {
	_assert_exit "unknown command: exits 1" 1 bash "$HELPER" unknowncmd
	return 0
}

_test_template_list() {
	local repo out exit_code=0
	repo=$(_setup_test_repo)
	out=$(bash "$HELPER" template list --repo "$repo" 2>&1) || exit_code=$?
	if [[ $exit_code -eq 0 ]] && echo "$out" | grep -q "test-template"; then
		_pass "template list: shows test-template"
	else
		_fail "template list: shows test-template" "exit=${exit_code} out=${out:0:200}"
	fi
	rm -rf "$repo"
	return 0
}

_test_opt_in_gate_disabled() {
	local repo exit_code=0
	repo=$(_setup_test_repo)
	bash "$HELPER" send "case-2026-0001-test" --template test-template \
		--dry-run --repo "$repo" 2>/dev/null || exit_code=$?
	if [[ $exit_code -ne 0 ]]; then
		_pass "opt-in gate: exits non-zero when chasers_enabled: false"
	else
		_fail "opt-in gate: exits non-zero when chasers_enabled: false" "expected non-zero exit"
	fi
	rm -rf "$repo"
	return 0
}

_test_opt_in_gate_enabled() {
	local repo out exit_code=0
	repo=$(_setup_test_repo)
	_enable_chasers "$repo"
	out=$(bash "$HELPER" send "case-2026-0001-test" --template test-template \
		--dry-run --repo "$repo" 2>&1) || exit_code=$?
	if ! echo "$out" | grep -q "chasers are disabled"; then
		_pass "opt-in gate: enabled case passes opt-in check"
	else
		_fail "opt-in gate: enabled case passes opt-in check" "${out:0:200}"
	fi
	rm -rf "$repo"
	return 0
}

_test_dry_run_no_smtp() {
	local repo out exit_code=0
	repo=$(_setup_test_repo)
	_enable_chasers "$repo"
	out=$(SMTP_PASS_DEFAULT="dummypass" bash "$HELPER" send "case-2026-0001-test" \
		--template test-template --dry-run --repo "$repo" 2>&1) || exit_code=$?
	if echo "$out" | grep -qE "DRY-RUN|From:|To:"; then
		_pass "dry-run: outputs substituted email, no SMTP"
	else
		_fail "dry-run: outputs substituted email, no SMTP" "exit=${exit_code} out=${out:0:300}"
	fi
	rm -rf "$repo"
	return 0
}

_test_missing_field_rejection() {
	local repo out exit_code=0
	repo=$(_setup_test_repo)
	_enable_chasers "$repo"

	cat > "${repo}/_config/case-chase-templates/bad-template.eml.tmpl" <<'EOF'
# Bad template with unresolvable field
From: {{sender_email}}
To: {{recipient_email}}
Subject: Test

Invoice {{invoice_number}} (no invoice attached).

Regards,
{{sender_name}}
EOF

	out=$(bash "$HELPER" send "case-2026-0001-test" --template bad-template \
		--dry-run --repo "$repo" 2>&1) || exit_code=$?
	if [[ $exit_code -ne 0 ]] && echo "$out" | grep -qE "Missing|invoice_number"; then
		_pass "missing field: exits non-zero with explicit list"
	else
		_fail "missing field: exits non-zero with explicit list" "exit=${exit_code} out=${out:0:300}"
	fi
	rm -rf "$repo"
	return 0
}

_test_template_test_command() {
	local repo out exit_code=0
	repo=$(_setup_test_repo)
	_enable_chasers "$repo"
	out=$(bash "$HELPER" template test \
		--case "case-2026-0001-test" \
		--template test-template \
		--repo "$repo" 2>&1) || exit_code=$?
	if echo "$out" | grep -qE "Template test|From:|DRY-RUN|END"; then
		_pass "template test: outputs substituted content"
	else
		_fail "template test: outputs substituted content" "exit=${exit_code} out=${out:0:300}"
	fi
	rm -rf "$repo"
	return 0
}

_test_failure_records_error() {
	local repo exit_code=0
	repo=$(_setup_test_repo)
	local sent_log="${repo}/_cases/case-2026-0001-test/comms/sent.jsonl"
	mkdir -p "$(dirname "$sent_log")"

	(
		# shellcheck source=/dev/null
		source "$SHARED" 2>/dev/null || true
		# shellcheck source=/dev/null
		source "$HELPER" 2>/dev/null || true
		_chase_record_failure \
			"${repo}/_cases/case-2026-0001-test" \
			"connection refused" \
			"test-template" \
			"client@example.com" \
			"testactor"
	)

	if [[ -f "$sent_log" ]]; then
		local status
		status=$(jq -r '.status' "$sent_log" 2>/dev/null) || status=""
		if [[ "$status" == "error" ]]; then
			_pass "failure: records error status in sent.jsonl"
		else
			_fail "failure: records error status in sent.jsonl" "status=${status}"
		fi
	else
		_fail "failure: records error status in sent.jsonl" "sent.jsonl not created"
	fi
	rm -rf "$repo"
	return 0
}

_test_credentials_not_logged() {
	local repo found=false
	repo=$(_setup_test_repo)
	_enable_chasers "$repo"

	SMTP_PASS_DEFAULT="S3cr3tP@ssw0rd!" bash "$HELPER" send "case-2026-0001-test" \
		--template test-template --repo "$repo" 2>/dev/null || true

	if [[ -f "${repo}/_cases/case-2026-0001-test/comms/sent.jsonl" ]]; then
		grep -q "S3cr3tP@ssw0rd!" "${repo}/_cases/case-2026-0001-test/comms/sent.jsonl" \
			2>/dev/null && found=true || true
	fi
	if [[ -f "${repo}/_cases/case-2026-0001-test/timeline.jsonl" ]]; then
		grep -q "S3cr3tP@ssw0rd!" "${repo}/_cases/case-2026-0001-test/timeline.jsonl" \
			2>/dev/null && found=true || true
	fi

	if [[ "$found" == false ]]; then
		_pass "security: credentials not in logs"
	else
		_fail "security: credentials not in logs" "password found in log file"
	fi
	rm -rf "$repo"
	return 0
}

_test_email_send_dry_run() {
	local tmpdir out exit_code=0
	tmpdir=$(mktemp -d)
	cat > "${tmpdir}/test.eml.tmpl" <<'EOF'
# Test
From: sender@example.com
To: recipient@example.com
Subject: Test

Hello World.
EOF
	out=$(python3 "$EMAIL_SEND" \
		--template "${tmpdir}/test.eml.tmpl" \
		--fields-json '{}' \
		--dry-run 2>&1) || exit_code=$?
	if [[ $exit_code -eq 0 ]] && echo "$out" | grep -q "Hello World"; then
		_pass "email_send.py: dry-run outputs template content"
	else
		_fail "email_send.py: dry-run outputs template content" \
			"exit=${exit_code} out=${out:0:200}"
	fi
	rm -rf "$tmpdir"
	return 0
}

_test_email_send_field_substitution() {
	local tmpdir out exit_code=0
	tmpdir=$(mktemp -d)
	cat > "${tmpdir}/sub.eml.tmpl" <<'EOF'
# Substitution test
From: {{sender_email}}
To: {{recipient_email}}
Subject: Hello {{recipient_name}}

Dear {{recipient_name}}, regards {{sender_name}}.
EOF
	local fj='{"sender_email":"a@b.com","recipient_email":"c@d.com","sender_name":"Alice","recipient_name":"Bob"}'
	out=$(python3 "$EMAIL_SEND" \
		--template "${tmpdir}/sub.eml.tmpl" \
		--fields-json "$fj" \
		--dry-run 2>&1) || exit_code=$?
	if echo "$out" | grep -q "Dear Bob" && echo "$out" | grep -q "regards Alice"; then
		_pass "email_send.py: field substitution works"
	else
		_fail "email_send.py: field substitution works" "out=${out:0:300}"
	fi
	rm -rf "$tmpdir"
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================

main() {
	echo "=== test-case-chase.sh ==="
	echo ""

	_test_helper_exists
	_test_email_send_exists
	_test_python_syntax
	_test_help_exits_zero
	_test_unknown_command_exits_nonzero
	_test_template_list
	_test_opt_in_gate_disabled
	_test_opt_in_gate_enabled
	_test_dry_run_no_smtp
	_test_missing_field_rejection
	_test_template_test_command
	_test_failure_records_error
	_test_credentials_not_logged
	_test_email_send_dry_run
	_test_email_send_field_substitution

	echo ""
	echo "=== Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed ==="

	if [[ $TESTS_FAILED -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
