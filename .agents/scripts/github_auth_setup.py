# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""One-command Pulse GitHub App setup: manifest creation and bulk read binding (GH#38337).

`app create` runs GitHub's App Manifest flow (github_auth_app_manifest), creates
the named profile, waits for installations and binds covered repositories.
`app bind` binds every covered pulse repository's read route in one locked
registry write (github_auth_app_bind). Keys, client secrets and installation
tokens never reach stdout, argv or logs.
"""
import argparse
import json
import sys
import time
import webbrowser

from github_app_auth import AuthError
from github_auth_app_bind import BindOptions, bind_app, installations
from github_auth_app_manifest import (NAME_LIMIT, OWNER, ManifestFlow, app_name, convert, gh_json,
                                      manifest, post_url, save_key)
from github_auth_config import load_profiles, paths
from github_auth_profiles import manage_profile

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
    options = BindOptions(args.profile, tuple(args.owner), dry_run=args.dry_run,
                          replace=args.replace, check=not args.no_check)
    return bind_app(options, registry_path, config_path)


def _login(owners):
    if not all(OWNER.fullmatch(owner) for owner in owners):
        raise AuthError("Owner must be a GitHub login")
    login = str(gh_json("user").get("login", ""))
    if not OWNER.fullmatch(login):
        raise AuthError("Could not resolve the authenticated GitHub login")
    return login


def create_app(args):
    owners = [args.owner] + list(args.install_on)
    login = _login(owners)
    name = app_name(args.name, args.owner, login)
    public = args.public or len(owners) > 1
    flow = ManifestFlow(post_url(args.owner, args.account_type, login))
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
    return bind_app(BindOptions(app["slug"], tuple(owners)), registry_path, config_path)


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
