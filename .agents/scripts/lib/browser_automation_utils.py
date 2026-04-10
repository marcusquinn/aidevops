#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Shared browser automation utilities for AI DevOps Framework.

Extracted from linkedin-automation.py and local-browser-automation.py to
eliminate duplication (27 similar lines, mass=149 per qlty smells).
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from playwright.sync_api import Page


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


def playwright_like_posts(
    page: "Page",
    max_likes: int,
    session_stats: dict,
    random_delay_fn,
    like_count_key: str = "likes_given",
    processed_count_key: str | None = "posts_processed",
    label: str = "",
) -> None:
    """Like posts on LinkedIn timeline using Playwright.

    Args:
        page: Playwright page object.
        max_likes: Maximum number of posts to like.
        session_stats: Mutable stats dict updated in-place.
        random_delay_fn: Callable matching ``random_delay(min, max)`` signature.
        like_count_key: Key in ``session_stats`` to increment for each like.
        processed_count_key: Optional key in ``session_stats`` to increment for
            each processed post.  Pass ``None`` to skip.
        label: Optional suffix appended to log messages (e.g. " (LOCAL browser)").
    """
    label_suffix = f" {label.strip()}" if label.strip() else ""
    print(f"👍 Starting to like posts{label_suffix} (max: {max_likes})...")

    likes_given = 0
    scroll_attempts = 0
    max_scrolls = 5

    while likes_given < max_likes and scroll_attempts < max_scrolls:
        # Find like buttons that haven't been clicked
        like_buttons = page.query_selector_all(
            'button[aria-label*="Like"][aria-pressed="false"]'
        )

        if not like_buttons:
            print("📜 Scrolling to load more posts...")
            page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
            random_delay_fn(3, 6)
            scroll_attempts += 1
            continue

        # Like posts with random selection
        for button in like_buttons[: min(3, max_likes - likes_given)]:
            try:
                # Scroll button into view
                button.scroll_into_view_if_needed()
                random_delay_fn(1, 3)

                # Click like button
                button.click()
                likes_given += 1
                session_stats[like_count_key] += 1
                if processed_count_key is not None:
                    session_stats[processed_count_key] += 1

                print(f"👍 Liked post {likes_given}/{max_likes}{label_suffix}")

                # Random delay between likes
                random_delay_fn()

                if likes_given >= max_likes:
                    break

            except Exception as e:
                print(f"⚠️ Error liking post: {e}")
                session_stats["errors"] += 1
                continue

        # Scroll for more content
        if likes_given < max_likes:
            page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
            random_delay_fn(3, 6)
            scroll_attempts += 1

    print(f"✅ Completed{label_suffix} liking session: {likes_given} posts liked")
