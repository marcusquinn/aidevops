#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../secret-helper.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "${TEST_ROOT}/bin"

cat >"${TEST_ROOT}/bin/gopass" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
	printf 'gopass synthetic fixture\n'
	exit 0
fi

if [[ "${1:-}" == "ls" || "${1:-}" == "list" ]]; then
	printf 'OUTPUT_TEST_SYNTHETIC\n'
	exit 0
fi

if [[ "${1:-}" == "show" || "${1:-}" == "cat" || " ${*} " == *" show "* ]]; then
	[[ "${AIDEVOPS_TEST_MISSING:-0}" != "1" ]] || exit 1
	printf '%s' "${AIDEVOPS_TEST_VALUE:-}"
	exit 0
fi
exit 1
SH
chmod +x "${TEST_ROOT}/bin/gopass"

PATH="${TEST_ROOT}/bin:${PATH}" python3 - "$HELPER" <<'PY'
import errno
import os
import pty
import subprocess
import sys
import termios

helper = sys.argv[1]
base_env = os.environ.copy()
fixture = "  synthetic%value  "


def environment(value: str, *, missing: bool = False) -> dict[str, str]:
    result = base_env.copy()
    result["AIDEVOPS_TEST_VALUE"] = value
    result["AIDEVOPS_TEST_MISSING"] = "1" if missing else "0"
    return result


def run_stream(value: str, *, missing: bool = False) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [helper, "get", "OUTPUT_TEST_SYNTHETIC"],
        env=environment(value, missing=missing),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def run_terminal(value: str) -> tuple[int, bytes, bytes]:
    master, slave = pty.openpty()
    attributes = termios.tcgetattr(slave)
    attributes[1] &= ~termios.OPOST
    termios.tcsetattr(slave, termios.TCSANOW, attributes)
    process = subprocess.Popen(
        [helper, "get", "OUTPUT_TEST_SYNTHETIC"],
        env=environment(value),
        stdin=subprocess.DEVNULL,
        stdout=slave,
        stderr=subprocess.PIPE,
    )
    os.close(slave)
    output = bytearray()
    while True:
        try:
            chunk = os.read(master, 4096)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        output.extend(chunk)
    os.close(master)
    stderr = process.communicate()[1]
    return process.returncode, bytes(output), stderr


stream = run_stream(fixture)
assert stream.returncode == 0, stream.stderr.decode(errors="replace")
assert stream.stdout == fixture.encode(), repr(stream.stdout)

terminal_status, terminal_stdout, terminal_stderr = run_terminal(fixture)
assert terminal_status == 0, terminal_stderr.decode(errors="replace")
assert terminal_stdout == fixture.encode() + b"\n", repr(terminal_stdout)

missing = run_stream(fixture, missing=True)
assert missing.returncode != 0
assert missing.stdout == b"", repr(missing.stdout)

print("terminal output contract tests passed")
PY
