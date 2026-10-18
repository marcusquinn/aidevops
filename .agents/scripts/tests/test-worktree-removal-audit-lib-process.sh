#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Process-CWD visibility, platform policy, and bounded inspector regressions.
# Source from test-worktree-removal-audit-lib.sh after the shared test framework.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_TEST_WORKTREE_REMOVAL_AUDIT_PROCESS_LOADED:-}" ]] && return 0
_TEST_WORKTREE_REMOVAL_AUDIT_PROCESS_LOADED=1

# =============================================================================
# Test 11: process-cwd helper refuses empty paths before glob-like matching
# =============================================================================
test_process_cwd_guard_refuses_empty_paths() {
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	local rc=0
	if _worktree_has_process_cwd "" "/tmp/example"; then
		rc=1
	fi
	if _worktree_has_process_cwd "/tmp/example" ""; then
		rc=1
	fi
	print_result "process_cwd_guard_refuses_empty_paths" "$rc" \
		"Expected empty path inputs to return non-match"
	return 0
}

# =============================================================================
# Test 12: snapshot collection failures block removal, while an explicitly
# supplied empty successful snapshot avoids a second platform scan.
# =============================================================================
test_process_cwd_snapshot_failure_is_fail_closed() {
	local log_file="${TEST_DIR}/t12-cleanup.log"
	local wt_path="${TEST_DIR}/snapshot-failure-wt"
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"

	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"
	capture_worktree_process_cwds() { return 1; }
	if worktree_removal_guard "$wt_path" "test.sh" "manual"; then
		rc=1
	fi
	assert_file_contains "$log_file" "worktree-skipped.*cwd-visibility-unusable" || rc=1
	if ! worktree_removal_guard "$wt_path" "test.sh" "manual" ""; then
		rc=1
	fi
	print_result "process_cwd_snapshot_failure_is_fail_closed" "$rc" \
		"Expected collection failure to block and explicit empty snapshot to pass"
	return 0
}

# =============================================================================
# Test 13: each platform backend fails closed when it cannot publish any cwd
# target instead of treating an empty snapshot as authoritative.
# =============================================================================
test_snapshot_backend_requires_visible_target() {
	local rc=0
	unset _AUDIT_WORKTREE_REMOVAL_HELPER_LOADED 2>/dev/null || true
	# shellcheck source=../audit-worktree-removal-helper.sh
	source "$AUDIT_HELPER"

	if [[ -d /proc ]]; then
		if (
			readlink() { return 1; }
			capture_worktree_process_cwds >/dev/null
		); then
			rc=1
		fi
	else
		if (
			lsof() { return 0; }
			capture_worktree_process_cwds >/dev/null
		); then
			rc=1
		fi
	fi
	print_result "snapshot_backend_requires_visible_target" "$rc" \
		"Expected an empty process-cwd backend result to fail closed"
	return 0
}

# =============================================================================
# The macOS lsof backend distinguishes complete output, partial/permission-
# limited output, and empty unusable output. Absence-only output never proves a
# candidate inactive.
# =============================================================================
test_lsof_snapshot_visibility_states() {
	local output=""
	local capture_status=0
	local rc=0

	if output=$(
		lsof() { return 0; }
		_capture_worktree_lsof_cwds
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq 1 && -z "$output" ]] || rc=1

	if output=$(
		lsof() {
			printf 'p123\nn/visible-lsof-cwd\n'
			return 1
		}
		_capture_worktree_lsof_cwds
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "$output" == "/visible-lsof-cwd" ]] || rc=1

	if output=$(
		lsof() {
			printf 'p123\nn/complete-lsof-cwd\n'
			return 0
		}
		_capture_worktree_lsof_cwds
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq 0 && "$output" == "/complete-lsof-cwd" ]] || rc=1
	print_result "lsof_snapshot_visibility_states" "$rc" \
		"Expected empty lsof to be unusable and partial lsof output to be degraded"
	return 0
}

