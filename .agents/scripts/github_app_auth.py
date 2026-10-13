#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Shared GitHub.com App signing, exchange and scoped token cache.

Secrets travel only in memory, stdin, private cache files or child environments.
HTTP failures expose status codes, never response bodies or request headers.
"""

import base64
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


class AuthError(Exception):
    """A diagnostic safe to display without revealing credentials."""


def private_read(path, secret=False):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    with os.fdopen(os.open(path, flags)) as stream:
        info = os.fstat(stream.fileno())
        forbidden = 0o077 if secret else 0o022
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & forbidden):
            raise AuthError("Unsafe ownership or permissions on auth input")
        return stream.read()


def atomic_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".app-auth-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def api(method, endpoint, credential, body=None):
    if not endpoint.startswith("/") or endpoint.startswith("//"):
        raise AuthError("Invalid GitHub API endpoint")
    request = urllib.request.Request(
        "https://api.github.com" + endpoint,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": "Bearer " + credential,
                 "Accept": "application/vnd.github+json",
                 "Content-Type": "application/json",
                 "User-Agent": "aidevops-github-app"}, method=method)
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
            data = response.read()
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as error:
        raise AuthError(f"GitHub App API HTTP {error.code}") from None
    except (OSError, ValueError):
        raise AuthError("GitHub App API transport/JSON failure") from None


def jwt(profile):
    issuer = str(profile.get("client_id") or profile.get("app_id") or "")
    if not issuer:
        raise AuthError("App identity is missing")
    path = Path(os.path.expandvars(profile["private_key_path"])).expanduser()
    # Validate without copying the key to stdout or to an additional file.
    private_read(path, secret=True)
    def encode(value):
        return base64.urlsafe_b64encode(value).rstrip(b"=")

    now = int(time.time())
    unsigned = encode(b'{"alg":"RS256","typ":"JWT"}') + b"." + encode(
        json.dumps({"iat": now - 60, "exp": now + 540, "iss": issuer}).encode())
    openssl = shutil.which("openssl")
    if not openssl:
        raise AuthError("OpenSSL is required for GitHub App signing")
    # Resolved executable, fixed signer flags, validated local key, no shell.
    result = subprocess.run(  # nosec B603
        [openssl, "dgst", "-sha256", "-sign", str(path), "-binary"],
        input=unsigned, capture_output=True, timeout=15, check=False)
    if result.returncode or not result.stdout:
        raise AuthError("GitHub App JWT signing failed")
    return (unsigned + b"." + encode(result.stdout)).decode()


def exchange(profile, installation, repo=None, permissions=None):
    if not str(installation).isdigit():
        raise AuthError("Invalid installation ID")
    credential = jwt(profile)
    body = {}
    if repo:
        identity = api("GET", f"/app/installations/{installation}", credential)
        if (str(identity.get("app_id")) != str(profile["app_id"])
                or identity.get("account", {}).get("login", "").lower() != repo.split("/")[0].lower()
                or identity.get("suspended_at")):
            raise AuthError("App/installation/repository ownership mismatch or suspension")
        body = {"repositories": [repo.split("/")[1]], "permissions": permissions}
    response = api("POST", f"/app/installations/{installation}/access_tokens", credential, body)
    try:
        expiry = datetime.datetime.fromisoformat(response["expires_at"].replace("Z", "+00:00")).timestamp()
        if not isinstance(response["token"], str) or not response["token"] or expiry <= time.time() + 60:
            raise ValueError()
    except (KeyError, TypeError, ValueError):
        raise AuthError("Invalid installation-token response") from None
    response["expires_at_epoch"] = expiry
    return response


@contextlib.contextmanager
def lock(path, timeout=100):
    # Python descriptors are non-inheritable; this lock never survives exec.
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise AuthError("Unsafe token lock")
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise AuthError("Token refresh lock timed out") from None
                time.sleep(0.1)
        yield
    finally:
        os.close(fd)


def cached_token(profile, installation, repo, cache):
    permissions = profile.get("permissions", {"metadata": "read", "issues": "read", "pull_requests": "read"})
    if (not isinstance(permissions, dict) or not permissions
            or any(value != "read" for value in permissions.values())):
        raise AuthError("Pulse App profiles support read-only permissions")
    key_path = Path(os.path.expandvars(profile["private_key_path"])).expanduser()
    # Invalidate when the key rotates, even if the file name stays unchanged.
    key_digest = hashlib.sha256(private_read(key_path, secret=True).encode()).hexdigest()
    scope = json.dumps(["github.com", profile["app_id"], installation, repo.lower(), permissions, key_digest], sort_keys=True)
    digest = hashlib.sha256(scope.encode()).hexdigest()
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = cache.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise AuthError("Unsafe token cache directory")
    path = cache / f"scoped-{digest}.json"
    with lock(cache / f"scoped-{digest}.lock"):
        if path.exists() or path.is_symlink():
            try:
                value = json.loads(private_read(path, secret=True))
                if value["expires_at_epoch"] > time.time() + 120 and isinstance(value["token"], str) and value["token"]:
                    return value
            except (ValueError, KeyError, TypeError):
                pass
        value = exchange(profile, installation, repo, permissions)
        atomic_json(path, value)
        return value


def legacy_main():
    """Internal backend for the existing shell helper; stdout is captured there."""
    profile = {"app_id": os.environ.get("AIDEVOPS_GITHUB_APP_ID", ""),
               "private_key_path": os.environ.get("AIDEVOPS_GITHUB_APP_PRIVATE_KEY_PATH", "")}
    command = sys.argv[1]
    if command == "jwt":
        print(jwt(profile))
    elif command == "installation":
        print(api("GET", f"/repos/{sys.argv[2]}/installation", jwt(profile))["id"])
    elif command == "exchange":
        print(json.dumps(exchange(profile, sys.argv[2])))
    else:
        raise AuthError("Unknown internal auth operation")


if __name__ == "__main__":
    try:
        legacy_main()
    except (AuthError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(str(error) if isinstance(error, AuthError) else "GitHub App authentication failed", file=sys.stderr)
        sys.exit(1)
