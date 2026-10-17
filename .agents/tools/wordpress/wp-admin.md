---
description: WordPress admin - content management, plugins, maintenance, WP-CLI and MainWP integration
mode: subagent
temperature: 0.2
tools:
  write: true
  edit: true
  bash: true
  read: true
  webfetch: true
  wordpress-mcp_*: true
  context7_*: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# WordPress Admin Subagent

<!-- AI-CONTEXT-START -->
## Quick Reference

- **Sites Config**: `~/.config/aidevops/wordpress-sites.json`
- **Sites Template**: `configs/wordpress-sites.json.txt`
- **MainWP Config**: `configs/mainwp-config.json`
- **Working Dir**: `~/.aidevops/.agent-workspace/work/wordpress/`
- **WP-CLI Commands**: See `wp-cli-reference.md`
- **Preferred Plugins**: See `wp-preferred.md`

**Site Management Options**:

| Method | When to Use |
|--------|-------------|
| wp-helper.sh | Multi-site WP-CLI via wordpress-sites.json |
| WP-CLI (SSH) | Direct access, any site |
| MainWP | Fleet operations, connected sites |
| WordPress MCP | AI-powered admin actions |

**Shared-host credential rule:** Before requesting SSH access for several sites, identify hosting account/server boundaries. Configure one entry under `servers`, reference it from each site with `server_ref`, and store/inject one password or key per account—not one credential set per domain. Hostinger websites with the same account username share SSH access.
**Site readiness first:** For a hostname or mapped multisite child, run `site-context-helper.sh readiness <hostname>` before requesting browser authentication. It identifies local hosting and SSH evidence without exposing credential values; keep WP-CLI execution in `wordpress-sites.json`/`wp-helper.sh`.

**wp-helper.sh Commands**:

```bash
wp-helper.sh --list                          # List all sites
wp-helper.sh production plugin list          # Run on specific site
wp-helper.sh --category client core version  # Run on category
wp-helper.sh --all plugin update --all       # Run on ALL sites
wp-helper.sh --change-plan production plan.json  # Reviewed post/term changes (dry run)
```

**Reviewed content changes:** for field-level edits to live posts and terms, use a change plan (dry run, backup, read-back, restore): `wp-change-plan.md`.

**SSH Access by Hosting Type**:

| Hosting | Auth Method | Access Pattern |
|---------|-------------|----------------|
| LocalWP | N/A | `cd ~/Local Sites/site/app/public && wp ...` |
| Hostinger | sshpass | `sshpass -f ~/.ssh/hostinger_password ssh user@host "wp ..."` |
| Hetzner | SSH key | `ssh root@server "wp ..."` |
| Cloudron | SSH key | Via Cloudron CLI or SSH |

**Related Subagents**:
- `@mainwp` — Fleet management (sites with MainWP Child)
- `@wp-dev` — Code changes, debugging
- `@hostinger` — Hostinger-hosted site operations
- `@hetzner` — Hetzner server management
- `@dns-providers`, `@cloudflare` — DNS/SSL issues
- `@ses` — Email delivery issues

**Always use Context7** for latest WP-CLI command syntax.
<!-- AI-CONTEXT-END -->

## Site Configuration

```bash
mkdir -p ~/.config/aidevops
cp ~/.aidevops/agents/configs/wordpress-sites.json.txt ~/.config/aidevops/wordpress-sites.json
```

```json
{
  "sites": {
    "local-dev": {
      "name": "Local Development",
      "type": "localwp",
      "path": "~/Local Sites/my-site/app/public",
      "multisite": false,
      "mainwp_connected": false
    },
    "production": {
      "name": "Production Site",
      "type": "hostinger",
      "url": "https://example.com",
      "ssh_host": "ssh.example.com",
      "mainwp_connected": true,
      "mainwp_site_id": 123
    }
  }
}
```

## WP-CLI Commands

Full command reference: `wp-cli-reference.md`. Covers content management, plugins, core, users, backup/restore, security, site health, multisite, and SEO.

## MainWP Integration

Use `@mainwp` for fleet operations (bulk updates, security scans, centralized backups, monitoring).

```bash
./.agents/scripts/mainwp-helper.sh sites production
./.agents/scripts/mainwp-helper.sh bulk-update-plugins production 123 124 125
./.agents/scripts/mainwp-helper.sh security-scan production 123
```

```bash
# Store MainWP API credentials
setup-local-api-keys.sh set mainwp-consumer-key-production YOUR_KEY
setup-local-api-keys.sh set mainwp-consumer-secret-production YOUR_SECRET
```

## Common Workflows

### Plugin Update Workflow

1. `wp plugin update --all --dry-run` — check what will change
2. `wp db export backup.sql` — backup first
3. `wp plugin update --all`
4. Test site, then `wp cache flush`

Premium plugins stuck on old versions (GPLVault, inactive plugins, vendor channel faults): `premium-plugin-updates.md`.

### Content Migration

1. `wp export --post_type=post`
2. `wp import export.xml --authors=create`
3. `wp search-replace 'old.com' 'new.com'`
4. `wp media regenerate`

### Site Cloning

1. `wp db export` + `tar -czf site.tar.gz .`
2. Transfer, extract, import database
3. `wp search-replace` + update `wp-config.php`

## Security Checklist

Before bulk operations:
1. **Backup first** — `wp db export`
2. **Staging test** — test on staging before production
3. **Security scan** — run `@mainwp` security scan after changes
4. **Audit log** — document significant changes
5. **Directory listing** — check an existing dated `wp-content/uploads/<year>/` folder returns 403/404, not an `Index of` page; assess server-level protection with `tools/runtime/php-server-admin.md` (empty `index.php` files protect only their own folder).

