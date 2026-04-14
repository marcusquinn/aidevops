#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
oauth-pool-lib/pool_ops_token_utils.py — Token extraction/decode/read helpers.

Extracted from the pool_ops.py monolith during the t2069 decomposition.
These commands read from stdin or env vars and print structured output
consumed by the shell wrapper (oauth-pool-helper.sh).
"""

from __future__ import annotations

import json
import os
import sys


# ---------------------------------------------------------------------------
# extract-token-fields: Extract access_token, refresh_token, expires_in
# from a JSON token response. Reads JSON from stdin.
# ---------------------------------------------------------------------------

def cmd_extract_token_fields() -> None:
    d = json.load(sys.stdin)
    print(d.get('access_token', ''))
    print(d.get('refresh_token', ''))
    print(d.get('expires_in', 3600))


# ---------------------------------------------------------------------------
# extract-token-error: Extract error message from token response.
# Reads JSON from stdin.
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# openai-read-auth: Read OpenAI auth fields from OpenCode auth file.
# Env: AUTH_PATH
# ---------------------------------------------------------------------------

def cmd_openai_read_auth() -> None:
    path = os.environ['AUTH_PATH']
    try:
        with open(path) as f:
            auth = json.load(f)
    except Exception:
        print('')
        print('')
        print('')
        print('')
        sys.exit(0)

    entry = auth.get('openai', {}) if isinstance(auth, dict) else {}
    print(entry.get('access', ''))
    print(entry.get('refresh', ''))
    print(entry.get('expires', ''))
    print(entry.get('accountId', ''))


# ---------------------------------------------------------------------------
# cursor-read-auth: Read Cursor auth.json fields.
# Env: AUTH_PATH
# ---------------------------------------------------------------------------

def cmd_cursor_read_auth() -> None:
    path = os.environ['AUTH_PATH']
    try:
        with open(path) as f:
            d = json.load(f)
        print(d.get('accessToken', ''))
        print(d.get('refreshToken', ''))
    except Exception:
        print('')
        print('')


# ---------------------------------------------------------------------------
# cursor-decode-jwt: Decode JWT fields from access token.
# Env: ACCESS
# ---------------------------------------------------------------------------

def cmd_cursor_decode_jwt() -> None:
    import base64

    token = os.environ['ACCESS']
    parts = token.split('.')
    if len(parts) >= 2:
        payload = parts[1] + '=' * (4 - len(parts[1]) % 4)
        try:
            data = json.loads(base64.urlsafe_b64decode(payload))
            print(data.get('email', ''))
            print(data.get('exp', 0))
        except Exception:
            print('')
            print(0)
    else:
        print('')
        print(0)


# ---------------------------------------------------------------------------
# google-validate: Validate token against Google API.
# Env: ACCESS, HEALTH_URL
# ---------------------------------------------------------------------------

def cmd_google_validate() -> None:
    from urllib.request import Request, urlopen
    from urllib.error import HTTPError, URLError

    token = os.environ['ACCESS']
    url = os.environ['HEALTH_URL']
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
