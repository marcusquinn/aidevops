#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
oauth-pool-lib/pool_ops_token_utils.py — Token extraction/decode/read helpers.
"""
from __future__ import annotations
import json
import os
import sys
import time
from urllib.request import Request, urlopen

# Same endpoint as ANTHROPIC_PROFILE_URL in oauth-pool-constants.mjs.
ANTHROPIC_PROFILE_URL = "https://api.anthropic.com/api/oauth/profile"


def _org_fields(d: object) -> tuple[str, str]:
    """(orgId, orgName) from an Anthropic token/profile ``organization`` object.

    Mirrors extractAnthropicOrg() in oauth-pool-anthropic-org.mjs (GH#38959).
    Newlines are stripped so the line-oriented output stays aligned.
    """
    org = d.get('organization') if isinstance(d, dict) else None
    if not isinstance(org, dict) or not isinstance(org.get('uuid'), str):
        return '', ''
    org_id = org['uuid'].strip()
    if not org_id:
        return '', ''
    name = org.get('name') if isinstance(org.get('name'), str) else ''
    return org_id, ' '.join(name.split())


def cmd_extract_token_fields() -> None:
    """Print access, refresh, expires_in, orgId, orgName (one per line)."""
    try:
        d = json.load(sys.stdin)
        org_id, org_name = _org_fields(d)
        print(d.get('access_token', ''))
        print(d.get('refresh_token', ''))
        print(d.get('expires_in', 3600))
        print(org_id)
        print(org_name)
    except Exception:
        print('')
        print('')
        print(3600)
        print('')
        print('')


def _fetch_profile_org(token: str, ua: str) -> tuple[str, str]:
    """(orgId, orgName) from the Anthropic profile endpoint; ('', '') on any
    failure. Mirrors fetchAnthropicOrg(); the token never leaves this process."""
    if not token:
        return '', ''
    req = Request(ANTHROPIC_PROFILE_URL, method="GET")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("User-Agent", ua or "aidevops")
    try:
        with urlopen(req, timeout=10) as resp:
            return _org_fields(json.load(resp))
    except Exception:
        return '', ''


def cmd_anthropic_profile_org() -> None:
    """anthropic-profile-org: print orgId and orgName for a grant's token.

    Env: TOKEN, UA. Used when the token response carried no organization.
    """
    org_id, org_name = _fetch_profile_org(os.environ.get('TOKEN', ''), os.environ.get('UA', ''))
    print(org_id)
    print(org_name)


def cmd_legacy_seat_org() -> None:
    """legacy-seat-org: print orgId and orgName of EMAIL's single legacy seat.

    Stdin: pool JSON. Env: EMAIL, UA. Resolves only when exactly one anthropic
    seat for EMAIL has no orgId and its own access token is unexpired; it never
    refreshes, so enrolling one seat cannot mutate another. Mirrors
    resolveLegacySeatOrg() in oauth-pool-anthropic-org.mjs. Empty lines when
    unresolved, so upsert falls back to update-in-place with a warning.
    """
    org_id, org_name = '', ''
    try:
        pool = json.load(sys.stdin)
        email = os.environ.get('EMAIL', '')
        seats = [a for a in pool.get('anthropic', []) if isinstance(a, dict)
                 and a.get('email') == email and not a.get('orgId')]
        now_ms = int(time.time() * 1000)
        if len(seats) == 1 and seats[0].get('access') and (seats[0].get('expires') or 0) > now_ms:
            org_id, org_name = _fetch_profile_org(seats[0]['access'], os.environ.get('UA', ''))
    except Exception:
        org_id, org_name = '', ''
    print(org_id)
    print(org_name)

def cmd_extract_token_error() -> None:
    try:
        d = json.load(sys.stdin)
        parts = []
        for k in ('type', 'error', 'message', 'error_description'):
            if k in d and d[k]:
                parts.append(str(d[k]))
        print(': '.join(parts) if parts else 'unknown')
    except Exception:
        print('unknown')

def cmd_openai_read_auth() -> None:
    path = os.environ['AUTH_PATH']
    try:
        with open(path) as f:
            auth = json.load(f)
    except Exception:
        print(''); print(''); print(''); print('')
        sys.exit(0)
    entry = auth.get('openai', {}) if isinstance(auth, dict) else {}
    print(entry.get('access', ''))
    print(entry.get('refresh', ''))
    print(entry.get('expires', ''))
    print(entry.get('accountId', ''))

def cmd_cursor_read_auth() -> None:
    path = os.environ['AUTH_PATH']
    try:
        with open(path) as f:
            d = json.load(f)
        print(d.get('accessToken', ''))
        print(d.get('refreshToken', ''))
    except Exception:
        print(''); print('')

def cmd_cursor_decode_jwt() -> None:
    import base64
    token = os.environ['ACCESS']
    parts = token.split('.')
    if len(parts) >= 2:
        payload = parts[1] + '=' * ((-len(parts[1])) % 4)
        try:
            data = json.loads(base64.urlsafe_b64decode(payload))
            print(data.get('email', ''))
            print(data.get('exp', 0))
        except Exception:
            print(''); print(0)
    else:
        print(''); print(0)

def cmd_google_validate() -> None:
    from urllib.parse import urlparse
    from urllib.request import Request, urlopen
    from urllib.error import HTTPError, URLError
    token = os.environ['ACCESS']
    url = os.environ['HEALTH_URL']
    parsed = urlparse(url)
    if parsed.scheme != 'https' or not (parsed.hostname or '').endswith('.googleapis.com'):
        print('INVALID_URL')
        return
    try:
        req = Request(url, method='GET')
        req.add_header('Authorization', 'Bearer ' + token)
        urlopen(req, timeout=10)
        print('OK')
    except HTTPError as e:
        print('HTTP_' + str(e.code))
    except (URLError, OSError):
        print('NETWORK_ERROR')
    except Exception:
        print('ERROR')
