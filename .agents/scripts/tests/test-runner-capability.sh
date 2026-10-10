#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$SCRIPT_DIR" <<'PY'
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

scripts = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='runner-capability-') as temp:
    root = Path(temp)
    repo = root / 'repo'
    repo.mkdir()
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    cli = bin_dir / 'aidevops'
    cli.write_text('''#!/usr/bin/env bash
[[ "$1 $2" == 'secret check' ]] || exit 99
[[ -z "${CHECK_CALLS:-}" ]] || printf '%s\\n' "$3" >>"$CHECK_CALLS"
[[ "$3" != SLOW ]] || exec sleep 10
[[ "$3" != LOCKED ]] || exit 3
printf 'PRIVATE_VALUE\n'
printf 'PRIVATE_ERROR\n' >&2
[[ "$3" == GOOD ]]
''')
    cli.chmod(0o700)
    env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'],
               AIDEVOPS_TEMP_DIR=str(root / 'workspace-temp'))
    config = repo / '.aidevops.json'
    passed = 0

    def check(label, issue, requirements=None, success=True, reason=''):
        global passed
        if requirements is None:
            config.unlink(missing_ok=True)
        elif isinstance(requirements, str):
            config.write_text(requirements)
        else:
            config.write_text(json.dumps({'dispatch_class_requirements': requirements}))
        result = subprocess.run(['bash', '-c',
            'source "$1/runner-capability-helper.sh"; runner_capability_check "$2" "$3"',
            'fixture', str(scripts), str(repo), json.dumps(issue)],
            env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == success, (label, result)
        expected = 'runner_capability_unmet' + (f' reason={reason}' if reason else '') + '\n'
        assert result.stdout == ('' if success else expected), (label, result)
        assert not result.stderr, (label, result.stderr)
        passed += 1
        print('PASS', label)

    issue = {'labels': [{'name': 'dispatch-class:publish'}], 'body': ''}
    check('no declarations preserves dispatch', issue)
    malformed_config = '{"dispatch_class_requirements": {}} trailing'
    check('malformed config without labels preserves dispatch', {'body': ''}, malformed_config)
    check('malformed config without class labels preserves dispatch',
          {'labels': [{'name': 'bug'}, 'auto-dispatch'], 'body': ''}, malformed_config)
    check('malformed config with class label defers distinctly', issue, malformed_config, False,
          'config_unreadable path=.aidevops.json')
    check('malformed config still checks brief secrets without class labels',
          {'body': 'requires-secrets: MISSING'}, malformed_config, False,
          'secret_missing name=MISSING')
    check('missing secret defers', issue, {'publish': {'secrets': ['MISSING']}}, False,
          'secret_missing name=MISSING')
    check('resolvable secret proceeds without output', issue, {'publish': {'secrets': ['GOOD']}})
    check('locked secret timeout defers', issue, {'publish': {'secrets': ['SLOW']}}, False,
          'check_timeout name=SLOW')
    check('unreadable secret defers', {'body': 'requires-secrets: LOCKED'}, success=False,
          reason='secret_unreadable name=LOCKED store=gopass fallback=disabled')
    check('brief requirement defers', {'body': 'requires-secrets: MISSING'}, success=False,
          reason='secret_missing name=MISSING')
    check('brief comma/space names proceed', {'body': 'requires-secrets: GOOD, GOOD'})
    check('brief and class combine', dict(issue, body='requires-secrets: MISSING'),
          {'publish': {'secrets': ['GOOD']}}, False, 'secret_missing name=MISSING')
    check('multiple classes combine', {'labels': ['dispatch-class:publish', 'dispatch-class:data']},
          {'publish': {'secrets': ['GOOD']}, 'data': {'secrets': ['MISSING']}}, False,
          'secret_missing name=MISSING')
    check('malformed secret fails closed', issue, {'publish': {'secrets': 'GOOD'}}, False)
    check('invalid name fails closed', {'body': 'requires-secrets: GOOD;evil'}, success=False)
    probe = repo / 'probe'
    probe.write_text('#!/usr/bin/env bash\nprintf PRIVATE_DATA\nexit 0\n')
    probe.chmod(0o700)
    check('successful probe proceeds without output', issue, {'publish': {'probe': 'probe'}})
    probe.write_text('#!/usr/bin/env bash\nexit 1\n')
    check('stale data probe defers', issue, {'publish': {'probe': 'probe'}}, False,
          'probe_failed path=probe')
    check('shell command is rejected', issue, {'publish': {'probe': 'probe; touch owned'}}, False)
    check('missing probe is rejected', issue, {'publish': {'probe': 'missing'}}, False,
          'probe_failed path=missing')
    check('path traversal is rejected', issue, {'publish': {'probe': '../bin/aidevops'}}, False)
    (repo / 'escape').symlink_to(cli)
    check('escaping symlink is rejected', issue, {'publish': {'probe': 'escape'}}, False,
          'probe_failed path=escape')
    probe.write_text('#!/usr/bin/env bash\nexec sleep 10\n')
    check('probe timeout defers', issue, {'publish': {'probe': 'probe'}}, False,
          'check_timeout path=probe')

    # Exercise the actual dispatch entry function, stopping at the next gate.
    # A capability failure must never reach a scope write, dedup or claim.
    core = (scripts / 'pulse-dispatch-core.sh').read_text()
    function = re.search(r'(?ms)^dispatch_with_dedup\(\) \{.*?^}', core).group()
    config.write_text(json.dumps({'dispatch_class_requirements': {'publish': {'secrets': ['MISSING']}}}))
    stub = '''
_ds_now_ns() { printf 0; return 0; }
_dispatch_load_and_validate_metadata() { issue_meta_json="$META"; return 0; }
_dispatch_preclaim_brief_scope() { printf REACHED_NEXT_GATE; return 1; }
gh() {
    local command="$1" endpoint="$2"
    [[ "$command $endpoint" == 'api repos/owner/repo/issues/42' ]] || return 1
    [[ "${FETCH_RC:-0}" == 0 ]] || return 1
    printf '%s' "$FRESH_META"
    return 0
}
'''
    fresh_issue = dict(issue, number=42, state='open')
    dispatch_env = dict(env, META=json.dumps(issue), FRESH_META=json.dumps(fresh_issue),
                        SCRIPT_DIR=str(scripts), LOGFILE=str(root / 'log'))
    invocation = function + stub + '\ndispatch_with_dedup 42 owner/repo title title runner "$1" prompt'
    result = subprocess.run(['bash', '-c', invocation, 'fixture', str(repo)],
                            env=dispatch_env, capture_output=True, text=True)
    assert result.returncode == 1 and not result.stdout and not result.stderr, result
    assert 'runner_capability_unmet' in (root / 'log').read_text()
    config.write_text(json.dumps({'dispatch_class_requirements': {'publish': {'secrets': ['GOOD']}}}))
    result = subprocess.run(['bash', '-c', invocation, 'fixture', str(repo)],
                            env=dispatch_env, capture_output=True, text=True)
    assert result.stdout == 'REACHED_NEXT_GATE' and not result.stderr, result
    print('PASS actual dispatch fails before scope/dedup/claim and capable runner proceeds')

    config.unlink()
    gates = (scripts / 'pulse-dispatch-worker-gates.sh').read_text()
    claim_function = re.search(r'(?ms)^_dlw_claim_lock_after_canary\(\) \{.*?^}', gates).group()
    claim_stub = '''
_ds_record() { return 0; }
_dedup_layer7_claim_lock() { printf CLAIM_WRITE; return 1; }
'''
    claim_invocation = claim_function + stub + claim_stub + '''
repo_path="$1"
_dlw_claim_lock_after_canary 42 owner/repo runner
'''
    for label, fresh, fetch_rc in (
        ('body edited after prefetch', dict(fresh_issue, body='requires-secrets: GOOD, MISSING'), 0),
        ('fresh read fails closed', fresh_issue, 1),
        ('malformed fresh metadata fails closed', {}, 0),
        ('closed fresh issue fails closed', dict(fresh_issue, state='closed'), 0),
        ('wrong fresh issue fails closed', dict(fresh_issue, number=43), 0),
    ):
        edited_env = dict(dispatch_env, FRESH_META=json.dumps(fresh), FETCH_RC=str(fetch_rc))
        result = subprocess.run(['bash', '-c', invocation, 'fixture', str(repo)],
                                env=edited_env, capture_output=True, text=True)
        assert result.returncode == 1 and not result.stdout and not result.stderr, (label, result)
        result = subprocess.run(['bash', '-c', claim_invocation, 'fixture', str(repo)],
                                env=edited_env, capture_output=True, text=True)
        assert result.returncode == 1 and not result.stdout and not result.stderr, (label, result)
        print('PASS', label)
        passed += 1
    result = subprocess.run(['bash', '-c', claim_invocation, 'fixture', str(repo)],
                            env=dispatch_env, capture_output=True, text=True)
    assert result.returncode == 0 and result.stdout == 'CLAIM_WRITE' and not result.stderr, result
    print('PASS final preclaim gate permits capable runner only')
    passed += 1
    log = (root / 'log').read_text()
    assert 'runner_capability_check source=fresh requirements=2' in log, log
    assert 'PRIVATE_' not in log and 'reason=secret_missing name=MISSING' in log, log

    # Exercise the shared fresh gate with inherited tool pipes and sockets.
    fresh_invocation = 'source "$1/runner-capability-helper.sh"; ' + stub + '''
runner_capability_check_fresh "$2" 42 owner/repo "$3"
'''
    for transport in ('pipe', 'socket', 'file'):
        for label, fresh, requirements, success in (
            ('capable', fresh_issue, None, True),
            ('malformed config without class label', dict(fresh_issue, labels=[]), malformed_config, True),
            ('malformed config with class label', fresh_issue, malformed_config, False),
            ('missing secret', dict(fresh_issue, body='requires-secrets: MISSING'), None, False),
            ('failed probe', fresh_issue, {'publish': {'probe': 'probe'}}, False),
            ('closed metadata', dict(fresh_issue, state='closed'), None, False),
        ):
            config.unlink(missing_ok=True)
            if isinstance(requirements, str):
                config.write_text(requirements)
            elif requirements is not None:
                probe.write_text('#!/usr/bin/env bash\nexit 1\n')
                config.write_text(json.dumps({'dispatch_class_requirements': requirements}))
            check_env = dict(dispatch_env, FRESH_META=json.dumps(fresh))
            destination = '/dev/stderr'
            if transport == 'file':
                destination = str(root / 'descriptor-log')
                Path(destination).write_text('existing audit\n')
            argv = ['bash', '-c', fresh_invocation, 'fixture', str(scripts), str(repo), destination]
            if transport == 'socket':
                reader, writer = socket.socketpair()
                with reader, writer:
                    result = subprocess.run(argv, env=check_env, stdout=subprocess.PIPE,
                                            stderr=writer, text=True)
                    writer.shutdown(socket.SHUT_WR)
                    diagnostics = reader.makefile().read()
            else:
                result = subprocess.run(argv, env=check_env, capture_output=True, text=True)
                diagnostics = result.stderr
            if transport == 'file':
                assert not diagnostics, result
                diagnostics = Path(destination).read_text()
                assert diagnostics.startswith('existing audit\n'), diagnostics
            assert (result.returncode == 0) == success, (transport, label, result, diagnostics)
            assert not result.stdout, result
            assert 'runner_capability_' in diagnostics, diagnostics
            assert 'No such device' not in diagnostics and 'PRIVATE_' not in diagnostics, diagnostics
            if not success:
                assert 'runner_capability_unmet' in diagnostics, diagnostics
            if label == 'malformed config with class label':
                assert 'reason=config_unreadable path=.aidevops.json' in diagnostics, diagnostics
                assert 'signal=config_unreadable cooldown=none' in diagnostics, diagnostics
            elif label in ('missing secret', 'failed probe'):
                signal = 'secret_missing' if label == 'missing secret' else 'probe_failed'
                assert f'signal={signal} cooldown=eligible' in diagnostics, diagnostics
            print('PASS fresh gate', transport, label)
            passed += 1
    config.unlink(missing_ok=True)
    result = subprocess.run(['bash', '-c', fresh_invocation, 'fixture', str(scripts),
                             str(repo), str(root / 'missing-parent' / 'log')],
                            env=dispatch_env, capture_output=True, text=True)
    assert result.returncode != 0 and not result.stdout, result
    print('PASS unusable audit log rejects admission')
    passed += 1

    # Re-sourcing at the admission/final gates retains state only for this cycle.
    calls = root / 'calls'
    cycle_log = root / 'cycle-log'
    cycle_env = dict(dispatch_env, CHECK_CALLS=str(calls),
                     FRESH_META=json.dumps(dict(fresh_issue, body='requires-secrets: LOCKED, SLOW')))
    watchdog = (scripts / 'pulse-watchdog.sh').read_text()
    timeout_function = re.search(r'(?ms)^run_stage_with_timeout\(\) \{.*?^}', watchdog).group()
    cycle_invocation = 'source "$1/runner-capability-helper.sh"; ' + stub + timeout_function + '''
_pulse_stage_cycle_timeout() { printf '%s' "$2"; return 0; }
LOGFILE="$3"
_PULSE_CYCLE_ID=first
run_stage_with_timeout first 20 runner_capability_check_fresh "$2" 42 owner/repo "$3" && exit 90
source "$1/runner-capability-helper.sh"
run_stage_with_timeout cached 20 runner_capability_check_fresh "$2" 42 owner/repo "$3" && exit 91
FRESH_META='{"number":42,"state":"open","labels":[],"body":""}'
runner_capability_check_fresh "$2" 42 owner/repo "$3" || exit 92
FRESH_META="$META_LOCKED"
_PULSE_CYCLE_ID=second
run_stage_with_timeout parallel-a 20 runner_capability_check_fresh "$2" 42 owner/repo "$3" &
first_pid=$!
run_stage_with_timeout parallel-b 20 runner_capability_check_fresh "$2" 42 owner/repo "$3" &
second_pid=$!
wait "$first_pid" && exit 93
wait "$second_pid" && exit 94
exit 0
'''
    cycle_env['META_LOCKED'] = cycle_env['FRESH_META']
    result = subprocess.run(['bash', '-c', cycle_invocation, 'fixture', str(scripts),
                             str(repo), str(cycle_log)], env=cycle_env, capture_output=True, text=True)
    assert result.returncode == 0 and not result.stdout and not result.stderr, result
    assert calls.read_text().splitlines() == ['LOCKED', 'LOCKED'], calls.read_text()
    health_log = cycle_log.read_text()
    assert health_log.count('runner_health:') == 2, health_log
    assert health_log.count('source=cycle_cache') == 2 and health_log.count('secret_gated_deferred=2') == 2
    assert 'PRIVATE_' not in health_log, health_log
    print('PASS cycle cache skips remaining checks, permits ungated candidates and resets next cycle')
    passed += 1

    # The real status-only command suppresses values/errors and decrypts once.
    source = (scripts / 'secret-helper.sh').read_text()
    function = re.search(r'(?ms)^cmd_check\(\) \{.*?^}', source).group()
    for status in (0, 1):
        stub = 'has_gopass() { return 1; }\n'
        stub += 'cmd_get() { printf PRIVATE_VALUE; printf PRIVATE_ERROR >&2; return ' + str(status) + '; }\n'
        result = subprocess.run(['bash', '-c', stub + function + '\ncmd_check GOOD'], capture_output=True)
        assert result.returncode == status and not result.stdout and not result.stderr, result
    print('PASS secret status suppresses values and errors')
    # Exercise the complete production CLI with an isolated synthetic store/HOME.
    gopass = bin_dir / 'gopass'
    gopass.write_text('''#!/usr/bin/env bash
case "$1" in
ls)
    [[ "${2:-}" != --flat ]] || printf 'aidevops/GOOD\\n'
    exit 0 ;;
show)
    printf 'decrypt\\n' >>"$CHECK_CALLS"
    [[ "$FIXTURE_STATUS" != hang ]] || exec sleep 10
    printf '%s' "$FIXTURE_VALUE"
    printf PRIVATE_ERROR >&2
    exit "$FIXTURE_STATUS" ;;
esac
exit 1
''')
    gopass.chmod(0o700)
    home = root / 'home'
    credentials = home / '.config/aidevops/credentials.sh'
    credentials.parent.mkdir(parents=True)
    credentials.write_text('export GOOD="STALE_PLAINTEXT"\nexport PLAINTEXT="PRIVATE_PLAINTEXT"\n')
    credentials.chmod(0o600)
    for status, value, name, expected in ((0, 'PRIVATE_VALUE', 'GOOD', 0),
                                          (1, '', 'GOOD', 3), (0, '', 'GOOD', 3),
                                          ('hang', '', 'GOOD', 3), (0, '', 'MISSING', 1),
                                          (0, '', 'PLAINTEXT', 0)):
        calls.write_text('')
        result = subprocess.run(['bash', str(scripts / 'secret-helper.sh'), 'check', name],
                                env=dict(env, HOME=str(home), CHECK_CALLS=str(calls),
                                         FIXTURE_VALUE=value, FIXTURE_STATUS=str(status)),
                                capture_output=True, timeout=7)
        assert result.returncode == expected and not result.stdout and not result.stderr, result
        assert calls.read_text().splitlines() == (['decrypt'] if name == 'GOOD' else []), calls.read_text()
    print('PASS gopass readable/unreadable/empty statuses decrypt once without plaintext fallback')
    print(f'{passed + 2} capability fixtures passed')
PY
