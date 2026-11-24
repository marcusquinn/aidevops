#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Runner-local preclaim requirements; no GitHub writes or secret output.

# GH#40077: the same Node resolver worker prelaunch uses. If it cannot load,
# the repo Node gate is skipped and prelaunch remains the backstop.
# shellcheck source=./project-node-runtime.sh
source "${BASH_SOURCE[0]%/*}/project-node-runtime.sh" 2>/dev/null || true

# GH#33399: never fall back to prefetched requirements. Shared by the early
# admission gate and the final gate immediately before the persistent claim.
runner_capability_check_fresh() {
	local repo_path="$1" issue_number="$2" repo_slug="$3" logfile="$4"
	# Tool stderr may be a socket: duplicate it, never reopen /dev/stderr.
	# Function-scoped redirections restore the caller's descriptor on return.
	if [[ "$logfile" == /dev/stderr ]]; then
		_runner_capability_check_fresh_logged "$repo_path" "$issue_number" "$repo_slug" 3>&2 || return 1
	else
		_runner_capability_check_fresh_logged "$repo_path" "$issue_number" "$repo_slug" 3>>"$logfile" || return 1
	fi
	return 0
}

_runner_capability_check_fresh_logged() {
	local repo_path="$1" issue_number="$2" repo_slug="$3"
	local capability_meta_json=""
	local reason=""
	# GH#40180: a host whose IPC services are down cannot run any worker, so
	# check it before any repo or per-issue read. Cached, so repeat calls are free.
	if ! reason=$(_runner_capability_host_ipc_verdict 2>&3); then
		_runner_capability_log_deferral "$issue_number" "$repo_slug" "$reason" ""
		return 1
	fi
	# GH#40077: repo-level gate first, so a repo this runner cannot run at all
	# costs no per-issue API read.
	if ! reason=$(_runner_capability_project_node "$repo_path" 2>&3); then
		_runner_capability_log_deferral "$issue_number" "$repo_slug" "$reason" ""
		return 1
	fi
	capability_meta_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" \
		--jq '{number, state, body, labels}' 2>/dev/null) || capability_meta_json=""
	if ! printf '%s' "$capability_meta_json" | jq -e --argjson number "$issue_number" \
		'.number == $number and .state == "open" and (.body | type == "string") and (.labels | type == "array")' >/dev/null 2>&1; then
		_runner_capability_log_deferral "$issue_number" "$repo_slug" \
			'runner_capability_unmet source=fresh metadata_unreadable' metadata_unreadable
		return 1
	fi
	if ! reason=$(_runner_capability_check_requirements "$repo_path" "$capability_meta_json" fresh 2>&3); then
		_runner_capability_log_deferral "$issue_number" "$repo_slug" "$reason" ""
		return 1
	fi
	return 0
}

# GH#40077: worker prelaunch resolves the repo Node pin (.nvmrc, .node-version,
# .tool-versions, engines.node) and fails with project_node_environment_failure
# when no installed Node satisfies it, after this runner already claimed. One
# runner without a newly pinned major churned 117 claims in 5 hours that way.
# The verdict depends only on the requirement and this runner's installs, so it
# is cached per requirement for a short TTL (a resolution costs ~1 s and both
# gates run per candidate). The signal is never cooldown-eligible: installing
# Node must reopen the repo within the TTL, not after the 6 h issue cooldown.
# Prints the unmet reason and returns 1; returns 0 when usable or unknown.
_runner_capability_project_node() {
	local repo_path="$1"
	local ttl="${AIDEVOPS_RUNNER_CAPABILITY_NODE_TTL_SECONDS:-300}"
	local requirements=""
	[[ -n "$repo_path" && -d "$repo_path" ]] || return 0
	declare -F _project_node_bin >/dev/null || return 0
	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl=300
	# GH#40104: worker prelaunch checks a fresh worktree cut from the remote
	# default branch, so evaluate that ref's pin, not a possibly stale mirror.
	local req_dir="$repo_path" snap="" rc=0
	if snap=$(_runner_capability_node_snapshot "$repo_path"); then
		req_dir="$snap"
	fi
	requirements=$(_project_node_requirement "$req_dir" 2>/dev/null) || requirements="unreadable"
	if [[ -z "$requirements" ]]; then
		[[ "$req_dir" == "$repo_path" ]] || rm -rf "$req_dir"
		return 0
	fi
	_runner_capability_project_node_verdict "$repo_path" "$req_dir" "$requirements" "$ttl" || rc=$?
	[[ "$req_dir" == "$repo_path" ]] || rm -rf "$req_dir"
	return "$rc"
}

