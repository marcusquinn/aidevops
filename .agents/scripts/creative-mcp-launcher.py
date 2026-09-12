# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Launch an operator-provisioned creative MCP from a reviewed source revision.

No installation, application startup or consent inference. Isolation flags are
operator attestations, not proof of an OS sandbox. Dependencies remain the
operator's responsibility; a source pin does not lock transitive dependencies.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

APPS = {
    "freecad": {
        "prefix": "FREECAD", "revision": "5dbfe2c80b53c3102bff0723951676e16edf2d84",
        "entry": "src/freecad_mcp/server.py", "module": "freecad_mcp.server",
        "import_root": "src", "python": (3, 12),
        "args": ["--host", "127.0.0.1"],
    },
    "ableton": {
        "prefix": "ABLETON", "revision": "8731a47a415f1590f50bdb3b4ac4f06d8328cf0b",
        "entry": "MCP_Server/server.py", "module": "MCP_Server.server",
        "import_root": ".", "python": (3, 10), "args": [],
    },
    "davinci-resolve": {
        "prefix": "RESOLVE", "revision": "c8fbe1887324de9d897e6036efcde60417e33e8c",
        "entry": "src/server.py", "module": None,
        "import_root": ".", "python": (3, 10), "args": [],
    },
}


def require_consent(prefix, env):
    """Reject before even probing an external executable."""
    # aidevops:trust-boundary -- registration is not application execution consent.
    if (env.get(f"AIDEVOPS_{prefix}_ISOLATED") != "1"
            or env.get(f"AIDEVOPS_{prefix}_CODE_EXECUTION") != "approved"):
        raise ValueError(
            f"Operator approval required: AIDEVOPS_{prefix}_ISOLATED=1 and "
            f"AIDEVOPS_{prefix}_CODE_EXECUTION=approved. The app and MCP must "
            "already be isolated; these flags do not create or verify a sandbox."
        )


def required_path(env, key, directory=False, executable=False):
    value = env.get(key, "")
    if not value or not Path(value).is_absolute():
        raise ValueError(f"Set {key} to an absolute operator-provisioned path")
    path = Path(value)
    if not (path.is_dir() if directory else path.is_file()):
        raise ValueError(f"{key} is unavailable; no installation or app launch was attempted")
    if executable and not os.access(path, os.X_OK):
        raise ValueError(f"{key} is not executable")
    # Preserve venv/bin/python: resolving its symlink selects the base Python
    # and loses the operator-installed virtual environment dependencies.
    return path.absolute() if executable else path.resolve()


def launch_environment(app, env):
    """Keep ordinary runtime/app settings, remove import/loader hooks and secrets."""
    allowed = {
        "PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "TEMP",
        "SYSTEMROOT", "WINDIR", "DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "DBUS_SESSION_BUS_ADDRESS",
        "RESOLVE_SCRIPT_API", "RESOLVE_SCRIPT_LIB", "PYTHON3HOME",
    }
    clean = {key: value for key, value in env.items() if key in allowed}
    clean.update({"PYTHONNOUSERSITE": "1", "GIT_CONFIG_NOSYSTEM": "1",
                  "GIT_CONFIG_GLOBAL": os.devnull})
    if app == "ableton":
        if env.get("ABLETON_HOST", "127.0.0.1") != "127.0.0.1":
            raise ValueError("ABLETON_HOST must be literal IPv4 loopback (127.0.0.1)")
        port = env.get("ABLETON_PORT", "9877")
        if not port.isdecimal() or not 1 <= int(port) <= 65535:
            raise ValueError("ABLETON_PORT must be between 1 and 65535")
        clean.update({"ABLETON_HOST": "127.0.0.1", "ABLETON_PORT": port,
                      "ABLETON_MCP_DISABLE_TELEMETRY": "true", "DISABLE_TELEMETRY": "true",
                      "MCP_DISABLE_TELEMETRY": "true", "ABLETON_MCP_DISABLE_DATASET": "1"})
    return clean


def checked_output(command, env, cwd=None):
    result = subprocess.run(command, cwd=cwd, env=env, capture_output=True,
                            text=True, check=True, timeout=15)
    return result.stdout.strip()


def prepare(app, env):
    spec = APPS[app]
    prefix = spec["prefix"]
    require_consent(prefix, env)
    clean = launch_environment(app, env)
    root = required_path(env, f"AIDEVOPS_{prefix}_MCP_SOURCE", directory=True)
    python = required_path(env, f"AIDEVOPS_{prefix}_MCP_PYTHON", executable=True)
    # An installed app path is an inventory check, not a licence/bridge check.
    app_path = env.get(f"AIDEVOPS_{prefix}_APP", "")
    if not app_path or not Path(app_path).is_absolute() or not Path(app_path).exists():
        raise ValueError(f"Set AIDEVOPS_{prefix}_APP to the installed app; availability is not assumed")
    git = shutil.which("git", path=clean.get("PATH", os.defpath))
    if not git:
        raise ValueError("Git is required to verify the reviewed MCP source revision")
    top = checked_output([git, "-C", str(root), "rev-parse", "--show-toplevel"], clean)
    if Path(top).resolve() != root:
        raise ValueError("MCP source must be the Git worktree root, not an ignored nested directory")
    if checked_output([git, "-C", str(root), "rev-parse", "HEAD"], clean) != spec["revision"]:
        raise ValueError("MCP source revision differs from the reviewed launcher pin")
    if checked_output([git, "-C", str(root), "status", "--porcelain", "--untracked-files=normal"], clean):
        raise ValueError("MCP source must be clean; do not run modified or untracked source")
    entry = root / spec["entry"]
    if not entry.is_file() or entry.is_symlink() or not entry.resolve().is_relative_to(root):
        raise ValueError("Reviewed MCP entry point is missing or escapes its source root")
    version = checked_output([str(python), "-I", "-c",
                              "import sys; print('%d.%d' % sys.version_info[:2])"], clean)
    if not re.fullmatch(r"\d+\.\d+", version) or tuple(map(int, version.split("."))) < spec["python"]:
        raise ValueError("MCP Python version is below the upstream requirement")
    if spec["module"]:
        code = ("import sys; sys.path.insert(0, sys.argv.pop(1)); "
                f"from {spec['module']} import main; main()")
        args = [str(root / spec["import_root"]), *spec["args"]]
    else:
        # Resolve's compact server only. No --full/advanced DB/XML entry point.
        code = ("import sys, runpy; root=sys.argv.pop(1); sys.path.insert(0, root); "
                "sys.argv=[root+'/src/server.py']; runpy.run_path(sys.argv[0], run_name='__main__')")
        args = [str(root)]
    return [str(python), "-I", "-c", code, *args], clean, root


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", choices=APPS)
    parser.add_argument("action", choices=("check", "run"), default="run", nargs="?")
    args = parser.parse_args(argv)
    try:
        command, env, root = prepare(args.app, os.environ)
        if args.action == "check":
            print("Reviewed source, interpreter and app path verified. "
                  "Dependencies, licence, bridge identity and live app operations remain unverified.")
            return 0
        os.chdir(root)
        os.execve(command[0], command, env)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        detail = str(exc) if isinstance(exc, ValueError) else type(exc).__name__
        print("Creative MCP: " + detail, file=sys.stderr)
        return 1
    return 1


if __name__ == "__main__":
    sys.exit(main())
