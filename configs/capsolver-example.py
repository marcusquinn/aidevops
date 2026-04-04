#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
CapSolver + Crawl4AI Integration Example
Demonstrates CAPTCHA solving with various types
"""

import asyncio
import capsolver
from crawl4ai import AsyncWebCrawler, BrowserConfig, CrawlerRunConfig, CacheMode

# IMPORTANT: Replace with your actual CapSolver API key
# Get your API key from: https://dashboard.capsolver.com/dashboard/overview
CAPSOLVER_API_KEY = "CAP-xxxxxxxxxxxxxxxxxxxxx"
capsolver.api_key = CAPSOLVER_API_KEY

async def solve_recaptcha_v2_example():
    """Example: Solving reCAPTCHA v2 checkbox"""
    site_url = "https://recaptcha-demo.appspot.com/recaptcha-v2-checkbox.php"
    site_key = "6LfW6wATAAAAAHLqO2pb8bDBahxlMxNdo9g947u9"

    browser_config = BrowserConfig(
        verbose=True,
        headless=False,
        use_persistent_context=True,
    )

    async with AsyncWebCrawler(config=browser_config) as crawler:
        # Initial page load
        await crawler.arun(
            url=site_url,
            cache_mode=CacheMode.BYPASS,
            session_id="captcha_session"
        )

        # Solve CAPTCHA using CapSolver
        print("🔄 Solving reCAPTCHA v2...")
        solution = capsolver.solve({
            "type": "ReCaptchaV2TaskProxyLess",
            "websiteURL": site_url,
            "websiteKey": site_key,
        })
        token = solution["gRecaptchaResponse"]
        print(f"✅ Token obtained: {token[:50]}...")

        # Inject token and submit
        js_code = f"""
            const textarea = document.getElementById('g-recaptcha-response');
            if (textarea) {{
                textarea.value = '{token}';
                document.querySelector('button.form-field[type="submit"]').click();
            }}
        """

        wait_condition = """() => {
            const items = document.querySelectorAll('h2');
            return items.length > 1;
        }"""

        run_config = CrawlerRunConfig(
            cache_mode=CacheMode.BYPASS,
            session_id="captcha_session",
            js_code=js_code,
            js_only=True,
            wait_for=f"js:{wait_condition}"
        )

        result = await crawler.arun(url=site_url, config=run_config)
        print("🎉 CAPTCHA solved successfully!")
        return result.markdown

async def solve_cloudflare_turnstile_example():
    """Example: Solving Cloudflare Turnstile"""
    site_url = "https://clifford.io/demo/cloudflare-turnstile"
    site_key = "0x4AAAAAAAGlwMzq_9z6S9Mh"

    browser_config = BrowserConfig(
        verbose=True,
        headless=False,
        use_persistent_context=True,
    )

    async with AsyncWebCrawler(config=browser_config) as crawler:
        # Initial page load
        await crawler.arun(
            url=site_url,
            cache_mode=CacheMode.BYPASS,
            session_id="turnstile_session"
        )

        # Solve Turnstile using CapSolver
        print("🔄 Solving Cloudflare Turnstile...")
        solution = capsolver.solve({
            "type": "AntiTurnstileTaskProxyLess",
            "websiteURL": site_url,
            "websiteKey": site_key,
        })
        token = solution["token"]
        print(f"✅ Token obtained: {token[:50]}...")

        # Inject token and submit
        js_code = f"""
            document.querySelector('input[name="cf-turnstile-response"]').value = '{token}';
            document.querySelector('button[type="submit"]').click();
        """

        wait_condition = """() => {
            const items = document.querySelectorAll('h1');
            return items.length === 0;
        }"""

        run_config = CrawlerRunConfig(
            cache_mode=CacheMode.BYPASS,
            session_id="turnstile_session",
            js_code=js_code,
            js_only=True,
            wait_for=f"js:{wait_condition}"
        )

        result = await crawler.arun(url=site_url, config=run_config)
        print("🎉 Turnstile solved successfully!")
        return result.markdown

async def main():
    """Main function to run examples"""
    print("🚀 CapSolver + Crawl4AI Integration Examples")
    print("=" * 50)

    try:
        # Example 1: reCAPTCHA v2
        print("\n📋 Example 1: reCAPTCHA v2")
        result1 = await solve_recaptcha_v2_example()
        if result1:
            print(f"✅ reCAPTCHA v2 result: {len(result1)} characters extracted")

        # Example 2: Cloudflare Turnstile
        print("\n📋 Example 2: Cloudflare Turnstile")
        result2 = await solve_cloudflare_turnstile_example()
        if result2:
            print(f"✅ Turnstile result: {len(result2)} characters extracted")

        print("\n✅ All examples completed successfully!")

    except Exception as e:
        print(f"❌ Error: {e}")
        print("💡 Make sure to set your CapSolver API key!")

if __name__ == "__main__":
    asyncio.run(main())
