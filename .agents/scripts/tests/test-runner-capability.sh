#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$SCRIPT_DIR" <<'PY'
import json
import hashlib
import fcntl
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
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
if [[ "$1 $2" == 'secret get' ]]; then
    [[ "$3" != ZFAIL ]] || exit 2
    printf '%s\\n' "${STORED_VALUE:-PRIVATE_VALUE}"
    exit 0
fi
[[ "$1 $2" == 'secret check' ]] || exit 99
[[ -z "${CHECK_CALLS:-}" ]] || printf '%s\\n' "$3" >>"$CHECK_CALLS"
[[ -z "${CHECK_DELAY:-}" ]] || sleep "$CHECK_DELAY"
[[ -z "${CHECK_STATUS:-}" ]] || exit "$CHECK_STATUS"
[[ "$3" != SLOW ]] || exec sleep 10
[[ "$3" != TIMEDOUT ]] || exit 5
[[ "$3" != LOCKED ]] || exit 3
printf 'PRIVATE_VALUE\n'
printf 'PRIVATE_ERROR\n' >&2
[[ "$3" == GOOD ]]
''')
    cli.chmod(0o700)
    env = dict(os.environ, HOME=str(root), PATH=str(bin_dir) + ':' + os.environ['PATH'],
               AIDEVOPS_TEMP_DIR=str(root / 'workspace-temp'),
               AIDEVOPS_RUNNER_CAPABILITY_SECRET_TIMEOUT_SECONDS='2')
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
        return result.stdout

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
    # Exercise final-text capture and the real runtime release entry, without
    # GitHub writes. A rejection on issue A must defer unrelated issue B too.
    output = root / 'worker-output'
    output.write_text('BLOCKED: sign-in rejected\n'
                      'TERMINAL_BLOCKER_REASON=runner_capability_unmet\n'
                      'TERMINAL_BLOCKER_REJECTED_SECRETS=GOOD\n')
    release = '''
