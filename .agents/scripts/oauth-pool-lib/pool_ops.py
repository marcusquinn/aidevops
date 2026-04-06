#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
oauth-pool-lib/pool_ops.py — Python operations for oauth-pool-helper.sh

Extracted from inline Python blocks to reduce shell nesting depth.
Each subcommand reads configuration from environment variables and
pool data from stdin or the pool file directly.

Usage:
  python3 pool_ops.py <command>

Commands:
  auto-clear          Atomically clear expired cooldowns in the pool file
  upsert              Upsert an account into the pool (reads pool JSON from stdin)
  rotate              Rotate to next available account (atomic, with lock)
  refresh             Refresh expired tokens (atomic, with lock)
  mark-failure        Mark current account as failed (atomic, with lock)
  check-accounts      Print account details for health check
  check-validate      Validate a token against provider API
  check-meta          Print account metadata (status, cooldown, last used)
  check-expiry        Print token expiry info
  normalize-cooldowns Normalize expired cooldowns (reads pool JSON from stdin)
  reset-cooldowns     Reset cooldowns for accounts (reads pool JSON from stdin)
  set-priority        Set priority on an account (reads pool JSON from stdin)
  remove-account      Remove an account from pool (reads pool JSON from stdin)
  assign-pending      Assign pending token to account (reads pool JSON from stdin)
  check-pending       Check if pending token exists (reads pool JSON from stdin)
  list-pending        List accounts for pending assignment (reads pool JSON from stdin)
  import-check        Check if email exists in pool (reads pool JSON from stdin)
  status-stats        Print pool statistics (reads pool JSON from stdin)
  list-accounts       List accounts with status (reads pool JSON from stdin)

