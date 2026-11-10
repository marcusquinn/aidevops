#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Runtime command-stub coverage for GH#37260; never contacts GitHub or dispatches.
set -euo pipefail
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$TEST_DIR" "${BASH_SOURCE[0]%/*}/.." <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys

root, scripts = map(lambda p: Path(p).resolve(), sys.argv[1:])
bin_dir = root / 'bin'
bin_dir.mkdir()
home = root / 'home'
home.mkdir()
log = root / 'pulse.log'
calls = root / 'calls'

def stub(name, body):
    path = bin_dir / name
    path.write_text('#!/bin/sh\n' + body + '\n')
    path.chmod(0o755)

stub('uname', 'printf "%s\\n" "$TEST_OS"')
stub('id', 'printf "%s\\n" "$TEST_LOGIN"; exit "${TEST_ID_RC:-0}"')
stub('dscl', 'printf "dscl:%s\\n" "$*" >> "$TEST_CALLS"; exit "${TEST_DSCL_RC:-0}"')
stub('osascript', 'printf "notify:%s\\n" "$*" >> "$TEST_CALLS"; exit "${TEST_NOTIFY_RC:-0}"')
env = dict(os.environ, HOME=str(home), LOGFILE=str(log), TEST_CALLS=str(calls),
           PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
           TEST_OS='Darwin', TEST_LOGIN='501')
prefix = 'source "$1/pulse-dispatch-preflight-lib.sh"; '

def run(code, **settings):
    result = subprocess.run(['bash', '-euc', prefix + code, 'test', str(scripts)],
                            env=dict(env, **settings), text=True, capture_output=True,
                            timeout=15)
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)

def function(file, name):
    text = (scripts / file).read_text()
    match = re.search(r'^' + re.escape(name) + r'\(\) \{\n.*?^\}', text, re.M | re.S)
    assert match, name
    return match.group()

run('_preflight_macos_user_lookup_ok', TEST_OS='Linux')
assert not calls.exists(), 'non-macOS must not consult Directory Services'
run('! _preflight_macos_user_lookup_ok')
assert not calls.exists(), 'numeric login must short-circuit dscl'
run('_preflight_macos_user_lookup_ok', TEST_LOGIN='example')
assert 'UniqueID' in calls.read_text()
run('! _preflight_macos_user_lookup_ok', TEST_LOGIN='example', TEST_DSCL_RC='1')
run('! _preflight_macos_user_lookup_ok', TEST_ID_RC='1')

# Run the real wrapper main: the gate must return before any later dependency,
# including worker lifecycle, event refill and busy-lock routine evaluation.
main = function('pulse-wrapper.sh', 'main')
run(main + '; main --refill-only')
assert log.read_text().count('WARN:') == 1
markers = list((home / '.aidevops/advisories').iterdir())
assert len(markers) == 1 and markers[0].name == 'macos-user-lookup.advisory'
assert calls.read_text().count('notify:') == 1
run(main + '; main')
assert log.read_text().count('WARN:') == 2
assert calls.read_text().count('notify:') == 1, 'suppress second notification within hour'

# Direct engine/routine entry points must also stop before their first stage.
run(function('pulse-dispatch-engine.sh', '_run_preflight_stages') + '; ! _run_preflight_stages')
run(function('pulse-routines.sh', 'evaluate_routines') + '; evaluate_routines')
assert calls.read_text().count('notify:') == 1

# Concurrent invocations share one reservation without creating lock files.
marker = markers[0]
stub('osascript', 'printf "notify:%s\\n" "$*" >> "$TEST_CALLS"; sleep 1')
marker.write_text('0\n')
run('( ' + main + '; main ) & ( ' + main + '; main ) & wait')
assert calls.read_text().count('notify:') == 2
assert list(marker.parent.iterdir()) == [marker]
stub('osascript', 'printf "notify:%s\\n" "$*" >> "$TEST_CALLS"; exit "${TEST_NOTIFY_RC:-0}"')

# Expire the marker; failed and missing desktop notification tools are harmless
# and reserve the same hourly throttle as a successful attempt.
marker.write_text('0\n')
run(main + '; main', TEST_NOTIFY_RC='1')
run(main + '; main')
assert calls.read_text().count('notify:') == 3
marker.write_text('0\n')
(bin_dir / 'osascript').unlink()
run(main + '; main')
assert int(marker.read_text().splitlines()[0]) > 0

# Bound a stalled Directory Services lookup using the production timeout helper.
stub('dscl', 'exec sleep 30')
run('! _preflight_macos_user_lookup_ok', TEST_LOGIN='example')

# Exercise the exact runner-attribution guard without unrelated jq/host probes.
engine = (scripts / 'pulse-dispatch-engine.sh').read_text()
guard = engine.split('\trunner=$(id -un 2>/dev/null)', 1)[1].split('\n\tsummary=""', 1)[0]
guard = 'runner=$(id -un 2>/dev/null)' + guard
run('check_runner() { ' + guard + '\nprintf "%s" "$runner"; }; '
    '[[ "$(check_runner)" == "example" ]]', USER='example', LOGNAME='backup')
run('check_runner() { ' + guard + '\nprintf "%s" "$runner"; }; '
    '[[ -z "$(check_runner)" ]]', USER='501', LOGNAME='502')
print('PASS: Linux no-op; healthy/numeric/failed/stalled lookups; wrapper/engine/routine gates; one marker; hourly notification suppression; failed/missing notifier; numeric runner guard')
PY