source "$1/terminal-blocker-circuit.sh"
source "$1/headless-runtime-failure.sh"
terminal_blocker_capture_output "$2" || exit 1
_hrff_prepare_terminal_blocker_release() { return 0; }
_hrff_apply_terminal_permission_hold() { return 0; }
_hrff_handle_terminal_blocker_release 1 owner/repo receipt
'''
    def record_rejection():
        result = subprocess.run(['bash', '-c', release, 'fixture', str(scripts), str(output)],
                                env=env, capture_output=True, text=True)
        assert result.returncode == 0 and not result.stdout and not result.stderr, result

    record_rejection()
    state_path = root / '.aidevops/cache/secret-rejections/state.json'
    advisory = root / '.aidevops/advisories/secret-rejected-GOOD.advisory'
    first_state, first_notice = state_path.read_bytes(), advisory.stat().st_mtime_ns
    record_rejection()
    assert state_path.read_bytes() == first_state and advisory.stat().st_mtime_ns == first_notice
    assert 'aidevops secret set GOOD' in advisory.read_text()
    assert 'PRIVATE_VALUE' not in state_path.read_text() + advisory.read_text()
    check('recorded rejection defers a different issue',
          {'number': 2, 'body': 'requires-secrets: GOOD'}, success=False,
          reason='secret_rejected name=GOOD')
    check('unrelated secret is still admitted', {'body': ''})
    # The unrelated name is present, so only its ordinary presence check runs.
    cli_text = cli.read_text()
    cli.write_text(cli_text.replace('[[ "$3" == GOOD ]]', '[[ "$3" == GOOD || "$3" == OTHER ]]'))
    check('unrelated required secret is still admitted', {'body': 'requires-secrets: OTHER'})
    env['STORED_VALUE'] = 'PRIVATE_REFRESHED_VALUE'
    check('changed stored value re-arms rejection', {'body': 'requires-secrets: GOOD'})
    assert json.loads(state_path.read_text()) == {}
    record_rejection()
    state = json.loads(state_path.read_text())
    state['GOOD']['time'] -= 86401
    state_path.write_text(json.dumps(state))
    check('expired rejection re-arms unchanged value', {'body': 'requires-secrets: GOOD'})
    assert 'PRIVATE_' not in state_path.read_text() + advisory.read_text()
    env.pop('STORED_VALUE')
    # A second failed lookup must not discard the first durable marker.
    result = subprocess.run(['python3', str(scripts / 'runner-secret-rejection.py'),
                             'record', 'GOOD', 'ZFAIL'], env=env, capture_output=True, text=True)
    assert result.returncode == 1 and 'PRIVATE_' not in result.stdout + result.stderr, result
    assert 'GOOD' in json.loads(state_path.read_text())
    check('partial record retains successful marker', {'body': 'requires-secrets: GOOD'},
          success=False, reason='secret_rejected name=GOOD')
    state = json.loads(state_path.read_text())
    state['GOOD']['time'] -= 86401
    state_path.write_text(json.dumps(state))
    check('partial marker also expires', {'body': 'requires-secrets: GOOD'})
    # Tool output cannot declare rejection; only final assistant text can.
    output.write_text(json.dumps({'type': 'tool', 'text':
        'BLOCKED: rejected\nTERMINAL_BLOCKER_REASON=runner_capability_unmet\n'
        'TERMINAL_BLOCKER_REJECTED_SECRETS=GOOD'}))
    result = subprocess.run(['bash', '-c', release, 'fixture', str(scripts), str(output)],
                            env=env, capture_output=True, text=True)
    assert result.returncode == 1 and json.loads(state_path.read_text()) == {}, result
    print('PASS partial record privacy and tool-output rejection boundary')
    check('locked secret timeout defers', issue, {'publish': {'secrets': ['SLOW']}}, False,
          'check_timeout name=SLOW')
    check('inner secret timeout defers', {'body': 'requires-secrets: TIMEDOUT'}, success=False,
          reason='check_timeout name=TIMEDOUT')
    check('unreadable secret defers', {'body': 'requires-secrets: LOCKED'}, success=False,
          reason='secret_unreadable name=LOCKED store=gopass fallback=disabled')
    check('brief requirement defers', {'body': 'requires-secrets: MISSING'}, success=False,
          reason='secret_missing name=MISSING')
    check('brief comma/space names proceed', {'body': 'requires-secrets: GOOD, GOOD'})
    check('label requirement defers', {'labels': ['needs-secret:MISSING']}, success=False,
          reason='secret_missing name=MISSING')
    check('label never replaces brief requirements',
          {'labels': [{'name': 'needs-secret:GOOD'}], 'body': 'requires-secrets: MISSING'},
          success=False, reason='secret_missing name=MISSING')
    check('label never replaces body marker requirements',
          {'labels': ['needs-secret:GOOD'], 'body': '<!-- aidevops:needs-secrets MISSING -->'},
          success=False, reason='secret_missing name=MISSING')
    check('body never replaces label requirements',
          {'labels': ['needs-secret:MISSING'], 'body': 'requires-secrets: GOOD'},
          success=False, reason='secret_missing name=MISSING')
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
    # GH#37587: requires-tools resolves bare names on PATH and never runs them.
    marker = root / 'tool-ran'
    tool = bin_dir / 'fixture-tool'
    tool.write_text(f'#!/usr/bin/env bash\ntouch {marker}\n')
    tool.chmod(0o700)
    check('present PATH tool proceeds', {'body': 'requires-tools: sh, fixture-tool'})
    assert not marker.exists(), 'requires-tools executed the tool'
    check('missing PATH tool defers', {'body': 'requires-tools: sh definitely-not-installed-xyz'},
          success=False, reason='tool_missing name=definitely-not-installed-xyz')
    check('tool path is rejected', {'body': 'requires-tools: /bin/sh'}, success=False,
          reason='invalid_requirements')
    check('tool argument text is rejected', {'body': 'requires-tools: sh;touch'}, success=False,
          reason='invalid_requirements')
    check('empty tool list is rejected', {'body': 'requires-tools:'}, success=False,
          reason='invalid_requirements')
    check('more than eight tools is rejected',
          {'body': 'requires-tools: ' + ' '.join(f't{n}' for n in range(9))}, success=False,
          reason='invalid_requirements')
    check('class tools combine with brief tools', issue,
          {'publish': {'tools': ['definitely-not-installed-xyz']}}, False,
          'tool_missing name=definitely-not-installed-xyz')
    # GH#38825: a missing repo root is named, not reported as invalid_requirements.
    missing = subprocess.run(['bash', '-c',
        'source "$1/runner-capability-helper.sh"; runner_capability_check "$2" "$3"',
        'fixture', str(scripts), str(root / 'no-such-repo'), json.dumps(issue)],
        env=env, capture_output=True, text=True)
    assert missing.returncode != 0 and missing.stdout == 'runner_capability_unmet reason=repo_path_missing\n', missing
    passed += 1
    print('PASS missing repo root reports repo_path_missing')
    # GH#37638: requires-loopback-health probes a fixed 127.0.0.1 port only.
    import http.server
    import threading

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200 if self.path == '/health' else 503)
            self.end_headers()

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    live = server.server_address[1]
    if live < 1024:
        raise SystemExit('ephemeral port below 1024')
    with socket.socket() as closed_socket:
        closed_socket.bind(('127.0.0.1', 0))
        closed = closed_socket.getsockname()[1]
    check('healthy loopback service proceeds', {'body': f'requires-loopback-health: {live}/health'})
    check('closed loopback port defers', {'body': f'requires-loopback-health: {closed}/health'},
          success=False, reason=f'service_unhealthy port={closed}')
    check('non-2xx loopback response defers', {'body': f'requires-loopback-health: {live}/other'},
          success=False, reason=f'service_unhealthy port={live}')
    check('class loopback_health combines', issue, {'publish': {'loopback_health': [f'{closed}/health']}},
          False, f'service_unhealthy port={closed}')
    for bad in (f'127.0.0.1:{live}/health', f'{live}/../health', '80/health',
                f'http://127.0.0.1:{live}/health', f'{live}/health?x=1', '70000/health',
                f'{live}/' + 'a' * 65, ''):
        check(f'invalid loopback value {bad[:20]!r} is rejected',
              {'body': f'requires-loopback-health: {bad}'}, success=False,
              reason='invalid_requirements')
    check('more than four loopback entries is rejected',
          {'body': 'requires-loopback-health: ' + ' '.join(f'{live + n}/h' for n in range(5))},
          success=False, reason='invalid_requirements')
    server.shutdown()

    # requires-device: only the runner holding the matching device id proceeds.
    device_file = root / 'device-id'
    device_file.write_text('device-1783820013-77368-17015\n')
    env['AIDEVOPS_DEVICE_ID_FILE'] = str(device_file)
    check('matching device id proceeds', {'body': 'requires-device: device-1783820013-77368-17015'})
    check('matching id in list proceeds',
          {'body': 'requires-device: device-1-2-3, device-1783820013-77368-17015'})
    check('non-matching device id defers', {'body': 'requires-device: device-1-2-3'},
          success=False, reason='device_mismatch')
    check('device check precedes secret reads',
          {'body': 'requires-device: device-1-2-3\nrequires-secrets: MISSING'},
          success=False, reason='device_mismatch')
    for bad in ('not-a-device', 'device-1-2', 'device-1-2-3;x', ''):
        check(f'malformed device id {bad!r} is rejected', {'body': f'requires-device: {bad}'},
              success=False, reason='invalid_requirements')
    check('more than four device ids is rejected',
          {'body': 'requires-device: ' + ' '.join(f'device-1-2-{n}' for n in range(5))},
          success=False, reason='invalid_requirements')
    env['AIDEVOPS_DEVICE_ID_FILE'] = str(root / 'missing-device-id')
    check('missing device file is unknown', {'body': 'requires-device: device-1-2-3'},
          success=False, reason='device_unknown')
    binary_device = root / 'binary-device-id'
    binary_device.write_bytes(b'\xff\xfe\x80')
    env['AIDEVOPS_DEVICE_ID_FILE'] = str(binary_device)
    check('undecodable device file is unknown', {'body': 'requires-device: device-1-2-3'},
          success=False, reason='device_unknown')
    check('issue without device line is unaffected', {'body': ''})
    env['AIDEVOPS_DEVICE_ID_FILE'] = str(device_file)
    deferral = subprocess.run(['bash', '-c',
        'source "$1/runner-capability-helper.sh"; '
        '_runner_capability_log_deferral 42 owner/repo "runner_capability_unmet reason=$2" "" 3>&1',
        'fixture', str(scripts), 'device_mismatch'], env=env, capture_output=True, text=True)
    assert 'signal=device_mismatch cooldown=eligible' in deferral.stdout, deferral
    device_file.write_bytes(b'\xff\xfe\n')
    decoding_verdict = check('undecodable device file is unknown',
                             {'body': 'requires-device: device-1-2-3'},
                             success=False, reason='device_unknown')
    unknown = subprocess.run(['bash', '-c',
        'source "$1/runner-capability-helper.sh"; '
        '_runner_capability_log_deferral 42 owner/repo "$2" "" 3>&1',
        'fixture', str(scripts), decoding_verdict.strip()], env=env, capture_output=True, text=True)
    assert 'signal=device_unknown cooldown=none' in unknown.stdout, unknown
    device_file.write_text('device-1783820013-77368-17015\n')
    check('repaired device file proceeds', {'body': 'requires-device: device-1783820013-77368-17015'})
    print('PASS device_mismatch deferral is cooldown=eligible')

    # Exercise the actual dispatch entry function, stopping at the next gate.
    # A capability failure must never reach a scope write, dedup or claim.
    core = (scripts / 'pulse-dispatch-core.sh').read_text()
    function = re.search(r'(?ms)^dispatch_with_dedup\(\) \{.*?^}', core).group()
    config.write_text(json.dumps({'dispatch_class_requirements': {'publish': {'secrets': ['MISSING']}}}))
    stub = '''
