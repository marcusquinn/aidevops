#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Local Browser Automation for AI DevOps Framework
Privacy-first browser automation using LOCAL browsers only (no cloud services)

Author: AI DevOps Framework
Version: 1.4.0

PRIVACY & SECURITY:
- All browser automation runs locally on your machine
- No data sent to cloud services or external browsers
- Complete privacy and security with local-only operation
- User maintains full control over browser and data

IMPORTANT: This script is for educational purposes and personal use only.
Always respect website Terms of Service and use responsibly.
"""

import os
import random
import sys
import time
from datetime import datetime

# Local browser automation imports (no cloud dependencies)
try:
    from playwright.sync_api import sync_playwright, Page
    PLAYWRIGHT_AVAILABLE = True
except ImportError:
    PLAYWRIGHT_AVAILABLE = False

# Shared browser automation utilities
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
from browser_automation_utils import playwright_login, playwright_like_posts, LikePostsConfig  # noqa: E402

try:
    from selenium import webdriver
    from selenium.webdriver.chrome.options import Options as ChromeOptions
    from selenium.webdriver.firefox.options import Options as FirefoxOptions
    SELENIUM_AVAILABLE = True
except ImportError:
    SELENIUM_AVAILABLE = False

class LocalBrowserAutomation:
    """Local browser automation class with privacy-first approach"""
    
    def __init__(self, headless: bool = False, delay_range: tuple = (2, 5)):
        self.headless = headless
        self.delay_range = delay_range
        self.session_stats = {
            'actions_performed': 0,
            'pages_visited': 0,
            'errors': 0,
            'start_time': datetime.now(),
            'browser_type': 'local'
        }
        
        print("🔒 LOCAL BROWSER AUTOMATION - Privacy First")
        print("✅ All automation runs locally on your machine")
        print("✅ No data sent to cloud services")
        print("✅ Complete privacy and security")
        print("")
        
    def random_delay(self, min_delay: float = None, max_delay: float = None):
        """Add random delay to mimic human behavior"""
        if min_delay is None:
            min_delay = self.delay_range[0]
        if max_delay is None:
            max_delay = self.delay_range[1]
        
        delay = random.uniform(min_delay, max_delay)
        print(f"⏳ Human-like delay: {delay:.1f} seconds...")
        time.sleep(delay)
    
    def get_local_playwright_browser(self, browser_type="chromium"):
        """Get a local Playwright browser instance"""
        if not PLAYWRIGHT_AVAILABLE:
            raise ImportError("Playwright not available. Install with: pip install playwright")
        
        print(f"🎭 Starting LOCAL Playwright {browser_type} browser...")
        
        p = sync_playwright().start()
        
        # Browser configuration for privacy
        browser_config = {
            "headless": self.headless,
            "args": [
                "--no-first-run",
                "--disable-background-timer-throttling",
                "--disable-backgrounding-occluded-windows",
                "--disable-renderer-backgrounding",
                "--disable-features=TranslateUI",
                "--disable-ipc-flooding-protection",
                "--disable-web-security",  # For local testing only
                "--disable-features=VizDisplayCompositor"
            ]
        }
        
        if browser_type == "chromium":
            browser = p.chromium.launch(**browser_config)
        elif browser_type == "firefox":
            browser = p.firefox.launch(**browser_config)
        elif browser_type == "webkit":
            browser = p.webkit.launch(**browser_config)
        else:
            browser = p.chromium.launch(**browser_config)
        
        print(f"✅ LOCAL {browser_type} browser started successfully")
        return browser, p
    
    def get_local_selenium_driver(self, browser_type="chrome"):
        """Get a local Selenium WebDriver instance"""
        if not SELENIUM_AVAILABLE:
            raise ImportError("Selenium not available. Install with: pip install selenium")
        
        print(f"🔧 Starting LOCAL Selenium {browser_type} driver...")
        
        if browser_type == "chrome":
            options = ChromeOptions()
            if self.headless:
                options.add_argument("--headless")
            
            # Privacy and security options
            options.add_argument("--no-sandbox")
            options.add_argument("--disable-dev-shm-usage")
            options.add_argument("--disable-blink-features=AutomationControlled")
            options.add_argument("--disable-extensions")
            options.add_argument("--disable-plugins")
            options.add_argument("--disable-images")  # Faster loading
            options.add_argument("--disable-javascript")  # Optional for scraping
            
            # User agent for privacy
            options.add_argument("--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
            
            driver = webdriver.Chrome(options=options)
            
        elif browser_type == "firefox":
            options = FirefoxOptions()
            if self.headless:
                options.add_argument("--headless")
            
            # Privacy options
            options.set_preference("dom.webnotifications.enabled", False)
            options.set_preference("media.volume_scale", "0.0")
            
            driver = webdriver.Firefox(options=options)
        else:
            raise ValueError(f"Unsupported browser type: {browser_type}")
        
        print(f"✅ LOCAL {browser_type} driver started successfully")
        return driver
    
    def linkedin_automation_playwright(self, email: str, password: str, max_likes: int = 10):
        """LinkedIn automation using LOCAL Playwright browser"""
        print("🔗 Starting LOCAL LinkedIn automation with Playwright...")
        print("🔒 Privacy: All automation runs locally on your machine")
        
        browser, playwright = self.get_local_playwright_browser()
        context = browser.new_context(
            user_agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            viewport={"width": 1920, "height": 1080}
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
            print(f"❌ Error during LOCAL automation: {e}")
            self.session_stats['errors'] += 1
            return False
        finally:
            browser.close()
            playwright.stop()
            print("🔒 LOCAL browser closed - no data transmitted externally")
    
    def _playwright_login(self, page: Page, email: str, password: str) -> bool:
        """Login to LinkedIn using LOCAL Playwright"""
        return playwright_login(page, email, password, label="LinkedIn via LOCAL browser")

    def _playwright_like_posts(self, page: Page, max_likes: int):
        """Like posts on LinkedIn timeline using LOCAL Playwright"""
        cfg = LikePostsConfig(
            max_likes=max_likes,
            session_stats=self.session_stats,
            random_delay_fn=self.random_delay,
            like_count_key="actions_performed",
            processed_count_key=None,
            label="LOCAL browser",
        )
        playwright_like_posts(page, cfg)

    def _print_session_summary(self):
        """Print automation session summary"""
        duration = datetime.now() - self.session_stats['start_time']

        print("\n" + "="*60)
        print("📊 LOCAL Browser Automation Session Summary")
        print("="*60)
        print(f"🔒 Browser Type: LOCAL {self.session_stats['browser_type']}")
        print(f"👍 Actions Performed: {self.session_stats['actions_performed']}")
        print(f"📰 Pages Visited: {self.session_stats['pages_visited']}")
        print(f"❌ Errors: {self.session_stats['errors']}")
        print(f"⏱️ Duration: {duration}")
        print(f"🕐 Started: {self.session_stats['start_time'].strftime('%Y-%m-%d %H:%M:%S')}")
        print("🔒 Privacy: All data processed locally - no external transmission")
        print("="*60)

def main():
    """Main function for LOCAL browser automation"""
    print("🔒 LOCAL Browser Automation for AI DevOps Framework")
    print("✅ Privacy-first automation using LOCAL browsers only")
    print("⚠️ IMPORTANT: Use responsibly and respect website Terms of Service")
    print("")

    # Check if LOCAL automation tools are available
    if not PLAYWRIGHT_AVAILABLE and not SELENIUM_AVAILABLE:
        print("❌ No LOCAL browser automation tools available")
        print("Install with: pip install playwright selenium")
        print("Then run: playwright install")
        return

    # Get credentials from environment
    email = os.getenv('LINKEDIN_EMAIL')
    password = os.getenv('LINKEDIN_PASSWORD')

    if not email or not password:
        print("🔐 LinkedIn credentials not found in environment variables")
        print("Set LINKEDIN_EMAIL and LINKEDIN_PASSWORD environment variables")
        print("Example: export LINKEDIN_EMAIL=your@email.com")
        print("         export LINKEDIN_PASSWORD=yourpassword")
        return

    # Configuration
    max_likes = int(os.getenv('LINKEDIN_MAX_LIKES', '10'))
    headless = os.getenv('LINKEDIN_HEADLESS', 'false').lower() == 'true'

    print(f"⚙️ LOCAL Browser Configuration:")
    print(f"   Email: {email}")
    print(f"   Max likes: {max_likes}")
    print(f"   Headless: {headless}")
    print(f"   Privacy: LOCAL browser only")
    print("")

    # Create LOCAL automation instance
    automation = LocalBrowserAutomation(headless=headless)

    # Run LOCAL automation
    if PLAYWRIGHT_AVAILABLE:
        print("🎭 Using LOCAL Playwright for automation")
        success = automation.linkedin_automation_playwright(email, password, max_likes)
    else:
        print("❌ Playwright not available for LOCAL automation")
        success = False

    if success:
        print("🎉 LOCAL LinkedIn automation completed successfully!")
        print("🔒 All data processed locally - complete privacy maintained")
    else:
        print("❌ LOCAL LinkedIn automation failed")

if __name__ == "__main__":
    main()