# GH#40104: copy the Node requirement files from origin's default branch into a
# private temp dir so the shared parser and resolver run on what workers see.
# Prints the dir; returns 1 (nothing printed) when the ref is unreadable.
_runner_capability_node_snapshot() {
	local repo_path="$1" ref="" commit="" file="" tmp="" content=""
	git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1 || return 1
	ref=$(git -C "$repo_path" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || ref=""
	if [[ -z "$ref" ]]; then
		for ref in origin/main origin/master; do
			git -C "$repo_path" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1 && break
			ref=""
		done
	fi
	[[ -n "$ref" ]] || return 1
	commit=$(git -C "$repo_path" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null) || return 1
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/runner-node-ref.XXXXXX" 2>/dev/null) || return 1
	for file in .nvmrc .node-version .tool-versions package.json; do
		if content=$(git -C "$repo_path" show "${commit}:${file}" 2>/dev/null); then
			printf '%s\n' "$content" >"$tmp/$file" || {
				rm -rf "$tmp"
				return 1
			}
		fi
	done
	printf '%s\n' "$tmp"
	return 0
}

_runner_capability_project_node_verdict() {
	local repo_path="$1" req_dir="$2" requirements="$3" ttl="$4"
	local line="" required="" active="" key="" dir="" file=""
	local tmp="" now="" stamp="" verdict="" detail="" node_rc=0
	# Requirement text is part of the key, so a pin change never reuses a verdict.
	key=$(printf '%s\n%s' "$repo_path" "$requirements" | cksum | tr ' ' '-') || key=""
	dir="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}/runner-capability-node"
	# A lost mkdir race just skips the cache for this call.
	if [[ "$key" =~ ^[0-9]+-[0-9]+$ ]] && mkdir -p "${dir%/*}" 2>/dev/null &&
		{ [[ -d "$dir" ]] || mkdir -m 700 "$dir" 2>/dev/null; } && [[ ! -L "$dir" ]]; then
		file="${dir}/${key}"
	fi
	now=$(date +%s)
	if [[ -n "$file" && -f "$file" && ! -L "$file" ]] &&
		IFS=$'\t' read -r stamp verdict detail <"$file" 2>/dev/null &&
		[[ "$stamp" =~ ^[0-9]+$ ]] && ((now >= stamp && now - stamp < ttl)); then
		[[ "$verdict" != ok ]] || return 0
		if [[ "$verdict" == unmet && "$detail" == runner_capability_unmet\ * ]]; then
			printf '%s source=node_cache\n' "$detail"
			return 1
		fi
	fi
	verdict="ok"
	detail=""
	if [[ "$requirements" == unreadable ]]; then
		verdict="unmet"
		detail="runner_capability_unmet reason=node_requirement_unreadable"
		printf 'runner_health: %s Node requirement unreadable (.nvmrc, .node-version, .tool-versions or package.json engines); its candidates defer, rechecked every %ss\n' \
			"${repo_path##*/}" "$ttl" >&2
	else
		_project_node_bin "$req_dir" "." >/dev/null 2>&1 || node_rc=$?
		if [[ "$node_rc" -eq 1 ]]; then
			while IFS= read -r line; do
				[[ "$line" == "hard "* ]] || continue
				required="${required}${required:+ and }${line#hard }"
			done <<<"$requirements"
			required=$(printf '%s' "$required" | tr -cd '0-9A-Za-z.<>=^~|* -' | cut -c1-120)
			active=$(node --version 2>/dev/null | tr -cd '0-9A-Za-z.' | cut -c1-24)
			[[ -n "$active" ]] || active="none"
			verdict="unmet"
			detail="runner_capability_unmet reason=node_unsatisfied active=${active} required=\"${required}\""
			printf 'runner_health: node %s cannot satisfy %s Node requirement "%s"; install a matching Node (fnm, nvm, volta, mise, Homebrew node@<major>, nodejs.org or n). Its candidates defer without claiming, rechecked every %ss\n' \
				"$active" "${repo_path##*/}" "$required" "$ttl" >&2
		fi
	fi
	if [[ -n "$file" ]] && tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null); then
		if ! { printf '%s\t%s\t%s\n' "$now" "$verdict" "$detail" >"$tmp" && mv -f "$tmp" "$file"; } 2>/dev/null; then
			rm -f "$tmp" 2>/dev/null || true
		fi
	fi
	[[ "$verdict" == ok ]] && return 0
	printf '%s\n' "$detail"
	return 1
}

# GH#40180: runner-wide host IPC health. A macOS host can lose opendirectoryd
# (getpwuid), trustd (Go TLS via the system trust store) or the Mach bootstrap
# port (Chromium) while its daemons look alive; every worker then claims an
# issue and fails the same way. Probes (any failure = unhealthy):
#   getpwuid       `id -un` prints a name, not a bare uid
#   trust_service  `gh auth status` shows no OSStatus/x509 error (curl is not a
#                  valid probe: it uses its own CA store and passed during the fault)
#   tls_timeout    `gh auth status` did not finish in time
#   tls_unknown    nonzero status without a recognized signed-out diagnostic
#   browser_*      opt-in headless Chromium launch (AIDEVOPS_RUNNER_CAPABILITY_BROWSER_PROBE=1)
# A signed-out CLI or missing browser binary stays healthy; other gates own those.
# Unknown TLS errors and an opted-in but unavailable browser probe defer safely.
# Default on for Darwin only (AIDEVOPS_RUNNER_CAPABILITY_HOST_IPC=auto|1|0): a
# container with an unnamed uid would otherwise fail the getpwuid probe forever.
# The verdict is host-wide, cached for AIDEVOPS_RUNNER_CAPABILITY_HOST_IPC_TTL_SECONDS
# (default 120, 0 = no cache) under a lock, so concurrent candidates share one probe
# and one `runner_health:` line per recheck interval. Never cooldown-eligible.
# Prints the unmet reason and returns 1; returns 0 when healthy, off or unknown.
_runner_capability_host_ipc_verdict() {
	case "${AIDEVOPS_RUNNER_CAPABILITY_HOST_IPC:-auto}" in
	0 | off | false | no) return 0 ;;
	1 | on | true | yes) ;;
	*) [[ "$(uname -s 2>/dev/null)" == Darwin ]] || return 0 ;;
	esac
	local rc=0
	python3 - "${BASH_SOURCE[0]%/*}/playwright-runtime.mjs" < <(
		_runner_capability_python_host_ipc_process
		_runner_capability_python_host_ipc_probes
		_runner_capability_python_host_ipc_cache_io
		_runner_capability_python_host_ipc_cache
	) || rc=$?
	[[ "$rc" -eq 0 ]] || return 1
	return 0
}

