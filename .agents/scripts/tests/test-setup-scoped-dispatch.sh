#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="${SCRIPT_DIR}/../../.."
SETUP_SH="${REPO_ROOT}/setup.sh"
AIDEVOPS_SH="${REPO_ROOT}/aidevops.sh"
RUNTIME_BUNDLE_VERIFIER="${REPO_ROOT}/.agents/scripts/runtime-bundle-verifier.sh"
POST_SETUP_MODULE="${REPO_ROOT}/.agents/scripts/setup/modules/post-setup.sh"
PACKAGE_JSON="${REPO_ROOT}/package.json"
GUI_WEB_PACKAGE_JSON="${REPO_ROOT}/packages/gui-web/package.json"

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '     %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_contains() {
	local test_name="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1 "missing: $needle"
	return 0
}

assert_occurrence_count() {
	local test_name="$1"
	local haystack="$2"
	local needle="$3"
	local expected_count="$4"
	python3 - "$test_name" "$haystack" "$needle" "$expected_count" <<'PY'
import sys

test_name, haystack, needle, expected_count = sys.argv[1:]
actual_count = haystack.count(needle)
if actual_count == int(expected_count):
    sys.exit(0)
print(f"{test_name}: expected {expected_count} occurrence(s), got {actual_count}")
sys.exit(1)
PY
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1 "occurrence count assertion failed"
	return 0
}

assert_not_contains() {
	local test_name="$1"
	local haystack="$2"
	local needle="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		print_result "$test_name" 0
		return 0
	fi
	print_result "$test_name" 1 "unexpected: $needle"
	return 0
}

file_text() {
	local path="$1"
	python3 - "$path" <<'PY'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).read_text())
PY
	return $?
}

