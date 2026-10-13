# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Pure schema validation and the single legacy policy adapter."""

from github_app_auth import AuthError


def validate_route(route, operation):
    if not isinstance(route, dict):
        raise AuthError("GitHub auth route must be an object")
    provider = route.get("provider")
    if provider == "inherit":
        if set(route) != {"provider"}:
            raise AuthError("An inherit route cannot contain App credentials")
    elif provider == "github-app":
        if operation != "read":
            raise AuthError("GitHub App write routing is not supported in this read-only release")
        if set(route) != {"provider", "profile", "installation_id"}:
            raise AuthError("App route requires only provider, profile and installation_id")
        if not isinstance(route["profile"], str) or not route["profile"].strip():
            raise AuthError("App route requires a nonempty profile")
        if not str(route["installation_id"]).isdigit():
            raise AuthError("App route requires a numeric installation_id")
    else:
        raise AuthError("Unsupported GitHub auth provider")


def validate_routes(routes):
    if not isinstance(routes, dict) or set(routes) != {"read", "write"}:
        raise AuthError("GitHub auth policy requires explicit read and write routes")
    for operation, route in routes.items():
        validate_route(route, operation)


def policy(entry):
    auth = entry.get("github_auth", {})
    if not isinstance(auth, dict) or set(auth) - {"pulse"}:
        raise AuthError("Only the pulse GitHub auth consumer is supported")
    if "pulse_auth" in entry and "pulse" in auth:
        raise AuthError("Conflicting pulse_auth and github_auth.pulse; remove one explicitly")
    if "pulse_auth" in entry:
        routes = {"read": entry["pulse_auth"], "write": {"provider": "inherit"}}
    else:
        routes = auth.get("pulse")
    if "pulse_auth" in entry or "pulse" in auth:
        validate_routes(routes)
    return routes
