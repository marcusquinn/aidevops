#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
LinkedIn Automation Script for AI DevOps Framework
Automates LinkedIn interactions like liking posts on timeline

Author: AI DevOps Framework
Version: 1.3.1

IMPORTANT: This script is for educational purposes and personal use only.
Always respect LinkedIn's Terms of Service and use responsibly.
"""

import os
import random
import sys
import time
from datetime import datetime

try:
    from playwright.sync_api import sync_playwright, Page
    PLAYWRIGHT_AVAILABLE = True
except ImportError:
    PLAYWRIGHT_AVAILABLE = False

# Shared browser automation utilities
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
from browser_automation_utils import playwright_login, playwright_like_posts, LikePostsConfig  # noqa: E402

try:
    # Selenium imports would go here if needed
    SELENIUM_AVAILABLE = True
except ImportError:
    SELENIUM_AVAILABLE = False

class LinkedInAutomation:
    """LinkedIn automation class with ethical guidelines"""
    
    def __init__(self, headless: bool = False, delay_range: tuple = (2, 5)):
        self.headless = headless
        self.delay_range = delay_range
        self.session_stats = {
            'likes_given': 0,
            'posts_processed': 0,
            'errors': 0,
            'start_time': datetime.now()
        }
        
    def random_delay(self, min_delay: float = None, max_delay: float = None):
        """Add random delay to mimic human behavior"""
        if min_delay is None:
            min_delay = self.delay_range[0]
        if max_delay is None:
            max_delay = self.delay_range[1]
        
        delay = random.uniform(min_delay, max_delay)
        print(f"⏳ Waiting {delay:.1f} seconds...")
        time.sleep(delay)
    
    def playwright_automation(self, email: str, password: str, max_likes: int = 10):
        """LinkedIn automation using Playwright"""
        if not PLAYWRIGHT_AVAILABLE:
            print("❌ Playwright not available. Install with: pip install playwright")
            return False
            
        print("🎭 Starting LinkedIn automation with Playwright...")
        
        with sync_playwright() as p:
            # Launch browser
            browser = p.chromium.launch(headless=self.headless)
            context = browser.new_context(
                user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
            )
            page = context.new_page()
            
            try:
                # Login to LinkedIn
                if not self._playwright_login(page, email, password):
                    return False
                
                # Navigate to feed
                print("📰 Navigating to LinkedIn feed...")
                page.goto("https://www.linkedin.com/feed/")
                page.wait_for_load_state("networkidle")
                
                # Like posts on timeline
                self._playwright_like_posts(page, max_likes)
                
                # Print session summary
                self._print_session_summary()
                
                return True
                
            except Exception as e:
                print(f"❌ Error during automation: {e}")
                self.session_stats['errors'] += 1
                return False
            finally:
                browser.close()
    
    def _playwright_login(self, page: Page, email: str, password: str) -> bool:
        """Login to LinkedIn using Playwright"""
        return playwright_login(page, email, password, label="LinkedIn")

    def _playwright_like_posts(self, page: Page, max_likes: int):
        """Like posts on LinkedIn timeline using Playwright"""
        cfg = LikePostsConfig(
            max_likes=max_likes,
            session_stats=self.session_stats,
            random_delay_fn=self.random_delay,
            like_count_key="likes_given",
            processed_count_key="posts_processed",
        )
        playwright_like_posts(page, cfg)
    
    def _print_session_summary(self):
        """Print automation session summary"""
        duration = datetime.now() - self.session_stats['start_time']
        
        print("\n" + "="*50)
        print("📊 LinkedIn Automation Session Summary")
        print("="*50)
        print(f"👍 Posts liked: {self.session_stats['likes_given']}")
        print(f"📰 Posts processed: {self.session_stats['posts_processed']}")
        print(f"❌ Errors: {self.session_stats['errors']}")
        print(f"⏱️ Duration: {duration}")
        print(f"🕐 Started: {self.session_stats['start_time'].strftime('%Y-%m-%d %H:%M:%S')}")
        print("="*50)

def main():
    """Main function for LinkedIn automation"""
    print("🔗 LinkedIn Automation for AI DevOps Framework")
    print("⚠️  IMPORTANT: Use responsibly and respect LinkedIn's Terms of Service")
    print("")
    
    # Check if automation tools are available
    if not PLAYWRIGHT_AVAILABLE and not SELENIUM_AVAILABLE:
        print("❌ No browser automation tools available")
        print("Install with: pip install playwright selenium")
        print("Then run: playwright install")
        return
    
    # Get credentials from environment or prompt
    email = os.getenv('LINKEDIN_EMAIL')
    password = os.getenv('LINKEDIN_PASSWORD')
    
    if not email or not password:
        print("🔐 LinkedIn credentials not found in environment variables")
        print("Set LINKEDIN_EMAIL and LINKEDIN_PASSWORD environment variables")
        print("Or run with: LINKEDIN_EMAIL=your@email.com LINKEDIN_PASSWORD=yourpass python linkedin-automation.py")
        return
    
    # Configuration
    max_likes = int(os.getenv('LINKEDIN_MAX_LIKES', '10'))
    headless = os.getenv('LINKEDIN_HEADLESS', 'false').lower() == 'true'
    
    print(f"⚙️ Configuration:")
    print(f"   Email: {email}")
    print(f"   Max likes: {max_likes}")
    print(f"   Headless: {headless}")
    print("")
    
    # Create automation instance
    automation = LinkedInAutomation(headless=headless)
    
    # Run automation
    if PLAYWRIGHT_AVAILABLE:
        success = automation.playwright_automation(email, password, max_likes)
    else:
        print("❌ Playwright not available")
        success = False
    
    if success:
        print("🎉 LinkedIn automation completed successfully!")
    else:
        print("❌ LinkedIn automation failed")

if __name__ == "__main__":
    main()