test_setup_stage_contract() {
	local text=""
	local verifier_text=""
	local post_setup_text=""
	text="$(file_text "$SETUP_SH")" || {
		print_result "setup.sh is readable" 1 "$SETUP_SH"
		return 0
	}
	verifier_text="$(file_text "$RUNTIME_BUNDLE_VERIFIER")" || {
		print_result "runtime bundle verifier is readable" 1 "$RUNTIME_BUNDLE_VERIFIER"
		return 0
	}
	post_setup_text="$(file_text "$POST_SETUP_MODULE")" || {
		print_result "post-setup module is readable" 1 "$POST_SETUP_MODULE"
		return 0
	}

	assert_contains "setup.sh accepts --stage" "$text" "--stage <name>"
	assert_contains "opencode scope maps to setup_opencode_cli" "$text" "opencode | \"\$SETUP_STAGE_OPENCODE\") printf '%s' \"\$SETUP_STAGE_OPENCODE\""
	assert_contains "agents scope maps to deploy_aidevops_agents" "$text" "agents | \"\$SETUP_STAGE_AGENTS\") printf '%s' \"\$SETUP_STAGE_AGENTS\""
	assert_contains "runtime-config scope maps to reconciliation" "$text" "runtime-config | runtime | \"\$SETUP_STAGE_RUNTIME_CONFIG\") printf '%s' \"\$SETUP_STAGE_RUNTIME_CONFIG\""
	assert_contains "source-access scope maps to signed broker setup" "$text" "source-access | \"\$SETUP_STAGE_SOURCE_ACCESS\") printf '%s' \"\$SETUP_STAGE_SOURCE_ACCESS\""
	assert_contains "hooks scope maps to setup_safety_hooks" "$text" "hooks | \"\$SETUP_STAGE_HOOKS\") printf '%s' \"\$SETUP_STAGE_HOOKS\""
	assert_contains "tabby scope maps to setup_tabby" "$text" "tabby | \"\$SETUP_STAGE_TABBY\") printf '%s' \"\$SETUP_STAGE_TABBY\""
	assert_contains "pulse scope maps to setup_supervisor_pulse" "$text" "pulse | \"\$SETUP_STAGE_PULSE\") printf '%s' \"\$SETUP_STAGE_PULSE\""
	assert_occurrence_count "pulse scoped and full setup refresh merge scheduler" "$text" \
		'_time_step "setup_pulse_merge_routine"' 2
	assert_contains "gui-desktop scope maps to native app installer" "$text" "gui-desktop | gui | app | \"\$SETUP_STAGE_GUI_DESKTOP\") printf '%s' \"\$SETUP_STAGE_GUI_DESKTOP\""
	assert_contains "ai-session scope maps to incremental setup" "$text" "ai-session | ai | \"\$SETUP_STAGE_AI_SESSION\") printf '%s' \"\$SETUP_STAGE_AI_SESSION\""
	assert_contains "ai-session scoped stage falls back to full setup" "$text" "AI-session incremental setup unavailable or failed; falling back to full setup"
	# shellcheck disable=SC2016 # Match literal setup.sh expressions.
	assert_contains "ai-session accepts linked worktree git files" "$text" 'git -C "$checkout_root" rev-parse --git-dir'
	# shellcheck disable=SC2016 # Match literal setup.sh expressions.
	assert_contains "ai-session resolves linked worktree common git dir" "$text" 'git -C "$checkout_root" rev-parse --git-common-dir'
	assert_contains "ai-session verifies deployed sha" "$text" "_setup_ai_session_verify_deploy \"\$current_sha\""
	# shellcheck disable=SC2016 # Match literal setup.sh expressions.
	assert_occurrence_count "ai-session and setup paths reconcile Tabby automatically" "$text" \
		'_time_step "$SETUP_STAGE_TABBY" setup_tabby' 4
	# shellcheck disable=SC2016 # Match literal post-setup expressions.
	assert_contains "non-interactive Tabby setup runs transactional sync first" "$post_setup_text" \
		'if bash "$tabby_helper" sync >/dev/null 2>&1; then'
	# shellcheck disable=SC2016 # Match literal post-setup expressions.
	assert_contains "non-interactive Tabby setup applies shell repair after sync" "$post_setup_text" \
		'bash "$tabby_helper" fix-shell >/dev/null 2>&1 || true'
	assert_not_contains "non-interactive Tabby failure does not defer manual repair" "$post_setup_text" \
		'run manually: aidevops tabby sync'
	assert_contains "setup sources the authoritative runtime bundle verifier" "$text" '.agents/scripts/runtime-bundle-verifier.sh'
	assert_contains "ai-session delegates to the authoritative verifier" "$text" 'verify_aidevops_runtime_bundle_convergence'
	# shellcheck disable=SC2016 # Match literal verifier expressions.
	assert_contains "verifier checks active bundle manifest version" "$verifier_text" '_runtime_bundle_verify_manifest_value "$manifest_file" framework_version'
	# shellcheck disable=SC2016 # Match literal verifier expressions.
	assert_contains "verifier checks active bundle manifest sha" "$verifier_text" '_runtime_bundle_verify_manifest_value "$manifest_file" git_sha'
	assert_contains "verifier checks release sentinel hashes" "$verifier_text" '.agents/scripts/version-manager-release.sh|scripts/version-manager-release.sh'
	assert_contains "ai-session reconciles generated runtime config" "$text" "_time_step \"\$SETUP_STAGE_RUNTIME_CONFIG\" _setup_reconcile_runtime_config"
	assert_contains "runtime reconciliation updates enabled primary runtimes" "$text" "update_runtime_configs || return \$?"
	assert_contains "runtime reconciliation deploys commands to remaining runtimes" "$text" "deploy_commands_to_all_runtimes || return \$?"
	assert_contains "ai-session classifies lint provisioning changes" "$text" ".agents/scripts/repo-verify-config-lib.sh"
	assert_contains "ai-session reruns repo verify rollout" "$text" "_time_step \"setup_repo_verify_guard\" setup_repo_verify_guard"
	assert_contains "ai-session version prefix is split for release safety" "$text" 'version_prefix="# ""Version:"'
	assert_not_contains "ai-session version prefix is not a version-manager target" "$text" '"# Version: "*'
	assert_contains "gui desktop default path is opt-in gated" "$text" "_time_step \"setup_gui_desktop_app_opt_in\" _setup_offer_gui_desktop_app"
	assert_contains "gui desktop env flag enables install" "$text" "AIDEVOPS_GUI_DESKTOP_INSTALL"
	assert_contains "gui desktop app dir can be configured" "$text" "AIDEVOPS_GUI_DESKTOP_APP_DIR"
	assert_contains "existing gui desktop app refreshes during update" "$text" "Refreshing existing macOS"
	assert_contains "gui desktop scoped stage runs installer" "$text" "_time_step \"\$SETUP_STAGE_GUI_DESKTOP\" setup_gui_desktop_app"
	assert_contains "agents scoped stage registers both opencode runtime plugins" "$text" "_time_step \"\$SETUP_STAGE_OPENCODE_PLUGINS\" setup_opencode_runtime_plugins"
	assert_occurrence_count "scoped, ai-session, and noninteractive setup register both opencode runtime plugins" "$text" \
		"_time_step \"\$SETUP_STAGE_OPENCODE_PLUGINS\" setup_opencode_runtime_plugins" 3
	assert_contains "unknown stages print actionable help" "$text" "Unknown setup stage/scope"
	return 0
}

