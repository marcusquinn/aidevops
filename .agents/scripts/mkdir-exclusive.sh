#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Dependency-light bootstrap shim: uutils 0.10.0 can report two successful
# creators for one directory (GH#40582). Never redefine mkdir on GNU/BSD hosts.
[[ -n "${_AIDEVOPS_MKDIR_EXCLUSIVE_LOADED:-}" ]] && return 0
_AIDEVOPS_MKDIR_EXCLUSIVE_LOADED=1

# Named primitive lets test interceptors preserve exclusivity without recursion.
aidevops_mkdir_exclusive() {
	command mkdir "$@"
	return $?
}

if [[ "$(command mkdir --version 2>/dev/null || true)" == *uutils* ]]; then
	# Pin the executable: callers can later restrict PATH (for example no-jq
	# bootstrap paths), but that must not lose the selected exclusive creator.
	if command -v gnumkdir >/dev/null 2>&1 &&
		_AIDEVOPS_MKDIR_GNU=$(type -P gnumkdir); then
		aidevops_mkdir_exclusive() {
			"$_AIDEVOPS_MKDIR_GNU" "$@"
			return $?
		}
	else
		# Python issues mkdir(2) directly and preserves EEXIST. Do not fall back
		# to the unsafe command if Python is missing. -p is not a mutex and can
		# retain the native implementation. Unsupported modes fail closed.
		_AIDEVOPS_MKDIR_PYTHON=$(type -P python3 || true)
		_AIDEVOPS_MKDIR_NATIVE=$(type -P mkdir || true)
		aidevops_mkdir_exclusive() {
			if [[ -z "$_AIDEVOPS_MKDIR_PYTHON" ]]; then
				printf 'mkdir: exclusive creation requires gnumkdir or python3\n' >&2
				return 1
			fi
			"$_AIDEVOPS_MKDIR_PYTHON" -c '
import getopt, os, subprocess, sys
try:
    options, paths = getopt.gnu_getopt(sys.argv[2:], "pm:v", ["parents", "mode=", "verbose", "help", "version"])
    if any(key in ("-p", "--parents", "--help", "--version") for key, _ in options):
        sys.exit(subprocess.call([sys.argv[1]] + sys.argv[2:]))
    mode, verbose = 0o777, False
    for key, value in options:
        if key in ("-m", "--mode"):
            mode = int(value, 8)
            # mkdir(2) alone cannot faithfully apply GNU special-bit modes.
            if not 0 <= mode <= 0o777:
                raise ValueError("fallback requires an octal mode from 000 to 777")
        elif key in ("-v", "--verbose"):
            verbose = True
    if not paths:
        raise ValueError("missing operand")
except (getopt.GetoptError, ValueError) as error:
    sys.exit("mkdir: " + str(error))
status = 0
for path in paths:
    try:
        # Explicit -m ignores umask, like coreutils; default mode respects it.
        if any(key in ("-m", "--mode") for key, _ in options):
            os.umask(0)
        os.mkdir(path, mode)
        if verbose:
            print("mkdir: created directory " + repr(path))
    except OSError as error:
        print("mkdir: " + str(error), file=sys.stderr)
        status = 1
sys.exit(status)
' "$_AIDEVOPS_MKDIR_NATIVE" "$@"
			return $?
		}
	fi
	mkdir() {
		aidevops_mkdir_exclusive "$@"
		return $?
	}
fi
