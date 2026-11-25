#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""
managesieve_client.py - shared ManageSieve (RFC 5804) client (GH#40429).

Run by email-sieve-helper.sh inside secret injection:

  managesieve_client.py PASSWORD_VAR USER list
  managesieve_client.py PASSWORD_VAR USER get NAME
  managesieve_client.py PASSWORD_VAR USER install NAME SCRIPT
  managesieve_client.py PASSWORD_VAR USER install-file NAME PATH
  managesieve_client.py PASSWORD_VAR USER remove NAME SCRIPT
  managesieve_client.py PASSWORD_VAR USER remove-parked NAME SCRIPT

The password is read from the environment variable named PASSWORD_VAR, never
from argv. `install` runs CHECKSCRIPT, PUTSCRIPT and SETACTIVE, then reads the
script back and fails unless it matches and is active. `remove` renames the
script aside, deletes it only if it still matches SCRIPT, and otherwise puts
it back.

Exit codes: 0 ok, 1 server/network error, 2 usage error, 4 no such script.
Host is required via SIEVE_HOST (legacy PURELYMAIL_SIEVE_HOST is accepted).
SIEVE_PORT (legacy PURELYMAIL_SIEVE_PORT) defaults to 4190.
"""

import base64
import contextlib
import os
import re
import select
import socket
import ssl
import sys

HOST = os.environ.get("SIEVE_HOST") or os.environ.get("PURELYMAIL_SIEVE_HOST", "")
PORT = os.environ.get("SIEVE_PORT") or os.environ.get("PURELYMAIL_SIEVE_PORT", "4190")
TIMEOUT = 30
PRE_TLS_WAIT = 1.0
# copy-to-remove parks under NAME[:100] + PARK_SUFFIX while checking it;
# must match the parked name in email-sieve-helper.sh.
PARK_SUFFIX = ".aidevops-remove"
# One response token: quoted string, trailing literal size, response code, atom.
TOKEN_RE = re.compile(rb'"((?:\\.|[^"\\])*)"|\{(\d+)\+?\}$|(\([^)]*\))|(\S+)')


class SieveError(Exception):
    """A non-OK server reply or a protocol violation."""


class Atom(str):
    """An unquoted protocol token (OK, NO, ACTIVE, response codes)."""


def quote(text):
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return b'"' + escaped.encode("utf-8") + b'"'


def decode(data):
    return data.decode("utf-8", "replace")


class Conn:
    """One authenticated ManageSieve session over STARTTLS."""

    def __init__(self, user, password):
        self.sock = socket.create_connection((HOST, int(PORT)), timeout=TIMEOUT)
        self.buf = b""
        status, _rest, items = self.response()
        if status != "OK":
            raise SieveError("greeting was " + status)
        if "STARTTLS" not in [str(i[0]).upper() for i in items if i]:
            raise SieveError("server does not offer STARTTLS")
        self._starttls()
        token = base64.b64encode(("\0" + user + "\0" + password).encode("utf-8"))
        self.command(b'AUTHENTICATE "PLAIN" ' + quote(token.decode("ascii")))

    def _starttls(self):
        self.command(b"STARTTLS")
        # Purelymail quirk: after "OK" to STARTTLS it re-sends its capability
        # list in plaintext, before the TLS handshake. Drain and discard that
        # unauthenticated listing, or its bytes corrupt the handshake.
        self._drain_pre_tls()
        self.sock = ssl.create_default_context().wrap_socket(self.sock, server_hostname=HOST)
        self._sync()

    def _sync(self):
        """Consume any capability listing sent over TLS, without timing.

        RFC 5804 servers re-send capabilities after STARTTLS; Purelymail does
        not. A NOOP reply has no data lines, while a capability listing does,
        so reading up to the first data-less reply leaves no unread response
        whichever way the server behaves (NO means NOOP is unsupported).
        """
        self.sock.sendall(b'NOOP "aidevops-sync"\r\n')
        while True:
            status, _rest, items = self.response()
            if status == "BYE":
                raise SieveError("server closed the session after STARTTLS")
            if status == "NO" or not items:
                return

    def _drain_pre_tls(self):
        """Discard a plaintext capability listing sent before TLS, if any.

        The socket is still plain here, so select() readability means data.
        """
        if not (self.buf or select.select([self.sock], [], [], PRE_TLS_WAIT)[0]):
            return
        self.response()
        if self.buf:
            raise SieveError("unexpected plaintext data before TLS handshake")

    def _fill(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise SieveError("connection closed by server")
        self.buf += chunk

    def readline(self):
        while b"\r\n" not in self.buf:
            self._fill()
        line, _sep, self.buf = self.buf.partition(b"\r\n")
        return line

    def read(self, size):
        while len(self.buf) < size:
            self._fill()
        data, self.buf = self.buf[:size], self.buf[size:]
        return data

    def tokens(self):
        """Parse one response line into atoms and strings (with literals)."""
        out = []
        line = self.readline()
        while True:
            size = None
            for match in TOKEN_RE.finditer(line):
                quoted, literal, code, atom = match.groups()
                if quoted is not None:
                    out.append(decode(re.sub(rb"\\(.)", rb"\1", quoted)))
                elif literal is not None:
                    size = int(literal)
                else:
                    out.append(Atom(decode(code or atom)))
            if size is None:
                return out
            out.append(decode(self.read(size)))
            line = self.readline()

    def response(self):
        """Read data lines up to OK/NO/BYE; return (status, rest, items)."""
        items = []
        while True:
            tokens = self.tokens()
            if tokens and isinstance(tokens[0], Atom) and tokens[0].upper() in ("OK", "NO", "BYE"):
                return tokens[0].upper(), tokens[1:], items
            items.append(tokens)

    def command(self, line, literal=None):
        data = line
        if literal is not None:
            data += b" {%d+}\r\n" % len(literal) + literal
        self.sock.sendall(data + b"\r\n")
        status, rest, items = self.response()
        if status != "OK":
            raise SieveError((status + " " + " ".join(str(t) for t in rest))[:300])
        return items

    def close(self):
        """Best-effort LOGOUT (bounded wait, also after errors), then close."""
        with contextlib.suppress(SieveError, OSError):
            self.sock.settimeout(PRE_TLS_WAIT)
            self.command(b"LOGOUT")
        with contextlib.suppress(OSError):
            self.sock.close()


def normalize(text):
    return text.replace("\r\n", "\n").rstrip()


def listing(conn):
    """Return [(name, active)] from LISTSCRIPTS."""
    return [(str(i[0]), len(i) > 1 and str(i[1]).upper() == "ACTIVE")
            for i in conn.command(b"LISTSCRIPTS") if i]


def first_string(items):
    return items[0][0] if items and items[0] else ""


def op_list(conn):
    for name, active in listing(conn):
        print("%s\t%s" % (name, "active" if active else "inactive"))
    return 0


def op_get(conn, name):
    try:
        items = conn.command(b"GETSCRIPT " + quote(name))
    except SieveError as err:
        if "NONEXISTENT" in str(err).upper():
            return 4
        raise
    sys.stdout.write(first_string(items))
    return 0


def op_install(conn, name, content):
    payload = content.encode("utf-8")
    conn.command(b"CHECKSCRIPT", payload)
    conn.command(b"PUTSCRIPT " + quote(name), payload)
    conn.command(b"SETACTIVE " + quote(name))
    stored = first_string(conn.command(b"GETSCRIPT " + quote(name)))
    if normalize(stored) != normalize(content):
        raise SieveError("read-back differs from the script sent")
    if (name, True) not in listing(conn):
        raise SieveError("script stored but not active")
    return 0


def op_install_file(conn, name, path):
    with open(path, encoding="utf-8", newline="") as stream:
        return op_install(conn, name, stream.read())


def op_remove(conn, name, expected):
    """Delete NAME only if it still holds EXPECTED.

    Renaming first moves the script out of reach of webmail saves (which write
    to NAME), so the contents checked are exactly the contents deleted.
    Interrupted removals use the explicit remove-parked operation instead.
    """
    parked, original = park(conn, name)
    stored = first_string(conn.command(b"GETSCRIPT " + quote(parked)))
    if normalize(stored) != normalize(expected):
        outcome = restore_parked(conn, parked, original)
        raise SieveError("script changed since it was checked; " + outcome)
    return drop(conn, parked)


def drop(conn, name):
    """Deactivate NAME if active, then delete it."""
    if (name, True) in listing(conn):
        conn.command(b'SETACTIVE ""')
    conn.command(b"DELETESCRIPT " + quote(name))
    return 0


def op_delete(conn, name):
    """Delete an inactive script; refuse an active one (exit 3, nothing changed)."""
    if (name, True) in listing(conn):
        sys.stderr.write(
            "sieve: '%s' is active; automatic deactivation is unsafe with "
            "concurrent writers; deactivate through server administration "
            "under exclusive access before deleting\n" % name
        )
        return 3
    conn.command(b"DELETESCRIPT " + quote(name))
    return 0


def op_delete_active(conn, name):
    """Legacy explicit path: refuse active targets without a conditional clear.

    ManageSieve has no atomic check-and-deactivate. DELETESCRIPT itself refuses
    an active target, so an activation after our listing also fails safely.
    """
    return op_delete(conn, name)


def park(conn, name):
    """Return (parked, original); RENAMESCRIPT refuses an existing destination."""
    parked = name[:100] + PARK_SUFFIX
    conn.command(b"RENAMESCRIPT " + quote(name) + b" " + quote(parked))
    return parked, name


def op_remove_parked(conn, name, expected):
    """Finish explicitly selected recovery without inferring an original name."""
    stored = first_string(conn.command(b"GETSCRIPT " + quote(name)))
    if normalize(stored) != normalize(expected):
        raise SieveError("parked script changed since it was checked; left in place")
    return drop(conn, name)


def restore_parked(conn, parked, name):
    """Rename PARKED back to NAME; describe where the script was left."""
    with contextlib.suppress(SieveError):
        conn.command(b"RENAMESCRIPT " + quote(parked) + b" " + quote(name))
        return "left in place"
    return "kept as '%s' (a new '%s' exists)" % (parked, name)


# Operation name -> (handler, argument count).
OPS = {"list": (op_list, 0), "get": (op_get, 1), "install": (op_install, 2),
       "install-file": (op_install_file, 2), "remove": (op_remove, 2),
       "remove-parked": (op_remove_parked, 2), "delete": (op_delete, 1),
       "delete-active": (op_delete_active, 1)}


USAGE = ("usage: managesieve_client.py PASSWORD_VAR USER list|get NAME|install NAME SCRIPT"
         "|install-file NAME PATH|remove NAME SCRIPT|remove-parked NAME SCRIPT")
ENDPOINT_VARS = ("SIEVE_HOST", "SIEVE_PORT", "PURELYMAIL_SIEVE_HOST", "PURELYMAIL_SIEVE_PORT")


def config_error(argv, entry):
    """Return the first usage/config problem as a message, or None."""
    bad_usage = entry is None or len(argv) - 4 != entry[1]
    padded = list(argv) + [""] * 4  # checks below are evaluated eagerly
    checks = (
        (bad_usage, USAGE),
        (not HOST.strip(), "sieve: SIEVE_HOST is required (or legacy PURELYMAIL_SIEVE_HOST)"),
        (padded[1] in ENDPOINT_VARS, "sieve: endpoint variables cannot hold the password"),
        (not re.fullmatch(r"[0-9]{1,5}", PORT) or not 1 <= int(PORT) <= 65535,
         "sieve: invalid port (expected 1-65535)"),
        (not os.environ.get(padded[1], "").rstrip("\r\n"), "sieve: password not available"),
    )
    return next((message for failed, message in checks if failed), None)


def main(argv):
    entry = OPS.get(argv[3]) if len(argv) >= 4 else None
    error = config_error(argv, entry)
    if error:
        sys.stderr.write(error + "\n")
        return 2
    password = os.environ[argv[1]].rstrip("\r\n")
    conn = None
    try:
        conn = Conn(argv[2], password)
        return entry[0](conn, *argv[4:])
    except (SieveError, OSError, ValueError) as err:
        sys.stderr.write("sieve: %s\n" % err)
        return 1
    finally:
        if conn is not None:
            conn.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