test_linked_worktree_checkout_contract() {
	local tmp_dir=""
	local source_repo=""
	local linked_worktree=""
	local helper_text=""
	tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-linked-checkout-test.XXXXXX") || {
		print_result "linked worktree fixture created" 1
		return 0
	}
	source_repo="$tmp_dir/repo"
	linked_worktree="$tmp_dir/linked"
	/usr/bin/git init -q "$source_repo" &&
		/usr/bin/git -C "$source_repo" config user.email "test@example.invalid" &&
		/usr/bin/git -C "$source_repo" config user.name "Test" &&
		/usr/bin/git -C "$source_repo" config commit.gpgsign false &&
		printf 'fixture\n' >"$source_repo/file" &&
		/usr/bin/git -C "$source_repo" add file &&
		/usr/bin/git -C "$source_repo" commit -qm fixture &&
		/usr/bin/git -C "$source_repo" worktree add -q -b linked-test "$linked_worktree" || {
		print_result "linked worktree fixture created" 1
		rm -rf "$tmp_dir"
		return 0
	}
	helper_text=$(
		python3 - "$SETUP_SH" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"(?ms)^_setup_git_checkout_available\(\) \{.*?^\}", text)
if not match:
    raise SystemExit(1)
print(match.group(0))
PY
	) || helper_text=""
	if [[ -n "$helper_text" ]]; then
		eval "$helper_text"
	fi
	if [[ -f "$linked_worktree/.git" ]] && declare -F _setup_git_checkout_available >/dev/null 2>&1 &&
		_setup_git_checkout_available "$linked_worktree"; then
		print_result "ai-session checkout detection accepts linked worktree .git files" 0
	else
		print_result "ai-session checkout detection accepts linked worktree .git files" 1
	fi
	rm -rf "$tmp_dir"
	return 0
}

test_shellcheck_wrapper_preserves_executable() {
	# Extend the existing isolated setup fixture without touching the host store.
	python3 - "$REPO_ROOT" <<'PY'
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1]).resolve()
# PATH may already contain the aidevops wrapper: prefer a declared real path
# or a legacy .real executable before copying the candidate.
candidates = [os.environ.get("SHELLCHECK_REAL_PATH"), shutil.which("shellcheck.real"),
              shutil.which("shellcheck.real", path=os.defpath),
              shutil.which("shellcheck", path=os.defpath), shutil.which("shellcheck")]
native = next((p for p in candidates if p and pathlib.Path(p).read_bytes()[:2] != b"#!"), None)
if not native:
    raise SystemExit("Native ShellCheck is required for the setup wrapper fixture")
