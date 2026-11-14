# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""One-command Pulse GitHub App setup: manifest creation and bulk read binding (GH#38337).

`app create` runs GitHub's App Manifest flow through a loopback-only page, saves
the returned private key with mode 0600 and creates the named profile. `app bind`
discovers the App's installations and binds every covered pulse repository's
read route in one locked registry write. Keys, client secrets and installation
tokens never reach stdout, argv or logs.
"""
import argparse
import html
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

from github_app_auth import (AuthError, DEFAULT_PULSE_READ_PERMISSIONS, NoRedirect, api,
                             atomic_json, exchange, jwt)
from github_auth_config import entry_for, load_profiles, paths, registry, registry_lock, settings
from github_auth_policy import policy, validate_routes
from github_auth_profiles import manage_profile

NAME_LIMIT = 34
OWNER = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?")
CODE = re.compile(r"[A-Za-z0-9_-]{1,200}")
POLL_SECONDS = 5


def add_app_parser(actions):
    apps = actions.add_parser("app").add_subparsers(dest="app_action", required=True)
    command = apps.add_parser("create")
    command.add_argument("--owner", required=True, help="Account or organization that owns the App")
    command.add_argument("--install-on", action="append", default=[],
                         help="Additional account to install on (implies --public)")
    command.add_argument("--name", help=f"App name (max {NAME_LIMIT} characters)")
    command.add_argument("--account-type", choices=("auto", "user", "org"), default="auto")
    command.add_argument("--public", action="store_true",
                         help="Allow installation on other accounts you control")
    command.add_argument("--no-browser", action="store_true")
    command.add_argument("--no-bind", action="store_true")
    command.add_argument("--timeout", type=int, default=600)
    command = apps.add_parser("bind")
    command.add_argument("--profile", required=True)
    command.add_argument("--owner", action="append", default=[])
    command.add_argument("--dry-run", action="store_true")
    command.add_argument("--replace", action="store_true",
                         help="Rebind repositories already routed to another App profile")
    command.add_argument("--no-check", action="store_true")


def manage_app(args, registry_path, config_path):
    if args.app_action == "create":
        return create_app(args)
    return bind_app(args.profile, registry_path, config_path, owners=args.owner,
                    dry_run=args.dry_run, replace=args.replace, check=not args.no_check)


# ---------------------------------------------------------------- create

def _gh_json(endpoint):
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


def manifest(name, owner, login, redirect, public):
    homepage = f"https://github.com/{owner}"
    return {"name": name, "url": homepage, "public": bool(public),
            "description": f"aidevops Pulse read-only agent operated by {login}",
            "hook_attributes": {"url": homepage, "active": False},
            "redirect_url": redirect,
            "default_permissions": {perm: "read" for perm in DEFAULT_PULSE_READ_PERMISSIONS},
            "default_events": []}


class ManifestFlow:
    """Loopback page that posts the manifest and captures the one-time code."""

    def __init__(self, post_url):
        self.post_url = post_url
        self.state = secrets.token_urlsafe(24)
        self.code = None
        self.done = threading.Event()
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
        if not secrets.compare_digest(state, self.state) or not CODE.fullmatch(code):
            return 400, "<p>Invalid or stale setup response. Return to the terminal.</p>"
        self.code = code
        self.done.set()
        return 200, "<p>App created. Return to the terminal to install it.</p>"

    def _handler(self):
        flow = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):  # keep one-time codes out of logs
                return

            def do_GET(self):  # noqa: N802 (http.server API)
                parsed = urllib.parse.urlsplit(self.path)
                if parsed.path == "/start":
                    status, body = 200, flow.form()
                elif parsed.path == "/callback":
                    status, body = flow.callback(urllib.parse.parse_qs(parsed.query))
                else:
                    status, body = 404, "<p>Not found</p>"
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
    if (not str(value.get("id", "")).isdigit() or not isinstance(value.get("pem"), str)
            or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", str(value.get("slug", "")))
            or not str(value.get("html_url", "")).startswith("https://github.com/")):
        raise AuthError("Unexpected manifest conversion response")
    return value


def save_key(slug, pem):
    keys = Path.home() / ".config/aidevops/keys"
    keys.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = keys.lstat()
    if not keys.is_dir() or keys.is_symlink() or info.st_uid != os.getuid():
        raise AuthError("Unsafe key directory")
    os.chmod(keys, 0o700)
    path = keys / f"{slug}.pem"
    if path.exists() or path.is_symlink():
        path = keys / f"{slug}-{int(time.time())}.pem"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(pem)
        stream.flush()
        os.fsync(stream.fileno())
    return path


def _post_url(owner, account_type, login):
    if account_type == "auto":
        account_type = "org" if _gh_json(f"users/{owner}").get("type") == "Organization" else "user"
    if account_type == "org":
        return f"https://github.com/organizations/{owner}/settings/apps/new"
    if owner.lower() != login.lower():
        raise AuthError("A personal-account App can only be created by that account; "
                        "use --owner with your login or an organization you administer")
    return "https://github.com/settings/apps/new"


def create_app(args):
    owners = [args.owner] + list(args.install_on)
    if not all(OWNER.fullmatch(owner) for owner in owners):
        raise AuthError("Owner must be a GitHub login")
    login = str(_gh_json("user").get("login", ""))
    if not OWNER.fullmatch(login):
        raise AuthError("Could not resolve the authenticated GitHub login")
    name = args.name or default_name(args.owner, login)
    if len(name) > NAME_LIMIT or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 _.-]*", name):
        raise AuthError(f"App name must be at most {NAME_LIMIT} letters, digits, spaces, dots, underscores or hyphens")
    public = args.public or len(owners) > 1
    flow = ManifestFlow(_post_url(args.owner, args.account_type, login))
    value = manifest(name, args.owner, login, f"{flow.base}/callback", public)
    app = convert(flow.run(value, not args.no_browser, args.timeout))
    key = save_key(app["slug"], app.pop("pem"))
    app.pop("client_secret", None)
    app.pop("webhook_secret", None)
    _register_profile(app, key)
    install = f"{app['html_url']}/installations/new"
    print(json.dumps({"app": app["slug"], "app_id": str(app["id"]), "profile": app["slug"],
                      "private_key_path": str(key), "public": public, "install_url": install}, indent=2))
    if args.no_bind:
        return 0
    registry_path, config_path = paths()
    profile = load_profiles(config_path)["profiles"][app["slug"]]
    await_installations(profile, owners, install, not args.no_browser, args.timeout)
    return bind_app(app["slug"], registry_path, config_path, owners=owners)


def _register_profile(app, key):
    namespace = argparse.Namespace(profile_action="set", name=app["slug"], app_id=str(app["id"]),
                                   client_id=app.get("client_id"), private_key_path=str(key), replace=False)
    try:
        manage_profile(namespace, paths()[1])
    except AuthError as error:
        raise AuthError(f"{error}. The App ({app['slug']}, ID {app['id']}) and key ({key}) were saved; "
                        "create a profile with `aidevops github auth profile set`") from None


def await_installations(profile, owners, install_url, open_browser, timeout):
    wanted = {owner.lower() for owner in owners}
    print(f"Install the App on: {', '.join(owners)} via {install_url}", file=sys.stderr)
    if open_browser:
        webbrowser.open(install_url)
    deadline = time.monotonic() + timeout
    seen = set()
    while time.monotonic() < deadline:
        found = {i["account"]["login"].lower() for i in installations(profile)} & wanted
        if found - seen and wanted - found and open_browser:
            webbrowser.open(install_url)  # reopen for the next account
        seen = found
        if wanted <= found:
            return
        time.sleep(POLL_SECONDS)
    if not seen:
        raise AuthError("No installation appeared; install the App, then run `aidevops github auth app bind`")
    print(f"Still not installed on: {', '.join(sorted(wanted - seen))}; binding installed owners", file=sys.stderr)


# ---------------------------------------------------------------- bind

def installations(profile):
    credential = jwt(profile)
    result, page = [], 1
    while True:
        batch = api("GET", f"/app/installations?per_page=100&page={page}", credential)
        if not isinstance(batch, list):
            raise AuthError("Unexpected installations response")
        result.extend(item for item in batch if isinstance(item, dict) and isinstance(item.get("account"), dict))
        if len(batch) < 100:
            return result
        page += 1


def coverage(profile, installation):
    """Return lower-case covered full names, or None when every repository is covered."""
    if installation.get("repository_selection") == "all":
        return None
    token = exchange(profile, installation["id"])["token"]
    names, page = set(), 1
    while True:
        data = api("GET", f"/installation/repositories?per_page=100&page={page}", token)
        repos = data.get("repositories") if isinstance(data, dict) else None
        if not isinstance(repos, list):
            raise AuthError("Unexpected installation repositories response")
        names.update(str(repo.get("full_name", "")).lower() for repo in repos if isinstance(repo, dict))
        if len(repos) < 100:
            return names
        page += 1


def installation_index(profile, owners=()):
    wanted = {owner.lower() for owner in owners}
    index = {}
    for item in installations(profile):
        login = str(item["account"].get("login", "")).lower()
        if wanted and login not in wanted:
            continue
        suspended = bool(item.get("suspended_at"))
        index[login] = {"id": str(item["id"]), "suspended": suspended,
                        "covered": None if suspended else coverage(profile, item)}
    return index


def decide_entry(entry, index, profile_name, replace):
    """Return (reason, route); route is set only when the entry should be bound."""
    slug = str(entry.get("slug") or "")
    install = index.get(slug.split("/")[0].lower())
    if not entry.get("pulse"):
        return "not-pulse-enabled", None
    if entry.get("local_only"):
        return "local-only", None
    if "pulse_auth" in entry:
        return "legacy-binding-run-migrate", None
    if install is None:
        return "no-installation", None
    if install["suspended"]:
        return "installation-suspended", None
    if install["covered"] is not None and slug.lower() not in install["covered"]:
        return "not-in-selected-installation", None
    route = {"provider": "github-app", "profile": profile_name, "installation_id": install["id"]}
    try:
        current = policy(entry)
    except AuthError:
        return "invalid-existing-policy", None
    if current and current["read"] == route:
        return "already-bound", None
    if current and current["read"].get("provider") == "github-app" and not replace:
        return "bound-to-other-app", None
    return "bind", route


def plan(data, index, profile_name, owners=(), replace=False):
    wanted = {owner.lower() for owner in owners}
    decisions = []
    for entry in data["initialized_repos"]:
        slug = str(entry.get("slug") or "")
        if "/" not in slug or (wanted and slug.split("/")[0].lower() not in wanted):
            continue
        reason, route = decide_entry(entry, index, profile_name, replace)
        decisions.append({"repo": slug, "decision": reason, "route": route})
    return decisions


def _apply(registry_path, config_path, index, profile_name, owners, replace):
    with registry_lock(registry_path):
        data = registry(registry_path)
        decisions = plan(data, index, profile_name, owners, replace)
        for item in decisions:
            if item["decision"] != "bind":
                continue
            entry = entry_for(data, item["repo"])
            current = policy(entry) or {"write": {"provider": "inherit"}}
            routes = {"read": item["route"], "write": current["write"]}
            validate_routes(routes)
            entry.setdefault("github_auth", {})["pulse"] = routes
            settings(data, item["repo"], config_path)
        if any(item["decision"] == "bind" for item in decisions):
            atomic_json(registry_path, data)
    return decisions


def _check(repo):
    cli = Path(__file__).with_name("github_auth_cli.py")
    result = subprocess.run([sys.executable, str(cli), "check", repo, "--consumer", "pulse"],  # nosec B603
                            capture_output=True, text=True, timeout=120, check=False)
    return "passed" if result.returncode == 0 and '"read_check": "passed"' in result.stdout else "failed"


def bind_app(profile_name, registry_path, config_path, owners=(), dry_run=False, replace=False, check=True):
    profile = load_profiles(config_path)["profiles"].get(profile_name)
    if not isinstance(profile, dict):
        raise AuthError("Unknown GitHub auth profile")
    index = installation_index(profile, owners)
    if dry_run:
        decisions = plan(registry(registry_path), index, profile_name, owners, replace)
    else:
        decisions = _apply(registry_path, config_path, index, profile_name, owners, replace)
    counts = {}
    for item in decisions:
        counts[item["decision"]] = counts.get(item["decision"], 0) + 1
    result = {"profile": profile_name, "dry_run": dry_run, "installations": sorted(index), "counts": counts,
              "repositories": [{"repo": i["repo"], "decision": i["decision"]} for i in decisions
                               if i["decision"] != "not-pulse-enabled"]}
    if check and not dry_run:
        first = {}
        for item in decisions:
            if item["decision"] in ("bind", "already-bound"):
                first.setdefault(item["repo"].split("/")[0].lower(), item["repo"])
        result["read_checks"] = {repo: _check(repo) for repo in first.values()}
    print(json.dumps(result, indent=2))
    failed = [repo for repo, state in result.get("read_checks", {}).items() if state != "passed"]
    return 1 if failed else 0
