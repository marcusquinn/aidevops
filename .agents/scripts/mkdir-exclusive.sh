#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Dependency-light bootstrap shim: uutils 0.10.0 can report two successful
# creators for one directory (GH#40582). Never redefine mkdir on GNU/BSD hosts.
[[ -n "${_AIDEVOPS_MKDIR_EXCLUSIVE_LOADED:-}" ]] && return 0
_AIDEVOPS_MKDIR_EXCLUSIVE_LOADED=1

if [[ "$(command mkdir --version 2>/dev/null || true)" == *uutils* ]]; then
	if command -v gnumkdir >/dev/null 2>&1; then
		mkdir() {
			command gnumkdir "$@"
			return $?
		}
	else
		# Python issues mkdir(2) directly and preserves EEXIST. Do not fall back
		# to the unsafe command if Python is missing. -p is not a mutex and can
		# retain the native implementation. Unsupported modes fail closed.
		mkdir() {
			python3 -c '
import getopt, os, subprocess, sys
try:
    options, paths = getopt.gnu_getopt(sys.argv[1:], "pm:v", ["parents", "mode=", "verbose", "help", "version"])
    if any(key in ("-p", "--parents", "--help", "--version") for key, _ in options):
        sys.exit(subprocess.call(["mkdir"] + sys.argv[1:]))
    mode, verbose = 0o777, False
    for key, value in options:
        if key in ("-m", "--mode"):
            mode = int(value, 8)
            if not 0 <= mode <= 0o7777:
                raise ValueError("invalid octal mode")
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
' "$@"
			return $?
		}
	fi
fi
