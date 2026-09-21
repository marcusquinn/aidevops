#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Run and administer the loopback-default prospecting service."""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import signal
import ssl
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

import prospecting_auth
from prospecting_api import ProspectingAPI
from prospecting_store import connect as connect_store
from prospecting_store import migrate

LOOPBACK = {"127.0.0.1", "::1", "localhost"}
UI_TYPES = {".css": "text/css", ".html": "text/html", ".js": "text/javascript", ".json": "application/json", ".svg": "image/svg+xml"}


def default_root() -> Path:
    configured = os.environ.get("AIDEVOPS_PROSPECTING_DIR")
    return Path(configured).expanduser() if configured else Path.home() / ".aidevops" / "prospecting"


def _private_write(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True)
        handle.write("\n")


def _handler(api: ProspectingAPI, ui_dir: Path | None) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "aidevops-prospecting/1"

        def log_message(self, _format: str, *_arguments: object) -> None:
            return

        def _run(self) -> None:
            if self.path.startswith("/ui/"):
                self._asset()
                return
            length = self.headers.get("Content-Length", "0")
            try:
                size = int(length)
            except ValueError:
                size = -1
            raw = self.rfile.read(size) if 0 <= size <= 65_536 else b""
            headers = {key: value for key, value in self.headers.items()}
            response = api.request(self.command, self.path, headers, raw)
            payload = json.dumps(response.body, separators=(",", ":")).encode()
            self.send_response(response.status)
            for key, value in response.headers.items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def _asset(self) -> None:
            if ui_dir is None:
                self.send_error(404)
                return
            relative = self.path.split("?", 1)[0][4:]
            candidate = (ui_dir / relative).resolve()
            try:
                candidate.relative_to(ui_dir)
            except ValueError:
                self.send_error(404)
                return
            media = UI_TYPES.get(candidate.suffix.lower())
            if media is None or not candidate.is_file() or candidate.is_symlink():
                self.send_error(404)
                return
            payload = candidate.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", media or mimetypes.guess_type(candidate.name)[0] or "application/octet-stream")
            self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; frame-ancestors 'none'")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        do_GET = _run
        do_POST = _run
        do_PATCH = _run
        do_PUT = _run
        do_DELETE = _run

    return Handler


def serve(args: argparse.Namespace) -> int:
    if args.bind not in LOOPBACK and (not args.allow_external or not args.tls_cert or not args.tls_key):
        raise ValueError("external binding requires --allow-external, --tls-cert, and --tls-key")
    ui_dir = args.ui_dir.resolve() if args.ui_dir else None
    if ui_dir is not None and (not ui_dir.is_dir() or ui_dir.is_symlink()):
        raise ValueError("UI directory must be a regular local directory")
    database = connect_store(args.store)
    migrate(database)
    auth_database = prospecting_auth.connect(args.store)
    api = ProspectingAPI(database, auth_database, host=args.bind)
    # sqlite connections stay on the serving thread; bounded local requests are
    # serialized rather than weakening sqlite's thread-affinity guard.
    server = HTTPServer((args.bind, args.port), _handler(api, ui_dir))
    if args.tls_cert and args.tls_key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(args.tls_cert, args.tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    state = args.store / "service-state.json"
    if state.exists():
        raise ValueError("service state already exists; run stop or remove stale state after verification")
    _private_write(state, {"schema": 1, "pid": os.getpid(), "bind": args.bind, "port": args.port})
    try:
        server.serve_forever()
    finally:
        server.server_close()
        database.close()
        auth_database.close()
        try:
            state.unlink()
        except FileNotFoundError:
            pass
    return 0


def start(args: argparse.Namespace) -> int:
    command = [sys.executable, str(Path(__file__).resolve()), "--store", str(args.store), "serve", "--bind", args.bind, "--port", str(args.port)]
    if args.allow_external:
        command.append("--allow-external")
    if args.tls_cert:
        command.extend(("--tls-cert", str(args.tls_cert)))
    if args.tls_key:
        command.extend(("--tls-key", str(args.tls_key)))
    if args.ui_dir:
        command.extend(("--ui-dir", str(args.ui_dir)))
    args.store.mkdir(mode=0o700, parents=True, exist_ok=True)
    log_path = args.store / "service.log"
    descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(descriptor, "ab", closefd=True) as log:
        subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)  # noqa: S603
    print(json.dumps({"status": "starting", "bind": args.bind, "port": args.port}))
    return 0


def stop(args: argparse.Namespace) -> int:
    state_path = args.store / "service-state.json"
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
        pid = int(state["pid"])
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        raise ValueError("valid service state is required") from error
    command_path = Path(f"/proc/{pid}/cmdline")
    if not command_path.is_file() or Path(__file__).name.encode() not in command_path.read_bytes():
        raise ValueError("refusing to signal a process that is not this service")
    os.kill(pid, signal.SIGTERM)
    print(json.dumps({"status": "stopping", "pid": pid}))
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("--store", type=Path, default=default_root(), help="private prospecting store directory")
    commands = root.add_subparsers(dest="command", required=True)
    for name in ("serve", "start"):
        command = commands.add_parser(name, help=f"{name} the service")
        command.add_argument("--bind", default="127.0.0.1")
        command.add_argument("--port", type=int, default=8765)
        command.add_argument("--allow-external", action="store_true")
        command.add_argument("--tls-cert", type=Path)
        command.add_argument("--tls-key", type=Path)
        command.add_argument("--ui-dir", type=Path)
    commands.add_parser("stop", help="stop the verified managed service")
    key = commands.add_parser("key-create", help="create a scoped read key in a private output file")
    key.add_argument("--project", action="append", required=True)
    key.add_argument("--output", required=True, type=Path)
    key.add_argument("--rotate")
    session = commands.add_parser("session-create", help="create an owner session in a private output file")
    session.add_argument("--project", action="append", required=True)
    session.add_argument("--ttl", type=int, default=3600)
    session.add_argument("--output", required=True, type=Path)
    revoke = commands.add_parser("revoke", help="revoke a key or session by non-secret identifier")
    revoke.add_argument("credential_id")
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "serve":
            return serve(args)
        if args.command == "start":
            return start(args)
        if args.command == "stop":
            return stop(args)
        database = prospecting_auth.connect(args.store)
        try:
            if args.command == "key-create":
                token = prospecting_auth.issue_read_key(database, args.project, rotate=args.rotate)
                _private_write(args.output, {"authorization": f"Bearer {token}"})
                result = {"created": True, "credential_id": token.split("_", 2)[1], "output": str(args.output)}
            elif args.command == "session-create":
                token, csrf = prospecting_auth.issue_owner_session(database, args.project, ttl_seconds=args.ttl)
                _private_write(args.output, {"cookie": f"prospecting_owner={token}", "csrf": csrf})
                result = {"created": True, "credential_id": token.split("_", 2)[1], "output": str(args.output)}
            elif args.command == "revoke":
                prospecting_auth.revoke(database, args.credential_id)
                result = {"revoked": args.credential_id}
            else:
                raise ValueError("unsupported command")
        finally:
            database.close()
        print(json.dumps(result, sort_keys=True))
        return 0
    except (OSError, ValueError, prospecting_auth.AuthError) as error:
        print(f"prospecting service: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