_runner_capability_python_host_ipc_process() {
	cat <<'PY'
import contextlib
import fcntl
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

def env_int(name, default, low, high):
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError:
        value = default
    return min(high, max(low, value))

def bounded(argv, timeout):
    # Returns (status, output); status 124 = timed out, 127 = not runnable.
    env = dict(os.environ, GH_PROMPT_DISABLED='1', NO_COLOR='1')
    try:
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True,
                                   env=env, text=True, errors='replace')
    except OSError:
        return 127, ''
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass
        # Escaped descendants may hold stdout open after the group is killed.
        # Do not wait for pipe EOF; only reap the direct child for a bounded time.
        process.stdout.close()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        return 124, ''
    return process.returncode, (output or '')[:8192]

PY
	return 0
}

_runner_capability_python_host_ipc_probes() {
	cat <<'PY'
def probe_identity(timeout):
    status, output = bounded(['id', '-un'], timeout)
    name = output.strip()
    if status != 0 or not name or re.fullmatch(r'[0-9]+', name):
        return 'getpwuid'
    return ''

def probe_tls(timeout):
    if not shutil.which('gh'):
        return ''
    status, output = bounded(['gh', 'auth', 'status', '--hostname', 'github.com'], timeout)
    if status == 124:
        return 'tls_timeout'
    if re.search(r'OSStatus|x509:', output):
        return 'trust_service'
    if status != 0 and not re.search(r'not logged into any GitHub hosts', output, re.I):
        return 'tls_unknown'
    return ''

def browser_enabled():
    return os.environ.get('AIDEVOPS_RUNNER_CAPABILITY_BROWSER_PROBE', '') in ('1', 'true', 'yes', 'on')

def probe_browser(timeout):
    if not browser_enabled():
        return ''
    command = os.environ.get('AIDEVOPS_RUNNER_CAPABILITY_BROWSER_PROBE_CMD', '')
    try:
        argv = shlex.split(command) if command.strip() else default_browser_argv()
    except ValueError:
        return 'browser_unavailable'
    status, output = bounded(argv, timeout)
    if status == 124:
        return 'browser_timeout'
    if re.search(r'bootstrap_check_in|MachPortRendezvous|Permission denied \(1100\)', output):
        return 'browser_bootstrap'
    if status in (78, 127):
        return 'browser_unavailable'
    return ''

def default_browser_argv():
    # Reuse the verified runtime resolver (including AIDEVOPS_PLAYWRIGHT_MODULE)
    # without npx or any package installation during admission.
    return [
        'node', '-e',
        "const {pathToFileURL}=require('node:url');"
        "(async()=>{try{"
        "const r=await import(pathToFileURL(process.argv[1]).href);"
        "const m=await r.resolvePlaywrightModule({allowNpx:false});"
        "const {chromium}=await r.loadPlaywright(m);"
        "(async()=>{const b=await chromium.launch({headless:true});await b.close();})()"
        ".catch(e=>{console.error(String(e&&e.message||e));process.exit(1);});"
        "}catch(e){process.exit(78);}})();", sys.argv[1]]

def run_probes():
    probe_timeout = env_int('AIDEVOPS_RUNNER_CAPABILITY_HOST_IPC_TIMEOUT_SECONDS', 5, 1, 30)
    browser_timeout = env_int('AIDEVOPS_RUNNER_CAPABILITY_BROWSER_TIMEOUT_SECONDS', 20, 1, 60)
    return (probe_identity(probe_timeout) or probe_tls(probe_timeout) or
            probe_browser(browser_timeout))

def report(failed, ttl, cached):
    print(f'runner_capability_unmet reason=host_ipc_unhealthy check={failed}' +
          (' source=host_ipc_cache' if cached else ''))
    if not cached:
        print(f'runner_health: host IPC unhealthy ({failed}); no worker on this runner can '
              f'launch a browser or reach GitHub with TLS. All its candidates defer without '
              f'claiming, rechecked every {ttl}s', file=sys.stderr)
    raise SystemExit(1)

PY
	return 0
}

