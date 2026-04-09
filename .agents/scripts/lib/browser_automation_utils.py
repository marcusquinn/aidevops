"""Shared browser automation utilities for LinkedIn and other web automation tasks."""

from playwright.sync_api import Page


def playwright_login(page: Page, email: str, password: str, context_label: str = "") -> bool:
    """
    Login to LinkedIn using Playwright.
    
    Args:
        page: Playwright Page object
        email: LinkedIn email/username
        password: LinkedIn password
        context_label: Optional label for logging (e.g., "LOCAL", empty for standard)
    
    Returns:
        True if login was successful, False otherwise
    """
    try:
        context_msg = f" using {context_label} browser" if context_label else ""
        print(f"🔐 Logging into LinkedIn{context_msg}...")
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
            context_msg = f" via {context_label} browser" if context_label else ""
            print(f"✅ Successfully logged into LinkedIn{context_msg}")
            return True
        else:
            print("❌ Login failed - check credentials")
            return False
            
    except Exception as e:
        print(f"❌ Login error: {e}")
        return False
