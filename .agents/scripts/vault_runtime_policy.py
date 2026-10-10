#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Content-free bridge to the shared shell runtime policy for summary helpers."""
import os
import ipaddress
import subprocess
import urllib.parse
import urllib.request

RUNTIME_BOUND = os.environ.get('AIDEVOPS_RUNTIME_POLICY', '').strip().lower() not in {
    '', 'provider-ai', 'provider-allowed', 'provider-ai-approved'
}


def _loopback(destination):
    host = urllib.parse.urlsplit(destination).hostname
    if host == 'localhost':
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except (ValueError, TypeError):
        return False


def runtime_policy_check(model, destination=''):
    """Validate only fixed route labels; never send payloads to a subprocess."""
    if not RUNTIME_BOUND:
        return
    if model not in {'ollama/summary', 'anthropic/summary'}:
        raise RuntimeError('VAULT_POLICY_DENIED: unknown summary route')
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vault-data-policy-helper.sh')
    bash = '/bin/bash' if os.path.isfile('/bin/bash') else '/run/current-system/sw/bin/bash'
    # Fixed system executable, repository-owned helper, validated labels, no shell.
    result = subprocess.run([bash, helper, 'check', '--model', model],  # nosec B603
                            capture_output=True, check=False,
                            env={**os.environ, 'AIDEVOPS_RUNTIME_POLICY': 'local-only'})
    if result.returncode or not _loopback(destination):
        raise RuntimeError('VAULT_POLICY_DENIED: summary request blocked before sending')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise RuntimeError('VAULT_POLICY_DENIED: summary redirect blocked before sending')