_runner_capability_python_host_ipc_cache_io() {
	cat <<'PY'
def cache_directory():
    base = Path(os.environ.get('AIDEVOPS_TEMP_DIR') or
                str(Path.home() / '.aidevops/.agent-workspace/tmp'))
    directory = base / 'runner-capability-host-ipc'
    try:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = directory.lstat()
    except OSError:
        return None
    if directory.is_symlink() or info.st_uid != os.getuid() or info.st_mode & 0o077:
        return None
    return directory

@contextlib.contextmanager
def cache_handle(fd):
    handle = os.fdopen(fd, 'r+')
    try:
        yield handle
    finally:
        # close() may retry a failed buffered flush. Never replace the verdict
        # (including report's SystemExit) with that persistence error.
        with contextlib.suppress(OSError):
            handle.close()

def cache_write(handle, state):
    try:
        handle.seek(0)
        json.dump(state, handle)
        handle.truncate()
        handle.flush()
    except OSError:
        pass

PY
	return 0
}

_runner_capability_python_host_ipc_cache() {
	cat <<'PY'
def main():
    ttl = env_int('AIDEVOPS_RUNNER_CAPABILITY_HOST_IPC_TTL_SECONDS', 120, 0, 1800)
    # Include effective enablement and launcher/resolution settings in the key.
    probes = ['base']
    if browser_enabled():
        command = os.environ.get('AIDEVOPS_RUNNER_CAPABILITY_BROWSER_PROBE_CMD', '').strip()
        probes = ['browser', command or default_browser_argv(),
                  os.environ.get('AIDEVOPS_PLAYWRIGHT_MODULE', ''),
                  os.environ.get('AIDEVOPS_PLAYWRIGHT_RUNTIME_DIR', ''), os.environ.get('PATH', ''),
                  str(Path.home()), os.getcwd()]
    directory = cache_directory() if ttl else None
    if directory is None:
        failed = run_probes()
        if failed:
            report(failed, ttl, False)
        return
    try:
        fd = os.open(directory / 'verdict.json', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    except OSError:
        failed = run_probes()
        if failed:
            report(failed, ttl, False)
        return
    with cache_handle(fd) as handle:
        info = os.fstat(handle.fileno())
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            failed = run_probes()
            if failed:
                report(failed, ttl, False)
            return
        # Cover the maximum sequential probe budget even when the holder has
        # different timeout settings: 2*30s identity/TLS + 60s browser, one
        # second of bounded cleanup per probe, plus 5s scheduling margin.
        deadline = time.monotonic() + 2 * (30 + 1) + (60 + 1) + 5
        locked = False
        while not locked:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                locked = True
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.05)
        if not locked:
            failed = run_probes()
            if failed:
                report(failed, ttl, False)
            return
        try:
            state = json.loads(handle.read() or '{}')
        except ValueError:
            state = {}
        now = time.time()
        at = state.get('at') if isinstance(state, dict) else None
        if (isinstance(at, (int, float)) and not isinstance(at, bool) and 0 <= now - at < ttl and
                state.get('probes') == probes and state.get('verdict') in ('ok', 'unmet')):
            if state['verdict'] == 'ok':
                return
            failed = str(state.get('check', ''))
            if re.fullmatch(r'[a-z_]{1,32}', failed):
                report(failed, ttl, True)
        failed = run_probes()
        cache_write(handle, {'at': time.time(), 'probes': probes,
                             'verdict': 'unmet' if failed else 'ok', 'check': failed})
        if failed:
            report(failed, ttl, False)

try:
    main()
except Exception:
    # An interpreter or filesystem fault in the probe itself is unknown, not
    # unhealthy: never pause a runner on it.
    raise SystemExit(0)
PY
	return 0
}

# GH#34427: AIDEVOPS_RUNNER_CAPABILITY_SECRET_TIMEOUT_SECONDS bounds each
# `aidevops secret check` (default 15, clamped 1-60, invalid -> default).

# GH#33743: keep the operator-facing "deferred:" text, and append a structured
# reason with the repo slug so candidate-scoped log matching classifies it as
# runner_capability_unmet instead of no_recent_log_evidence. cooldown=eligible
# marks deterministic runner-local gaps (missing secret, failing probe, missing
# PATH tool, invalid requirement map); transient store/API/timeout signals are
# always re-checked.
_runner_capability_log_deferral() {
	local issue_number="$1" repo_slug="$2" reason="$3" signal="$4"
	local cooldown="none"
	reason="${reason//$'\n'/ }"
	if [[ -z "$reason" ]]; then
		# No checker verdict (interpreter failure): never cool down on it.
		reason="runner_capability_unmet"
		[[ -n "$signal" ]] || signal="check_error"
	fi
	if [[ -z "$signal" ]]; then
		if [[ "$reason" =~ reason=([a-z_]+) ]]; then
			signal="${BASH_REMATCH[1]}"
		elif [[ "$reason" == runner_capability_unmet ]]; then
			signal="invalid_requirements"
		else
			signal="check_error"
		fi
	fi
	case "$signal" in
	secret_missing | probe_failed | tool_missing | service_unhealthy | invalid_requirements | device_mismatch) cooldown="eligible" ;;
	esac
	printf '[dispatch_with_dedup] #%s deferred: %s — DISPATCH_BLOCK_REASON reason=runner_capability_unmet signal=%s cooldown=%s issue=#%s repo=%s\n' \
		"$issue_number" "$reason" "$signal" "$cooldown" "$issue_number" "$repo_slug" >&3
	return 0
}

