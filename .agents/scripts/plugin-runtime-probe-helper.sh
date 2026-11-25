#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Bash 3.2 entry point; Python owns private artifacts and child process cleanup.
# Requires python3, jq and opencode. No packages are installed by this helper.
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile


def interrupted(signum, frame):
    raise InterruptedError("probe interrupted")


def run(command, cwd, env, timeout):
    # Kill the entire owned process group, including model/MCP descendants.
    # Regular files avoid OpenCode truncating large debug output at process.exit.
    with tempfile.TemporaryFile(dir=str(cwd)) as stdout, tempfile.TemporaryFile(dir=str(cwd)) as stderr:
        child = subprocess.Popen(command, cwd=str(cwd), env=env,
                                 stdin=subprocess.DEVNULL, stdout=stdout,
                                 stderr=stderr, start_new_session=True)
        try:
            child.wait(timeout=timeout)
            stdout.seek(0)
            stderr.seek(0)
            return child.returncode, stdout.read(), stderr.read()
        finally:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()


def main():
    parser = argparse.ArgumentParser(description=(
        "Run trusted TSV permission probes in isolated OpenCode sessions. "
        "TSV: id<TAB>step|step. Each row gets a fresh session. "
        "Outputs are content-free: arbitrary tool input/output may contain secrets. "
        "Only report.jsonl and sanitized probe events survive, including on failure."))
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--worktree', type=Path)
    mode.add_argument('--baseline', action='store_true')
    parser.add_argument('--probes', type=Path, required=True)
    parser.add_argument('--model', help='defaults to routed worker model, then configured model')
    parser.add_argument('--out', type=Path, help='new private directory (must not exist)')
    parser.add_argument('--timeout', type=int, default=180, help='seconds per session')
    parser.add_argument('--config-query', action='append', choices=[
        '.plugin', '.permission.external_directory | keys'],
        help='repeatable safe resolved-config selector; default: .plugin')
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error('--timeout must be positive')
    for tool in ('jq', 'opencode'):
        if not shutil.which(tool):
            parser.error('required executable unavailable: ' + tool)
    probes = []
    for line in args.probes.read_text().splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        probe_id, separator, steps = line.partition('\t')
        if not separator or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', probe_id) or not steps.strip():
            parser.error('expected id<TAB>step|step with safe unique id')
        if any(item[0] == probe_id for item in probes):
            parser.error('duplicate probe id')
        probes.append((probe_id, steps))
    if not probes:
        parser.error('probe file is empty')

    home = Path.home()
    worktree = (args.worktree or Path(os.environ.get('WORKER_WORKTREE_PATH', os.getcwd()))).resolve()
    plugin = ((worktree / '.agents/plugins/opencode-aidevops/index.mjs') if args.worktree else
              home / '.aidevops/agents/plugins/opencode-aidevops/index.mjs')
    if not worktree.is_dir() or not plugin.is_file():
        parser.error('worktree or selected plugin is unavailable')
    plugin_url = plugin.resolve().as_uri()
    config_home = Path(os.environ.get('XDG_CONFIG_HOME', str(home / '.config')))
    data_home = Path(os.environ.get('XDG_DATA_HOME', str(home / '.local/share')))
    config = config_home / 'opencode/opencode.json'
    if not config.is_file():
        parser.error('global opencode.json is required (JSON; convert JSONC before probing)')
    os.umask(0o077)
    if args.out:
        root = args.out.absolute()
        if not root.parent.is_dir():
            parser.error('--out parent must exist')
        root.mkdir(mode=0o700)  # Never delete or reuse caller-owned directories.
    else:
        parent = Path(os.environ.get('AIDEVOPS_TEMP_DIR', str(home / '.aidevops/.agent-workspace/tmp')))
        if not parent.is_dir():
            parser.error('private temporary parent must exist')
        root = Path(tempfile.mkdtemp(prefix='plugin-runtime-probe-', dir=str(parent)))

    def emit(record):
        line = json.dumps(record, ensure_ascii=True)
        with (root / 'report.jsonl').open('a') as report:
            report.write(line + '\n')
        print(line, flush=True)

    def safe_label(value):
        # Labels, not arbitrary provider messages, paths, commands or payloads.
        return value if isinstance(value, str) and re.fullmatch(r'[a-zA-Z0-9_.:-]{1,80}', value) else 'redacted'

    result = 1
    try:
        emit({'report': str(root / 'report.jsonl')})
        cfg = root / 'cfg/opencode'
        cfg.mkdir(parents=True)
        data = root / 'data/opencode'
        data.mkdir(parents=True)
        cwd = root / 'project'
        cwd.mkdir()
        for name in ('agent', 'command', 'tool', 'skills', 'themes', 'node_modules',
                     'package.json', 'bun.lock', 'AGENTS.md', 'tui.json'):
            source = config_home / 'opencode' / name
            if source.exists():
                (cfg / name).symlink_to(source.resolve(), target_is_directory=source.is_dir())
        (root / 'cfg/aidevops').symlink_to(config_home / 'aidevops', target_is_directory=True)
        # jq preserves all existing provider and permission settings, replacing plugins only.
        code, output, _ = run(['jq', '--arg', 'p', plugin_url, '.plugin = [$p]', str(config)],
                              cwd, os.environ.copy(), 30)
        if code:
            raise RuntimeError('global configuration is not valid JSON')
        (cfg / 'opencode.json').write_bytes(output)
        auth = data_home / 'opencode/auth.json'
        if auth.is_file():
            shutil.copyfile(str(auth), str(data / 'auth.json'))
            (data / 'auth.json').chmod(0o600)
        env = os.environ.copy()
        for key in list(env):
            if key.startswith(('WORKER_', 'DISPATCH_', 'AIDEVOPS_FULL_LOOP_', 'AIDEVOPS_ATTEMPT_',
                               'AIDEVOPS_SESSION_', 'AIDEVOPS_OPENCODE_SESSION_', 'OPENCODE_SESSION_')):
                env.pop(key, None)
        for key in ('OPENCODE_CONFIG', 'OPENCODE_CONFIG_CONTENT', 'OPENCODE_CONFIG_DIR',
                    'OPENCODE_PURE', 'OPENCODE_ATTACH', 'AIDEVOPS_SESSION_ORIGIN',
                    'AIDEVOPS_WORKER_ID', 'AIDEVOPS_PARENT_WORKER_ID', 'AIDEVOPS_ROOT_WORKER_ID',
                    'AIDEVOPS_CORRELATION_ID', 'AIDEVOPS_CAUSATION_ID',
                    'AIDEVOPS_PARENT_EVENT_ID', 'AIDEVOPS_ROOT_EVENT_ID'):
            env.pop(key, None)
        env.update(XDG_CONFIG_HOME=str(root / 'cfg'), XDG_DATA_HOME=str(root / 'data'),
                   XDG_CACHE_HOME=str(root / 'cache'), XDG_STATE_HOME=str(root / 'state'),
                   OPENCODE_DB_ACTIVITY_DIR=str(root / 'activity'),
                   AIDEVOPS_SESSION_BUS_DIR=str(root / 'session-bus'),
                   AIDEVOPS_WORK_DIR=str(root / 'work'),
                   OPENCODE_DISABLE_PROJECT_CONFIG='1', AIDEVOPS_HEADLESS='true',
                   WORKER_WORKTREE_PATH=str(worktree), WORKER_ISSUE_NUMBER='0',
                   WORKER_SESSION_KEY='plugin-probe-' + root.name,
                   AIDEVOPS_WORKER_BLOCKER_LOG_FILE=str(root / 'blockers.raw.jsonl'),
                   AIDEVOPS_PERMISSION_REQUEST_FILE=str(root / 'request.raw.json'))
        code, output, _ = run(['opencode', 'debug', 'config'], cwd, env, args.timeout)
        if code:
            raise RuntimeError('opencode debug config failed (details suppressed)')
        # Some plugins print startup notices before the pretty-printed config.
        text = re.sub(r'\x1b\[[0-9;]*m', '', output.decode('utf-8'))
        resolved = None
        for match in re.finditer(r'^\s*\{', text, re.MULTILINE):
            try:
                candidate, _ = json.JSONDecoder().raw_decode(text[match.end() - 1:])
            except ValueError:
                continue
            if isinstance(candidate, dict) and 'plugin' in candidate:
                resolved = candidate
                break
        if resolved is None:
            raise RuntimeError('resolved configuration JSON unavailable')
        if resolved.get('plugin') != [plugin_url]:
            raise RuntimeError('resolved plugin list is not exactly the selected plugin')
        for query in args.config_query or ['.plugin']:
            value = [plugin_url] if query == '.plugin' else sorted(
                (resolved.get('permission', {}).get('external_directory') or {}).keys())
            # These explicitly selected paths are the only resolved config disclosed.
            emit({'config_query': query, 'value': value})
        model = (args.model or env.get('AIDEVOPS_ROUTING_MODEL') or
                 os.environ.get('WORKER_MODEL') or resolved.get('model'))
        if not model or '/' not in model:
            raise RuntimeError('no provider/model configured; use --model')
        del resolved, output
        emit({'mode': 'head' if args.worktree else 'baseline', 'plugin_count': 1,
              'payload_policy': 'arbitrary input and output suppressed'})
        for probe_id, steps in probes:
            prompt = ('This is a bounded runtime permission probe, not an implementation task. '
                      'Execute only the following tool steps in order, once each. '
                      'Do not delegate, seek approval, retry a denied step, or modify files. '
                      'Stop after the steps or the first denial. Steps:\n' +
                      '\n'.join(steps.split('|')))
            code, output, _ = run(['opencode', 'run', '--format', 'json', '--model', model, prompt],
                                  cwd, env, args.timeout)
            tools = 0
            errors = 0
            for line in output.splitlines():
                try:
                    event = json.loads(line)
                except (ValueError, UnicodeDecodeError):
                    continue
                if event.get('type') == 'error':
                    errors += 1
                    emit({'probe': probe_id, 'session_error': safe_label(
                        (event.get('error') or {}).get('name'))})
                part = event.get('part') or {}
                if part.get('type') != 'tool':
                    continue
                tools += 1
                state = part.get('state') or {}
                payload = state.get('output', state.get('error', ''))
                tool_input = state.get('input') or {}
                input_kind = ('filePath' if 'filePath' in tool_input else
                              'command' if 'command' in tool_input else 'other')
                emit({'probe': probe_id, 'tool': safe_label(part.get('tool')),
                      'status': safe_label(state.get('status')),
                      'input': input_kind + ': [content suppressed]',
                      'output': '[content suppressed; {} characters]'.format(len(str(payload)))})
            emit({'probe': probe_id, 'exit_code': code, 'tool_events': tools, 'errors': errors})
            raw_events = root / 'blockers.raw.jsonl'
            if raw_events.exists():
                for line in raw_events.read_text().splitlines():
                    event = json.loads(line)
                    record = {'probe': probe_id, 'event': safe_label(event.get('event')),
                              'permission': safe_label(event.get('permission')),
                              'tool': safe_label(event.get('tool')),
                              'grantable': event.get('grantable') is True}
                    with (root / (probe_id + '.events.jsonl')).open('a') as target:
                        target.write(json.dumps(record) + '\n')
                    emit(record)
                raw_events.unlink()
            if errors or code != 0 or tools == 0:
                raise RuntimeError('probe session failed without usable tool evidence')
        result = 0
    except (Exception, KeyboardInterrupt) as error:
        # Never echo provider errors, credentials, config, prompts or raw stderr.
        emit({'harness': 'failed', 'error_type': type(error).__name__,
              'reason': str(error) if isinstance(error, RuntimeError) else 'details suppressed'})
    finally:
        # Do not let a second interrupt strand the auth/config copies mid-cleanup.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        for entry in root.iterdir():
            if entry.name == 'report.jsonl' or entry.name.endswith('.events.jsonl'):
                continue
            try:
                if entry.is_dir() and not entry.is_symlink():
                    shutil.rmtree(str(entry))
                else:
                    entry.unlink()
            except OSError:
                result = 1
                emit({'harness': 'failed', 'reason': 'private artifact cleanup failed'})
    if result == 0:
        emit({'harness': 'complete'})
    return result


signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
sys.exit(main())
PY
