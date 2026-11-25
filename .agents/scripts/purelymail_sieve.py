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
import socket
import ssl
import sys

HOST = os.environ.get("PURELYMAIL_SIEVE_HOST", "mailserver.purelymail.com")
PORT = int(os.environ.get("PURELYMAIL_SIEVE_PORT", "4190"))
TIMEOUT = 30
PRE_TLS_WAIT = 1.0
CAPABILITY_WAIT = 2.0


class SieveError(Exception):
    """A non-OK server reply or a protocol violation."""


class Atom(str):
    """An unquoted protocol token (OK, NO, ACTIVE, response codes)."""


def quote(text):
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return b'"' + escaped.encode("utf-8") + b'"'


class Conn:
    """One authenticated ManageSieve session over STARTTLS."""

    def __init__(self, user, password):
        raw = socket.create_connection((HOST, PORT), timeout=TIMEOUT)
        self.sock = raw
        self.buf = b""
        status, _rest, items = self.response()
        if status != "OK":
            raise SieveError("greeting was " + status)
        if "STARTTLS" not in [str(i[0]).upper() for i in items if i]:
            raise SieveError("server does not offer STARTTLS")
        self.command(b"STARTTLS")
        # Purelymail quirk: after "OK" to STARTTLS it re-sends its capability
        # list in plaintext, before the TLS handshake. Drain and discard that
        # unauthenticated listing, or its bytes corrupt the handshake.
        plaintext_caps = self._drain_pre_tls(raw)
        self.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=HOST)
        # RFC 5804 section 2.2: the server re-sends capabilities over TLS.
        # Purelymail sends none there, so ask. Wait for application data, not
        # socket readability: TLS 1.3 session tickets make the socket readable
        # without any ManageSieve response.
        if plaintext_caps:
            self.sock.sendall(b"CAPABILITY\r\n")
        else:
            self.sock.settimeout(CAPABILITY_WAIT)
            try:
                self._fill()
            except socket.timeout:
                self.sock.sendall(b"CAPABILITY\r\n")
            finally:
                self.sock.settimeout(TIMEOUT)
        status, _rest, _items = self.response()
        if status != "OK":
            raise SieveError("CAPABILITY after STARTTLS was " + status)
        token = base64.b64encode(("\0" + user + "\0" + password).encode("utf-8"))
        self.command(b'AUTHENTICATE "PLAIN" ' + quote(token.decode("ascii")))

    def _drain_pre_tls(self, raw):
        """Discard a plaintext capability listing sent before TLS, if any."""
        if not self.buf:
            raw.settimeout(PRE_TLS_WAIT)
            try:
                self._fill()
            except socket.timeout:
                return False
            finally:
                raw.settimeout(TIMEOUT)
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
        i = 0
        while i < len(line):
            char = line[i:i + 1]
            if char == b" ":
                i += 1
            elif char == b'"':
                i += 1
                buf = bytearray()
                while i < len(line) and line[i:i + 1] != b'"':
                    if line[i:i + 1] == b"\\":
                        i += 1
                    buf += line[i:i + 1]
                    i += 1
                i += 1
                out.append(buf.decode("utf-8", "replace"))
            elif char == b"{":
                end = line.find(b"}", i)
                if end < 0:
                    raise SieveError("malformed literal")
                size = int(line[i + 1:end].rstrip(b"+"))
                out.append(self.read(size).decode("utf-8", "replace"))
                line = self.readline()
                i = 0
            elif char == b"(":
                end = line.find(b")", i)
                end = len(line) - 1 if end < 0 else end
                out.append(Atom(line[i:end + 1].decode("utf-8", "replace")))
                i = end + 1
            else:
                end = line.find(b" ", i)
                end = len(line) if end < 0 else end
                out.append(Atom(line[i:end].decode("utf-8", "replace")))
                i = end
        return out

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


def active_names(conn):
    return [str(i[0]) for i in conn.command(b"LISTSCRIPTS")
            if len(i) > 1 and str(i[1]).upper() == "ACTIVE"]


def run(conn, op, args):
    if op == "list":
        for item in conn.command(b"LISTSCRIPTS"):
            if item:
                active = len(item) > 1 and str(item[1]).upper() == "ACTIVE"
                print("%s\t%s" % (item[0], "active" if active else "inactive"))
    elif op == "get" and len(args) == 1:
        try:
            items = conn.command(b"GETSCRIPT " + quote(args[0]))
        except SieveError as err:
            if "NONEXISTENT" in str(err).upper():
                return 4
            raise
        sys.stdout.write(items[0][0] if items and items[0] else "")
    elif op == "install" and len(args) == 2:
        name, content = args
        payload = content.encode("utf-8")
        conn.command(b"CHECKSCRIPT", payload)
        conn.command(b"PUTSCRIPT " + quote(name), payload)
        conn.command(b"SETACTIVE " + quote(name))
        items = conn.command(b"GETSCRIPT " + quote(name))
        stored = items[0][0] if items and items[0] else ""
        if normalize(stored) != normalize(content):
            raise SieveError("read-back differs from the script sent")
        if name not in active_names(conn):
            raise SieveError("script stored but not active")
    elif op == "remove" and len(args) == 1:
        name = args[0]
        if name in active_names(conn):
            conn.command(b'SETACTIVE ""')
        conn.command(b"DELETESCRIPT " + quote(name))
    else:
        sys.stderr.write("sieve: unknown operation or arguments\n")
        return 2
    return 0


def main(argv):
    if len(argv) < 4:
        sys.stderr.write("usage: purelymail_sieve.py PASSWORD_VAR USER OP [ARGS]\n")
        return 2
    password = os.environ.get(argv[1], "").rstrip("\r\n")
    if not password:
        sys.stderr.write("sieve: password not available\n")
        return 2
    conn = None
    try:
        conn = Conn(argv[2], password)
        rc = run(conn, argv[3], argv[4:])
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