runner_capability_check() {
	local repo_path="$1"
	local issue_meta_json="$2"
	local source="${3:-}"
	# GH#40180: runner-wide verdict first; it prints the unmet reason itself.
	_runner_capability_host_ipc_verdict || return 1
	_runner_capability_check_requirements "$repo_path" "$issue_meta_json" "$source" || return 1
	return 0
}

# The fresh entry point has already checked host health before reading metadata.
_runner_capability_check_requirements() {
	local repo_path="$1" issue_meta_json="$2" source="${3:-}"
	local cycle="${_PULSE_CYCLE_ID:-}"
	# Assemble only trusted literal code; issue metadata stays in argv as data.
	python3 - "$repo_path" "$issue_meta_json" "$source" "$cycle" "${BASH_SOURCE[0]%/*}/network-tier-helper.sh" < <(
		_runner_capability_python_runtime
		_runner_capability_python_cycle
		_runner_capability_python_secrets
		_runner_capability_python_classes
		_runner_capability_python_tools
		_runner_capability_python_services
		_runner_capability_python_device
		_runner_capability_python_requirements
	)
	local rc=$?
	[[ "$rc" -eq 0 ]] || return 1
	return 0
}

_runner_capability_python_runtime() {
	cat <<'PY'
import contextlib
import fcntl
import hashlib
import json
import os
import re
import runpy
import shutil
import signal
import stat
import subprocess
import sys
import time
from pathlib import Path

def unmet(reason=''):
    print('runner_capability_unmet' + (f' reason={reason}' if reason else ''))
    raise SystemExit(1)

def unmet_exception(error):
    # GH#39779: runner environment failures are re-checked next cycle
    # (signal=check_error), never cooled down as invalid requirements.
    # Parse errors in issue-declared requirements stay invalid_requirements.
    unmet('check_error' if isinstance(error, (OSError, RuntimeError)) else '')

def resolve_root(path):
    # GH#38825: name a missing repo root instead of a generic invalid map.
    if not Path(path).is_dir():
        unmet('repo_path_missing')
    return Path(path).resolve(strict=True)

def check_rejections(names):
    # GH#39779: a busy or unreadable host-wide rejection state is transient,
    # not an invalid requirement; name it as the standalone helper CLI does.
    try:
        rejection = runpy.run_path(str(Path(sys.argv[5]).parent / 'runner-secret-rejection.py'))
        rejected_name = rejection['process_names']('check', sorted(names))
    except (OSError, ValueError):
        unmet('rejection_state_unreadable')
    if rejected_name:
        unmet(f'secret_rejected name={rejected_name}')

def run_check(argv, target, secret=False, cwd=None, timeout=5):
    # Bound descendants too: a locked pinentry or probe child must not survive.
    env = os.environ.copy()
    if secret:
        # The inner supervisor must time out first so it can kill its gopass
        # group before this watchdog SIGKILLs the supervisor.
        try:
            inner = int(env.get('AIDEVOPS_SECRET_READ_TIMEOUT_SECONDS', '12'))
        except ValueError:
            inner = 12
        env['AIDEVOPS_SECRET_READ_TIMEOUT_SECONDS'] = str(max(1, min(inner, timeout - 1)))
    try:
        process = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True, env=env)
    except OSError:
        return f'check_failed {target}' if secret else f'probe_failed {target}'
    try:
        status = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        return f'check_timeout {target}'
    if not status:
        return ''
    if secret:
        if status == 5:
            return f'check_timeout {target}'
        if status == 3:
            return f'secret_unreadable {target} store=gopass fallback=disabled'
        return f'{"secret_missing" if status == 1 else "check_failed"} {target}'
    return f'probe_failed {target}'

PY
	return 0
}

_runner_capability_python_cycle() {
	cat <<'PY'
@contextlib.contextmanager
def capability_state(filename, timeout=None):
    # Pulse watchdogs isolate candidates in subshells. Share metadata, not values,
    # under an exclusive lock so concurrent candidates cannot decrypt twice.
    if not filename:
        yield None, {}
        return
    base = Path(os.environ.get('AIDEVOPS_TEMP_DIR') or
                str(Path.home() / '.aidevops/.agent-workspace/tmp'))
    directory = base / 'runner-capability'
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.lstat()
    if directory.is_symlink() or info.st_uid != os.getuid() or info.st_mode & 0o077:
        unmet('cycle_state_unreadable')
    # Expired cycle files contain only names/counts; retain a day for diagnostics.
    for old in directory.glob('*.json'):
        try:
            if old.name != 'readable.json' and not old.is_symlink() and old.stat().st_mtime < time.time() - 86400:
                old.unlink()
        except FileNotFoundError:
            pass
    path = directory / filename
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'r+') as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            unmet('cycle_state_unreadable')
        if timeout is None:
            fcntl.flock(handle, fcntl.LOCK_EX)
        else:
            deadline = time.monotonic() + timeout
            while True:
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        yield None, {}
                        return
                    time.sleep(min(0.05, remaining))
        data = handle.read()
        state = json.loads(data) if data else {}
        yield handle, state

