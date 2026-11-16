#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Source this library, then call install_record name method path reason update-path.
# Metadata only: never pass credentials or complete installation command lines.
# AIDEVOPS_INSTALL_RECORD_FILE overrides the JSONL ledger location.
# AIDEVOPS_INSTALL_SCAN_ROOT overrides HOME for directory scans and disables
# host package-manager discovery, allowing an entirely isolated report fixture.

install_record() {
	local name="${1:-}" method="${2:-}" path="${3:-}" reason="${4:-}" update="${5:-}"
	local installer="${BASH_SOURCE[1]:-session}"
	installer="${installer##*/}"
	if _install_record_cli add --name "$name" --method "$method" --path "$path" \
		--reason "$reason" --update "$update" --installer "${installer:-session}"; then
		return 0
	fi
	return 1
}

_install_record_cli() {
	if ! command -v python3 >/dev/null 2>&1; then
		printf 'Install records require Python 3.\n' >&2
		return 1
	fi
	python3 -c "$_AIDEVOPS_INSTALL_RECORD_PROGRAM" "$@"
	return $?
}

# Keep the portable standard-library implementation as data, not a shell
# function body. Sourcing the library performs no scans or filesystem writes.
IFS= read -r -d '' _AIDEVOPS_INSTALL_RECORD_PROGRAM <<'PY' || true
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

NAME, METHOD, PATH, REASON, UPDATE, INSTALLER, DATE = (
    "name", "method", "path", "reason", "update", "installer", "date"
)
FIELDS = (NAME, METHOD, PATH, REASON, UPDATE, INSTALLER)


def command(args):
    """Read-only package queries, bounded and without shell evaluation."""
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=30)
        return result.stdout if result.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def read_records(path):
    records = []
    if path.exists():
        with path.open() as stream:
            for line in stream:
                item = json.loads(line)
                if not isinstance(item, dict) or not all(
                    isinstance(item.get(key), str)
                    for key in FIELDS + (DATE,)
                ):
                    raise ValueError("Invalid install record schema")
                records.append(item)
    return records


def safe_metadata(values):
    # Reject rather than partially redact: do not persist token-bearing commands,
    # URL credentials, terminal controls, or common credential formats.
    forbidden = re.compile(
        r"(?i)(token|password|passwd|secret|api[_-]?key|authorization|bearer)"
        r"|https?://[^\s/]+@|[?&][^\s=]+=|\b(?:gh[pousr]_|github_pat_|sk-)[\w-]+"
        r"|[\x00-\x1f\x7f]|[;&|`]|\$\("
    )
    return all(value and len(value) <= 1024 and not forbidden.search(value) for value in values)


def add(args, ledger):
    values = [args.name, args.method, args.path, args.reason, args.update, args.installer]
    if not safe_metadata(values) or not os.path.isabs(args.path):
        raise ValueError("Use non-sensitive metadata and an absolute install path; no credentials or command lines")
    ledger.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Lock the ledger itself: concurrent helpers cannot append duplicate entries.
    fd = os.open(str(ledger), os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "r+", encoding="utf-8") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        records = [json.loads(line) for line in stream]
        identity = (args.name, args.method, os.path.normpath(args.path))
        if any((r[NAME], r[METHOD], r[PATH]) == identity for r in records):
            return
        item = dict(zip(FIELDS, values))
        item[PATH] = identity[2]
        item[DATE] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        stream.write(json.dumps(item) + "\n")


def display(value):
    # Do not let externally installed filenames or package output inject controls.
    return str(value).encode("unicode_escape").decode("ascii")


def shebang_warning(path):
    try:
        with path.open("rb") as stream:
            line = stream.readline(4096)
        if not line.startswith(b"#!"):
            return ""
        words = shlex.split(line[2:].decode("utf-8", "replace").strip())
        if not words:
            return " [broken shebang: missing interpreter]"
        interpreter = words[0]
        if not os.path.isfile(interpreter) or not os.access(interpreter, os.X_OK):
            return " [broken shebang: missing interpreter " + display(interpreter) + "]"
        if Path(interpreter).name == "env":
            targets = words[1:]
            if targets and targets[0] == "-S":
                targets = targets[1:]
            if targets and not targets[0].startswith("-") and "=" not in targets[0]:
                if not shutil.which(targets[0]):
                    return " [broken shebang: missing interpreter " + display(targets[0]) + "]"
    except (OSError, ValueError):
        return " [unreadable install]"
    return ""


