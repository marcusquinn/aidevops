#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Hosted-service and README onboarding for wp-plugin-new-helper.sh.

The shell caller validates repository identity, visibility and linked-worktree
safety before calling this companion. Credentials are environment-only.
"""

import base64
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

repo, root, visibility = sys.argv[1:]
owner, name = repo.split('/')
readme = Path(root) / 'README.md'
text = readme.read_text()
pattern = r'(<!-- aidevops:badges:start -->)(.*?)(<!-- aidevops:badges:end -->)'
match = re.search(pattern, text, re.S)
if not match:
    sys.exit('README badge markers missing; preserve/restore the starter block before onboarding')


def request(url, headers, body=None):
    # Do not follow credential-bearing redirects to another host.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, hdrs, newurl):
            return None
    req = urllib.request.Request(url, data=body, headers=headers)
    with urllib.request.build_opener(NoRedirect).open(req, timeout=30) as response:
        return json.load(response)


def report(service, error):
    # Never print response bodies, headers or tokens.
    print(f'{service}: unavailable ({getattr(error, "code", "network/response error")}); retry quality onboarding')


grade = ''
sonar_ready = False
if visibility == 'public':
    token = os.environ.get('CODACY_API_TOKEN', '')
    if token:
        headers = {'api-token': token, 'Content-Type': 'application/json'}
        try:
            try:
                request('https://api.codacy.com/api/v3/repositories', headers,
                        json.dumps({'provider': 'gh', 'repositoryFullPath': repo}).encode())
            except urllib.error.HTTPError as error:
                if error.code != 409:
                    raise
            data = request(f'https://api.codacy.com/api/v3/organizations/gh/{owner}/repositories/{name}', headers)
            grade = data.get('data', {}).get('badges', {}).get('grade', '')
            if not isinstance(grade, str) or not re.fullmatch(r'https://app\.codacy\.com/project/badge/Grade/[A-Za-z0-9-]+', grade):
                grade = ''
            print('Codacy: registered; grade badge ' + ('available' if grade else 'pending'))
        except (urllib.error.URLError, ValueError, TypeError, AttributeError) as error:
            report('Codacy', error)
    else:
        print('Codacy: missing CODACY_API_TOKEN; store with aidevops secret set CODACY_API_TOKEN and rerun')

    token = os.environ.get('SONAR_TOKEN', '')
    expected_org = owner
    expected_key = repo.replace('/', '_')
    properties = Path(root) / 'sonar-project.properties'
    if properties.exists():
        settings = properties.read_text()
        configured = re.search(r'^\s*sonar\.projectKey\s*=\s*(\S+)\s*$', settings, re.M)
        if configured:
            expected_key = configured[1]
        configured_org = re.search(r'^\s*sonar\.organization\s*=\s*(\S+)\s*$', settings, re.M)
        if configured_org:
            expected_org = configured_org[1]
    org = os.environ.get('SONAR_ORGANIZATION', expected_org)
    key = os.environ.get('SONAR_PROJECT_KEY', expected_key)
    if key != expected_key or org != expected_org:
        print('SonarCloud: project key or organization differs from this repository configuration; skipping unrelated project')
        token = ''
    if token:
        headers = {'Authorization': 'Basic ' + base64.b64encode((token + ':').encode()).decode()}
        try:
            # An existing project is not proof it is bound or has an analysis.
            query = urllib.parse.urlencode({'component': key, 'metricKeys': 'alert_status'})
            try:
                data = request('https://sonarcloud.io/api/measures/component?' + query, headers)
                sonar_ready = any(m.get('metric') == 'alert_status' for m in data.get('component', {}).get('measures', []))
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise
                headers['Content-Type'] = 'application/x-www-form-urlencoded'
                request('https://sonarcloud.io/api/projects/create', headers,
                        urllib.parse.urlencode({'organization': org, 'project': key,
                                                'name': name, 'visibility': 'public'}).encode())
                print('SonarCloud: project provisioned; GitHub import/automatic analysis still requires org admin')
        except (urllib.error.URLError, ValueError, TypeError, AttributeError) as error:
            report('SonarCloud', error)
    if not sonar_ready:
        method = ('disable Automatic Analysis and configure the existing Actions scanner with a repository SONAR_TOKEN'
                  if (Path(root) / '.github/workflows/sonarcloud.yml').exists()
                  else 'enable automatic analysis')
        print(f'SonarCloud: https://sonarcloud.io/projects/create — an org admin must import this GitHub repository and {method}, then rerun quality.')
    else:
        print('SonarCloud: quality-gate measure exists; GitHub binding/automatic analysis remain unverified by the published API, so verify the project belongs to this repository.')

# Keep unrelated badges, existing releases and both markers. Never copy the
# starter's project ID; new-repository release cleanup belongs in _rename.
lines = [line for line in match[2].splitlines()
         if not re.search(r'codacy|sonarcloud|codefactor', line, re.I)]
if grade:
    lines.append(f'[![Codacy]({grade})](https://app.codacy.com/gh/{repo}/dashboard)')
if sonar_ready:
    query = urllib.parse.urlencode({'project': key, 'metric': 'alert_status'})
    lines.append(f'[![SonarCloud](https://sonarcloud.io/api/project_badges/measure?{query})](https://sonarcloud.io/dashboard?id={urllib.parse.quote(key)})')
if visibility == 'public':
    # CodeFactor is an org app, not a provisioning API. Restore its badge only
    # when the public endpoint serves a real grade, not an error SVG or HTML.
    badge = f'https://www.codefactor.io/repository/github/{repo}/badge'
    try:
        with urllib.request.urlopen(badge, timeout=30) as response:
            image = response.read(65536).decode('utf-8')
            if (urllib.parse.urlparse(response.url).hostname == 'www.codefactor.io'
                    and '<svg' in image and not re.search(r'not found|unknown|error|pending|n/a', image, re.I)):
                lines.append(f'[![CodeFactor]({badge})](https://www.codefactor.io/repository/github/{repo})')
            else:
                print('CodeFactor: grade badge unavailable; verify org app repository access')
    except (urllib.error.URLError, ValueError, UnicodeError) as error:
        report('CodeFactor', error)
readme.write_text(text[:match.start()] + match[1] + '\n' + '\n'.join(lines).strip() + '\n' + match[3] + text[match.end():])