def cycle_state(cycle):
    filename = hashlib.sha256(cycle.encode()).hexdigest() + '.json' if cycle else ''
    return capability_state(filename)

def unreadable(name, handle, state, cached=False):
    count = state.get('deferred', 0) + 1
    if handle is not None:
        handle.seek(0)
        json.dump({'name': name, 'deferred': count,
                   'at': state.get('at', time.time()) if cached else time.time()}, handle)
        handle.truncate()
        handle.flush()
    if sys.argv[3] == 'fresh' and not cached:
        print('runner_health: gpg store locked or entry unreadable; '
              'secret-gated candidates deferred>=1; gopass authoritative '
              '(no plaintext fallback); see reference/secret-handling.md', file=sys.stderr)
    if sys.argv[3] == 'fresh':
        print(f'runner_capability_health secret_gated_deferred={count}', file=sys.stderr)
    unmet(f'secret_unreadable name={name} store=gopass fallback=disabled' +
          (' source=cycle_cache' if cached else ''))

def check_cached_unreadable(handle, state):
    name = state.get('name', '')
    try:
        ttl = max(0, int(os.environ.get('AIDEVOPS_RUNNER_CAPABILITY_UNREADABLE_TTL_SECONDS', '120')))
    except ValueError:
        ttl = 120
    if (re.fullmatch(r'[A-Z][A-Z0-9_]{0,127}', name) and
            time.time() - float(state.get('at', 0)) < ttl):
        unreadable(name, handle, state, cached=True)
    if handle is not None and name:
        handle.seek(0)
        handle.truncate()
        handle.flush()

PY
	return 0
}

_runner_capability_python_secrets() {
	cat <<'PY'
def readable_ttl():
    # GH#39815: every candidate re-decrypted the same names at both gates;
    # under gpg-agent contention those checks hit check_timeout in bursts.
    try:
        ttl = int(os.environ.get('AIDEVOPS_RUNNER_CAPABILITY_READABLE_TTL_SECONDS', '300'))
    except ValueError:
        ttl = 300
    return min(1800, max(0, ttl))

def fresh_readable(readable, ttl, now):
    if not isinstance(readable, dict) or not ttl:
        return {}
    return {name: at for name, at in readable.items()
            if re.fullmatch(r'[A-Z][A-Z0-9_]{0,127}', name) and
            isinstance(at, (int, float)) and not isinstance(at, bool) and 0 <= now - at < ttl}

def cached_readable(state, name):
    return name in fresh_readable(state.get('readable'), readable_ttl(), time.time())

def write_host_readable(handle, state, name, success):
    if handle is None:
        return
    readable = fresh_readable(state, readable_ttl(), time.time())
    if success and readable_ttl():
        readable[name] = time.time()
    else:
        readable.pop(name, None)
    handle.seek(0)
    json.dump(readable, handle)
    handle.truncate()
    handle.flush()

def remember_readable(handle, state, name, checked_at=None):
    # Names and timestamps only. Any unreadable record is expired by now, and
    # unreadable() rewrites state without this map, so a lock clears it.
    ttl = readable_ttl()
    if handle is None or not ttl:
        return
    now = time.time()
    readable = fresh_readable(state.get('readable'), ttl, now)
    readable[name] = now if checked_at is None else checked_at
    state['readable'] = readable
    handle.seek(0)
    json.dump({'readable': readable}, handle)
    handle.truncate()
    handle.flush()

def check_secrets(secrets, cycle):
    # Loaded runners can exceed 5s; default 15s, clamped 1-60, invalid -> default.
    try:
        secret_timeout = int(os.environ.get('AIDEVOPS_RUNNER_CAPABILITY_SECRET_TIMEOUT_SECONDS', '15'))
    except ValueError:
        secret_timeout = 15
    secret_timeout = min(60, max(1, secret_timeout))
    check_rejections(secrets)
    with cycle_state(cycle) as (handle, state):
        check_cached_unreadable(handle, state)
        reused = 0
        for name in sorted(secrets):
            # Only readability is reused; requirements stay fresh (GH#33399).
            if cached_readable(state, name):
                reused += 1
                continue
            # Pulse cycles share positive metadata on this host, but never share
            # locked-store verdicts. Keep the lock through the decrypt so a
            # concurrent cycle reuses its result instead of loading gpg-agent.
            with capability_state('readable.json' if cycle else '', secret_timeout) as (host, readable):
                if name in fresh_readable(readable, readable_ttl(), time.time()):
                    reused += 1
                    remember_readable(handle, state, name, readable[name])
                    continue
                reason = run_check(['aidevops', 'secret', 'check', name], f'name={name}', timeout=secret_timeout, secret=True)
                write_host_readable(host, readable, name, not reason)
            # A timed-out lock falls back to the ordinary check, never an
            # unbounded wait. Only retry failure invalidation: publishing an
            # unlocked success could resurrect a newer failure from the holder.
            if host is None and cycle and reason:
                with capability_state('readable.json', secret_timeout) as (host, readable):
                    write_host_readable(host, readable, name, False)
            if reason.startswith('secret_unreadable '):
                unreadable(name, handle, state)
            if reason:
                unmet(reason)
            remember_readable(handle, state, name)
        if reused:
            print(f'runner_capability_secret_cache reused={reused} checked={len(secrets) - reused}',
                  file=sys.stderr)

PY
	return 0
}

