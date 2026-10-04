#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""README badge onboarding for wp-plugin-new-helper.sh.

Usage:
  wp_plugin_quality.py onboard OWNER/REPO ROOT VISIBILITY
  wp_plugin_quality.py strip-badges README

The shell caller validates repository identity, visibility and linked-worktree
safety before calling `onboard`. Credentials are environment-only.
"""

from __future__ import annotations

from pathlib import Path
import re
import sys
import urllib.parse

from wp_plugin_quality_services import codacy_grade, codefactor_badge, sonar_status

BADGE_BLOCK = re.compile(r'(<!-- aidevops:badges:start -->)(.*?)(<!-- aidevops:badges:end -->)', re.S)
QUALITY_BADGE = re.compile(r'codacy|sonarcloud|codefactor', re.I)
# A new repository has no hosted analysis or release yet.
NEW_REPO_BADGE = re.compile(r'codacy|sonarcloud|codefactor|github/v/release', re.I)


def _rewrite_block(match: re.Match, drop: re.Pattern, additions: list[str]) -> str:
    # Keep unrelated badges and both markers; never copy the starter's project IDs.
    lines = [line for line in match[2].splitlines() if not drop.search(line)]
    lines.extend(additions)
    return match[1] + '\n' + '\n'.join(lines).strip() + '\n' + match[3]


def strip_badges(readme: Path) -> int:
    """Remove hosted-service and release badges; no-op without markers."""
    text = readme.read_text()
    readme.write_text(BADGE_BLOCK.sub(lambda match: _rewrite_block(match, NEW_REPO_BADGE, []), text))
    return 0


def _hosted_badges(repo: str, root: Path) -> list[str]:
    badges = []
    grade = codacy_grade(repo)
    if grade:
        badges.append(f'[![Codacy]({grade})](https://app.codacy.com/gh/{repo}/dashboard)')
    sonar_ready, key = sonar_status(repo, root)
    if sonar_ready:
        query = urllib.parse.urlencode({'project': key, 'metric': 'alert_status'})
        badges.append(f'[![SonarCloud](https://sonarcloud.io/api/project_badges/measure?{query})]'
                      f'(https://sonarcloud.io/dashboard?id={urllib.parse.quote(key)})')
    # CodeFactor is an org app, not a provisioning API.
    codefactor = codefactor_badge(repo)
    if codefactor:
        badges.append(f'[![CodeFactor]({codefactor})](https://www.codefactor.io/repository/github/{repo})')
    return badges


def onboard(repo: str, root: Path, visibility: str) -> int:
    readme = root / 'README.md'
    text = readme.read_text()
    match = BADGE_BLOCK.search(text)
    if not match:
        print('README badge markers missing; preserve/restore the starter block before onboarding', file=sys.stderr)
        return 1
    # Private repositories defer hosted onboarding until they are public.
    additions = _hosted_badges(repo, root) if visibility == 'public' else []
    block = _rewrite_block(match, QUALITY_BADGE, additions)
    readme.write_text(text[:match.start()] + block + text[match.end():])
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == 'strip-badges':
        return strip_badges(Path(argv[2]))
    if len(argv) == 5 and argv[1] == 'onboard' and re.fullmatch(r'[\w.-]+/[\w.-]+', argv[2]):
        return onboard(argv[2], Path(argv[3]), argv[4])
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
