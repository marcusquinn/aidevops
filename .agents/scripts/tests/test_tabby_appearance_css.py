#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Tests for the managed Tabby appearance CSS block."""

from __future__ import annotations

import os
import sys
import unittest

import yaml

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from tabby_appearance_css import MANAGED_CSS, ensure_managed_appearance_css  # noqa: E402

USER_CSS_CONFIG = """version: 8
profiles: []
appearance:
  tabsInFullscreen: true
  css: |
    /* Widen left-side tab sidebar. */
    .content.tabs-on-left {
      --side-tab-width: calc(300px * var(--spaciness));
    }
  tabsLocation: left
hacks: {}
"""
ON = {"AIDEVOPS_TABBY_HIDE_SCROLLBAR": "1"}
OFF = {"AIDEVOPS_TABBY_HIDE_SCROLLBAR": "false"}


def css_of(text: str) -> str:
    return yaml.safe_load(text)["appearance"]["css"]


class ManagedCssTests(unittest.TestCase):
    def test_appends_after_user_css_and_is_idempotent(self) -> None:
        updated, changed = ensure_managed_appearance_css(USER_CSS_CONFIG, ON)
        self.assertTrue(changed)
        self.assertIn("--side-tab-width", css_of(updated))
        self.assertTrue(css_of(updated).endswith(MANAGED_CSS + "\n"))
        self.assertIn("  tabsLocation: left\nhacks: {}\n", updated)
        again, changed_again = ensure_managed_appearance_css(updated, ON)
        self.assertFalse(changed_again)
        self.assertEqual(again, updated)

    def test_opt_out_removes_only_managed_block(self) -> None:
        managed, _ = ensure_managed_appearance_css(USER_CSS_CONFIG, ON)
        reverted, changed = ensure_managed_appearance_css(managed, OFF)
        self.assertTrue(changed)
        self.assertNotIn("aidevops:managed", reverted)
        self.assertEqual(css_of(reverted), css_of(USER_CSS_CONFIG))

    def test_creates_css_and_appearance_sections(self) -> None:
        no_css = "profiles: []\nappearance:\n  tabsLocation: left\n"
        updated, changed = ensure_managed_appearance_css(no_css, ON)
        self.assertTrue(changed)
        self.assertEqual(css_of(updated), MANAGED_CSS + "\n")
        for source in ("profiles: []\n", "profiles: []\nappearance: {}\n"):
            updated, changed = ensure_managed_appearance_css(source, ON)
            self.assertTrue(changed)
            self.assertEqual(css_of(updated), MANAGED_CSS + "\n")

    def test_replaces_inline_empty_css(self) -> None:
        inline = "appearance:\n  css: ''\n  flexTabs: true\n"
        updated, _ = ensure_managed_appearance_css(inline, ON)
        self.assertEqual(css_of(updated), MANAGED_CSS + "\n")
        self.assertTrue(yaml.safe_load(updated)["appearance"]["flexTabs"])

    def test_rejects_unsupported_inline_mapping(self) -> None:
        with self.assertRaises(ValueError):
            ensure_managed_appearance_css("appearance: {css: x}\n", ON)


if __name__ == "__main__":
    unittest.main()