modules = root / ".agents/scripts/setup/modules"
setup = (root / "setup.sh").read_text()
assert setup.index('source "${SETUP_IMPL_MODULES_DIR}/shell-env.sh"') < setup.index(
    'source "${SETUP_IMPL_MODULES_DIR}/tool-install.sh"'
)
assert "setup_shellcheck_wrapper()" not in (modules / "tool-install-discovery.sh").read_text()
script = r'''
set -euo pipefail
print_info() { printf '%s\n' "$*"; return 0; }
print_success() { printf '%s\n' "$*"; return 0; }
print_warning() { printf '%s\n' "$*"; return 0; }
record_mutation() { printf '%s\n' "$*" >>"$MUTATION_LOG"; return 0; }
# Block mutations as well as recording them: a regressed setup must never
# reach the host Nix store, even with our simulated absolute resolution.
mv() { record_mutation "mv $*"; return 1; }
cp() { record_mutation "cp $*"; return 1; }
chmod() { record_mutation "chmod $*"; return 1; }
sudo() { record_mutation "sudo $*"; return 1; }
realpath() {
    local target="$1"
    if [[ "$FIXTURE_KIND" == nix && "$target" == "$FIXTURE_BIN/shellcheck" ]]; then
        printf '%s\n' /nix/store/fixture-shellcheck/bin/shellcheck
        return 0
    fi
    command realpath "$target"
    return 0
}
source "$MODULES/shell-env.sh"
source "$MODULES/tool-install.sh"
setup_shellcheck_wrapper
[[ "$(command -v shellcheck)" == "$HOME/.aidevops/bin/shellcheck" ]]
shellcheck --version
bash -x "$SHELLCHECK_PATH" --version
# Idempotency with the shim already first on PATH must not recurse.
setup_shellcheck_wrapper
shellcheck --version
'''
temp_parent = pathlib.Path(os.environ.get("AIDEVOPS_TEMP_DIR", pathlib.Path.home() / ".aidevops/.agent-workspace/tmp"))
temp_parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="setup-shellcheck-", dir=temp_parent) as temp:
    base = pathlib.Path(temp)
    for kind in ("nix", "user", "legacy"):
        case = base / kind
        home = case / "home"
        deployed = home / ".aidevops/agents/scripts/shellcheck-wrapper.sh"
        deployed.parent.mkdir(parents=True)
        shutil.copy2(root / ".agents/scripts/shellcheck-wrapper.sh", deployed)
        bindir = case / "nix/store/fixture-shellcheck/bin" if kind == "nix" else home / ".local/bin"
        bindir.mkdir(parents=True)
        executable = bindir / "shellcheck"
        shutil.copy2(native, executable)
        if kind == "legacy":
            executable.rename(bindir / "shellcheck.real")
            shutil.copy2(deployed, executable)
        before = {p: (p.read_bytes(), p.stat().st_mode) for p in bindir.iterdir()}
        log = case / "mutations"
        log.touch()
        env = os.environ.copy()
        # Inherited overrides must not hide the simulated PATH executable.
        for key in ("SHELLCHECK_REAL_PATH", "SHELLCHECK_PATH", "_SHELLCHECK_WRAPPER_ACTIVE"):
            env.pop(key, None)
        env.update(HOME=str(home), PATH=f"{bindir}:/usr/bin:/bin", PLATFORM_MACOS="false",
                   MODULES=str(modules), INSTALL_DIR=str(root), FIXTURE_KIND=kind,
                   FIXTURE_BIN=str(bindir), MUTATION_LOG=str(log), SHELL="/bin/bash")
        # Explicit forwarding isolates the fixture from host .real installs,
        # which the production wrapper intentionally searches before PATH.
        forwarded = bindir / "shellcheck.real" if kind == "legacy" else executable
        env["SHELLCHECK_REAL_PATH"] = str(forwarded)
        result = subprocess.run(["bash", "-c", script], env=env, text=True, capture_output=True)
        assert result.returncode == 0, f"{kind}: {result.stdout}\n{result.stderr}"
        after = {p: (p.read_bytes(), p.stat().st_mode) for p in bindir.iterdir()}
        assert before == after, f"{kind}: original executable changed"
        mutations = log.read_text()
        assert str(bindir) not in mutations and "/nix/store/" not in mutations, mutations
        assert "sudo" not in mutations and "sudo" not in result.stdout, result.stdout
        assert "Absolute-path ShellCheck callers bypass the shim" in result.stdout
        assert result.stdout.count("ShellCheck - shell script analysis tool") == 3
        assert f"+ {forwarded} --version" in result.stderr, "wrapper bypassed fixture executable"
        assert (home / ".aidevops/bin/shellcheck").resolve() == deployed
        print(f"verified {kind}: original preserved, shim forwards, repeated setup works")
PY
	local rc=$?
	print_result "ShellCheck setup preserves Nix, user-local and legacy executables" "$rc"
	return 0
}

test_setup_version_substitution_keeps_syntax() {
	local tmp_dir=""
	tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-setup-version-test.XXXXXX") || {
		print_result "version substitution temp dir created" 1
		return 0
	}
	cp "$SETUP_SH" "$tmp_dir/setup.sh" || {
		print_result "version substitution fixture copied" 1
		rm -rf "$tmp_dir"
		return 0
	}
	python3 - "$tmp_dir/setup.sh" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
