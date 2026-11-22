#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Isolated install-record regression: no real installations or host scans.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$SCRIPT_DIR/../../.." <<'PY'
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1]).resolve()
helper = repo / '.agents/scripts/install-record-helper.sh'
base = Path(os.environ.get('AIDEVOPS_TEMP_DIR', str(Path.home() / '.aidevops/.agent-workspace/tmp')))
base.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='install-record-test-', dir=base) as directory:
    root = Path(directory)
    binary = root / '.local/bin'
    binary.mkdir(parents=True)
    ledger = root / 'state/installs.jsonl'
    # Construct PATH here, not in an inline runner command (GH#38574).
    env = dict(os.environ, AIDEVOPS_INSTALL_RECORD_FILE=str(ledger),
               AIDEVOPS_INSTALL_SCAN_ROOT=str(root), HOME=str(root),
               PATH=str(binary) + os.pathsep + os.environ['PATH'])

    def run(args, expected=0, environment=None):
        result = subprocess.run(args, env=environment or env, cwd=repo,
                                text=True, capture_output=True, timeout=90)
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        return result.stdout

    def executable(name, source):
        path = binary / name
        path.write_text('#!' + sys.executable + '\n' + source)
        path.chmod(0o700)
        return path

    broken = binary / 'broken-python'
    broken.write_text('#!' + str(root / 'removed-python') + '\n')
    broken.chmod(0o700)
    args = ['bash', str(helper), 'add', '--name', 'example', '--method', 'fixture',
            '--path', str(binary / 'example'), '--reason', 'Verification fixture', '--update', 'fixture manager']
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(lambda _: run(args), range(16)))
    records = [json.loads(row) for row in ledger.read_text().splitlines()]
    assert len(records) == 1 and records[0]['installer'] == 'session'
    assert len(records[0]['date']) > 20
    before = ledger.read_bytes()
    output = run(['bash', 'aidevops.sh', 'installs'])
    assert 'example' in output and 'broken shebang' in output and 'broken-python' in output
    assert 'fixture manager' in output and 'Verification fixture' in output
    assert before == ledger.read_bytes()
    assert 'installs' in run(['bash', 'aidevops.sh', 'help'])
    print('PASS: routed report/help, concurrent deduplication, broken shebang, read-only ledger')

    for unsafe in ['download --token=fixture', 'https://person:password@invalid.test', 'Bearer fixture', 'sk-' + 'fixturevalue']:
        rejected = args.copy()
        rejected[rejected.index('--reason') + 1] = unsafe
        run(rejected, expected=1)
        assert before == ledger.read_bytes()
    print('PASS: token-bearing metadata rejected without ledger writes')

    # Exercise real wired helper functions with package managers stubbed.
    utilities = root / 'utilities'
    utilities.mkdir()
    for name in ('bash', 'python3', 'dirname', 'uname', 'chmod', 'mkdir', 'grep', 'date', 'sed', 'tr', 'cat'):
        location = shutil.which(name)
        if location:
            (utilities / name).symlink_to(location)
    manager_env = dict(env, PATH=str(binary) + os.pathsep + str(utilities))
    executable('pipx', 'raise SystemExit(1)\n')
    executable('uv', '''import pathlib, sys
root = pathlib.Path(__file__).parent
if sys.argv[1:] == ['tool', 'dir', '--bin']:
    print(root)
elif sys.argv[1:3] == ['tool', 'install']:
    name = 'comfy' if sys.argv[-1] == 'comfy-cli' else 'yt-dlp'
    tool = root / name
    tool.write_text('#!' + sys.executable + '\\nprint("fixture tool")\\n')
    tool.chmod(0o700)
else:
    raise SystemExit(1)
''')
    for _ in range(2):
        run(['bash', '.agents/scripts/comfy-cli-helper.sh', 'install'], environment=manager_env)
    records = [json.loads(row) for row in ledger.read_text().splitlines()]
    comfy = [r for r in records if r['name'] == 'comfy-cli']
    assert len(comfy) == 1 and comfy[0]['method'] == 'uv-tool'
    assert comfy[0]['installer'] == 'comfy-cli-helper.sh'
    print('PASS: wired comfy-cli install and re-run produce exactly one attributed entry')

    source_cmd = 'source "$1"; install_record api fixture "$2" "Library fixture" "fixture manager"'
    run(['bash', '-eu', '-c', source_cmd, 'fixture-caller.sh', str(helper), str(binary / 'api')])
    assert json.loads(ledger.read_text().splitlines()[-1])['installer'] == 'session'
    print('PASS: sourceable library API under strict mode')

    yt = repo / '.agents/scripts/yt-dlp-helper.sh'
    run(['bash', '-eu', '-c', 'source "$1" help >/dev/null; install_ytdlp_isolated; install_ytdlp_isolated', 'fixture', str(yt)], environment=manager_env)
    records = [json.loads(row) for row in ledger.read_text().splitlines()]
    yt_records = [r for r in records if r['name'] == 'yt-dlp']
    assert len(yt_records) == 1 and yt_records[0]['update'] == 'uv tool upgrade yt-dlp'
    print('PASS: isolated yt-dlp install/upgrade attribution and deduplication')

    executable('brew', '''import pathlib, sys
tool = pathlib.Path(__file__).parent / 'mkcert'
tool.write_text('#!' + sys.executable + '\\n')
tool.chmod(0o700)
''')
    localdev = repo / '.agents/scripts/localdev-helper-init.sh'
    localdev_cmd = '''source "$1"
print_info() { :; }; print_success() { :; }; print_warning() { :; }; print_error() { return 1; }
ensure_mkcert; ensure_mkcert
'''
    run(['bash', '-eu', '-c', localdev_cmd, 'fixture', str(localdev)], environment=manager_env)
    records = [json.loads(row) for row in ledger.read_text().splitlines()]
    mkcert = [r for r in records if r['name'] == 'mkcert']
    assert len(mkcert) == 1 and mkcert[0]['method'] == 'brew'
    print('PASS: mkcert package install and already-installed re-run')

    executable('npm', 'print(' + repr(str(root / 'npm')) + ')\n')
    (root / 'npm/bin').mkdir(parents=True)
    (root / 'npm/bin/npm-fixture').write_text('fixture')
    (root / 'npm/bin/npm-fixture').chmod(0o700)
    # Real dpkg-query output: status abbreviation first; rc = removed, not purged.
    executable('dpkg-query', 'print("ii \\tabove\\t2.0\\nii \\tactive\\t2.0\\nrc \\tremoved\\t3.0")\n')
    policy = '''above:
  Installed: 2.0
  Candidate: 2.0
  Version table:
 *** 2.0 100
        100 /var/lib/dpkg/status
     1.0 500
        500 https://distro.invalid stable/main amd64 Packages
active:
  Installed: 2.0
  Candidate: 2.0
  Version table:
 *** 2.0 500
        500 https://distro.invalid stable/main amd64 Packages
        100 /var/lib/dpkg/status
removed:
  Installed: (none)
  Candidate: 1.0
  Version table:
     1.0 500
        500 https://distro.invalid stable/main amd64 Packages
'''
    executable('apt-cache', 'print(' + repr(policy) + ')\n')
    executable('dpkg', 'raise SystemExit(0)\n')
    live_queries = dict(env)
    del live_queries['AIDEVOPS_INSTALL_SCAN_ROOT']
    output = run(['bash', str(helper), 'report'], environment=live_queries)
    assert 'npm-fixture' in output and '- above 2.0' in output, output
    assert '- active 2.0' not in output, output
    assert '- removed' not in output and '(none)' not in output, output
    print('PASS: npm prefix discovery, disabled-source APT warning, removed packages skipped')

    # A translated parent locale must not change the labels parsed by the report.
    executable('apt-cache', 'import os\npolicy = ' + repr(policy) + '\n'
               'print(policy if os.environ.get("LC_ALL") == "C" else '
               'policy.replace("Installed:", "Installiert:"))\n')
    translated_queries = dict(live_queries, LC_ALL='de_DE.UTF-8', LANG='de_DE.UTF-8')
    output = run(['bash', str(helper), 'report'], environment=translated_queries)
    assert '- above 2.0' in output and '- active 2.0' not in output
    print('PASS: APT version warning under a translated parent locale')

    # Both older and installed versions can carry phased-update annotations.
    for phased_policy in (policy.replace('1.0 500', '1.0 500 (phased 10%)'),
                          policy.replace('2.0 500', '2.0 500 (phased 20%)')):
        executable('apt-cache', 'print(' + repr(phased_policy) + ')\n')
        output = run(['bash', str(helper), 'report'], environment=live_queries)
        assert '- above 2.0' in output and '- active 2.0' not in output
    print('PASS: phased APT headers retain correct source/version associations')

print('All isolated runtime checks passed')
PY
