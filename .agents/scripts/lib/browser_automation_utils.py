#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Shared browser automation utilities for AI DevOps Framework.

Extracted from linkedin-automation.py and local-browser-automation.py to
eliminate duplication (27 similar lines, mass=149 per qlty smells).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Callable

if TYPE_CHECKING:
    from playwright.sync_api import Page


@dataclass
class LikePostsConfig:
    """Configuration for the post-liking session."""
    max_likes: int
    session_stats: dict
    random_delay_fn: Callable
    like_count_key: str = "likes_given"
    processed_count_key: str | None = "posts_processed"
    label: str = ""


def playwright_login(
    page: "Page",
    email: str,
    password: str,
    label: str = "LinkedIn",
) -> bool:
    """Login to LinkedIn using Playwright.

    Args:
        page: Playwright page object.
        email: LinkedIn account email.
        password: LinkedIn account password.
        label: Display label used in log messages (e.g. "LinkedIn" or "LOCAL browser").

    Returns:
        True on successful login, False otherwise.
    """
    try:
        print(f"🔐 Logging into {label}...")
        page.goto("https://www.linkedin.com/login")

        # Fill login form
        page.fill('input[name="session_key"]', email)
        page.fill('input[name="session_password"]', password)

        # Click login button
        page.click('button[type="submit"]')

        # Wait for navigation
        page.wait_for_load_state("networkidle")

        # Check if login was successful
        if "feed" in page.url or "mynetwork" in page.url:
            print(f"✅ Successfully logged into {label}")
            return True
        else:
            print("❌ Login failed - check credentials")
            return False

    except Exception as e:
        print(f"❌ Login error: {e}")
        return False


def _click_like_button(button, cfg, likes_given, label_suffix):
    """Click a single like button and update stats.

    Returns updated likes_given count, or the same count on error.
    """
    try:
        button.scroll_into_view_if_needed()
        cfg.random_delay_fn(1, 3)
        button.click()
        likes_given += 1
        cfg.session_stats[cfg.like_count_key] += 1
        if cfg.processed_count_key is not None:
            cfg.session_stats[cfg.processed_count_key] += 1
        print(f"Liked post {likes_given}/{cfg.max_likes}{label_suffix}")
        cfg.random_delay_fn()
    except Exception as e:
        print(f"Error liking post: {e}")
        cfg.session_stats["errors"] += 1
    return likes_given


def _scroll_for_more(page, cfg):
    """Scroll the page to load more content."""
    page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
    cfg.random_delay_fn(3, 6)


def playwright_like_posts(page: "Page", cfg: LikePostsConfig) -> None:
    """Like posts on LinkedIn timeline using Playwright.

    Args:
        page: Playwright page object.
        cfg: LikePostsConfig with session parameters.
    """
    label_suffix = f" {cfg.label.strip()}" if cfg.label.strip() else ""
    print(f"Starting to like posts{label_suffix} (max: {cfg.max_likes})...")

    likes_given = 0
    scroll_attempts = 0
    max_scrolls = 5

    while likes_given < cfg.max_likes and scroll_attempts < max_scrolls:
        like_buttons = page.query_selector_all(
            'button[aria-label*="Like"][aria-pressed="false"]'
        )

        if not like_buttons:
            print("Scrolling to load more posts...")
            _scroll_for_more(page, cfg)
            scroll_attempts += 1
            continue

        for button in like_buttons[: min(3, cfg.max_likes - likes_given)]:
            likes_given = _click_like_button(button, cfg, likes_given, label_suffix)
            if likes_given >= cfg.max_likes:
                break

        if likes_given < cfg.max_likes:
            _scroll_for_more(page, cfg)
            scroll_attempts += 1

    print(f"Completed{label_suffix} liking session: {likes_given} posts liked")
