# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""GitHub App Manifest flow for `aidevops github auth app create` (GH#38337).

A loopback-only page posts a read-only manifest to GitHub, captures the
one-time code, converts it once and saves the private key with mode 0600.
Keys, client secrets and one-time codes never reach stdout, argv or logs.
"""
import html
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import subprocess  # nosec B404 -- fixed `gh api` argv only, never a shell
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

from github_app_auth import AuthError, DEFAULT_PULSE_READ_PERMISSIONS, NoRedirect

NAME_LIMIT = 34
OWNER = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?")
CODE = re.compile(r"[A-Za-z0-9_-]{1,200}")
APP_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9 _.-]*")


def gh_json(endpoint):
    result = subprocess.run(["gh", "api", endpoint], capture_output=True, text=True,  # nosec B603 B607
                            timeout=30, check=False)
    if result.returncode:
        raise AuthError(f"gh api {endpoint} failed; is gh authenticated?")
    return json.loads(result.stdout)


def default_name(owner, login):
    base = f"{owner}-agent" if owner.lower() == login.lower() else f"{owner}-agent-{login}"
    if len(base) > NAME_LIMIT:
        base = f"{owner}-agent"[:NAME_LIMIT].rstrip("-")
    return base


def app_name(requested, owner, login):
    name = requested or default_name(owner, login)
    if len(name) > NAME_LIMIT or not APP_NAME.fullmatch(name):
        raise AuthError(f"App name must be at most {NAME_LIMIT} letters, digits, spaces, dots, underscores or hyphens")
    return name


def manifest(name, owner, login, redirect, public):
    homepage = f"https://github.com/{owner}"
    return {"name": name, "url": homepage, "public": bool(public),
            "description": f"aidevops Pulse read-only agent operated by {login}",
            "hook_attributes": {"url": homepage, "active": False},
            "redirect_url": redirect,
            "default_permissions": {perm: "read" for perm in DEFAULT_PULSE_READ_PERMISSIONS},
            "default_events": []}


def post_url(owner, account_type, login):
    if account_type == "auto":
        account_type = "org" if gh_json(f"users/{owner}").get("type") == "Organization" else "user"
    if account_type == "org":
        return f"https://github.com/organizations/{owner}/settings/apps/new"
    if owner.lower() != login.lower():
        raise AuthError("A personal-account App can only be created by that account; "
                        "use --owner with your login or an organization you administer")
    return "https://github.com/settings/apps/new"


class ManifestFlow:
    """Loopback page that posts the manifest and captures the one-time code."""

    def __init__(self, target_url):
        self.post_url = target_url
        self.state = secrets.token_urlsafe(24)
        self.code = None
        self.done = threading.Event()
        self._accept = threading.Lock()
        self.manifest_json = ""
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), self._handler())

    @property
    def base(self):
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def form(self):
        action = html.escape(f"{self.post_url}?state={self.state}", quote=True)
        value = html.escape(self.manifest_json, quote=True)
        return ("<!doctype html><meta charset=utf-8><title>aidevops GitHub App setup</title>"
                f"<form id=f method=post action=\"{action}\">"
                f"<input type=hidden name=manifest value=\"{value}\">"
                "<p>Creating a read-only GitHub App for aidevops Pulse.</p>"
                "<button type=submit>Continue to GitHub</button></form>"
                "<script>document.getElementById('f').submit()</script>")

    def callback(self, query):
        state = (query.get("state") or [""])[0]
        code = (query.get("code") or [""])[0]
        # The state is single-use: validate and consume it atomically so a
        # concurrent or replayed callback cannot replace the accepted code.
        with self._accept:
            if (self.done.is_set() or not secrets.compare_digest(state, self.state)
                    or not CODE.fullmatch(code)):
                return 400, "<p>Invalid or stale setup response. Return to the terminal.</p>"
            self.code = code
            self.done.set()
        return 200, "<p>App created. Return to the terminal to install it.</p>"

    def respond(self, path):
        parsed = urllib.parse.urlsplit(path)
        if parsed.path == "/start":
            return 200, self.form()
        if parsed.path == "/callback":
            return self.callback(urllib.parse.parse_qs(parsed.query))
        return 404, "<p>Not found</p>"

    def _handler(self):
        flow = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):  # keep one-time codes out of logs
                return

            def do_GET(self):  # noqa: N802 (http.server API)
                status, body = flow.respond(self.path)
                data = body.encode()
                self.send_response(status)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        return Handler

    def run(self, manifest_value, open_browser, timeout):
        self.manifest_json = json.dumps(manifest_value)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        try:
            start = f"{self.base}/start"
            print(f"Open {start} to create the App (loopback only).", file=sys.stderr)
            if open_browser:
                webbrowser.open(start)
            if not self.done.wait(timeout):
                raise AuthError("Timed out waiting for GitHub App creation")
            return self.code
        finally:
            self.server.shutdown()
            self.server.server_close()


def _valid_conversion(value):
    return (str(value.get("id", "")).isdigit() and isinstance(value.get("pem"), str)
            and bool(re.fullmatch(r"[a-z0-9][a-z0-9-]*", str(value.get("slug", ""))))
            and str(value.get("html_url", "")).startswith("https://github.com/"))


def convert(code):
    request = urllib.request.Request(
        f"https://api.github.com/app-manifests/{code}/conversions", data=b"", method="POST",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "aidevops-github-app"})
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
            value = json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise AuthError(f"Manifest conversion HTTP {error.code}") from None
    except (OSError, ValueError):
        raise AuthError("Manifest conversion transport/JSON failure") from None
    if not isinstance(value, dict) or not _valid_conversion(value):
        raise AuthError("Unexpected manifest conversion response")
    return value


def _key_directory():
    keys = Path.home() / ".config/aidevops/keys"
    keys.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = keys.lstat()
    if not keys.is_dir() or keys.is_symlink() or info.st_uid != os.getuid():
        raise AuthError("Unsafe key directory")
    os.chmod(keys, 0o700)  # nosec B103 nosemgrep -- owner-only private-key directory; traversal needs +x
    return keys


def save_key(slug, pem):
    keys = _key_directory()
    path = keys / f"{slug}.pem"
    if path.exists() or path.is_symlink():
        path = keys / f"{slug}-{int(time.time())}.pem"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(pem)
        stream.flush()
        os.fsync(stream.fileno())
    return path
