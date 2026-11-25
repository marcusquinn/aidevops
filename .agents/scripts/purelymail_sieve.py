#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""
purelymail_sieve.py - minimal ManageSieve (RFC 5804) client (GH#40230).

Run by purelymail-helper.sh inside secret injection:

  purelymail_sieve.py PASSWORD_VAR USER list
  purelymail_sieve.py PASSWORD_VAR USER get NAME
  purelymail_sieve.py PASSWORD_VAR USER install NAME SCRIPT
  purelymail_sieve.py PASSWORD_VAR USER remove NAME

The password is read from the environment variable named PASSWORD_VAR, never
from argv. `install` runs CHECKSCRIPT, PUTSCRIPT and SETACTIVE, then reads the
script back and fails unless it matches and is active. `remove` deactivates the
script when active, then deletes it.

Exit codes: 0 ok, 1 server/network error, 2 usage error, 4 no such script.
Host and port default to Purelymail; PURELYMAIL_SIEVE_HOST and
PURELYMAIL_SIEVE_PORT override them (for a local test server).
"""

import base64
import os
import re
import socket
import ssl
import sys

HOST = os.environ.get("PURELYMAIL_SIEVE_HOST", "mailserver.purelymail.com")
PORT = int(os.environ.get("PURELYMAIL_SIEVE_PORT", "4190"))
TIMEOUT = 30
PRE_TLS_WAIT = 1.0
CAPABILITY_WAIT = 2.0
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
        self.sock = socket.create_connection((HOST, PORT), timeout=TIMEOUT)
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
        plaintext_caps = self._drain_pre_tls()
        self.sock = ssl.create_default_context().wrap_socket(self.sock, server_hostname=HOST)
        # RFC 5804 section 2.2: the server re-sends capabilities over TLS.
        # Purelymail sends none there, so ask when none arrive. Wait for
        # application data, not socket readability: TLS 1.3 session tickets
        # make the socket readable without any ManageSieve response.
        if plaintext_caps or not self._data_within(CAPABILITY_WAIT):
            self.sock.sendall(b"CAPABILITY\r\n")
        status, _rest, _items = self.response()
        if status != "OK":
            raise SieveError("CAPABILITY after STARTTLS was " + status)

    def _data_within(self, seconds):
        """Return True when data is buffered or arrives within SECONDS."""
        if self.buf:
            return True
        self.sock.settimeout(seconds)
        try:
            self._fill()
            return True
        except socket.timeout:
            return False
        finally:
            self.sock.settimeout(TIMEOUT)

    def _drain_pre_tls(self):
        """Discard a plaintext capability listing sent before TLS, if any."""
        if not self._data_within(PRE_TLS_WAIT):
            return False
        self.response()
        if self.buf:
            raise SieveError("unexpected plaintext data before TLS handshake")
        return True

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
        try:
            self.sock.close()
        except OSError:
            pass


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


def op_remove(conn, name):
    if (name, True) in listing(conn):
        conn.command(b'SETACTIVE ""')
    conn.command(b"DELETESCRIPT " + quote(name))
    return 0


# Operation name -> (handler, argument count).
OPS = {"list": (op_list, 0), "get": (op_get, 1), "install": (op_install, 2), "remove": (op_remove, 1)}


def main(argv):
    entry = OPS.get(argv[3]) if len(argv) >= 4 else None
    if entry is None or len(argv) - 4 != entry[1]:
        sys.stderr.write("usage: purelymail_sieve.py PASSWORD_VAR USER list|get NAME|install NAME SCRIPT|remove NAME\n")
        return 2
    password = os.environ.get(argv[1], "").rstrip("\r\n")
    if not password:
        sys.stderr.write("sieve: password not available\n")
        return 2
    conn = None
    try:
        conn = Conn(argv[2], password)
        rc = entry[0](conn, *argv[4:])
        try:
            conn.command(b"LOGOUT")
        except (SieveError, OSError):
            pass
        return rc
    except (SieveError, OSError, ValueError) as err:
        sys.stderr.write("sieve: %s\n" % err)
        return 1
    finally:
        if conn is not None:
            conn.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
