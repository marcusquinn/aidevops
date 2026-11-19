#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# opencode-runtime-switch-helper.sh — show which OpenCode major the global
# `opencode` command runs, and switch an unintended global OpenCode 2 back to
# the stable OpenCode 1 that aidevops supports by default (GH#39282).
#
# OpenCode 1 cannot read an OpenCode 2 database (different schema in the same
# opencode.db), so every data folder holding OpenCode 2 tables is renamed to a
# timestamped backup: the default one and aidevops per-project isolated ones.
# Nothing is deleted; each run writes a ready-to-run undo script. The full
# setup run afterwards reconciles config keys, the stable shim, plugin
# registration and the managed service.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

PROFILE_HELPER="${SCRIPT_DIR}/opencode-runtime-profile.py"
SERVICE_HELPER="${SCRIPT_DIR}/opencode-service-helper.py"
SERVICE_CONFIG="${HOME}/.config/aidevops/opencode-service.json"
WORK_DIR="${AIDEVOPS_WORK_DIR:-${HOME}/.aidevops/.agent-workspace/work}"
CONFIG_DIR="${HOME}/.config/opencode"
# The PID keeps recovery paths unique even for two runs in the same second.
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
SWITCH_BACKUP_SUFFIX=".v2-backup-${STAMP}"
SWITCH_STATE_DIR="${HOME}/.aidevops/opencode-use-stable"
SWITCH_LOCK_DIR="${SWITCH_STATE_DIR}/.lock"
UNDO_SCRIPT="${SWITCH_STATE_DIR}/undo-${STAMP}.sh"
USE_STABLE_CMD="aidevops opencode-runtime use-stable"

# An aidevops-launched session points XDG_DATA_HOME at a per-project folder;
# the shared default is still ~/.local/share/opencode.
if [[ -n "${AIDEVOPS_OPENCODE_ISOLATED_DB:-}" ]]; then
	DATA_DIR="${HOME}/.local/share/opencode"
else
	DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/opencode"
fi

# State filled by _load_state.
GLOBAL_PATH=""
GLOBAL_OWNER=""
GLOBAL_PACKAGE=""
GLOBAL_PROFILE=""
GLOBAL_VERSION=""
GLOBAL_SEMVER=""
# Data folders to move aside, one per line; filled by _collect_backup_targets.
BACKUP_TARGETS=""
# Progress recorded by use-stable for the failure report and undo script.
DONE_STEPS=""
UNDO_LINES=""
MOVED_COUNT=0
V2_REMOVED=0
PLAN_STEP=0
INTERRUPTED=0

_usage() {
	cat <<EOF
Usage: aidevops opencode-runtime <command>

Commands:
  status                  Show the global opencode version, profile and installer
  use-stable [--yes] [--dry-run]
                          Switch a global OpenCode 2 back to stable OpenCode 1.
                          Moves OpenCode 2 data folders to timestamped backups,
                          removes OpenCode 2 through the channel that installed it,
                          installs the tested OpenCode 1 release and runs setup.
                          Writes an undo script; nothing is deleted.

OpenCode 1 is the stable aidevops default. OpenCode 2 is an optional preview
available as 'opencode2'. Run use-stable from a plain terminal with OpenCode closed.
EOF
	return 0
}

_profile_helper() {
	python3 "$PROFILE_HELPER" "$@" 2>/dev/null
	return $?
}

_realpath() {
	local path="$1"
	python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null || printf '%s\n' "$path"
	return 0
}

# Resolve the global `opencode` through aidevops shims; print "owner<TAB>path".
_resolve_global() {
	local payload=""
	payload=$(aidevops_opencode_owner_payload v1) || return 1
	# shellcheck disable=SC2016  # Single quotes intentional: bash -c payload
	bash -c "${payload}"'printf "%s\t%s\n" "$r_owner" "$r"'
	return $?
}