path.write_text(re.sub(r"# Version: .*", "# Version: 9.9.9", text))
PY
	if bash -n "$tmp_dir/setup.sh"; then
		print_result "version substitution keeps setup.sh syntactically valid" 0
	else
		print_result "version substitution keeps setup.sh syntactically valid" 1
	fi
	rm -rf "$tmp_dir"
	return 0
}

test_cli_scope_contract() {
	local text=""
	text="$(file_text "$AIDEVOPS_SH")" || {
		print_result "aidevops.sh is readable" 1 "$AIDEVOPS_SH"
		return 0
	}

	assert_contains "aidevops exposes setup command" "$text" "setup) cmd_setup \"\$@\" ;;"
	assert_contains "aidevops setup requires scope" "$text" "Usage: aidevops setup --scope <scope>"
	assert_contains "aidevops setup lists gui-desktop scope" "$text" "gui-desktop  Install native macOS aidevops.app only"
	assert_contains "aidevops setup lists ai-session scope" "$text" "ai-session  Apply changed deploy stages; fall back to full setup if needed"
	assert_contains "aidevops setup lists runtime-config scope" "$text" "runtime-config  Reconcile generated runtime commands/configuration"
	assert_contains "aidevops setup lists source-access scope" "$text" "source-access  Install/verify the signed root approval broker"
	assert_contains "aidevops setup passes scope to setup.sh" "$text" "bash \"\$setup_script\" --stage \"\$scope\""
	assert_contains "aidevops setup full preserves full setup" "$text" "bash \"\$setup_script\" --non-interactive"
	return 0
}

test_gui_desktop_package_contract() {
	local text=""
	text="$(file_text "$PACKAGE_JSON")" || {
		print_result "package.json is readable" 1 "$PACKAGE_JSON"
		return 0
	}

	assert_contains "npm package includes Bun lockfile" "$text" '"bun.lock"'
	assert_contains "npm package includes README metric badges" "$text" '"docs/metrics/"'
	assert_contains "npm package includes GUI shared sources" "$text" '"packages/gui-shared/src/"'
	assert_contains "npm package includes GUI API sources" "$text" '"packages/gui-api/src/"'
	assert_contains "npm package includes GUI web sources" "$text" '"packages/gui-web/src/"'
	assert_contains "npm package includes GUI web config" "$text" '"packages/gui-web/vite.config.ts"'
	assert_contains "npm package includes GUI desktop installer" "$text" '"packages/gui-desktop/scripts/"'
	return 0
}

test_gui_desktop_installer_contract() {
	local installer="${REPO_ROOT}/packages/gui-desktop/scripts/install-macos-app.sh"
	local text=""
	text="$(file_text "$installer")" || {
		print_result "GUI desktop installer is readable" 1 "$installer"
		return 0
	}

	assert_contains "installer honours configured app dir env" "$text" 'AIDEVOPS_GUI_DESKTOP_APP_DIR'
	assert_contains "installer keeps explicit app-dir override" "$text" '--app-dir'
	assert_contains "installer dependency check includes new Zilla Slab font package" "$text" 'node_modules/@fontsource/zilla-slab'
	python3 - "$installer" "$GUI_WEB_PACKAGE_JSON" <<'PY'
import json
import pathlib
import re
import sys

installer_path = pathlib.Path(sys.argv[1])
package_path = pathlib.Path(sys.argv[2])
installer_text = installer_path.read_text()
package_json = json.loads(package_path.read_text())
expected = sorted(
    f"node_modules/{name}"
    for name in (package_json.get("dependencies") or {})
    if name.startswith("@fontsource/")
)
actual = sorted(set(re.findall(r"node_modules/@fontsource/[a-z0-9_.-]+", installer_text)))
if actual == expected:
    sys.exit(0)
print("expected font dependencies:", ", ".join(expected), file=sys.stderr)
print("installer font dependencies:", ", ".join(actual), file=sys.stderr)
sys.exit(1)
PY
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "installer font dependency checks match GUI web package" 0
		return 0
	fi
	print_result "installer font dependency checks match GUI web package" 1 "packages/gui-desktop/scripts/install-macos-app.sh is out of sync with packages/gui-web/package.json"
	return 0
}

main() {
	test_setup_stage_contract
	test_linked_worktree_checkout_contract
	test_shellcheck_wrapper_preserves_executable
	test_setup_version_substitution_keeps_syntax
	test_cli_scope_contract
	test_gui_desktop_package_contract
	test_gui_desktop_installer_contract

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
