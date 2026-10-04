#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Hosted quality-service probes for wp_plugin_quality.py.

Credentials come only from the environment. Output never includes response
bodies, headers or tokens.
"""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request

CODACY_API = 'https://api.codacy.com/api/v3'
SONAR_API = 'https://sonarcloud.io/api'
CODACY_GRADE = re.compile(r'https://app\.codacy\.com/project/badge/Grade/[A-Za-z0-9-]+')
BADGE_ERROR = re.compile(r'not found|unknown|error|pending|n/a', re.I)
SERVICE_ERRORS = (urllib.error.URLError, ValueError, TypeError, AttributeError)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow credential-bearing redirects to another host."""

    def redirect_request(self, *_args, **_kwargs):
        return None


def request_json(url: str, headers: dict[str, str], body: bytes | None = None):
    req = urllib.request.Request(url, data=body, headers=headers)
    with urllib.request.build_opener(_NoRedirect).open(req, timeout=30) as response:
        return json.load(response)


def report(service: str, error: Exception) -> None:
    code = getattr(error, 'code', 'network/response error')
    print(f'{service}: unavailable ({code}); retry quality onboarding')


def _ignore_status(call, url: str, headers: dict[str, str], body: bytes, status: int) -> None:
    try:
        call(url, headers, body)
    except urllib.error.HTTPError as error:
        if error.code != status:
            raise


def codacy_grade(repo: str) -> str:
    """Register the repository with Codacy and return its grade badge URL."""
    token = os.environ.get('CODACY_API_TOKEN', '')
    if not token:
        print('Codacy: missing CODACY_API_TOKEN; store with aidevops secret set CODACY_API_TOKEN and rerun')
        return ''
    owner, name = repo.split('/')
    headers = {'api-token': token, 'Content-Type': 'application/json'}
    body = json.dumps({'provider': 'gh', 'repositoryFullPath': repo}).encode()
    try:
        # 409: already registered.
        _ignore_status(request_json, f'{CODACY_API}/repositories', headers, body, 409)
        data = request_json(f'{CODACY_API}/organizations/gh/{owner}/repositories/{name}', headers)
    except SERVICE_ERRORS as error:
        report('Codacy', error)
        return ''
    grade = data.get('data', {}).get('badges', {}).get('grade', '') if isinstance(data, dict) else ''
    grade = grade if isinstance(grade, str) and CODACY_GRADE.fullmatch(grade) else ''
    print('Codacy: registered; grade badge ' + ('available' if grade else 'pending'))
    return grade


def _sonar_setting(settings: str, name: str) -> str | None:
    found = re.search(rf'^\s*sonar\.{name}\s*=\s*(\S+)\s*$', settings, re.M)
    return found[1] if found else None


def sonar_identity(repo: str, root: Path) -> tuple[str, str] | None:
    """Return (organization, project key) unless env overrides name another project."""
    expected_org, _name = repo.split('/')
    expected_key = repo.replace('/', '_')
    properties = root / 'sonar-project.properties'
    if properties.exists():
        settings = properties.read_text()
        expected_key = _sonar_setting(settings, 'projectKey') or expected_key
        expected_org = _sonar_setting(settings, 'organization') or expected_org
    org = os.environ.get('SONAR_ORGANIZATION', expected_org)
    key = os.environ.get('SONAR_PROJECT_KEY', expected_key)
    if (org, key) != (expected_org, expected_key):
        print('SonarCloud: project key or organization differs from this repository configuration; skipping unrelated project')
        return None
    return org, key


def _sonar_probe(org: str, key: str, name: str, token: str) -> bool:
    headers = {'Authorization': 'Basic ' + base64.b64encode((token + ':').encode()).decode()}
    query = urllib.parse.urlencode({'component': key, 'metricKeys': 'alert_status'})
    try:
        # An existing project is not proof it is bound or has an analysis.
        data = request_json(f'{SONAR_API}/measures/component?{query}', headers)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
        form = {'organization': org, 'project': key, 'name': name, 'visibility': 'public'}
        request_json(f'{SONAR_API}/projects/create', headers, urllib.parse.urlencode(form).encode())
        print('SonarCloud: project provisioned; GitHub import/automatic analysis still requires org admin')
        return False
    measures = data.get('component', {}).get('measures', [])
    return any(measure.get('metric') == 'alert_status' for measure in measures)


def sonar_status(repo: str, root: Path) -> tuple[bool, str]:
    """Return (quality gate measured, project key) and print the remaining admin step."""
    identity = sonar_identity(repo, root)
    token = os.environ.get('SONAR_TOKEN', '')
    ready = False
    key = identity[1] if identity else ''
    if identity and token:
        try:
            ready = _sonar_probe(identity[0], key, repo.split('/')[1], token)
        except SERVICE_ERRORS as error:
            report('SonarCloud', error)
    if ready:
        print('SonarCloud: quality-gate measure exists; GitHub binding/automatic analysis remain '
              'unverified by the published API, so verify the project belongs to this repository.')
        return True, key
    scanner = (root / '.github/workflows/sonarcloud.yml').exists()
    method = ('disable Automatic Analysis and configure the existing Actions scanner with a repository SONAR_TOKEN'
              if scanner else 'enable automatic analysis')
    print(f'SonarCloud: https://sonarcloud.io/projects/create — an org admin must import this '
          f'GitHub repository and {method}, then rerun quality.')
    return False, key


def codefactor_badge(repo: str) -> str:
    """Return the CodeFactor badge URL only when it serves a real grade."""
    badge = f'https://www.codefactor.io/repository/github/{repo}/badge'
    try:
        with urllib.request.urlopen(badge, timeout=30) as response:
            image = response.read(65536).decode('utf-8')
            host = urllib.parse.urlparse(response.url).hostname
    except (urllib.error.URLError, ValueError, UnicodeError) as error:
        report('CodeFactor', error)
        return ''
    if host == 'www.codefactor.io' and '<svg' in image and not BADGE_ERROR.search(image):
        return badge
    print('CodeFactor: grade badge unavailable; verify org app repository access')
    return ''