def apt_report():
    if not shutil.which("dpkg-query") or not shutil.which("apt-cache"):
        return
    installed = command(["dpkg-query", "-W", "-f=${binary:Package}\t${Version}\n"])
    packages = [row.split("\t")[0] for row in installed.splitlines() if "\t" in row]
    print("\nAPT packages above enabled-source versions (possible disabled source):")
    found = False
    # Batch queries rather than starting a process for every installed package.
    for offset in range(0, len(packages), 100):
        policy = command(["apt-cache", "policy"] + packages[offset:offset + 100])
        package, version, current, available, sourced = "", "", "", [], False

        def flush():
            if version and available and not sourced and all(
                subprocess.run(["dpkg", "--compare-versions", version, "gt", v],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
                for v in available
            ):
                print("- " + display(package) + " " + display(version) +
                      " (newer than enabled sources; installed version has no active source)")
                return True
            return False

        for line in policy.splitlines():
            if line and not line[0].isspace() and line.endswith(":"):
                found = flush() or found
                package, version, current, available, sourced = line[:-1], "", "", [], False
            elif line.strip().startswith("Installed:"):
                version = line.split(":", 1)[1].strip()
            else:
                match = re.match(r"\s+(?:\*\*\*\s+)?(\S+)\s+(-?\d+)\s*$", line)
                if match:
                    current = match.group(1)
                elif re.match(r"\s+-?\d+\s+", line) and "/var/lib/dpkg/status" not in line:
                    available.append(current)
                    sourced = sourced or current == version
        found = flush() or found
    if not found:
        print("No above-source versions detected (or package policy unavailable).")


def report(ledger):
    records = read_records(ledger)
    print("Recorded installs:")
    known = set()
    for item in records:
        known.add(os.path.normpath(item[PATH]))
        path = Path(item[PATH])
        warning = shebang_warning(path) if path.exists() else " [missing path]"
        print("- {name} ({method}): {path}".format(**{k: display(v) for k, v in item.items()}) + warning)
        print("  Installed by {installer} on {date}; why: {reason}; updates: {update}".format(
            **{k: display(v) for k, v in item.items()}))
    if not records:
        print("None recorded yet.")
    root = Path(os.environ.get("AIDEVOPS_INSTALL_SCAN_ROOT", str(Path.home())))
    directories = [root / p for p in (".local/bin", ".bun/bin", ".aidevops/runtimes", ".aidevops/tools")]
    isolated = "AIDEVOPS_INSTALL_SCAN_ROOT" in os.environ
    uv_items = []
    if not isolated:
        prefix = command(["npm", "prefix", "-g"]).strip()
        if prefix and Path(prefix).is_absolute():
            directories.extend([Path(prefix) / "bin", Path(prefix) / "lib/node_modules"])
        uv_items = command(["uv", "tool", "list"]).splitlines()
        uv_bin = command(["uv", "tool", "dir", "--bin"]).strip()
        if uv_bin and Path(uv_bin).is_absolute():
            directories.append(Path(uv_bin))
    print("\nKnown untracked installs (origin and update path unknown):")
    seen = set(known)
    for directory in directories:
        if not directory.is_dir():
            continue
        try:
            children = sorted(directory.iterdir())
        except OSError:
            print("- Cannot read " + display(directory))
            continue
        for path in children:
            if str(path) in seen:
                continue
            seen.add(str(path))
            warning = shebang_warning(path) if path.is_file() else ""
            if path.is_symlink() and not path.exists():
                warning = " [broken symlink]"
            print("- " + display(path) + warning)
    # uv lists package names and their exported executables; paths above identify
    # tracked tools even when the distribution and executable names differ.
    for line in uv_items:
        if line and not line[0].isspace() and line.split()[0] not in {r[NAME] for r in records}:
            print("- uv tool: " + display(line))
    if not isolated:
        apt_report()
    print("\nRead-only report: nothing was updated or deleted.")


parser = argparse.ArgumentParser(description="Record installs or show a read-only installs report")
sub = parser.add_subparsers(dest="command")
adder = sub.add_parser("add", help="Record non-sensitive install metadata, not shell commands")
for field in FIELDS[:5]:
    adder.add_argument("--" + field, required=True)
adder.add_argument("--installer", default="session", help=argparse.SUPPRESS)
sub.add_parser("report", help="List records, untracked installs and broken interpreters")
args = parser.parse_args()
ledger = Path(os.environ.get("AIDEVOPS_INSTALL_RECORD_FILE",
                          str(Path.home() / ".aidevops/.agent-workspace/state/installs.jsonl")))
try:
    if args.command == "add":
        add(args, ledger)
    else:
        report(ledger)
except (OSError, ValueError, KeyError) as error:
    # Do not echo rejected metadata or potentially sensitive malformed records.
    print("Install records: operation failed (" + type(error).__name__ + "). Check metadata and ledger access.", file=sys.stderr)
    sys.exit(1)
PY

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	_install_record_cli "$@"
	exit $?
fi
