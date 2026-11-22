#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by secret-helper.sh. Values travel through pipes, never argv or files.

has_systemd_creds() {
	command -v systemd-creds >/dev/null 2>&1 || return 1
	local help=""
	help=$(systemd-creds --help 2>/dev/null) || return 1
	# --refuse-null (259+) is required: never accept unauthenticated credentials.
	[[ "$help" == *--user* && "$help" == *--refuse-null* ]] || return 1
	return 0
}

systemd_owns_secret() {
	local name="$1"
	[[ "$name" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
	[[ -e "$CONFIG_DIR/creds/$name.cred" || -L "$CONFIG_DIR/creds/$name.cred" ]] || return 1
	return 0
}

systemd_secret_names() {
	local path="" name=""
	for path in "$CONFIG_DIR/creds/"*.cred; do
		[[ -e "$path" || -L "$path" ]] || continue
		name="${path##*/}"
		name="${name%.cred}"
		[[ "$name" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
		printf '%s\n' "$name"
	done
	return 0
}

# Bound both polkit and TPM operations. Diagnostics may contain private data.
systemd_secret_read() {
	local name="$1"
	has_systemd_creds || return 3
	python3 - "$CONFIG_DIR/creds" "$name" <<'PY'
import os
import stat
import subprocess
import sys

directory, name = sys.argv[1:]
try:
    for path, kind in ((directory, stat.S_ISDIR),
                       (os.path.join(directory, name + '.cred'), stat.S_ISREG)):
        info = os.lstat(path)
        if not kind(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            sys.exit(3)
    result = subprocess.run(['systemd-creds', '--user', '--no-ask-password',
                             '--refuse-null', '--name=' + name, 'decrypt',
                             os.path.join(directory, name + '.cred'), '-'],
                            capture_output=True, timeout=4)
    if result.returncode or not result.stdout or b'\0' in result.stdout:
        sys.exit(3)
    sys.stdout.buffer.write(result.stdout)
except (OSError, subprocess.SubprocessError):
    sys.exit(3)
PY
	local rc=$?
	return "$rc"
}

# stdin is plaintext; only ciphertext is ever written. Verify before replacement.
systemd_secret_write() {
	local name="$1"
	has_systemd_creds || return 1
	python3 -c '
import os
import stat
import subprocess
import sys
import tempfile

directory, name = sys.argv[1:]
temporary = None
try:
    os.makedirs(directory, mode=0o700, exist_ok=True)
    info = os.lstat(directory)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        sys.exit(1)
    value = sys.stdin.buffer.read()
    if not value or b"\0" in value:
        sys.exit(1)
    base = ["systemd-creds", "--user", "--no-ask-password", "--name=" + name]
    encrypted = subprocess.run(base + ["--with-key=host", "encrypt", "-", "-"],
                               input=value, capture_output=True, timeout=10)
    if encrypted.returncode:
        sys.exit(1)
    check = subprocess.run(base + ["--refuse-null", "decrypt", "-", "-"],
                           input=encrypted.stdout, capture_output=True, timeout=4)
    if check.returncode or check.stdout != value:
        sys.exit(1)
    fd, temporary = tempfile.mkstemp(prefix=".credential-", dir=directory)
    with os.fdopen(fd, "wb") as output:
        output.write(encrypted.stdout)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, os.path.join(directory, name + ".cred"))
except (OSError, subprocess.SubprocessError):
    sys.exit(1)
finally:
    if temporary and os.path.exists(temporary):
        os.unlink(temporary)
' "$CONFIG_DIR/creds" "$name"
	local rc=$?
	return "$rc"
}

# The existing injection/redaction pipeline needs a seekable temporary file.
# With encrypted credentials present, refuse persistent temporary storage.
secret_env_tempfile() {
	local names=""
	names=$(systemd_secret_names)
	if [[ -z "$names" ]]; then
		mktemp || return 1
		return 0
	fi
	local runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
	local runtime_fstype=""
	case "$(uname -s)" in
	Linux)
		runtime_fstype=$(stat -f -c %T "$runtime" 2>/dev/null) || runtime_fstype=""
		;;
	esac
	if [[ -d "$runtime" && ! -L "$runtime" && -O "$runtime" && "$runtime_fstype" == tmpfs ]]; then
		mktemp "$runtime/aidevops-secret-env.XXXXXXXX" || return 1
		return 0
	fi
	print_error "Encrypted secret injection requires an owned tmpfs XDG_RUNTIME_DIR" >&2
	return 1
}

# Opt-in import, sharing the existing strict literal parser. Never prune sources.
cmd_import_systemd_credentials() {
	has_systemd_creds || return 1
	local file=""
	file=$(credential_store_file)
	python3 - "$SCRIPT_DIR" "$file" <<'PY'
import os
import subprocess
import sys
from collections import Counter

scripts, path = sys.argv[1:]


def gopass_names():
    try:
        listing = subprocess.run(['gopass', 'ls', '--flat'], capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return set()
    if listing.returncode:
        return set()
    return {line.rsplit('/', 1)[-1].strip() for line in listing.stdout.decode(errors='replace').splitlines()}


sys.path.insert(0, scripts)
from credential_literals import SECRET_NAME, literal, parse, read_source

try:
    original, _ = read_source(path, private=True)
    assignments, errors = parse(original, path)
    if errors:
        raise ValueError('unsupported source')
    counts = Counter(name for _, name, _ in assignments)
    for _, name, raw in assignments:
        value = literal(raw)
        if not SECRET_NAME.search(name) or counts[name] != 1 or not value or value.startswith(('YOUR_', 'CHANGE_ME')):
            continue
        destination = os.path.expanduser('~/.config/aidevops/creds/' + name + '.cred')
        if os.path.lexists(destination):
            print('Keeping existing encrypted entry: ' + name)
            continue
        result = subprocess.run(['bash', os.path.join(scripts, 'secret-helper.sh'),
                                 'set', name, '--backend', 'systemd-creds'],
                                input=value.encode(), capture_output=True, timeout=20)
        if result.returncode:
            raise ValueError('import failed')
        print('Imported and decrypt-verified: ' + name)
        if name in gopass_names():
            print('Warning: gopass entry ' + name + ' exists and its value still takes precedence over the imported credential', file=sys.stderr)
except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
    print('Encrypted import failed safely; source retained', file=sys.stderr)
    sys.exit(1)
PY
	local rc=$?
	return "$rc"
}
