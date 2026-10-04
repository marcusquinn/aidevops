---
description: WordPress plugin coding standards - security, structure, assets, i18n, compatibility, WordPress.org rules and lint mapping
mode: subagent
temperature: 0.2
tools:
  write: true
  edit: true
  bash: true
  read: true
  glob: true
  grep: true
  context7_*: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# WordPress Plugin Standards

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Use for**: writing or reviewing WordPress plugin code, and configuring its quality tools.
- **Full set**: WP Plugin Starter
  [`STANDARDS.md`](https://github.com/wpallstars/wp-plugin-starter-template-for-ai-coding/blob/main/STANDARDS.md)
  is the complete standard for plugins made with `/new-wp-plugin`. Link it; do not copy it.
- **Primary sources**: WordPress Plugin Handbook and WordPress Coding Standards (WPCS).
  Use Context7 for current function signatures and wording.
- Examples use the prefix `myplug_` / `MYPLUG_` and text domain `my-plugin`.

<!-- AI-CONTEXT-END -->

## Security

| Rule | Why | Good | Bad |
|------|-----|------|-----|
| Sanitise input early | Request data is attacker-controlled and slashed by WordPress. | `$t = sanitize_text_field( wp_unslash( $_POST['t'] ?? '' ) );` `$id = absint( $_GET['id'] ?? 0 );` | `$t = $_POST['t'];` |
| Escape output late, for its context | Escaping at the point of output is the only place the context is known. | `echo esc_html( $t );` `esc_attr()`, `esc_url()`, `wp_kses_post()` | `echo $t;` |
| Capability check, then nonce, on every state change | The capability decides who may act; the nonce proves this user meant to. | `current_user_can( 'manage_options' ) \|\| wp_die(); check_admin_referer( 'myplug_save' );` AJAX: `check_ajax_referer( 'myplug_ajax' );` | Saving options in an `admin_init` handler with no checks |
| Prepare every query | Interpolated values are SQL injection. | `$wpdb->get_row( $wpdb->prepare( "SELECT * FROM {$wpdb->prefix}myplug_items WHERE id = %d", $id ) );` | `"… WHERE id = $id"` |
| Always set a REST `permission_callback` | A missing callback logs a notice and leaves the route open. | `'permission_callback' => fn() => current_user_can( 'edit_posts' )` | `'permission_callback' => '__return_true'` on a write route (acceptable only for public reads) |
| Handle uploads through core | Core checks type, extension and upload errors. | `wp_handle_upload( $_FILES['f'], array( 'test_form' => false, 'mimes' => array( 'csv' => 'text/csv' ) ) );` | `move_uploaded_file( $_FILES['f']['tmp_name'], $dest );` |
| Safe remote requests and redirects | User-supplied URLs can reach internal hosts or redirect off-site. | `wp_safe_remote_get( $url );` `wp_safe_redirect( $url ); exit;` | `wp_remote_get( $_GET['url'] );` `wp_redirect( $_GET['to'] );` |

## Structure

| Rule | Why | Good | Bad |
|------|-----|------|-----|
| Unique prefix for functions, classes, options, hooks, CSS | Every plugin shares one global namespace. | `myplug_get_settings()`, `MyPlug_Admin`, option `myplug_settings`, hook `myplug_after_save`, `.myplug-panel` | `get_settings()` (a deprecated core function) |
| Guard direct access | PHP files must not run outside WordPress. | `defined( 'ABSPATH' ) \|\| exit;` | No guard in an included file |
| No output on include | Output during load breaks headers and activation ("unexpected output"). | Files only declare code and register hooks | `echo` at file scope; whitespace after a closing `?>` |
| Register on `plugins_loaded` / `init` | Other plugins, translations and post types are not ready at file load. | `add_action( 'init', 'myplug_register_post_types' );` | Calling `register_post_type()` at file scope |
| `uninstall.php` removes everything the plugin stored | Deleting a plugin must not leave orphan data; deactivation must keep it. | `defined( 'WP_UNINSTALL_PLUGIN' ) \|\| exit; delete_option( 'myplug_settings' ); delete_transient( 'myplug_cache' ); wp_clear_scheduled_hook( 'myplug_cron' ); delete_metadata( 'user', 0, 'myplug_seen', '', true );` | Deleting data on deactivation, or never |
| Settings API (or the starter's settings registry) | It provides the nonce, capability and sanitise callback. | `register_setting( 'myplug', 'myplug_settings', array( 'sanitize_callback' => 'myplug_sanitize_settings' ) );` | `update_option( 'myplug_settings', $_POST['settings'] );` |

## Assets and i18n

| Rule | Why | Good | Bad |
|------|-----|------|-----|
| Enqueue only on the plugin's own screens | Global assets slow and break other screens. | `if ( 'settings_page_myplug' !== $hook_suffix ) { return; }` in an `admin_enqueue_scripts` callback | Enqueueing on every admin page |
| Version assets by plugin version | Cache busting tied to releases. | `wp_enqueue_script( 'myplug-admin', plugins_url( 'assets/admin.js', __FILE__ ), array(), MYPLUG_VERSION, true );` | `null` or `time()` as the version |
| Literal text domain and strings | Extraction tools read only literals. | `__( 'Settings saved.', 'my-plugin' )` | `__( $message, MYPLUG_DOMAIN )` |
| Translate script strings | JS strings otherwise stay in English. | `wp_set_script_translations( 'myplug-admin', 'my-plugin' );` | Hard-coded strings in JS |

## Compatibility

| Rule | Why | Good | Bad |
|------|-----|------|-----|
| State minimums in header and `readme.txt` | WordPress blocks installs below them; both files must agree. | `Requires at least: 6.2` and `Requires PHP: 7.4` (example values) in both | Minimums only in one file, or different values |
| No deprecated functions | They emit notices and are removed later. | Run with `WP_DEBUG_LOG`; no `_deprecated_*` lines in `debug.log` | `get_page_by_title()` (deprecated in 6.2) |
| Handle multisite activation | Network activation must set up every site. | Activation hook honours `$network_wide`; `wp_initialize_site` sets up new sites | Creating tables only for the current site |

## WordPress.org

| Rule | Why | Good | Bad |
|------|-----|------|-----|
| Plugin Check clean | Review uses the same checks. | `wp-plugin-release-helper.sh plugin-check` (or `wp plugin check my-plugin`) with no errors | Submitting with errors |
| `readme.txt` under 10 KB | The directory limits it. | One short line per feature | A full manual in `readme.txt` |
| Disclose every external service | Guidelines require what is sent, when, and links to terms and privacy policy. | `== External services ==` entry per remote call | An undocumented API call |
| GPL-compatible code and assets | The directory accepts GPL-compatible work only. | Licences recorded for bundled libraries, fonts and images | Assets with unknown licences |
| No updater code in the WordPress.org build | WordPress.org delivers updates; Plugin Check reports `plugin_updater_detected`. | Exclude the GitHub updater from the WordPress.org zip (`wp-plugin-release.md`) | Shipping a custom updater to WordPress.org |

## Tooling

| Tool | Use | Note |
|------|-----|------|
| PHPCS + WPCS | `vendor/bin/phpcs --standard=WordPress` | Primary style and security sniffs (escaping, nonces, prepared SQL). |
| PHPStan + `szepeviktor/phpstan-wordpress` | Static types against WordPress stubs | Raise the level gradually; no blanket baselines of new code. |
| Plugin Check | `wp-plugin-release-helper.sh plugin-check` | WordPress.org review rules. |
| SonarCloud / Codacy | Complexity, duplication, Semgrep/Opengrep security | Disable `php:S100`, `php:S101`, `php:S116` (WordPress snake_case functions, `My_Plugin` classes, snake_case properties) and Stylelint `selector-class-pattern` (WordPress/BEM class names) in the service configuration. Do not rename code to satisfy them, and keep the remaining findings. |

Codacy coding-standard changes: `tools/code-review/codacy.md`.

## Related

- `wp-dev.md` — development and debugging
- `wp-plugin-new.md` — new plugin from WP Plugin Starter
- `wp-plugin-release.md` — release builds, preflight, Plugin Check