Security: No token values are printed to stdout/stderr (except structured
output consumed by the shell wrapper). Secrets flow via env vars, never argv.
"""

import json
import os
import sys
import tempfile
import time


# ---------------------------------------------------------------------------
# Cross-platform exclusive file lock (stdlib only, no pip dependencies).
# ---------------------------------------------------------------------------

def _acquire_lock(lock_fd):
    """Acquire an exclusive lock on the given file descriptor."""
    if sys.platform == 'win32':
        import msvcrt
        deadline = time.time() + 30
        while True:
            try:
                lock_fd.seek(0)
                msvcrt.locking(lock_fd.fileno(), msvcrt.LK_NBLCK, 1)
                return
            except OSError:
                if time.time() >= deadline:
                    raise
                time.sleep(0.1)
    else:
        import fcntl
        fcntl.flock(lock_fd, fcntl.LOCK_EX)


def _release_lock(lock_fd):
    """Release an exclusive lock on the given file descriptor."""
    if sys.platform == 'win32':
        import msvcrt
        try:
            lock_fd.seek(0)
            msvcrt.locking(lock_fd.fileno(), msvcrt.LK_UNLCK, 1)
        except OSError:
            pass
    else:
        import fcntl
        fcntl.flock(lock_fd, fcntl.LOCK_UN)


def _atomic_write_json(path, data):
    """Atomically write JSON data to a file (write-to-temp then rename)."""
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix='.tmp-', suffix='.tmp')
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(data, f, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------
# auto-clear: Atomically clear expired cooldowns in the pool file.
# Env: POOL_FILE_PATH
# ---------------------------------------------------------------------------

def cmd_auto_clear():
    pool_path = os.environ['POOL_FILE_PATH']

    lock_path = pool_path + '.lock'
    lock_fd = open(lock_path, 'w')
    try:
        _acquire_lock(lock_fd)
        with open(pool_path) as f:
            pool = json.load(f)

        now = int(time.time() * 1000)
        changed = False
        for provider in list(pool.keys()):
            if provider.startswith('_'):
                continue
            accounts = pool.get(provider, [])
            if not isinstance(accounts, list):
                continue
            for acct in accounts:
                cd = acct.get('cooldownUntil')
                if cd and isinstance(cd, (int, float)) and cd > 0 and cd <= now:
                    if acct.get('status') == 'rate-limited':
                        acct['status'] = 'idle'
                    acct['cooldownUntil'] = 0
                    changed = True
        if changed:
            _atomic_write_json(pool_path, pool)
            print('CHANGED')
        else:
            print('UNCHANGED')
    finally:
        _release_lock(lock_fd)
        lock_fd.close()


# ---------------------------------------------------------------------------
# upsert: Upsert an account into the pool.
# Reads pool JSON from stdin.
# Env: PROVIDER, EMAIL, ACCESS, REFRESH, EXPIRES, NOW_ISO, ACCOUNT_ID
# ---------------------------------------------------------------------------

def cmd_upsert():
    pool = json.load(sys.stdin)
    provider = os.environ['PROVIDER']
    email = os.environ['EMAIL']
    access = os.environ['ACCESS']
    refresh = os.environ['REFRESH']
    expires = int(os.environ['EXPIRES'])
    now_iso = os.environ['NOW_ISO']
    account_id = os.environ.get('ACCOUNT_ID', '')

    if provider not in pool:
        pool[provider] = []

    found = False
    for account in pool[provider]:
        if account.get('email') == email:
            account['access'] = access
            account['refresh'] = refresh
            account['expires'] = expires
            account['lastUsed'] = now_iso
            account['status'] = 'active'
            account['cooldownUntil'] = None
            if account_id:
                account['accountId'] = account_id
            found = True
            break

    if not found:
        entry = {
            'email': email,
            'access': access,
            'refresh': refresh,
            'expires': expires,
            'added': now_iso,
            'lastUsed': now_iso,
            'status': 'active',
            'cooldownUntil': None,
        }
        if account_id:
            entry['accountId'] = account_id
        pool[provider].append(entry)

    json.dump(pool, sys.stdout, indent=2)


# ---------------------------------------------------------------------------
# normalize-cooldowns: Normalize expired cooldowns.
# Reads pool JSON from stdin.
# Env: PROVIDER (provider name or "all")
# ---------------------------------------------------------------------------

def cmd_normalize_cooldowns():
    provider = os.environ.get('PROVIDER', 'all')
    pool = json.load(sys.stdin)
    now = int(time.time() * 1000)
    updated = 0
    providers = list(pool.keys()) if provider == 'all' else [provider]
    for prov in providers:
        if prov.startswith('_'):
            continue
        for account in pool.get(prov, []):
            cooldown_ms = account.get('cooldownUntil') or 0
            if cooldown_ms > 0 and cooldown_ms <= now:
                account['status'] = 'idle'
                account['cooldownUntil'] = 0
                updated += 1
    json.dump({'updated': updated, 'pool': pool}, sys.stdout, separators=(',', ':'))


# ---------------------------------------------------------------------------
# rotate: Rotate to next available account.
# Env: POOL_FILE_PATH, AUTH_FILE_PATH, PROVIDER, UA_HEADER
# ---------------------------------------------------------------------------

def cmd_rotate():
    import urllib.request
    import urllib.error
    from datetime import datetime, timezone

    pool_path = os.environ['POOL_FILE_PATH']
    auth_path = os.environ['AUTH_FILE_PATH']
    provider = os.environ['PROVIDER']

    TOKEN_URLS = {
        'anthropic': 'https://platform.claude.com/v1/oauth/token',
        'openai':    'https://auth.openai.com/oauth/token',
        'google':    'https://oauth2.googleapis.com/token',
    }
    CLIENT_IDS = {
        'anthropic': '9d1c250a-e61b-44d9-88ed-5944d1962f5e',
        'openai':    'app_EMoamEEZ73f0CkXaXp7hrann',
        'google':    '681255809395-oo8ft6t5t0rnmhfqgpnkqtev5b9a2i5j.apps.googleusercontent.com',
    }

    def _try_refresh(account, prov, now_ms):
        refresh_tok = account.get('refresh', '')
        token_url = TOKEN_URLS.get(prov, '')
        client_id = CLIENT_IDS.get(prov, '')
        if not (refresh_tok and token_url and client_id):
            return
        body = json.dumps({
            'grant_type': 'refresh_token',
            'refresh_token': refresh_tok,
            'client_id': client_id,
        }).encode('utf-8')
        req = urllib.request.Request(
            token_url, data=body,
            headers={'Content-Type': 'application/json',
                     'User-Agent': os.environ.get('UA_HEADER', 'aidevops/1.0')},
            method='POST',
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                rdata = json.loads(resp.read().decode('utf-8'))
            new_access = rdata.get('access_token', '')
            if new_access:
                account['access'] = new_access
                account['refresh'] = rdata.get('refresh_token', refresh_tok)
                account['expires'] = now_ms + int(rdata.get('expires_in', 3600)) * 1000
                account['status'] = 'active'
                print('REFRESHED', file=sys.stderr)
        except (urllib.error.URLError, urllib.error.HTTPError) as e:
            print(f'REFRESH_FAILED:{e}', file=sys.stderr)

    lock_path = pool_path + '.lock'
    lock_fd = open(lock_path, 'w')
    try:
        _acquire_lock(lock_fd)

        with open(pool_path) as f:
            pool = json.load(f)
        accounts = pool.get(provider, [])
        if len(accounts) < 2:
            print('ERROR:need_accounts')
            sys.exit(0)

        with open(auth_path) as f:
            auth = json.load(f)
        current_auth = auth.get(provider, {})
        current_access = current_auth.get('access', '')

        current_email = None
        for a in accounts:
            if a.get('access', '') == current_access and current_access:
                current_email = a.get('email', 'unknown')
                break
        if current_email is None:
            sorted_by_used = sorted(accounts, key=lambda a: a.get('lastUsed', ''), reverse=True)
            current_email = sorted_by_used[0].get('email', 'unknown')

        now_ms = int(time.time() * 1000)
        # Tier 1: non-current accounts that are available right now
        candidates = [
            a for a in accounts
            if a.get('email') != current_email
            and a.get('status', 'active') in ('active', 'idle')
            and (not a.get('cooldownUntil') or a['cooldownUntil'] <= now_ms)
        ]
        all_rate_limited = False
        if not candidates:
            # Tier 2: ALL accounts sorted by shortest remaining cooldown
            candidates = sorted(
                accounts,
                key=lambda a: a.get('cooldownUntil') or 0,
            )
            all_rate_limited = True
        if not candidates:
            print('ERROR:no_alternate')
            sys.exit(0)

        if not all_rate_limited:
            candidates.sort(key=lambda a: (-(a.get('priority') or 0), a.get('lastUsed', '')))

        next_account = candidates[0]
        next_email = next_account.get('email', 'unknown')

        # Auto-refresh if expired and refresh token available
        if next_account.get('expires', 0) <= now_ms and next_account.get('refresh'):
            _try_refresh(next_account, provider, now_ms)

        auth_entry = {
            'type':    current_auth.get('type', 'oauth'),
            'refresh': next_account.get('refresh', ''),
            'access':  next_account.get('access', ''),
            'expires': next_account.get('expires', 0),
        }
        if provider == 'openai':
            account_id = next_account.get('accountId', current_auth.get('accountId', ''))
            if account_id:
                auth_entry['accountId'] = account_id
        auth[provider] = auth_entry
        _atomic_write_json(auth_path, auth)

        now_iso = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        for a in pool[provider]:
            if a.get('email') == next_email:
                a['lastUsed'] = now_iso
                break
        _atomic_write_json(pool_path, pool)

    finally:
        _release_lock(lock_fd)
        lock_fd.close()

    if all_rate_limited:
        cd = next_account.get('cooldownUntil') or 0
        wait_mins = max(0, (cd - now_ms + 59999) // 60000) if cd > now_ms else 0
        print(f'OK_COOLDOWN:{wait_mins}')
    else:
        print('OK')
    print(current_email)
    print(next_email)


# ---------------------------------------------------------------------------
# refresh: Refresh expired tokens.
# Env: POOL_FILE_PATH, AUTH_FILE_PATH, PROVIDER, TARGET_EMAIL, UA_HEADER
# ---------------------------------------------------------------------------

def cmd_refresh():
    import urllib.request
    import urllib.error

    pool_path = os.environ['POOL_FILE_PATH']
    auth_path = os.environ['AUTH_FILE_PATH']
    provider = os.environ['PROVIDER']
    target_email = os.environ['TARGET_EMAIL']
    ua_header = os.environ.get('UA_HEADER', 'aidevops/1.0')

    token_urls = {
        'anthropic': 'https://platform.claude.com/v1/oauth/token',
        'openai': 'https://auth.openai.com/oauth/token',
        'google': 'https://oauth2.googleapis.com/token',
    }
    client_ids = {
        'anthropic': '9d1c250a-e61b-44d9-88ed-5944d1962f5e',
        'openai': 'app_EMoamEEZ73f0CkXaXp7hrann',
        'google': '681255809395-oo8ft6t5t0rnmhfqgpnkqtev5b9a2i5j.apps.googleusercontent.com',
    }

    token_url = token_urls.get(provider, '')
    client_id = client_ids.get(provider, '')
    if not token_url or not client_id:
        print('ERROR:no_endpoint')
        sys.exit(0)

    lock_path = pool_path + '.lock'
    lock_fd = open(lock_path, 'w')
    try:
        _acquire_lock(lock_fd)

        with open(pool_path) as f:
            pool = json.load(f)

        accounts = pool.get(provider, [])
        now_ms = int(time.time() * 1000)
        refreshed = []
        failed = []

        for acct in accounts:
            email = acct.get('email', 'unknown')
            if target_email != 'all' and email != target_email:
                continue

            refresh_tok = acct.get('refresh', '')
            expires = acct.get('expires', 0)

            if not refresh_tok:
                continue

            # Only refresh if expired or expiring within 1 hour (3600000ms)
            if expires and expires > now_ms + 3600000:
                continue

            body = json.dumps({
                'grant_type': 'refresh_token',
                'refresh_token': refresh_tok,
                'client_id': client_id,
            }).encode('utf-8')

            req = urllib.request.Request(
                token_url,
                data=body,
                headers={
                    'Content-Type': 'application/json',
                    'User-Agent': ua_header,
                },
                method='POST',
            )
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    rdata = json.loads(resp.read().decode('utf-8'))
                new_access = rdata.get('access_token', '')
                new_refresh = rdata.get('refresh_token', refresh_tok)
                new_expires_in = int(rdata.get('expires_in', 3600))
                if new_access:
                    acct['access'] = new_access
                    acct['refresh'] = new_refresh
                    acct['expires'] = now_ms + new_expires_in * 1000
                    acct['status'] = 'active'
                    refreshed.append(email)
                else:
                    failed.append(email)
            except (urllib.error.URLError, urllib.error.HTTPError) as e:
                failed.append(f'{email}({e})')

        # Write updated pool
        if refreshed:
            _atomic_write_json(pool_path, pool)

            # Also update auth.json if the currently-active account was refreshed
            # OR if auth.json has empty/missing tokens for this provider (self-heal).
            # GH#17487: Previously, only expired tokens triggered the write-back.
            if os.path.exists(auth_path):
                with open(auth_path) as f:
                    auth = json.load(f)
                current_access = auth.get(provider, {}).get('access', '')
                auth_expires = auth.get(provider, {}).get('expires', 0)
                # Self-heal: detect empty/missing/expired tokens
                needs_heal = (
                    not current_access
                    or (auth_expires and auth_expires <= now_ms)
                    or not auth_expires
                )
                if needs_heal:
                    heal_acct = None
                    for acct in accounts:
                        if acct.get('email') in refreshed:
                            heal_acct = acct
                            break
                    if not heal_acct:
                        for acct in accounts:
                            if acct.get('access') and acct.get('expires', 0) > now_ms:
                                heal_acct = acct
                                break
                    if heal_acct:
                        auth_entry = {
                            'type': 'oauth',
                            'refresh': heal_acct.get('refresh', ''),
                            'access': heal_acct.get('access', ''),
                            'expires': heal_acct.get('expires', 0),
                        }
                        if provider == 'openai':
                            account_id = heal_acct.get('accountId', auth.get(provider, {}).get('accountId', ''))
                            if account_id:
                                auth_entry['accountId'] = account_id
                        auth[provider] = auth_entry
                        _atomic_write_json(auth_path, auth)
                        print(f'HEALED_AUTH:{provider}:{heal_acct.get("email", "")}', file=sys.stderr)

    finally:
        _release_lock(lock_fd)
        lock_fd.close()

    for e in refreshed:
        print(f'REFRESHED:{e}')
    for e in failed:
        print(f'FAILED:{e}')
    if not refreshed and not failed:
        print('NONE')


# ---------------------------------------------------------------------------
# mark-failure: Mark current account as failed.
# Env: POOL_FILE_PATH, AUTH_FILE_PATH, PROVIDER, REASON, RETRY_SECONDS
# ---------------------------------------------------------------------------

def cmd_mark_failure():
    from datetime import datetime, timezone

    pool_path = os.environ['POOL_FILE_PATH']
    auth_path = os.environ['AUTH_FILE_PATH']
    provider = os.environ['PROVIDER']
    reason = os.environ['REASON']
    retry_seconds = int(os.environ['RETRY_SECONDS'])

    status_map = {
        'rate_limit': 'rate-limited',
        'auth_error': 'auth-error',
        'provider_error': 'rate-limited',
    }
    target_status = status_map.get(reason, 'rate-limited')

    lock_path = pool_path + '.lock'
    lock_fd = open(lock_path, 'w')
    try:
        _acquire_lock(lock_fd)
        with open(pool_path) as f:
            pool = json.load(f)
        with open(auth_path) as f:
            auth = json.load(f)

        accounts = pool.get(provider, [])
        if not accounts:
            print('SKIP:no_accounts')
            sys.exit(0)

        current_auth = auth.get(provider, {}) if isinstance(auth, dict) else {}
        current_access = current_auth.get('access', '')
        current_account_id = current_auth.get('accountId', '')

        idx = -1
        if current_access:
            for i, acct in enumerate(accounts):
                if acct.get('access', '') == current_access:
                    idx = i
                    break

        if idx < 0 and provider == 'openai' and current_account_id:
            for i, acct in enumerate(accounts):
                if acct.get('accountId', '') == current_account_id:
                    idx = i
                    break

        if idx < 0:
            best_i = 0
            best_last = ''
            for i, acct in enumerate(accounts):
                last = acct.get('lastUsed', '')
                if last >= best_last:
                    best_last = last
                    best_i = i
            idx = best_i

        now_ms = int(time.time() * 1000)
        cooldown_until = now_ms + retry_seconds * 1000
        now_iso = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

        target = accounts[idx]
        target['status'] = target_status
        target['cooldownUntil'] = cooldown_until
        target['lastUsed'] = now_iso
        pool[provider] = accounts

        _atomic_write_json(pool_path, pool)
        email = target.get('email', 'unknown')
        print(f'OK:{email}:{target_status}:{cooldown_until}')
    finally:
        _release_lock(lock_fd)
        lock_fd.close()


# ---------------------------------------------------------------------------
# check-accounts: Print account details for health check.
# Reads pool JSON from stdin.
# Env: PROV, NOW_MS
# ---------------------------------------------------------------------------

def cmd_check_accounts():
    pool = json.load(sys.stdin)
    prov = os.environ['PROV']
    now = int(os.environ['NOW_MS'])
    for a in pool.get(prov, []):
        expires_in = a.get('expires', 0) - now
        print(json.dumps({'email': a['email'], 'expires_in': expires_in,
                          'account': a}))


# ---------------------------------------------------------------------------
# check-validate: Validate a token against provider API.
# Env: PROV, EXPIRES_IN, TOKEN, UA
# ---------------------------------------------------------------------------

def cmd_check_validate():
    from urllib.request import Request, urlopen
    from urllib.error import HTTPError, URLError

    prov = os.environ['PROV']
    expires_in = int(os.environ['EXPIRES_IN'])
    token = os.environ['TOKEN']
    ua = os.environ['UA']

    if prov not in ('anthropic', 'google'):
        raise SystemExit(0)
    if not token:
        print('    Validity: no access token')
        raise SystemExit(0)
    if expires_in <= 0:
        print('    Validity: EXPIRED - will auto-refresh on next use')
        raise SystemExit(0)
    if prov == 'anthropic':
        req = Request('https://api.anthropic.com/v1/models', method='GET')
        req.add_header('Authorization', f'Bearer {token}')
        req.add_header('User-Agent', ua)
        req.add_header('anthropic-version', '2023-06-01')
        req.add_header('anthropic-beta', 'oauth-2025-04-20')
    else:
        req = Request('https://generativelanguage.googleapis.com/v1beta/models?pageSize=1', method='GET')
        req.add_header('Authorization', f'Bearer {token}')
    try:
        urlopen(req, timeout=10)
        print('    Validity: OK')
    except HTTPError as e:
        if e.code == 401:
            print('    Validity: INVALID (401 - needs refresh)')
        elif prov == 'google' and e.code == 403:
            print('    Validity: OK (403 - token valid, check AI Pro/Ultra subscription)')
        else:
            print(f'    Validity: HTTP {e.code}')
    except (URLError, OSError):
        print('    Validity: ERROR (network)')
    except Exception:
        print('    Validity: ERROR')


# ---------------------------------------------------------------------------
# check-meta: Print account metadata.
# Reads account JSON from stdin.
# Env: NOW_MS
# ---------------------------------------------------------------------------

def cmd_check_meta():
    from datetime import datetime

    a = json.load(sys.stdin)
    now = int(os.environ['NOW_MS'])
    print(f"    Status: {a.get('status', 'unknown')}")
    cd = a.get('cooldownUntil')
    if cd and cd > now:
        cd_mins = (cd - now + 59999) // 60000
        print(f'    Cooldown: {cd_mins}m remaining')
    lu = a.get('lastUsed')
    if lu:
        try:
            lu_ts = datetime.fromisoformat(lu.replace('Z', '+00:00')).timestamp() * 1000
            ago = now - lu_ts
            ago_mins = int(ago // 60000)
            ago_hours = ago_mins // 60
            if ago_hours > 0:
                print(f'    Last used: {ago_hours}h {ago_mins % 60}m ago')
            else:
                print(f'    Last used: {ago_mins}m ago')
        except Exception:
            print(f'    Last used: {lu}')
    print(f"    Refresh token: {'present' if a.get('refresh') else 'MISSING'}")


# ---------------------------------------------------------------------------
# check-expiry: Print token expiry info.
# Env: EXPIRES_IN (milliseconds remaining)
# ---------------------------------------------------------------------------

def cmd_check_expiry():
    expires_in = int(os.environ['EXPIRES_IN'])
    if expires_in <= 0:
        print('    Token: EXPIRED')
    else:
        mins = expires_in // 60000
        hours = mins // 60
        if hours > 0:
            print(f'    Token: expires in {hours}h {mins % 60}m')
        else:
            print(f'    Token: expires in {mins}m')


# ---------------------------------------------------------------------------
# reset-cooldowns: Reset cooldowns for accounts.
# Reads pool JSON from stdin.
# Env: PROVIDER
# ---------------------------------------------------------------------------

def cmd_reset_cooldowns():
    pool = json.load(sys.stdin)
    target = os.environ['PROVIDER']
    providers = list(pool.keys()) if target == 'all' else [target]
    cleared = 0
    for prov in providers:
        for a in pool.get(prov, []):
            if a.get('cooldownUntil') or a.get('status') in ('rate-limited', 'auth-error'):
                a['cooldownUntil'] = None
                a['status'] = 'idle'
                cleared += 1
    json.dump({'cleared': cleared, 'pool': pool}, sys.stdout, indent=2)


# ---------------------------------------------------------------------------
# set-priority: Set priority on an account.
# Reads pool JSON from stdin.
# Env: PROVIDER, EMAIL, PRIORITY
# ---------------------------------------------------------------------------

def cmd_set_priority():
    pool = json.load(sys.stdin)
    provider = os.environ['PROVIDER']
    email = os.environ['EMAIL']
    priority = int(os.environ['PRIORITY'])

    accounts = pool.get(provider, [])
    idx = next((i for i, a in enumerate(accounts) if a.get('email') == email), -1)
    if idx < 0:
        print('ERROR:not_found')
        sys.exit(0)

    if priority == 0:
        accounts[idx].pop('priority', None)
    else:
        accounts[idx]['priority'] = priority
    json.dump(pool, sys.stdout, indent=2)


# ---------------------------------------------------------------------------
# remove-account: Remove an account from pool.
# Reads pool JSON from stdin.
# Env: PROVIDER, EMAIL
# ---------------------------------------------------------------------------

def cmd_remove_account():
    pool = json.load(sys.stdin)
    provider = os.environ['PROVIDER']
    email = os.environ['EMAIL']

    if provider not in pool:
        print(json.dumps(pool, indent=2))
        sys.exit(1)

    original_count = len(pool[provider])
    pool[provider] = [a for a in pool[provider] if a.get('email') != email]
    new_count = len(pool[provider])

    if original_count == new_count:
        print(json.dumps(pool, indent=2))
        sys.exit(1)

    json.dump(pool, sys.stdout, indent=2)


# ---------------------------------------------------------------------------
# assign-pending: Assign pending token to account.
# Reads pool JSON from stdin.
# Env: PROVIDER, EMAIL
# ---------------------------------------------------------------------------

def cmd_assign_pending():
    pool = json.load(sys.stdin)
    provider = os.environ['PROVIDER']
    email = os.environ['EMAIL']
    pending_key = '_pending_' + provider
    pending = pool.get(pending_key)

    if not pending:
        print('ERROR:no_pending')
        sys.exit(0)

    accounts = pool.get(provider, [])
    idx = next((i for i, a in enumerate(accounts) if a.get('email') == email), -1)
    if idx < 0:
        print('ERROR:not_found')
        sys.exit(0)

    accounts[idx]['refresh'] = pending.get('refresh', accounts[idx].get('refresh', ''))
    accounts[idx]['access'] = pending.get('access', accounts[idx].get('access', ''))
    accounts[idx]['expires'] = pending.get('expires', accounts[idx].get('expires', 0))
    accounts[idx]['status'] = 'active'
    accounts[idx]['cooldownUntil'] = None
    del pool[pending_key]
    json.dump(pool, sys.stdout, indent=2)


# ---------------------------------------------------------------------------
# check-pending: Check if pending token exists.
# Reads pool JSON from stdin.
# Env: PROVIDER
# ---------------------------------------------------------------------------

def cmd_check_pending():
    pool = json.load(sys.stdin)
    provider = os.environ['PROVIDER']
    pending = pool.get('_pending_' + provider)
    if pending:
        print('FOUND:' + pending.get('added', 'unknown'))
    else:
        print('NONE')


# ---------------------------------------------------------------------------
# list-pending: List accounts for pending assignment.
# Reads pool JSON from stdin.
# Env: PROVIDER
# ---------------------------------------------------------------------------

def cmd_list_pending():
    pool = json.load(sys.stdin)
    provider = os.environ['PROVIDER']
    for i, a in enumerate(pool.get(provider, []), 1):
        print(f'  {i}. {a["email"]}')


# ---------------------------------------------------------------------------
# import-check: Check if email exists in pool.
# Reads pool JSON from stdin.
# Env: EMAIL
# ---------------------------------------------------------------------------

def cmd_import_check():
    pool = json.load(sys.stdin)
    email = os.environ['EMAIL']
    for acc in pool.get('anthropic', []):
        if acc.get('email') == email:
            print('yes')
            sys.exit(0)
    print('no')


# ---------------------------------------------------------------------------
# status-stats: Print pool statistics.
# Reads pool JSON from stdin.
# Env: NOW_MS, PROV
# ---------------------------------------------------------------------------

def cmd_status_stats():
    pool = json.load(sys.stdin)
    now = int(os.environ['NOW_MS'])
    prov = os.environ['PROV']
    accounts = pool.get(prov, [])

    total = len(accounts)
    available = sum(1 for a in accounts if not a.get('cooldownUntil') or a['cooldownUntil'] <= now)
    active = sum(1 for a in accounts if a.get('status') in ('active', 'idle'))
    rate_lim = sum(1 for a in accounts if a.get('status') == 'rate-limited' and a.get('cooldownUntil', 0) > now)
    auth_err = sum(1 for a in accounts if a.get('status') == 'auth-error')

    print(f'{prov} pool:')
    print(f'  Total accounts : {total}')
    print(f'  Available now  : {available}')
    print(f'  Active/idle    : {active}')
    print(f'  Rate limited   : {rate_lim}')
    print(f'  Auth errors    : {auth_err}')
    if available == 0 and total > 0:
        print('  WARNING: no accounts available — run reset-cooldowns or add an account')


# ---------------------------------------------------------------------------
# list-accounts: List accounts with status.
# Reads pool JSON from stdin.
# Env: PROVIDER
# ---------------------------------------------------------------------------

def cmd_list_accounts():
    pool = json.load(sys.stdin)
    prov = os.environ['PROVIDER']
    for i, a in enumerate(pool.get(prov, []), 1):
        status = a.get('status', 'unknown')
        email = a.get('email', 'unknown')
        priority = a.get('priority')
        priority_str = f' priority:{priority}' if priority is not None else ''
        print(f'  {i}. {email} [{status}]{priority_str}')


# ---------------------------------------------------------------------------
# extract-token-fields: Extract token fields from JSON response.
# Reads JSON from stdin.
# ---------------------------------------------------------------------------

def cmd_extract_token_fields():
    d = json.load(sys.stdin)
    print(d.get('access_token', ''))
    print(d.get('refresh_token', ''))
    print(d.get('expires_in', 3600))


# ---------------------------------------------------------------------------
# extract-token-error: Extract error message from token response.
# Reads JSON from stdin.
# ---------------------------------------------------------------------------

def cmd_extract_token_error():
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

def cmd_openai_read_auth():
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

def cmd_cursor_read_auth():
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

def cmd_cursor_decode_jwt():
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

def cmd_google_validate():
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


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

COMMANDS = {
    'auto-clear': cmd_auto_clear,
    'upsert': cmd_upsert,
    'normalize-cooldowns': cmd_normalize_cooldowns,
    'rotate': cmd_rotate,
    'refresh': cmd_refresh,
    'mark-failure': cmd_mark_failure,
    'check-accounts': cmd_check_accounts,
    'check-validate': cmd_check_validate,
    'check-meta': cmd_check_meta,
    'check-expiry': cmd_check_expiry,
    'reset-cooldowns': cmd_reset_cooldowns,
    'set-priority': cmd_set_priority,
    'remove-account': cmd_remove_account,
    'assign-pending': cmd_assign_pending,
    'check-pending': cmd_check_pending,
    'list-pending': cmd_list_pending,
    'import-check': cmd_import_check,
    'status-stats': cmd_status_stats,
    'list-accounts': cmd_list_accounts,
    'extract-token-fields': cmd_extract_token_fields,
    'extract-token-error': cmd_extract_token_error,
    'openai-read-auth': cmd_openai_read_auth,
    'cursor-read-auth': cmd_cursor_read_auth,
    'cursor-decode-jwt': cmd_cursor_decode_jwt,
    'google-validate': cmd_google_validate,
}


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <command>', file=sys.stderr)
        print(f'Commands: {", ".join(sorted(COMMANDS))}', file=sys.stderr)
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd not in COMMANDS:
        print(f'Unknown command: {cmd}', file=sys.stderr)
        sys.exit(1)

    COMMANDS[cmd]()


if __name__ == '__main__':
    main()