_runner_capability_python_classes() {
	cat <<'PY'
def class_requirements(root, issue):
    class_names = []
    for label in issue.get('labels', []):
        name = label.get('name', '') if isinstance(label, dict) else label
        if name.startswith('dispatch-class:'):
            class_names.append(name[len('dispatch-class:'):])
    classes = {}
    # Repo config only contributes class requirements; ungated issues ignore it.
    if class_names:
        config_path = root / '.aidevops.json'
        if config_path.is_symlink():
            unmet()
        try:
            config = json.loads(config_path.read_text()) if config_path.exists() else {}
        except (ValueError, OSError):
            unmet('config_unreadable path=.aidevops.json')
        classes = config.get('dispatch_class_requirements', {})
        if not isinstance(classes, dict):
            unmet()
    requirements = []
    for name in class_names:
        requirement = classes.get(name, {})
        if not isinstance(requirement, dict):
            unmet()
        requirements.append(requirement)
    return requirements

PY
	return 0
}

# GH#37587: requires-tools names are bare commands resolved on PATH only; the
# dispatcher never executes them.
_runner_capability_python_tools() {
	cat <<'PY'
def requirement_tools(requirements, body):
    tools = set()
    declared = [requirement for requirement in requirements if 'tools' in requirement]
    for line in body.splitlines():
        if line.startswith('requires-tools:'):
            declared.append({'tools': re.split(r'[,\s]+', line.partition(':')[2].strip())})
    for requirement in declared:
        names = requirement.get('tools', [])
        if not isinstance(names, list) or len(names) > 8:
            unmet('invalid_requirements')
        for name in names:
            # A bare command name only: no path, argument or shell text.
            if not isinstance(name, str) or not re.fullmatch(r'[a-z][a-z0-9._-]{0,63}', name):
                unmet('invalid_requirements')
            tools.add(name)
    if len(tools) > 8:
        unmet('invalid_requirements')
    return tools

def check_tools(tools):
    # Cheapest deterministic gate first: PATH lookup only, nothing is run.
    for name in sorted(tools):
        if not shutil.which(name):
            unmet(f'tool_missing name={name}')

PY
	return 0
}

# GH#37638: requires-loopback-health gates on a healthy local service. Only a
# port and a safe path come from the issue; host, method and headers are fixed.
_runner_capability_python_services() {
	cat <<'PY'
def requirement_services(requirements, body):
    services = set()
    declared = [requirement for requirement in requirements if 'loopback_health' in requirement]
    for line in body.splitlines():
        if line.startswith('requires-loopback-health:'):
            declared.append({'loopback_health': re.split(r'[,\s]+', line.partition(':')[2].strip())})
    for requirement in declared:
        entries = requirement.get('loopback_health', [])
        if not isinstance(entries, list) or len(entries) > 4:
            unmet('invalid_requirements')
        for entry in entries:
            # <port>[/<path>] only: no scheme, host, query, fragment or '..'.
            match = re.fullmatch(r'([0-9]{1,5})(?:/([A-Za-z0-9_./-]{0,64}))?', entry) if isinstance(entry, str) else None
            if not match:
                unmet('invalid_requirements')
            port, path = int(match.group(1)), match.group(2) or ''
            if not 1024 <= port <= 65535 or '..' in path:
                unmet('invalid_requirements')
            services.add((port, path))
    if len(services) > 4:
        unmet('invalid_requirements')
    return services

def probe_service(port, path):
    import http.client
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=2)
    try:
        connection.request('GET', '/' + path)
        response = connection.getresponse()
        response.read(4096)
        return 200 <= response.status < 300
    except (OSError, http.client.HTTPException):
        return False
    finally:
        connection.close()

def check_services(services, cycle):
    # Per-cycle cache keyed by port and path so many issues probe a service once.
    for port, path in sorted(services):
        cache = None
        if cycle:
            base = Path(os.environ.get('AIDEVOPS_TEMP_DIR') or
                        str(Path.home() / '.aidevops/.agent-workspace/tmp'))
            directory = base / 'runner-capability'
            digest = hashlib.sha256(f'{cycle}\0{port}\0{path}'.encode()).hexdigest()
            cache = directory / f'health-{digest}.json'
        healthy = None
        if cache is not None:
            try:
                if not cache.is_symlink():
                    healthy = bool(json.loads(cache.read_text()).get('healthy'))
            except (OSError, ValueError, AttributeError):
                healthy = None
        if healthy is None:
            healthy = probe_service(port, path)
            if cache is not None:
                try:
                    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
                    if not directory.is_symlink():
                        cache.write_text(json.dumps({'healthy': healthy}))
                except OSError:
                    pass
        if not healthy:
            unmet(f'service_unhealthy port={port}')

PY
	return 0
}