### Image-library advisories: who can reach it

Read-only audit method observed with WordPress 7.1.3 in October 2026; recheck installed plugin versions, settings and call paths. Only the host can patch shared ImageMagick/Ghostscript libraries; see [Hostinger's shared image library notes](../../services/hosting/hostinger.md#read-only-audit-notes).

1. **Trace processing, not storage**: ImageMagick is reached when the selected image editor uses Imagick: core sub-sizes (`wp_generate_attachment_metadata()`, `wp_create_image_subsizes()`), `media_handle_upload()`, `media_handle_sideload()`, REST media uploads, or plugin calls to `wp_get_image_editor()`/`Imagick`. A file stored outside the Media Library without these processing calls does not reach ImageMagick. Search each active plugin (including network-active plugins), the active theme, must-use plugins and code kept by snippet plugins (for example Code Snippets' `{prefix}snippets` table), then trace callers:

   ```bash
   grep -rEn --include='*.php' 'wp_get_image_editor|wp_generate_attachment_metadata|wp_create_image_subsizes|media_handle_upload|media_handle_sideload|new \\?Imagick' wp-content/plugins/<slug>
   ```

2. **Account entry and capabilities**: read `users_can_register`, `default_role` and multisite network `registration`; check the resulting role's `upload_files`, not just whether registration is enabled.
   - **WooCommerce**: read `woocommerce_enable_myaccount_registration` and `woocommerce_enable_signup_and_login_from_checkout`. Users without `edit_posts`, `manage_woocommerce` or `view_admin_dashboard` are redirected away from wp-admin; uploads confined to its profile screen do not reach those customers. The redirect (`includes/admin/class-wc-admin.php` → `prevent_admin_access()`) exempts `admin-ajax.php` and `admin-post.php`, so other plugins' AJAX upload handlers and front-end paths still reach them.
   - **Ultimate Multisite**: read network `wp-ultimo_v2_settings` → `enable_registration`, `enable_email_verification`, `default_role` (new site owner; administrator/editor can upload), plus `upload_filetypes` (`pdf` exposes Ghostscript thumbnail processing) and `fileupload_maxk`. Check public sign-up page availability; inspect `wu_customers` dates/email domains to distinguish real sign-ups from team tests, keeping evidence private. Then list which customers hold `upload_files` on a site of their own (`get_blogs_of_user()`, then the role on each site): the settings show what a sign-up could get; this shows who can upload now.
3. **Front-end paths observed** (absence of calls is version-specific evidence, not a permanent safety guarantee):
   - **Tutor LMS 4.1.2**: profile/cover photos enter the Media Library with sub-sizes for any logged-in user (`classes/User.php` → `update_user_photo()` on `wp_ajax_tutor_user_photo_upload`: a nonce check that Tutor's front-end script data satisfies, and no capability check). It accepts only JPEG, PNG, GIF or WebP by `getimagesize()`, so those decoders and the profiles embedded in them are what reach ImageMagick. Evidence of use: `_tutor_profile_photo`/`_tutor_cover_photo` user meta holds the attachment ID, and `sizes` in that attachment's metadata shows the editor ran. Its registration requires `users_can_register` (`classes/Student.php`), but WooCommerce/other sign-ups still grant access.
   - **Fluent Forms Pro 6.2.15**: `src/Uploader.php` → `copyToWpMedia()` invokes the editor for the "Media Library" upload location, not the default location. Post forms do too: `src/Components/Post/PostFormHandler.php` → `setFeaturedImage()` → `getAttachmentToImageUrl()` calls `wp_generate_attachment_metadata()`. Find post forms as `{prefix}fluentform_form_meta` rows with `meta_key = 'postFeeds'`. Record the installed version when rechecking.
   - **AI Engine**: inspect each bot's `fileUpload`/`imageUpload` in `mwai_chatbots`, then trace enabled upload handling in the installed version.
   - **Webmention 5.10.1**: remote avatars resize only with `webmention_avatar_store_enable=1` (`includes/class-webmention.php`); `webmention_avatars` only controls display.
   - **No editor calls found** in audited Bookly Files, Ninja Job Board, Kadence form uploads, Fluent Support or Fluent Booking app code; the latter two's vendored WPFluent `Media` helper was unused. Record installed versions and verify callers before relying on this finding.
   - **Guest (`wp_ajax_nopriv_`) upload handlers**: check that the nonce a handler verifies is ever created and printed to visitors. Simple Feature Requests 2.4.9.6 registers `wp_ajax_nopriv_sfr_set_feature_request_attachments` (`inc/class-ajax.php`: `wp_handle_upload()`, then `wp_generate_attachment_metadata()`) and checks `sfr-attachment-nonce`. Its front-end script sends `sfr_vars.attachment_nonce`, but the free build never creates that nonce (`inc/class-assets.php` localises only `sfr-nonce`) and its attachment features are premium-only, so the handler is closed there. Recheck when the premium version is installed.
4. **Evidence of use**: inspect image/PDF attachments whose authors lack `upload_files`. Author 0 images are usually imports or made by code (for example WooCommerce's placeholder image or a site icon); inspect attachment meta (such as a source-URL key) to establish origin rather than assuming public uploads.
5. **Mitigate the reachable path**: while awaiting the host's fix, disable the specific upload/registration setting rather than switching every site to GD. Follow the [GD trade-off](../../services/hosting/hostinger.md#read-only-audit-notes): lost PDF thumbnails, HEIC conversion and embedded colour profiles.