# npm/bun package that owns a resolved binary path, from its node_modules path.
_package_for_path() {
	local real="$1"
	case "$real" in
	*/node_modules/@opencode/cli/*) printf '@opencode/cli\n' ;;
	*/node_modules/opencode-ai/*) printf 'opencode-ai\n' ;;
	*) printf '\n' ;;
	esac
	return 0
}

_refine_owner() {
	local owner="$1" real="$2"
	local home_real=""
	home_real=$(_realpath "$HOME")
	case "$real" in
	"$HOME"/.opencode/bin/* | "$home_real"/.opencode/bin/*)
		printf 'installer\n'
		return 0
		;;
	esac
	case "$owner" in
	npm | bun) [[ -n "$(_package_for_path "$real")" ]] || owner="unknown" ;;
	esac
	printf '%s\n' "$owner"
	return 0
}

# First line of "<opencode> --version", read without an early-exit pipe reader.
_version_line() {
	local path="$1"
	local output=""
	output=$("$path" --version 2>/dev/null || true)
	printf '%s\n' "${output%%$'\n'*}"
	return 0
}

_load_state() {
	local resolved="" owner="" path="" real=""
	resolved=$(_resolve_global 2>/dev/null || printf 'none\t')
	IFS=$'\t' read -r owner path <<<"$resolved"
	GLOBAL_PATH="$path"
	GLOBAL_OWNER="none"
	GLOBAL_PACKAGE=""
	GLOBAL_PROFILE=""
	GLOBAL_VERSION=""
	GLOBAL_SEMVER=""
	[[ -n "$path" ]] || return 0
	real=$(_realpath "$path")
	GLOBAL_OWNER=$(_refine_owner "$owner" "$real")
	GLOBAL_PACKAGE=$(_package_for_path "$real")
	GLOBAL_VERSION=$(_version_line "$path")
	GLOBAL_SEMVER=$(aidevops_parse_semver "$GLOBAL_VERSION" || true)
	GLOBAL_PROFILE=$(_profile_helper installed "$path" || true)
	return 0
}

# Print each OpenCode data folder whose opencode.db holds OpenCode 2 tables:
# the default folder plus the fixed-depth aidevops isolated folders
# (<work>/opencode-interactive|opencode-server/<id>/opencode). Symlinks are
# skipped, as in opencode-db-inventory-lib.sh. One python pass keeps large
# session inventories fast. An unreadable database fails the whole inventory
# (exit 3): guessing could leave an OpenCode 2 database where OpenCode 1 runs.
_v2_data_dirs() {
	python3 - "$DATA_DIR" "$WORK_DIR" <<'PY'
import glob, os, pathlib, sqlite3, sys

default_dir, work_dir = sys.argv[1], sys.argv[2]
candidates = [default_dir]
for kind in ("opencode-interactive", "opencode-server"):
    candidates += sorted(glob.glob(os.path.join(glob.escape(work_dir), kind, "*", "opencode")))
unreadable = 0
for data_dir in candidates:
    db = os.path.join(data_dir, "opencode.db")
    if os.path.islink(data_dir) or os.path.islink(db) or not os.path.isfile(db):
        continue
    try:
        con = sqlite3.connect(pathlib.Path(db).resolve().as_uri() + "?mode=ro", uri=True)
        found = con.execute("select 1 from sqlite_master where type='table' and name='session_v2'").fetchone()
        con.close()
    except sqlite3.Error as error:
        print(f"Could not read {db}: {error}", file=sys.stderr)
        unreadable += 1
        continue
    if found:
        print(data_dir)
sys.exit(3 if unreadable else 0)
PY
	return $?
}

_collect_backup_targets() {
	local found=""
	found=$(_v2_data_dirs) || {
		printf 'Could not check every OpenCode data folder for OpenCode 2 data (see above). Nothing changed.\n' >&2
		return 1
	}
	if [[ "$GLOBAL_PROFILE" == "v2" && -d "$DATA_DIR" ]] && ! grep -Fxq -- "$DATA_DIR" <<<"$found"; then
		found="${DATA_DIR}"$'\n'"${found}"
	fi
	BACKUP_TARGETS=$(printf '%s\n' "$found" | sed '/^$/d')
	return 0
}

_backup_target_count() {
	[[ -n "$BACKUP_TARGETS" ]] || { printf '0\n'; return 0; }
	printf '%s\n' "$BACKUP_TARGETS" | grep -c .
	return 0
}

_profile_label() {
	local profile="$1"
	case "$profile" in
	v1) printf 'v1 (stable, aidevops default)\n' ;;
	v2) printf 'v2 (preview, not yet the aidevops default)\n' ;;
	*) printf 'unknown\n' ;;
	esac
	return 0
}

cmd_status() {
	_load_state
	local preview=""
	preview=$(command -v opencode2 2>/dev/null || true)
	printf 'OpenCode runtime\n'
	printf '  Global opencode: %s\n' "${GLOBAL_PATH:-not installed}"
	printf '  Version:         %s\n' "${GLOBAL_VERSION:-unknown}"
	printf '  Profile:         %s\n' "$(_profile_label "$GLOBAL_PROFILE")"
	printf '  Installed by:    %s%s\n' "$GLOBAL_OWNER" "${GLOBAL_PACKAGE:+ (${GLOBAL_PACKAGE})}"
	printf '  Data folder:     %s\n' "$DATA_DIR"
	printf '  Preview:         %s\n' "${preview:-opencode2 not installed}"
	if [[ -n "${AIDEVOPS_OPENCODE_PROFILE:-}" ]]; then
		printf '  Override:        AIDEVOPS_OPENCODE_PROFILE=%s\n' "$AIDEVOPS_OPENCODE_PROFILE"
	fi
	if [[ "$GLOBAL_PROFILE" == "v2" ]]; then
		printf '\nThe global opencode is the OpenCode 2 preview. To switch back to stable OpenCode 1:\n  %s\n' "$USE_STABLE_CMD"
	fi
	return 0
}

_v2_removal_command() {
	case "$GLOBAL_OWNER" in
	brew) printf 'brew uninstall opencode\n' ;;
	npm) printf 'npm uninstall -g %s\n' "$GLOBAL_PACKAGE" ;;
	bun) printf 'bun remove -g %s\n' "$GLOBAL_PACKAGE" ;;
	installer) printf 'mv %q %q\n' "$GLOBAL_PATH" "${GLOBAL_PATH}${SWITCH_BACKUP_SUFFIX}" ;;
	*) return 1 ;;
	esac
	return 0
}

_v2_reinstall_command() {
	case "$GLOBAL_OWNER" in
	brew) printf 'brew install opencode\n' ;;
	npm) printf 'npm install -g %q\n' "${GLOBAL_PACKAGE}@${GLOBAL_SEMVER:-latest}" ;;
	bun) printf 'bun install -g %q\n' "${GLOBAL_PACKAGE}@${GLOBAL_SEMVER:-latest}" ;;
	installer) printf 'mv %q %q\n' "${GLOBAL_PATH}${SWITCH_BACKUP_SUFFIX}" "$GLOBAL_PATH" ;;
	*) return 1 ;;
	esac
	return 0
}

_v1_installer() {
	if command -v npm >/dev/null 2>&1; then
		printf 'npm\n'
	elif command -v bun >/dev/null 2>&1; then
		printf 'bun\n'
	else
		return 1
	fi
	return 0
}

_print_manual_steps() {
	local version="$1"
	printf 'Could not tell how %s was installed (owner: %s).\n' "${GLOBAL_PATH:-opencode}" "$GLOBAL_OWNER"
	printf 'Switch manually from a plain terminal with OpenCode closed:\n'
	printf '  1. mv %q %q\n' "$DATA_DIR" "${DATA_DIR}${SWITCH_BACKUP_SUFFIX}"
	printf '  2. Remove OpenCode 2 with the tool that installed it (which -a opencode shows where it is)\n'
	printf '  3. npm install -g opencode-ai@%s\n' "$version"
	printf '  4. aidevops setup --scope full\n'
	return 0
}

_plan_line() {
	local text="$1"
	PLAN_STEP=$((PLAN_STEP + 1))
	printf '  %s. %s\n' "$PLAN_STEP" "$text"
	return 0
}

_print_plan() {
	local version="$1" installer="$2"
	local count=""
	count=$(_backup_target_count)
	printf 'Plan: switch the global opencode to stable OpenCode %s\n' "$version"
	if [[ -n "$GLOBAL_PATH" ]]; then
		printf '  Current: %s (%s, installed by %s)\n' "$GLOBAL_PATH" "${GLOBAL_VERSION:-unknown}" "$GLOBAL_OWNER"
	fi
	if [[ -f "$SERVICE_CONFIG" ]]; then
		_plan_line "Stop the managed OpenCode service"
	fi
	if [[ "$count" -gt 0 ]]; then
		_plan_line "Rename ${count} OpenCode 2 data folder(s) to *${SWITCH_BACKUP_SUFFIX}, keeping sign-in files:"
		printf '%s\n' "$BACKUP_TARGETS" | sed 's/^/       /'
	fi
	if [[ "$GLOBAL_PROFILE" == "v2" ]]; then
		_plan_line "Remove OpenCode 2: $(_v2_removal_command)"
	fi
	_plan_line "Install OpenCode 1: ${installer} install -g opencode-ai@${version}"
	_plan_line "Run aidevops setup --scope full, then check the version"
	printf 'Nothing is deleted. An undo script is written to %s\n' "$UNDO_SCRIPT"
	return 0
}

_confirm() {
	local answer=""
	if [[ ! -t 0 ]]; then
		printf 'No terminal to confirm in; rerun with --yes to proceed.\n' >&2
		return 1
	fi
	read -r -p "Switch to stable OpenCode 1 now? [y/N] " answer
	case "$answer" in
	y | Y | yes | YES) return 0 ;;
	esac
	return 1
}

_step_done() {
	local message="$1"
	DONE_STEPS="${DONE_STEPS}  - ${message}"$'\n'
	printf '[OK] %s\n' "$message"
	return 0
}

# Undo runs in reverse order, so each completed step prepends its inverse.
# The script is rewritten after every step, so an interrupted or failed run
# still leaves a usable undo for whatever already changed.
_add_undo() {
	local line="$1"
	UNDO_LINES="${line}"$'\n'"${UNDO_LINES}"
	_write_undo_script || printf 'Could not update %s\n' "$UNDO_SCRIPT" >&2
	return 0
}

# One switch at a time: mkdir is atomic. A lock left by a dead run is reclaimed.
_acquire_lock() {
	local holder=""
	mkdir -p "$SWITCH_STATE_DIR" || return 1
	if ! mkdir "$SWITCH_LOCK_DIR" 2>/dev/null; then
		holder=$(cat "${SWITCH_LOCK_DIR}/pid" 2>/dev/null || true)
		if [[ "$holder" =~ ^[0-9]+$ ]] && kill -0 "$holder" 2>/dev/null; then
			printf 'Another %s is running (PID %s). Wait for it to finish.\n' "$USE_STABLE_CMD" "$holder" >&2
			return 1
		fi
		rm -rf "$SWITCH_LOCK_DIR"
		mkdir "$SWITCH_LOCK_DIR" 2>/dev/null || {
			printf 'Another %s just started. Wait for it to finish.\n' "$USE_STABLE_CMD" >&2
			return 1
		}
	fi
	printf '%s\n' "$$" >"${SWITCH_LOCK_DIR}/pid" || true
	trap '_release_lock' EXIT
	return 0
}

_release_lock() {
	rm -rf "$SWITCH_LOCK_DIR" 2>/dev/null || true
	return 0
}

# A signal only sets a flag, so the running step finishes and records its
# undo line before the switch stops at the next checkpoint.
_on_signal() {
	INTERRUPTED=1
	return 0
}

_checkpoint() {
	[[ "$INTERRUPTED" == "1" ]] || return 0
	printf '\n[INTERRUPTED] Stopped part-way.\n' >&2
	if [[ -n "$UNDO_LINES" ]]; then
		printf 'To put everything back, close OpenCode and run:\n  bash %q\n' "$UNDO_SCRIPT" >&2
	else
		printf 'Nothing had changed yet.\n' >&2
	fi
	exit 130
}

_write_undo_script() {
	[[ -n "$UNDO_LINES" ]] || return 0
	mkdir -p "$(dirname "$UNDO_SCRIPT")" || return 1
	{
		printf '#!/usr/bin/env bash\n'
		printf '# Undo "%s" from %s. Close OpenCode first.\n' "$USE_STABLE_CMD" "$STAMP"
		printf 'set -e\n'
		printf '%s' "$UNDO_LINES"
		printf 'aidevops setup --scope full\n'
		printf 'echo "Restored the state from before %s."\n' "$STAMP"
	} >"$UNDO_SCRIPT" || return 1
	chmod 700 "$UNDO_SCRIPT" 2>/dev/null || true
	return 0
}

_stop_service() {
	[[ -f "$SERVICE_CONFIG" ]] || return 0
	python3 "$SERVICE_HELPER" stop || return 1
	_step_done "Stopped the managed OpenCode service"
	return 0
}

# A rename under an open database risks a torn copy, so require it closed.
# Returns 0 when a database is open, 1 when all are closed, 2 when no tool
# (lsof or pgrep) can tell; the caller refuses both 0 and 2.
_data_dirs_in_use() {
	local dir="" pids=""
	local dbs=()
	while IFS= read -r dir; do
		[[ -n "$dir" && -e "${dir}/opencode.db" ]] && dbs+=("${dir}/opencode.db")
	done <<<"$BACKUP_TARGETS"
	[[ ${#dbs[@]} -gt 0 ]] || return 1
	if command -v lsof >/dev/null 2>&1; then
		pids=$(lsof -t -- "${dbs[@]}" 2>/dev/null || true)
		[[ -n "$pids" ]] && return 0
		return 1
	fi
	command -v pgrep >/dev/null 2>&1 || return 2
	pgrep -x opencode >/dev/null 2>&1 && return 0
	return 1
}

_backup_config() {
	local name=""
	for name in opencode.json opencode.jsonc; do
		[[ -f "${CONFIG_DIR}/${name}" ]] || continue
		[[ ! -e "${CONFIG_DIR}/${name}${SWITCH_BACKUP_SUFFIX}" ]] || return 1
		cp -p "${CONFIG_DIR}/${name}" "${CONFIG_DIR}/${name}${SWITCH_BACKUP_SUFFIX}" || return 1
		_add_undo "$(printf 'cp -p %q %q' "${CONFIG_DIR}/${name}${SWITCH_BACKUP_SUFFIX}" "${CONFIG_DIR}/${name}")"
	done
	return 0
}

_backup_one_dir() {
	local dir="$1"
	local backup="${dir}${SWITCH_BACKUP_SUFFIX}" name=""
	if [[ -e "$backup" ]]; then
		printf 'Backup path already exists: %s\n' "$backup" >&2
		return 1
	fi
	mv "$dir" "$backup" || return 1
	# Keep any OpenCode 1 data created since as *.v1-<stamp>; the replacement
	# folder may be missing if the run stopped right after the rename.
	_add_undo "$(printf 'if [ -e %q ]; then mv %q %q; fi; mv %q %q' "$dir" "$dir" "${dir}.v1-${STAMP}" "$backup" "$dir")"
	mkdir -p "$dir" || return 1
	chmod 700 "$dir" 2>/dev/null || true
	for name in auth.json mcp-auth.json; do
		[[ -f "${backup}/${name}" ]] || continue
		cp -p "${backup}/${name}" "${dir}/${name}" || return 1
		chmod 600 "${dir}/${name}" 2>/dev/null || true
	done
	MOVED_COUNT=$((MOVED_COUNT + 1))
	return 0
}

_backup_data_dirs() {
	local dir=""
	_backup_config || return 1
	while IFS= read -r dir; do
		[[ -n "$dir" ]] || continue
		_backup_one_dir "$dir" || return 1
		_checkpoint
	done <<<"$BACKUP_TARGETS"
	[[ "$MOVED_COUNT" -eq 0 ]] || _step_done "Renamed ${MOVED_COUNT} OpenCode 2 data folder(s) to *${SWITCH_BACKUP_SUFFIX}"
	return 0
}

_remove_v2() {
	local reinstall=""
	reinstall=$(_v2_reinstall_command) || return 1
	case "$GLOBAL_OWNER" in
	brew) brew uninstall opencode || return 1 ;;
	npm) npm uninstall -g "$GLOBAL_PACKAGE" || return 1 ;;
	bun) bun remove -g "$GLOBAL_PACKAGE" || return 1 ;;
	installer) mv "$GLOBAL_PATH" "${GLOBAL_PATH}${SWITCH_BACKUP_SUFFIX}" || return 1 ;;
	*) return 1 ;;
	esac
	V2_REMOVED=1
	_add_undo "$reinstall"
	hash -r
	_step_done "Removed OpenCode 2 ($(_v2_removal_command))"
	return 0
}

_install_v1() {
	local version="$1" installer="$2"
	local bin=""
	if [[ "$installer" == "npm" ]]; then
		npm install -g --no-audit --no-fund "opencode-ai@${version}" || return 1
		bin="$(npm prefix -g)/bin/opencode"
		_add_undo "npm uninstall -g opencode-ai"
	else
		bun install -g "opencode-ai@${version}" || return 1
		bin="${BUN_INSTALL:-${HOME}/.bun}/bin/opencode"
		_add_undo "bun remove -g opencode-ai"
	fi
	hash -r
	if [[ "$(_profile_helper installed "$bin" || true)" != "v1" ]]; then
		printf 'Installed binary %s does not report OpenCode 1\n' "$bin" >&2
		return 1
	fi
	_step_done "Installed OpenCode ${version} at ${bin}"
	return 0
}

_run_setup() {
	command -v aidevops >/dev/null 2>&1 || {
		printf 'aidevops command not found on PATH\n' >&2
		return 1
	}
	aidevops setup --scope full || return 1
	_step_done "Ran aidevops setup --scope full"
	return 0
}

_verify_stable() {
	local path="" version=""
	hash -r
	path=$(command -v opencode 2>/dev/null || true)
	if [[ -z "$path" || "$(_profile_helper installed "$path" || true)" != "v1" ]]; then
		printf 'The opencode command on PATH is not OpenCode 1 yet. Check: which -a opencode\n' >&2
		return 1
	fi
	version=$(_version_line "$path")
	_step_done "opencode now reports ${version:-OpenCode 1} (${path})"
	return 0
}

_print_undo() {
	_write_undo_script || {
		printf 'Could not write %s. Undo steps, in order:\n%s' "$UNDO_SCRIPT" "$UNDO_LINES"
		return 0
	}
	[[ -n "$UNDO_LINES" ]] || return 0
	printf '\nTo undo this switch later, close OpenCode and run:\n  bash %q\n' "$UNDO_SCRIPT"
	return 0
}

_report_failure() {
	local step="$1" version="$2" installer="$3"
	printf '\n[FAILED] %s. Stopped here.\n' "$step" >&2
	if [[ -n "$DONE_STEPS" ]]; then
		printf 'Already done:\n%s' "$DONE_STEPS" >&2
	fi
	if [[ "$V2_REMOVED" == "1" ]]; then
		printf 'To finish the switch: %s install -g opencode-ai@%s && aidevops setup --scope full\n' "$installer" "$version" >&2
	fi
	_print_undo >&2
	return 0
}

_finish_success() {
	printf '\nDone: the global opencode is stable OpenCode 1.\n'
	if [[ "$MOVED_COUNT" -gt 0 ]]; then
		printf 'Your OpenCode 2 sessions stay in the *%s folders listed in the undo script.\n' "$SWITCH_BACKUP_SUFFIX"
	fi
	printf 'Next: open a new terminal, run "opencode auth list", and sign in with "opencode auth login" if a provider is missing.\n'
	printf 'The OpenCode 2 preview remains available as opencode2 when setup has installed it.\n'
	_print_undo
	return 0
}

# Refuse states where switching is unsafe or would be undone by setup.
_preflight_refusals() {
	local dry_run="$1"
	if [[ "${AIDEVOPS_OPENCODE_PROFILE:-}" == "v2" ]]; then
		printf 'AIDEVOPS_OPENCODE_PROFILE=v2 is set, so setup would keep OpenCode 2.\n' >&2
		printf 'Remove that export from your shell profile, open a new terminal, then rerun: %s\n' "$USE_STABLE_CMD" >&2
		return 1
	fi
	if [[ "$dry_run" != "1" && -n "${OPENCODE:-}" ]]; then
		printf 'This is running inside OpenCode. Close OpenCode, open a plain terminal, then run: %s\n' "$USE_STABLE_CMD" >&2
		return 1
	fi
	return 0
}

_run_switch() {
	local version="$1" installer="$2"
	local in_use=1
	trap '_on_signal' INT TERM HUP
	_stop_service || { _report_failure "Stopping the managed OpenCode service failed" "$version" "$installer"; return 1; }
	if _data_dirs_in_use; then in_use=0; else in_use=$?; fi
	if [[ "$in_use" -eq 0 ]]; then
		_report_failure "OpenCode still has a database open; close every OpenCode window and rerun" "$version" "$installer"
		return 1
	fi
	if [[ "$in_use" -eq 2 ]]; then
		_report_failure "Cannot check whether OpenCode is still running (neither lsof nor pgrep is available)" "$version" "$installer"
		return 1
	fi
	_checkpoint
	_backup_data_dirs || { _report_failure "Backing up OpenCode data failed" "$version" "$installer"; return 1; }
	_checkpoint
	if [[ "$GLOBAL_PROFILE" == "v2" ]]; then
		_remove_v2 || { _report_failure "Removing OpenCode 2 failed" "$version" "$installer"; return 1; }
		_checkpoint
	fi
	_install_v1 "$version" "$installer" || { _report_failure "Installing OpenCode ${version} failed" "$version" "$installer"; return 1; }
	_checkpoint
	_run_setup || { _report_failure "aidevops setup failed" "$version" "$installer"; return 1; }
	_verify_stable || { _report_failure "Version check failed" "$version" "$installer"; return 1; }
	_finish_success
	return 0
}

# Validate the detected state; print the reason and return 1 when unsupported.
_switch_supported() {
	local version="$1"
	if [[ -n "$GLOBAL_PATH" && "$GLOBAL_PROFILE" != "v2" ]]; then
		printf '%s does not report a known OpenCode version (%s); run: aidevops setup --scope full\n' "$GLOBAL_PATH" "${GLOBAL_VERSION:-no output}" >&2
		return 1
	fi
	if [[ "$GLOBAL_PROFILE" == "v2" ]] && ! _v2_removal_command >/dev/null; then
		_print_manual_steps "$version"
		return 1
	fi
	return 0
}

cmd_use_stable() {
	local assume_yes=0 dry_run=0 arg="" version="" installer=""
	for arg in "$@"; do
		case "$arg" in
		--yes | -y) assume_yes=1 ;;
		--dry-run) dry_run=1 ;;
		-h | --help) _usage; return 0 ;;
		*) printf 'Unknown option: %s\n' "$arg" >&2; _usage >&2; return 1 ;;
		esac
	done
	if [[ "$dry_run" != "1" ]]; then
		_acquire_lock || return 1
	fi
	_load_state
	if [[ "$GLOBAL_PROFILE" == "v1" ]]; then
		printf 'Already stable: %s is OpenCode %s. Nothing changed.\n' "$GLOBAL_PATH" "$GLOBAL_VERSION"
		return 0
	fi
	_preflight_refusals "$dry_run" || return 1
	version=$(_profile_helper get v1 testedVersion || printf '%s' "$OPENCODE_PLUGIN_TESTED_VERSION")
	_switch_supported "$version" || return 1
	installer=$(_v1_installer) || { printf 'npm or bun is required to install OpenCode 1. Install Node.js first.\n' >&2; return 1; }
	_collect_backup_targets || return 1
	_print_plan "$version" "$installer"
	[[ "$dry_run" == "1" ]] && { printf 'Dry run: nothing changed.\n'; return 0; }
	if [[ "$assume_yes" != "1" ]]; then
		_confirm || { printf 'Cancelled: nothing changed.\n'; return 1; }
	fi
	_run_switch "$version" "$installer"
	return $?
}

main() {
	local command="${1:-status}"
	[[ $# -gt 0 ]] && shift
	case "$command" in
	status) cmd_status ;;
	use-stable) cmd_use_stable "$@" ;;
	help | -h | --help) _usage ;;
	*) printf 'Unknown command: %s\n' "$command" >&2; _usage >&2; return 1 ;;
	esac
	return $?
}

main "$@"
