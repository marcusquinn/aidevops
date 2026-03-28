/**
 * wp-plugin-smoke-test.spec.js — Generic Playwright smoke test for WordPress plugins (t1696)
 *
 * Used by wordpress-plugin.sh when a plugin has no tests/e2e/ directory.
 * Tests the most common failure modes: activation errors, PHP fatals, settings page load.
 *
 * Environment variables (set by wordpress-plugin.sh test):
 *   WP_BASE_URL     — wp-env base URL, e.g. http://localhost:8888
 *   WP_PLUGIN_SLUG  — plugin slug, e.g. git-updater
 *
 * Prerequisites:
 *   npm install -D @playwright/test
 *   npx playwright install chromium
 *
 * Run directly:
 *   WP_BASE_URL=http://localhost:8888 WP_PLUGIN_SLUG=my-plugin \
 *     npx playwright test wp-plugin-smoke-test.spec.js --reporter=line
 */

const { test, expect } = require('@playwright/test');

const BASE_URL = process.env.WP_BASE_URL || 'http://localhost:8888';
const PLUGIN_SLUG = process.env.WP_PLUGIN_SLUG || 'my-plugin';
const WP_ADMIN = `${BASE_URL}/wp-admin`;
const WP_ADMIN_USER = process.env.WP_ADMIN_USER || 'admin';
const WP_ADMIN_PASS = process.env.WP_ADMIN_PASS || 'password';

// =============================================================================
// Helpers
// =============================================================================

/**
 * Log in to wp-admin. Reuses the browser context across tests in the same
 * worker via storageState — login is performed once per test file.
 */
async function wpLogin(page) {
  await page.goto(`${WP_ADMIN}/`);
  // Already logged in?
  if (page.url().includes('/wp-admin/') && !page.url().includes('wp-login.php')) {
    return;
  }
  await page.fill('#user_login', WP_ADMIN_USER);
  await page.fill('#user_pass', WP_ADMIN_PASS);
  await page.click('#wp-submit');
  await page.waitForURL(/wp-admin/);
}

/**
 * Check the current page for PHP fatal/parse error markers.
 * Returns an array of error strings found, or empty array if clean.
 */
async function collectPhpErrors(page) {
  const content = await page.content();
  const patterns = [
    /Fatal error:/i,
    /Parse error:/i,
    /PHP Fatal error/i,
    /Call to undefined function/i,
    /Uncaught Error:/i,
    /Uncaught TypeError:/i,
  ];
  return patterns
    .filter((re) => re.test(content))
    .map((re) => re.source);
}

// =============================================================================
// Tests
// =============================================================================

test.describe(`WordPress plugin smoke tests: ${PLUGIN_SLUG}`, () => {
  test.beforeEach(async ({ page }) => {
    await wpLogin(page);
  });

  // ---------------------------------------------------------------------------
  // 1. wp-admin dashboard loads without PHP errors
  // ---------------------------------------------------------------------------
  test('wp-admin dashboard loads without PHP errors', async ({ page }) => {
    await page.goto(`${WP_ADMIN}/`);
    const errors = await collectPhpErrors(page);
    expect(errors, `PHP errors on dashboard: ${errors.join(', ')}`).toHaveLength(0);
    // Dashboard should show the "Dashboard" heading
    await expect(page.locator('#wpbody')).toBeVisible();
  });

  // ---------------------------------------------------------------------------
  // 2. Plugin is listed and active on the Plugins page
  // ---------------------------------------------------------------------------
  test('plugin is listed and active on Plugins page', async ({ page }) => {
    await page.goto(`${WP_ADMIN}/plugins.php`);
    const errors = await collectPhpErrors(page);
    expect(errors, `PHP errors on plugins page: ${errors.join(', ')}`).toHaveLength(0);

    // Plugin row should exist
    const pluginRow = page.locator(`tr[data-slug="${PLUGIN_SLUG}"]`);
    await expect(pluginRow).toBeVisible({ timeout: 10000 });

    // Plugin should be active (row has 'active' class)
    await expect(pluginRow).toHaveClass(/active/);
  });

  // ---------------------------------------------------------------------------
  // 3. Deactivate → reactivate cycle (no fatal errors)
  // ---------------------------------------------------------------------------
  test('deactivate and reactivate without errors', async ({ page }) => {
    await page.goto(`${WP_ADMIN}/plugins.php`);

    // Deactivate
    const deactivateLink = page.locator(
      `tr[data-slug="${PLUGIN_SLUG}"] .deactivate a`
    );
    if (await deactivateLink.isVisible()) {
      await deactivateLink.click();
      await page.waitForURL(/plugins\.php/);
      const deactivateErrors = await collectPhpErrors(page);
      expect(
        deactivateErrors,
        `PHP errors after deactivation: ${deactivateErrors.join(', ')}`
      ).toHaveLength(0);
    }

    // Reactivate
    const activateLink = page.locator(
      `tr[data-slug="${PLUGIN_SLUG}"] .activate a`
    );
    if (await activateLink.isVisible()) {
      await activateLink.click();
      await page.waitForURL(/plugins\.php/);
      const activateErrors = await collectPhpErrors(page);
      expect(
        activateErrors,
        `PHP errors after reactivation: ${activateErrors.join(', ')}`
      ).toHaveLength(0);
    }
  });

  // ---------------------------------------------------------------------------
  // 4. Plugin settings page loads (if it exists)
  // ---------------------------------------------------------------------------
  test('plugin settings page loads without errors (if present)', async ({ page }) => {
    // Common settings page slug patterns
    const settingsSlugs = [
      `options-general.php?page=${PLUGIN_SLUG}`,
      `admin.php?page=${PLUGIN_SLUG}`,
      `tools.php?page=${PLUGIN_SLUG}`,
      `settings.php?page=${PLUGIN_SLUG}`,
    ];

    let settingsFound = false;
    for (const slug of settingsSlugs) {
      const url = `${WP_ADMIN}/${slug}`;
      const response = await page.goto(url);
      if (response && response.status() === 200) {
        const content = await page.content();
        // Check it's not a "page not found" redirect
        if (!content.includes('You do not have sufficient permissions')) {
          settingsFound = true;
          const errors = await collectPhpErrors(page);
          expect(
            errors,
            `PHP errors on settings page (${slug}): ${errors.join(', ')}`
          ).toHaveLength(0);
          break;
        }
      }
    }

    if (!settingsFound) {
      test.info().annotations.push({
        type: 'skip-reason',
        description: `No settings page found for ${PLUGIN_SLUG} — skipping settings test`,
      });
    }
  });

  // ---------------------------------------------------------------------------
  // 5. Front-end home page loads without PHP errors
  // ---------------------------------------------------------------------------
  test('front-end home page loads without PHP errors', async ({ page }) => {
    await page.goto(BASE_URL);
    const errors = await collectPhpErrors(page);
    expect(errors, `PHP errors on front-end: ${errors.join(', ')}`).toHaveLength(0);
    // Page should return 200
    const response = await page.goto(BASE_URL);
    expect(response?.status()).toBe(200);
  });

  // ---------------------------------------------------------------------------
  // 6. Multisite: Network Admin loads without PHP errors
  // ---------------------------------------------------------------------------
  test('multisite network admin loads without PHP errors', async ({ page }) => {
    await page.goto(`${WP_ADMIN}/network/`);
    // If not multisite, this redirects to wp-admin — that's fine
    const errors = await collectPhpErrors(page);
    expect(errors, `PHP errors on network admin: ${errors.join(', ')}`).toHaveLength(0);
  });
});
