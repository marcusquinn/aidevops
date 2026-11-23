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
	local checker="${BASH_SOURCE[0]%/*}/tool-version-check.sh"
	AIDEVOPS_TOOL_VERSION_CHECK="${AIDEVOPS_TOOL_VERSION_CHECK:-$checker}" \
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
# Scan directory kinds: plain bin, global npm bin, global npm node_modules.
BIN, NPM_BIN, NPM_LIB = "bin", "npm-bin", "npm-lib"
BIN_KINDS = (BIN, NPM_BIN)


def command(args):
    """Read-only package queries, bounded and without shell evaluation."""
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=30,
                                env=dict(os.environ, LC_ALL="C"))
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
    # GH#38587: removed-but-not-purged packages (rc) are still listed by
    # dpkg-query; keep only installed rows (ii, or hi when held).
    installed = command(["dpkg-query", "-W", "-f=${db:Status-Abbrev}\t${binary:Package}\t${Version}\n"])
    packages = [row.split("\t")[1] for row in installed.splitlines()
                if row.count("\t") >= 2 and row.split("\t")[0].strip() in ("ii", "hi")]
    print("\nAPT packages above enabled-source versions (possible disabled source):")
    found = False
    # Batch queries rather than starting a process for every installed package.
    for offset in range(0, len(packages), 100):
        policy = command(["apt-cache", "policy"] + packages[offset:offset + 100])
        package, version, current, available, sourced = "", "", "", [], False

        def flush():
            if version not in ("", "(none)") and available and not sourced and all(
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
                match = re.match(r"\s+(?:\*\*\*\s+)?(\S+)\s+(-?\d+)"
                                 r"(?:\s+\(phased \d+%\))?\s*$", line)
                if match:
                    current = match.group(1)
                elif re.match(r"\s+-?\d+\s+", line) and "/var/lib/dpkg/status" not in line:
                    available.append(current)
                    sourced = sourced or current == version
        found = flush() or found
    if not found:
        print("No above-source versions detected (or package policy unavailable).")


def resolved(path):
    try:
        return os.path.realpath(str(path))
    except (OSError, ValueError):
        return str(path)


def managed_inventory():
    """Tools `aidevops update` maintains, from tool-version-check.sh --inventory.

    GH#38587: one source of truth with the updater; network-free, no version calls.
    """
    rows = []
    checker = os.environ.get("AIDEVOPS_TOOL_VERSION_CHECK", "")
    if checker and os.path.isfile(checker):
        for line in command(["bash", checker, "--inventory"]).splitlines():
            fields = line.split("\t")
            if len(fields) == 4 and all(fields):
                rows.append(fields)
    return rows


def uv_tools(lines):
    """Map uv tool package lines to their exported executable names."""
    tools, current = [], None
    for line in lines:
        if line and not line[0].isspace() and not line.startswith("-"):
            current = (line, [])
            tools.append(current)
        elif current and line.strip().startswith("- "):
            current[1].append(line.strip()[2:].strip())
    return tools


def npm_packages(directory):
    """Package directories under node_modules, expanding @scope folders."""
    packages = []
    for path in sorted(directory.iterdir()):
        if path.name.startswith("@") and path.is_dir() and not path.is_symlink():
            packages.extend(sorted(p for p in path.iterdir() if p.is_dir()))
        elif path.is_dir() and not path.name.startswith("."):
            packages.append(path)
    return packages


def directory_entries(directory, kind):
    """Install candidates: executables/symlinks in bin dirs, non-empty dirs elsewhere."""
    if kind == NPM_LIB:
        return npm_packages(directory)
    entries = []
    for path in sorted(directory.iterdir()):
        if kind == NPM_BIN and path.is_symlink() and path.exists():
            # A shared prefix bin (e.g. Homebrew's) also links other managers'
            # payloads; only links staying inside this prefix are npm's.
            owned = (resolved(directory) + os.sep,
                     resolved(directory.parent / "lib/node_modules") + os.sep)
            if not resolved(path).startswith(owned):
                continue
        if kind in BIN_KINDS:
            if path.is_symlink() or (path.is_file() and os.access(str(path), os.X_OK)):
                entries.append(path)
        elif path.is_dir() and not path.is_symlink():
            if any(path.iterdir()):
                entries.append(path)
        elif path.is_symlink() or path.is_file():
            entries.append(path)
    return entries


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
    directories = [(root / ".local/bin", BIN), (root / ".bun/bin", BIN),
                   (root / ".aidevops/runtimes", "dir"), (root / ".aidevops/tools", "dir")]
    isolated = "AIDEVOPS_INSTALL_SCAN_ROOT" in os.environ
    uv_items = []
    uv_bin_dirs = set()
    npm_lib = None
    managed_paths, managed_packages, recorded_packages = set(), set(), set()
    if not isolated:
        # Discover manager bin dirs first so managed tools outside PATH resolve.
        prefix = command(["npm", "prefix", "-g"]).strip()
        if prefix and Path(prefix).is_absolute():
            npm_lib = Path(prefix) / "lib/node_modules"
            directories.extend([(Path(prefix) / "bin", NPM_BIN), (npm_lib, NPM_LIB)])
            # A recorded npm executable resolves inside its package directory.
            lib_real = resolved(npm_lib) + os.sep
            for path in known:
                real = resolved(path)
                if real.startswith(lib_real):
                    parts = Path(real[len(lib_real):]).parts
                    recorded_packages.add("/".join(parts[:2] if parts[0].startswith("@") else parts[:1]))
        uv_items = command(["uv", "tool", "list"]).splitlines()
        uv_bin = command(["uv", "tool", "dir", "--bin"]).strip()
        if uv_bin and Path(uv_bin).is_absolute():
            directories.append((Path(uv_bin), BIN))
            uv_bin_dirs.add(resolved(uv_bin))
        print("\nManaged by aidevops update:")
        listed = False
        launcher = shutil.which("aidevops")
        if launcher:
            print("- aidevops (framework): " + display(launcher))
            managed_paths.update({launcher, resolved(launcher)})
            listed = True
        for name, category, cli, package in managed_inventory():
            managed_packages.add(package)
            location = shutil.which(cli)
            if not location:
                # User bin dirs may be absent from a restricted PATH.
                location = next((str(d / cli) for d, kind in directories
                                 if kind in BIN_KINDS and os.access(str(d / cli), os.X_OK)), None)
            if not location:
                continue
            # The updater rejects the Cloud Foundry `cf` ("cf version 8.x");
            # it stays an untracked install, not Cloudflare's managed CLI.
            if cli == "cf" and command([location, "--version"]).startswith("cf version "):
                continue
            managed_paths.update({location, resolved(location)})
            print("- " + display(name) + " (" + display(category) + "): " + display(location))
            listed = True
        if not listed:
            print("None found on PATH.")
    tools = uv_tools(uv_items)
    recorded_names = {r[NAME] for r in records}
    uv_executables = {exe for _, exes in tools for exe in exes}
    print("\nKnown untracked installs (origin and update path unknown):")
    seen = set(known) | managed_paths
    seen_real = {resolved(p) for p in seen}
    for directory, kind in directories:
        if not directory.is_dir():
            continue
        try:
            children = directory_entries(directory, kind)
        except OSError:
            print("- Cannot read " + display(directory))
            continue
        for path in children:
            real = resolved(path)
            if str(path) in seen or real in seen_real:
                continue
            # uv tools print once, as their package line below.
            if kind == BIN and path.name in uv_executables and resolved(directory) in uv_bin_dirs:
                continue
            # npm bin links print once, as their package directory.
            if npm_lib and kind in BIN_KINDS and real.startswith(resolved(npm_lib) + os.sep):
                continue
            if kind == NPM_LIB:
                package = str(path.relative_to(directory))
                if package in managed_packages or package in recorded_packages:
                    continue
            seen.add(str(path))
            seen_real.add(real)
            warning = shebang_warning(path) if path.is_file() else ""
            if path.is_symlink() and not path.exists():
                warning = " [broken symlink]"
            print("- " + display(path) + warning)
    # uv lists package names and their exported executables; paths above identify
    # tracked tools even when the distribution and executable names differ.
    for line, _ in tools:
        name = line.split()[0]
        if name not in recorded_names and name not in managed_packages:
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