# GH#38547: requires-device: only the runner whose local device id matches may
# claim. Device ids are public in claim comments; checked before any secret read.
_runner_capability_python_device() {
	cat <<'PY'
def check_device(body):
    wanted = []
    for line in body.splitlines():
        if line.startswith('requires-device:'):
            wanted.extend(re.split(r'[,\s]+', line.partition(':')[2].strip()))
    if not wanted:
        return
    if len(wanted) > 4 or not all(re.fullmatch(r'device-[0-9]+-[0-9]+-[0-9]+', item) for item in wanted):
        unmet('invalid_requirements')
    device_file = os.environ.get('AIDEVOPS_DEVICE_ID_FILE') or str(Path.home() / '.aidevops/state/device-id')
    try:
        local = Path(device_file).read_text().strip()
    except (OSError, UnicodeError):
        local = ''
    if not local:
        unmet('device_unknown')
    if local not in wanted:
        unmet('device_mismatch')

PY
	return 0
}

_runner_capability_python_requirements() {
	cat <<'PY'
try:
    root = resolve_root(sys.argv[1])
    issue = json.loads(sys.argv[2])
    check_device(issue.get('body', ''))
    requirements = class_requirements(root, issue)
    # Issue text can name secrets and PATH tools, never executable commands.
    for label in issue.get('labels', []):
        name = label.get('name', '') if isinstance(label, dict) else label
        if name.startswith('needs-secret:'):
            requirements.append({'secrets': [name.partition(':')[2]]})
    for names in re.findall(r'<!-- aidevops:needs-secrets ([A-Za-z_0-9 ]+) -->', issue.get('body', '')):
        requirements.append({'secrets': names.split()})
    for line in issue.get('body', '').splitlines():
        if line.startswith('requires-secrets:'):
            names = re.split(r'[,\s]+', line.partition(':')[2].strip())
            if not names or not all(names):
                unmet()
            requirements.append({'secrets': names})
        elif line.startswith('requires-ssh:'):
            requirements.append({'ssh_commands': [json.loads(line.partition(':')[2])]})
    secrets, probes, ssh_commands = set(), [], []
    tools = requirement_tools(requirements, issue.get('body', ''))
    for requirement in requirements:
        commands = requirement.get('ssh_commands', [])
        if not isinstance(commands, list) or len(commands) > 8:
            unmet('invalid_requirements')
        for command in commands:
            if (not isinstance(command, list) or not command or len(command) > 128
                    or not all(isinstance(arg, str) and len(arg) <= 4096 for arg in command)
                    or command[0] not in ('ssh', '/usr/bin/ssh')):
                unmet('invalid_requirements')
            ssh_commands.append(command)
        names = requirement.get('secrets', [])
        if not isinstance(names, list) or len(names) > 32:
            unmet()
        for name in names:
            if not isinstance(name, str) or not re.fullmatch(r'[A-Z][A-Z0-9_]{0,127}', name):
                unmet()
            secrets.add(name)
        if 'probe' in requirement:
            probe = requirement['probe']
            # A literal executable path, not shell syntax, arguments or an URL.
            if not isinstance(probe, str) or not re.fullmatch(r'[A-Za-z0-9_./-]+', probe):
                unmet()
            path = Path(probe)
            if path.is_absolute() or '..' in path.parts:
                unmet()
            try:
                executable = (root / path).resolve(strict=True)
            except OSError:
                unmet(f'probe_failed path={probe}')
            if root not in executable.parents or not executable.is_file() or not os.access(executable, os.X_OK):
                unmet(f'probe_failed path={probe}')
            probes.append((str(executable), probe))
    if len(secrets) > 32 or len(probes) > 8 or len(ssh_commands) > 8:
        unmet()
    check_tools(tools)
    check_services(requirement_services(requirements, issue.get('body', '')), sys.argv[4] if sys.argv[3] == 'fresh' else '')
    # Only analyze exact argv; never execute SSH or issue-provided shell text.
    # The same tier gate used inside the worker is authoritative before claim.
    network_timeout = int(os.environ.get('AIDEVOPS_NETWORK_POLICY_TIMEOUT_SECONDS', '30'))
    if ssh_commands and network_timeout <= 0:
        unmet('invalid_requirements')
    for command in ssh_commands:
        reason = run_check(['bash', str(Path(sys.argv[5]).resolve()), 'check-argv',
                            json.dumps(command), '--cwd', str(root)],
                           'ssh', cwd=root, timeout=network_timeout)
        if reason:
            unmet('ssh_network_requirement_unmet recovery=reference/ssh-bindings.md')
    if sys.argv[3] == 'fresh':
        print(f'runner_capability_check source=fresh requirements={len(secrets) + len(probes) + len(ssh_commands) + len(tools)}',
              file=sys.stderr)
    if secrets:
        check_secrets(secrets, sys.argv[4] if sys.argv[3] == 'fresh' else '')
    for executable, probe in probes:
        reason = run_check([executable], f'path={probe}', cwd=root)
        if reason:
            unmet(reason)
except (OSError, ValueError, TypeError, AttributeError, RuntimeError) as error:
    unmet_exception(error)
PY
	return 0
}