# =============================================================================
# Test 14: a partially visible /proc snapshot preserves readable evidence and
# reports degraded visibility instead of aliasing it to a total failure.
# =============================================================================
test_proc_snapshot_preserves_degraded_visibility() {
	local proc_root="${TEST_DIR}/fake-proc"
	local output=""
	local capture_status=0
	local rc=0
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /hidden-cwd "${proc_root}/2/cwd"

	if output=$(
		readlink() {
			local link_path="$1"
			if [[ "$link_path" == */1/cwd ]]; then
				printf '/visible-cwd\n'
				return 0
			fi
			return 1
		}
		_capture_worktree_proc_cwds "$proc_root"
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_preserves_degraded_visibility" "$rc" \
		"Expected unreadable unknown ownership to preserve visible cwd evidence with degraded status"
	return 0
}

# =============================================================================
# Linux /proc entries that are unreadable but provably foreign do not invalidate
# otherwise usable evidence.
# =============================================================================
test_proc_snapshot_skips_foreign_uid_unreadable_entry() {
	local proc_root="${TEST_DIR}/fake-proc-foreign"
	local current_uid=""
	local foreign_uid=""
	local output=""
	local rc=0
	current_uid=$(id -u)
	foreign_uid=$((current_uid + 1))
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /foreign-cwd "${proc_root}/2/cwd"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' \
		"$foreign_uid" "$foreign_uid" "$foreign_uid" "$foreign_uid" >"${proc_root}/2/status"

	output=$(
		readlink() {
			local link_path="$1"
			[[ "$link_path" == */1/cwd ]] || return 1
			printf '/visible-cwd\n'
			return 0
		}
		_capture_worktree_proc_cwds "$proc_root"
	) || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_skips_foreign_uid_unreadable_entry" "$rc" \
		"Expected foreign unreadable cwd to be skipped without hiding visible evidence"
	return 0
}

# =============================================================================
# hidepid-style /proc mounts can deny both cwd and status reads for other users.
# Directory ownership still proves those entries are foreign, so they must not
# degrade the whole snapshot and force recoverable archival for every cleanup.
# =============================================================================
test_proc_snapshot_skips_foreign_uid_when_status_unreadable() {
	local proc_root="${TEST_DIR}/fake-proc-foreign-owner"
	local current_uid=""
	local foreign_uid=""
	local output=""
	local rc=0
	current_uid=$(id -u)
	foreign_uid=$((current_uid + 1))
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /foreign-cwd "${proc_root}/2/cwd"

	output=$(
		readlink() {
			local link_path="$1"
			[[ "$link_path" == */1/cwd ]] || return 1
			printf '/visible-cwd\n'
			return 0
		}
		_worktree_proc_entry_owner_uid() {
			local proc_dir="$1"
			if [[ "${proc_dir##*/}" == "2" ]]; then
				printf '%s\n' "$foreign_uid"
			else
				printf '%s\n' "$current_uid"
			fi
			return 0
		}
		_capture_worktree_proc_cwds "$proc_root"
	) || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_skips_foreign_uid_when_status_unreadable" "$rc" \
		"Expected hidepid-style foreign /proc entries to be skipped without degraded visibility"
	return 0
}

# =============================================================================
# Same-UID unreadability is explicitly degraded while preserving readable cwd
# evidence for candidate-specific positive matching.
# =============================================================================
test_proc_snapshot_marks_same_uid_unreadable_entry_degraded() {
	local proc_root="${TEST_DIR}/fake-proc-same-uid"
	local current_uid=""
	local output=""
	local capture_status=0
	local rc=0
	current_uid=$(id -u)
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /same-user-cwd "${proc_root}/2/cwd"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' \
		"$current_uid" "$current_uid" "$current_uid" "$current_uid" >"${proc_root}/2/status"

	if output=$(
		readlink() {
			local link_path="$1"
			[[ "$link_path" == */1/cwd ]] || return 1
			printf '/visible-cwd\n'
			return 0
		}
		_capture_worktree_proc_cwds "$proc_root"
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_marks_same_uid_unreadable_entry_degraded" "$rc" \
		"Expected simulated same-UID EACCES to return degraded status with visible evidence intact"
	return 0
}

# A protected same-UID process is usable only when the optional read-only
# inspector returns its actual absolute CWD. The fixture never calls sudo.
test_proc_snapshot_recovers_protected_same_uid_cwd() {
	local proc_root="${TEST_DIR}/fake-proc-inspected"
	local current_uid=""
	local output=""
	local rc=0
	current_uid=$(id -u)
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /protected-cwd "${proc_root}/2/cwd"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' \
		"$current_uid" "$current_uid" "$current_uid" "$current_uid" >"${proc_root}/2/status"

	output=$(
		readlink() {
			[[ "$1" == */1/cwd ]] || return 1
			printf '/visible-cwd\n'
		}
		_worktree_privileged_read_cwd() {
			[[ "$1" == "$proc_root" && "$2" == "${proc_root}/2" ]] || return 1
			printf '/protected-cwd\n'
		}
		_capture_worktree_proc_cwds "$proc_root"
	) || rc=1
	[[ "$output" == $'/visible-cwd\n/protected-cwd' ]] || rc=1
	_worktree_cwd_snapshot_contains_path /protected-cwd /protected-cwd "$output" || rc=1
	print_result "proc_snapshot_recovers_protected_same_uid_cwd" "$rc" \
		"Expected inspected CWD to be captured and eligible for active-path blocking"
	return 0
}

test_privileged_inspector_rejects_untrusted_proc_root() {
	local output=""
	local rc=0
	if output=$(
		sudo() {
			printf '/should-not-be-used\n'
			return 0
		}
		_worktree_privileged_read_cwd "${TEST_DIR}/fake-proc" "${TEST_DIR}/fake-proc/2"
	); then
		rc=1
	fi
	[[ -z "$output" ]] || rc=1
	print_result "privileged_inspector_rejects_untrusted_proc_root" "$rc" \
		"Expected non-system proc roots to fail before invoking sudo"
	return 0
}

test_privileged_inspector_uses_bounded_execution() {
	local output=""
	local rc=0
	output=$(
		worktree_process_platform() {
			printf '%s\n' Linux
			return 0
		}
		timeout_sec() {
			[[ "$1" == "5" && "$2" == "sudo" && "$3" == "-n" && "$4" == "--" ]] || return 1
			[[ "$5" == "/usr/local/libexec/aidevops-worktree-cwd-inspect" && "$6" == "2" ]] || return 1
			printf '/bounded-cwd\n'
		}
		_worktree_privileged_read_cwd /proc /proc/2
	) || rc=1
	[[ "$output" == "/bounded-cwd" ]] || rc=1
	print_result "privileged_inspector_uses_bounded_execution" "$rc" \
		"Expected the privileged inspector to use the shared five-second timeout"
	return 0
}

# Platform detection reads data, not executable shell, and never enables removal.
test_process_platform_policy() {
	local release_file="${TEST_DIR}/os-release"
	local id_value=""
	local rc=0
	for id_value in nixos '"nixos"' "'nixos'"; do
		printf 'ID=%s\n' "$id_value" >"$release_file"
		[[ "$(worktree_process_platform Linux "$release_file")" == nixos ]] || rc=1
	done
	[[ "$(worktree_process_platform Darwin "$release_file")" == Darwin ]] || rc=1
	printf 'ID=ubuntu\nID_LIKE=nixos\n' >"$release_file"
	[[ "$(worktree_process_platform Linux "$release_file")" == Linux ]] || rc=1
	[[ "$(worktree_process_platform Linux "${TEST_DIR}/missing-release")" == Linux ]] || rc=1
	printf '%s\n' "ID=\$(exit 99)" >"$release_file"
	[[ "$(worktree_process_platform Linux "$release_file")" == Linux ]] || rc=1
	worktree_process_inspector_allowed nixos && rc=1
	worktree_process_inspector_allowed Linux || rc=1
	worktree_process_inspector_allowed Darwin || rc=1
	print_result "process_platform_policy" "$rc" "Expected exact NixOS detection with unchanged legacy policy"
	return 0
}

test_unprivileged_proc_collector() {
	local rc=0
	python3 - "$SCRIPT_DIR/.." "$TEST_DIR" <<'PY' || rc=1
import contextlib
import io
import os
from pathlib import Path
import sys
from unittest.mock import patch

sys.path.insert(0, sys.argv[1])
import worktree_process_proc as provider

root = Path(sys.argv[2]) / 'portable-proc'
root.mkdir()
uid = os.getuid()
for pid, identities, state in (
    ('1', [uid] * 4, 'S'),
    ('2', [uid] * 4, 'S'),
    ('3', [uid + 1] * 4, 'S'),
    ('4', [uid + 1, uid, uid + 1, uid + 1], 'S'),
    ('5', [uid] * 4, 'Z'),
    ('6', [], 'S'),
    ('7', [uid] * 4, 'S'),
):
    process = root / pid
    process.mkdir()
    (process / 'status').write_text(f'State:\t{state}\nUid:\t' + ' '.join(map(str, identities)))
    (process / 'cwd').symlink_to('/visible' if pid != '7' else '/invalid\npath')
    (process / 'comm').write_text('sshd-session\n')
real_readlink = os.readlink

def readlink(path):
    if Path(path).parent.name not in ('1', '7'):
        raise PermissionError('fixture denial')
    return real_readlink(path)

with patch.object(provider.os, 'readlink', readlink):
    paths, denied = provider.collect(root)
assert paths == ['/visible']
assert {p.name for p in denied} == {'2', '4', '6', '7'}
assert provider.denied_process_is_irrelevant(root / 'vanished', uid)
for snapshot, expected in ((paths, 0), ([], 1)):
    with patch.object(provider, 'collect', return_value=(snapshot, [])), contextlib.redirect_stdout(io.StringIO()):
        assert provider.main(['paths']) == expected
with patch.object(provider, 'collect', return_value=(paths, denied)), contextlib.redirect_stdout(io.StringIO()):
    assert provider.main(['paths']) == 2
    assert provider.main(['denied']) == 0
with patch.object(provider, 'collect', side_effect=PermissionError()):
    assert provider.main(['paths']) == 1
assert provider.main(['invalid']) == 1
PY
	print_result "unprivileged_proc_collector" "$rc" "Expected portable fail-closed process evidence without subprocesses"
	return 0
}

test_nixos_process_inspector_never_escalates() {
	local output=""
	local rc=0
	if output=$(
		worktree_process_platform() {
			printf '%s\n' nixos
			return 0
		}
		timeout_sec() {
			printf '%s\n' unexpected-escalation
			return 0
		}
		_worktree_privileged_read_cwd /proc /proc/2
	); then
		rc=1
	fi
	[[ -z "$output" ]] || rc=1
	print_result "nixos_process_inspector_never_escalates" "$rc" "Expected refusal before invoking the privileged adapter"
	return 0
}

# GH#32871: the installed inspector accepts same-user setuid-root helpers
# (real UID = caller; other UIDs caller or root) and refuses other identities.
test_privileged_inspector_uid_rule() {
	local rc=0
	python3 - "${SCRIPT_DIR}/../worktree-cwd-inspect.py" <<'PY' || rc=1
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("inspector", sys.argv[1])
inspector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inspector)
accept = inspector.uid_fields_accepted
cases = [
    (["1000", "1000", "1000", "1000"], 1000, True),
    (["1000", "0", "0", "0"], 1000, True),
    (["1000", "0", "0", "1000"], 1000, True),
    (["1000", "1001", "1001", "1001"], 1000, False),
    (["0", "1000", "1000", "1000"], 1000, False),
    (["0", "0", "0", "0"], 1000, False),
    (["1000", "1000", "1000", "1001"], 1000, False),
    (["1000", "0", "0"], 1000, False),
    (["1000", "x", "0", "0"], 1000, False),
    (["0", "0", "0", "0"], 0, False),
]
failed = [case for case in cases if accept(case[0], case[1]) is not case[2]]
if failed:
    print(f"  unexpected UID decisions: {failed}")
    raise SystemExit(1)
PY
	print_result "privileged_inspector_uid_rule" "$rc" \
		"Expected same-user setuid-root processes to be accepted and other identities refused"
	return 0
}

test_proc_snapshot_rejects_failed_inspector_output() {
	local proc_root="${TEST_DIR}/fake-proc-failed-inspector"
	local current_uid=""
	local output=""
	local capture_status=0
	local rc=0
	current_uid=$(id -u)
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /untrusted-cwd "${proc_root}/2/cwd"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' \
		"$current_uid" "$current_uid" "$current_uid" "$current_uid" >"${proc_root}/2/status"

	if output=$(
		readlink() {
			[[ "$1" == */1/cwd ]] || return 1
			printf '/visible-cwd\n'
		}
		_worktree_privileged_read_cwd() {
			printf '/untrusted-cwd\n'
			return 1
		}
		_capture_worktree_proc_cwds "$proc_root"
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_rejects_failed_inspector_output" "$rc" \
		"Expected plausible output from a failed inspector to stay hidden and fail closed"
	return 0
}

# =============================================================================
# Zombies have no live execution context or working directory. Their cwd link
# can remain present while readlink returns ENOENT, so they are safe to skip.
# =============================================================================
test_proc_snapshot_skips_zombie_cwd_denial() {
	local proc_root="${TEST_DIR}/fake-proc-zombie"
	local current_uid=""
	local output=""
	local rc=0
	current_uid=$(id -u)
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /zombie-cwd "${proc_root}/2/cwd"
	printf 'State:\tZ (zombie)\nUid:\t%s\t%s\t%s\t%s\n' \
		"$current_uid" "$current_uid" "$current_uid" "$current_uid" >"${proc_root}/2/status"

	output=$(
		readlink() {
			local link_path="$1"
			[[ "$link_path" == */1/cwd ]] || return 1
			printf '/visible-cwd\n'
			return 0
		}
		_capture_worktree_proc_cwds "$proc_root"
	) || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_skips_zombie_cwd_denial" "$rc" \
		"Expected a proven zombie process to be skipped without degrading visible CWD evidence"
	return 0
}

# =============================================================================
# Same-UID daemon metadata cannot prove that a process is unrelated to a
# candidate worktree. An unreadable daemon cwd therefore remains degraded.
# =============================================================================
test_proc_snapshot_marks_same_uid_daemon_denial_degraded() {
	local proc_root="${TEST_DIR}/fake-proc-same-uid-daemon"
	local current_uid=""
	local output=""
	local capture_status=0
	local rc=0
	current_uid=$(id -u)
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /daemon-hidden-cwd "${proc_root}/2/cwd"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' \
		"$current_uid" "$current_uid" "$current_uid" "$current_uid" >"${proc_root}/2/status"
	printf 'gpg-agent\n' >"${proc_root}/2/comm"

	if output=$(
		readlink() {
			local link_path="$1"
			[[ "$link_path" == */1/cwd ]] || return 1
			printf '/visible-cwd\n'
			return 0
		}
		_capture_worktree_proc_cwds "$proc_root"
	); then
		capture_status=0
	else
		capture_status=$?
	fi
	[[ "$capture_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_marks_same_uid_daemon_denial_degraded" "$rc" \
		"Expected same-UID daemon metadata to remain insufficient deletion evidence"
	return 0
}

# =============================================================================
# Degraded visibility is candidate-specific: unrelated readable CWDs require a
# recoverable path, while any readable target inside the candidate hard-blocks.
# =============================================================================
test_degraded_visibility_preserves_positive_candidate_match() {
	local log_file="${TEST_DIR}/degraded-candidate-cleanup.log"
	local wt_path="${TEST_DIR}/degraded-candidate"
	local guard_status=0
	local rc=0
	export AIDEVOPS_CLEANUP_LOG="$log_file"
	mkdir -p "$wt_path"

	if worktree_removal_guard "$wt_path" "test.sh" "manual" "/unrelated-readable-cwd" \
		"$_WT_CWD_VISIBILITY_DEGRADED"; then
		guard_status=0
	else
		guard_status=$?
	fi
	[[ "$guard_status" -eq "$_WT_CWD_CAPTURE_DEGRADED_RC" ]] || rc=1
	[[ "${WORKTREE_REMOVAL_GUARD_REASON:-}" == "$_WT_CWD_REASON_DEGRADED" ]] || rc=1

	if worktree_removal_guard "$wt_path" "test.sh" "manual" "$wt_path/active-shell" \
		"$_WT_CWD_VISIBILITY_DEGRADED"; then
		guard_status=0
	else
		guard_status=$?
	fi
	[[ "$guard_status" -eq 1 ]] || rc=1
	[[ "${WORKTREE_REMOVAL_GUARD_REASON:-}" == "active-cwd" ]] || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*cwd-visibility-degraded.*mode=recoverable-required" || rc=1
	assert_file_contains "$log_file" "worktree-skipped.*active-cwd.*mode=skipped" || rc=1
	print_result "degraded_visibility_preserves_positive_candidate_match" "$rc" \
		"Expected unrelated denial to be recoverable-only and readable candidate CWD to hard-block"
	return 0
}

# =============================================================================
# Foreign skips alone are not usable evidence: an empty snapshot still blocks
# destructive cleanup.
# =============================================================================
test_proc_snapshot_requires_usable_evidence_after_foreign_skips() {
	local proc_root="${TEST_DIR}/fake-proc-foreign-only"
	local current_uid=""
	local foreign_uid=""
	local rc=0
	current_uid=$(id -u)
	foreign_uid=$((current_uid + 1))
	mkdir -p "${proc_root}/1"
	ln -s /foreign-cwd "${proc_root}/1/cwd"
	printf 'Uid:\t%s\t%s\t%s\t%s\n' \
		"$foreign_uid" "$foreign_uid" "$foreign_uid" "$foreign_uid" >"${proc_root}/1/status"

	if (
		readlink() { return 1; }
		_capture_worktree_proc_cwds "$proc_root" >/dev/null
	); then
		rc=1
	fi
	print_result "proc_snapshot_requires_usable_evidence_after_foreign_skips" "$rc" \
		"Expected zero captured cwd targets to remain fail-closed"
	return 0
}

# =============================================================================
# A process that vanishes during readlink is ignored when other usable evidence
# remains in the snapshot.
# =============================================================================
test_proc_snapshot_ignores_vanished_entry() {
	local proc_root="${TEST_DIR}/fake-proc-vanished"
	local output=""
	local rc=0
	mkdir -p "${proc_root}/1" "${proc_root}/2"
	ln -s /visible-cwd "${proc_root}/1/cwd"
	ln -s /vanished-cwd "${proc_root}/2/cwd"

	output=$(
		readlink() {
			local link_path="$1"
			if [[ "$link_path" == */1/cwd ]]; then
				printf '/visible-cwd\n'
				return 0
			fi
			rm -f "$link_path"
			return 1
		}
		_capture_worktree_proc_cwds "$proc_root"
	) || rc=1
	[[ "$output" == "/visible-cwd" ]] || rc=1
	print_result "proc_snapshot_ignores_vanished_entry" "$rc" \
		"Expected a vanished process to be ignored without losing visible evidence"
	return 0
}