_ds_now_ns() { printf 0; return 0; }
_dlw_sealed_hold_active() { return 1; }
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
            ('missing tool', dict(fresh_issue, body='requires-tools: definitely-not-installed-xyz'), None, False),
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
            elif label in ('missing secret', 'missing tool', 'failed probe'):
                signal = {'missing secret': 'secret_missing', 'missing tool': 'tool_missing'}.get(
                    label, 'probe_failed')
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

    # GH#40077: an unsatisfiable repo Node pin defers before any issue read or
    # claim, caches the verdict, and reopens when the requirement is met.
    node_repo = root / 'node-repo'
    node_repo.mkdir()
    fake_node = root / 'fake-node-bin'
    fake_node.mkdir()
    (fake_node / 'node').write_text('#!/usr/bin/env bash\nprintf "v98.0.0\\n"\n')
    (fake_node / 'node').chmod(0o700)
    gh_calls = root / 'node-gh-calls'
    node_log = root / 'node-log'
    node_env = dict(dispatch_env, GH_CALLS=str(gh_calls), PATH=str(fake_node) + ':' + env['PATH'],
                    AIDEVOPS_NODE_BREW_PREFIXES=str(root / 'no-brew'), N_PREFIX=str(root / 'no-n'))
    node_invocation = 'source "$1/runner-capability-helper.sh"; ' + '''
gh() { printf 'gh\\n' >>"$GH_CALLS"; printf '%s' "$FRESH_META"; return 0; }
runner_capability_check_fresh "$2" 42 owner/repo "$3"
'''
    def node_gate(pin):
        (node_repo / '.nvmrc').write_text(pin + '\n')
        return subprocess.run(['bash', '-c', node_invocation, 'fixture', str(scripts),
                               str(node_repo), str(node_log)],
                              env=node_env, capture_output=True, text=True)
    for attempt in ('computed', 'cached'):
        result = node_gate('99')
        assert result.returncode == 1 and not result.stdout and not result.stderr, (attempt, result)
        assert not gh_calls.exists(), (attempt, gh_calls.read_text())
    node_text = node_log.read_text()
    assert node_text.count('reason=node_unsatisfied active=v98.0.0 required="99"') == 2, node_text
    assert node_text.count('signal=node_unsatisfied cooldown=none') == 2, node_text
    assert node_text.count('runner_health: node v98.0.0 cannot satisfy node-repo') == 1, node_text
    assert node_text.count('source=node_cache') == 1, node_text
    result = node_gate('98')
    assert result.returncode == 0 and not result.stdout and not result.stderr, result
    assert gh_calls.read_text().splitlines() == ['gh'], gh_calls.read_text()
    print('PASS unsatisfiable repo Node pin defers before any issue read, caches, and reopens when met')
    passed += 1

    # GH#40104: the gate reads the pin from the remote default ref, not a stale
    # canonical working tree.
    stale_repo = root / 'stale-repo'
    stale_repo.mkdir()
    git_env = dict(node_env, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@example.invalid',
                   GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@example.invalid')
    def git(*args):
        subprocess.run(['git', '-C', str(stale_repo), *args], env=git_env, check=True,
                       capture_output=True, text=True)
    git('init', '-q')
    (stale_repo / '.nvmrc').write_text('99\n')
    git('add', '.nvmrc')
    git('commit', '-q', '-m', 'pin 99')
    git('update-ref', 'refs/remotes/origin/main', 'HEAD')
    (stale_repo / '.nvmrc').write_text('98\n')  # stale working tree pin
    node_repo = stale_repo
    gh_calls.unlink(missing_ok=True)
    node_log.unlink(missing_ok=True)
    def stale_gate():
        return subprocess.run(['bash', '-c', node_invocation, 'fixture', str(scripts),
                               str(stale_repo), str(node_log)],
                              env=node_env, capture_output=True, text=True)
    result = stale_gate()
    assert result.returncode == 1 and not gh_calls.exists(), result
    assert 'reason=node_unsatisfied active=v98.0.0 required="99"' in node_log.read_text()
    (stale_repo / '.nvmrc').write_text('98\n')
    git('commit', '-q', '-am', 'pin 98')
    git('update-ref', 'refs/remotes/origin/main', 'HEAD')
    result = stale_gate()
    assert result.returncode == 0 and not result.stdout and not result.stderr, result
    print('PASS stale canonical pin does not mask a newer remote default-branch pin')
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
_pulse_stage_fuse_claim() { return 1; }
_pulse_stage_note_start() { return 0; }
_pulse_stage_record_timing() { return 0; }
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

    # Expiry retries once under the lock; timeouts do not retain stale metadata.
    cycle_file = root / 'workspace-temp/runner-capability' / (hashlib.sha256(b'first').hexdigest() + '.json')
    state = json.loads(cycle_file.read_text())
    state['at'] = 0
    cycle_file.write_text(json.dumps(state))
    calls.write_text('')
    def direct_cycle(name):
        return subprocess.run(['bash', '-c', 'source "$1/runner-capability-helper.sh"; '
                               '_PULSE_CYCLE_ID=first; runner_capability_check "$2" "$3" fresh',
                               'fixture', str(scripts), str(repo),
                               json.dumps({'body': 'requires-secrets: ' + name})],
                              env=cycle_env, capture_output=True, text=True)
    result = direct_cycle('TIMEDOUT')
    assert result.returncode == 1 and 'check_timeout name=TIMEDOUT' in result.stdout, result
    assert not cycle_file.read_text(), cycle_file.read_text()
    assert direct_cycle('GOOD').returncode == 0
    assert calls.read_text().splitlines() == ['TIMEDOUT', 'GOOD']
    print('PASS expired cache rechecks and timeout does not cache')

    # GH#40166: independent Pulse processes share only positive name/timestamp
    # metadata. The existing locked-store and timeout fixtures above stay intact.
    host_env = dict(cycle_env, AIDEVOPS_TEMP_DIR=str(root / 'host-cache'))
    host_file = root / 'host-cache/runner-capability/readable.json'
    def host_check(cycle, extra=None, parallel=False):
        argv = ['bash', '-c', 'source "$1/runner-capability-helper.sh"; '
                '_PULSE_CYCLE_ID="$4"; runner_capability_check "$2" "$3" fresh',
                'fixture', str(scripts), str(repo),
                json.dumps({'body': 'requires-secrets: GOOD, OTHER'}), cycle]
        options = dict(env=dict(host_env, **(extra or {})), stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, text=True)
        return subprocess.Popen(argv, **options) if parallel else subprocess.run(argv, **options)

    calls.write_text('')
    assert host_check('host-first').returncode == 0
    result = host_check('host-second')
    assert result.returncode == 0 and 'reused=2 checked=0' in result.stderr, result
    assert calls.read_text().splitlines() == ['GOOD', 'OTHER'], calls.read_text()
    metadata = json.loads(host_file.read_text())
    assert set(metadata) == {'GOOD', 'OTHER'}, metadata
    assert all(re.fullmatch(r'[A-Z][A-Z0-9_]*', name) and
               isinstance(at, (int, float)) and not isinstance(at, bool)
               for name, at in metadata.items()), metadata
    assert 'PRIVATE_' not in host_file.read_text()
    assert host_file.stat().st_mode & 0o777 == 0o600
    print('PASS different cycles reuse host names and timestamps without value bytes')
    passed += 1

    host_file.write_text(json.dumps({'GOOD': 0, 'OTHER': 0, 'bad-name': time.time()}))
    calls.write_text('')
    assert host_check('host-expired').returncode == 0
    assert calls.read_text().splitlines() == ['GOOD', 'OTHER']
    assert set(json.loads(host_file.read_text())) == {'GOOD', 'OTHER'}
    for index, (status, reason) in enumerate(((1, 'secret_missing'), (3, 'secret_unreadable'),
                                             (5, 'check_timeout'), (2, 'check_failed'))):
        host_file.write_text(json.dumps({'GOOD': 0, 'OTHER': time.time()}))
        result = host_check(f'host-failure-{index}', {'CHECK_STATUS': str(status)})
        assert result.returncode == 1 and f'reason={reason} name=GOOD' in result.stdout, result
        assert 'GOOD' not in json.loads(host_file.read_text())
    print('PASS expired host entries recheck and every failed check removes the name')
    passed += 1

    host_file.write_text('{}')
    calls.write_text('')
    processes = [host_check(f'host-parallel-{i}', {'CHECK_DELAY': '0.4'}, parallel=True)
                 for i in range(4)]
    for process in processes:
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 0 and not stdout and 'PRIVATE_' not in stderr, (stdout, stderr)
    assert calls.read_text().splitlines() == ['GOOD', 'OTHER'], calls.read_text()
    print('PASS concurrent independent cycles decrypt each name once under the host lock')
    passed += 1

    host_file.write_text('{}')
    calls.write_text('')
    with host_file.open('r+') as locked:
        fcntl.flock(locked, fcntl.LOCK_EX)
        started = time.monotonic()
        result = host_check('host-lock-timeout',
                            {'AIDEVOPS_RUNNER_CAPABILITY_SECRET_TIMEOUT_SECONDS': '1'})
        assert result.returncode == 0 and time.monotonic() - started < 6, result
        assert calls.read_text().splitlines() == ['GOOD', 'OTHER']
    print('PASS host lock timeout falls back to bounded direct checks')
    passed += 1

    host_file.chmod(0o644)
    result = host_check('host-unsafe-mode')
    assert result.returncode == 1 and 'cycle_state_unreadable' in result.stdout, result
    host_file.chmod(0o600)
    host_file.unlink()
    target = root / 'host-symlink-target'
    target.write_text('unchanged')
    host_file.symlink_to(target)
    result = host_check('host-symlink')
    assert result.returncode == 1 and target.read_text() == 'unchanged', result
    host_file.unlink()
    print('PASS host cache rejects unsafe permissions and symlink targets')
    passed += 1

    # The real status-only command suppresses values/errors and decrypts once.
    source = (scripts / 'secret-helper.sh').read_text()
    function = re.search(r'(?ms)^cmd_check\(\) \{.*?^}', source).group()
    for status in (0, 1):
        stub = 'has_gopass() { return 1; }\n'
        stub += 'resolve_injection_source() { return 1; }\n'
        stub += 'get_secret_value() { printf PRIVATE_VALUE; printf PRIVATE_ERROR >&2; return ' + str(status) + '; }\n'
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
    [[ "$FIXTURE_STATUS" != slow ]] || sleep 5
    printf '%s' "$FIXTURE_VALUE"
    printf PRIVATE_ERROR >&2
    [[ "$FIXTURE_STATUS" != slow ]] || exit 0
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
                                          ('hang', '', 'GOOD', 5), ('slow', 'PRIVATE_VALUE', 'GOOD', 0),
                                          (0, '', 'MISSING', 1),
                                          (0, '', 'PLAINTEXT', 0)):
        calls.write_text('')
        result = subprocess.run(['bash', str(scripts / 'secret-helper.sh'), 'check', name],
                                env=dict(env, HOME=str(home), CHECK_CALLS=str(calls),
                                         FIXTURE_VALUE=value, FIXTURE_STATUS=str(status),
                                         AIDEVOPS_SECRET_READ_TIMEOUT_SECONDS='6' if status == 'slow' else '1'),
                                capture_output=True, timeout=9)
        assert result.returncode == expected and not result.stdout and not result.stderr, result
        assert calls.read_text().splitlines() == (['decrypt'] if name == 'GOOD' else []), calls.read_text()
    print('PASS gopass readable/unreadable/empty statuses decrypt once without plaintext fallback')
    print(f'{passed + 2} capability fixtures passed')
PY
