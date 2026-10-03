#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$SCRIPT_DIR" <<'PY'
import json
import os
import re
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
[[ "$3" != SLOW ]] || exec sleep 10
printf 'PRIVATE_VALUE\n'
printf 'PRIVATE_ERROR\n' >&2
[[ "$3" == GOOD ]]
''')
    cli.chmod(0o700)
    env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'])
    config = repo / '.aidevops.json'
    passed = 0

    def check(label, issue, requirements=None, success=True):
        global passed
        if requirements is None:
            config.unlink(missing_ok=True)
        else:
            config.write_text(json.dumps({'dispatch_class_requirements': requirements}))
        result = subprocess.run(['bash', '-c',
            'source "$1/runner-capability-helper.sh"; runner_capability_check "$2" "$3"',
            'fixture', str(scripts), str(repo), json.dumps(issue)],
            env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == success, (label, result)
        assert result.stdout == ('' if success else 'runner_capability_unmet\n'), (label, result)
        assert not result.stderr, (label, result.stderr)
        passed += 1
        print('PASS', label)

    issue = {'labels': [{'name': 'dispatch-class:publish'}], 'body': ''}
    check('no declarations preserves dispatch', issue)
    check('missing secret defers', issue, {'publish': {'secrets': ['MISSING']}}, False)
    check('resolvable secret proceeds without output', issue, {'publish': {'secrets': ['GOOD']}})
    check('locked secret timeout defers', issue, {'publish': {'secrets': ['SLOW']}}, False)
    check('brief requirement defers', {'body': 'requires-secrets: MISSING'}, success=False)
    check('brief comma/space names proceed', {'body': 'requires-secrets: GOOD, GOOD'})
    check('brief and class combine', dict(issue, body='requires-secrets: MISSING'),
          {'publish': {'secrets': ['GOOD']}}, False)
    check('multiple classes combine', {'labels': ['dispatch-class:publish', 'dispatch-class:data']},
          {'publish': {'secrets': ['GOOD']}, 'data': {'secrets': ['MISSING']}}, False)
    check('malformed secret fails closed', issue, {'publish': {'secrets': 'GOOD'}}, False)
    check('invalid name fails closed', {'body': 'requires-secrets: GOOD;evil'}, success=False)
    probe = repo / 'probe'
    probe.write_text('#!/usr/bin/env bash\nprintf PRIVATE_DATA\nexit 0\n')
    probe.chmod(0o700)
    check('successful probe proceeds without output', issue, {'publish': {'probe': 'probe'}})
    probe.write_text('#!/usr/bin/env bash\nexit 1\n')
    check('stale data probe defers', issue, {'publish': {'probe': 'probe'}}, False)
    check('shell command is rejected', issue, {'publish': {'probe': 'probe; touch owned'}}, False)
    check('missing probe is rejected', issue, {'publish': {'probe': 'missing'}}, False)
    check('path traversal is rejected', issue, {'publish': {'probe': '../bin/aidevops'}}, False)
    (repo / 'escape').symlink_to(cli)
    check('escaping symlink is rejected', issue, {'publish': {'probe': 'escape'}}, False)
    probe.write_text('#!/usr/bin/env bash\nexec sleep 10\n')
    check('probe timeout defers', issue, {'publish': {'probe': 'probe'}}, False)

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
    assert 'PRIVATE_' not in log and 'MISSING' not in log, log

    # The real status-only command must suppress both successful values and errors.
    source = (scripts / 'secret-helper.sh').read_text()
    function = re.search(r'(?ms)^cmd_check\(\) \{.*?^}', source).group()
    for status in (0, 1):
        stub = 'cmd_get() { printf PRIVATE_VALUE; printf PRIVATE_ERROR >&2; return ' + str(status) + '; }\n'
        result = subprocess.run(['bash', '-c', stub + function + '\ncmd_check GOOD'], capture_output=True)
        assert result.returncode == status and not result.stdout and not result.stderr, result
    print('PASS secret status suppresses values and errors')
    print(f'{passed + 2} capability fixtures passed')
PY
