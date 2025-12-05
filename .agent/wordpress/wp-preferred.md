---
description: WordPress preferred plugins and theme recommendations
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: true
  task: true
---

# WordPress Preferred Plugins & Theme

<!-- AI-CONTEXT-START -->
## Quick Reference

**Theme**: Kadence (https://wordpress.org/themes/kadence/)
**Total Plugins**: 127+ curated plugins across 19 categories

**Selection Criteria** (applied globally):
- Speed optimization (minimal frontend impact)
- WP standards compliance (native UI patterns)
- Quality documentation
- Regular updates without breaking changes
- Tested compatibility with this stack

**Key Ecosystems**:
- **Kadence**: Theme, Blocks Pro, Conversions, Shop Kit, Starter Templates
- **Fluent**: Forms, CRM, Support, Booking, Community, Boards, SMTP
- **Flying**: Analytics, Pages, Scripts (performance suite)

**Quick Install (minimal stack)**:

```bash
wp plugin install antispam-bee compressx fluent-smtp kadence-blocks simple-cloudflare-turnstile --activate
wp theme install kadence --activate
```

**Pro/Premium plugins**: Require license activation via vendor dashboards
**License keys**: Store in `~/.config/aidevops/mcp-env.sh` (see api-key-setup.md)
**Updates**: Git Updater available for managing plugin updates from Git repositories
<!-- AI-CONTEXT-END -->

## Selection Criteria

Plugins are chosen based on:

1. **Speed Optimization** - Minimal frontend impact, efficient code
2. **WP Standards** - Following WordPress coding standards and UI patterns
3. **Documentation** - Clear, comprehensive, up-to-date docs
4. **Update Frequency** - Regular updates without breaking changes
5. **Conflict-Free** - Tested for compatibility with this stack

## Theme

| Name | Slug | Source |
|------|------|--------|
| Kadence | `kadence` | https://wordpress.org/themes/kadence/ |
| Kadence Pro (plugin) | `kadence-pro` | https://www.kadencewp.com/kadence-theme/pro/ |

## Plugins by Category

### Minimal (Essential Starter Stack)

These 5 plugins form the minimal recommended installation for any new WordPress site.

| Slug | Name | Source |
|------|------|--------|
| `antispam-bee` | Antispam Bee | https://wordpress.org/plugins/antispam-bee/ |
| `compressx` | CompressX | https://wordpress.org/plugins/compressx/ |
| `fluent-smtp` | FluentSMTP | https://wordpress.org/plugins/fluent-smtp/ |
| `kadence-blocks` | Kadence Blocks | https://wordpress.org/plugins/kadence-blocks/ |
| `simple-cloudflare-turnstile` | Simple Cloudflare Turnstile | https://wordpress.org/plugins/simple-cloudflare-turnstile/ |

### Admin

| Slug | Name | Source |
|------|------|--------|
| `admin-bar-dashboard-control` | Admin Bar & Dashboard Control | https://wordpress.org/plugins/admin-bar-dashboard-control/ |
| `admin-columns-pro` | Admin Columns Pro | https://www.admincolumns.com/ |
| `admin-menu-editor-pro` | Admin Menu Editor Pro | https://adminmenueditor.com/upgrade-to-pro/ |
| `wp-toolbar-editor` | AME Toolbar Editor | https://adminmenueditor.com/ |
| `hide-admin-notices` | Hide Admin Notices | https://wordpress.org/plugins/hide-admin-notices/ |
| `magic-login` | Magic Login | https://wordpress.org/plugins/magic-login/ |
| `mainwp-child` | MainWP Child | https://wordpress.org/plugins/mainwp-child/ |
| `mainwp-child-reports` | MainWP Child Reports | https://wordpress.org/plugins/mainwp-child-reports/ |
| `manage-notification-emails` | Manage Notification E-mails | https://wordpress.org/plugins/manage-notification-emails/ |
| `network-plugin-auditor` | Network Plugin Auditor | https://wordpress.org/plugins/network-plugin-auditor/ |
| `plugin-groups` | Plugin Groups | https://wordpress.org/plugins/plugin-groups/ |
| `plugin-toggle` | Plugin Toggle | https://wordpress.org/plugins/plugin-toggle/ |
| `user-switching` | User Switching | https://wordpress.org/plugins/user-switching/ |

### AI

| Slug | Name | Source |
|------|------|--------|
| `ai-engine` | AI Engine | https://wordpress.org/plugins/ai-engine/ |
| `ai-engine-pro` | AI Engine (Pro) | https://meowapps.com/plugin/ai-engine/ |

### CMS (Content Management)

| Slug | Name | Source |
|------|------|--------|
| `auto-post-scheduler` | Auto Post Scheduler | https://wordpress.org/plugins/auto-post-scheduler/ |
| `auto-upload-images` | Auto Upload Images | https://wordpress.org/plugins/auto-upload-images/ |
| `block-options` | EditorsKit | https://wordpress.org/plugins/block-options/ |
| `bookmark-card` | Bookmark Card | https://wordpress.org/plugins/bookmark-card/ |
| `browser-shots` | Browser Shots | https://wordpress.org/plugins/browser-shots/ |
| `bulk-actions-select-all` | Bulk Actions Select All | https://wordpress.org/plugins/bulk-actions-select-all/ |
| `carbon-copy` | Carbon Copy | https://wordpress.org/plugins/carbon-copy/ |
| `code-block-pro` | Code Block Pro | https://wordpress.org/plugins/code-block-pro/ |
| `distributor` | Distributor | https://wordpress.org/plugins/distributor/ |
| `iframe-block` | iFrame Block | https://wordpress.org/plugins/iframe-block/ |
| `ics-calendar` | ICS Calendar | https://wordpress.org/plugins/ics-calendar/ |
| `mammoth-docx-converter` | Mammoth .docx converter | https://wordpress.org/plugins/mammoth-docx-converter/ |
| `nav-menu-roles` | Nav Menu Roles | https://wordpress.org/plugins/nav-menu-roles/ |
| `ninja-tables` | Ninja Tables | https://wordpress.org/plugins/ninja-tables/ |
| `ninja-tables-pro` | Ninja Tables Pro | https://wpmanageninja.com/ninja-tables/ |
| `post-draft-preview` | Post Draft Preview | https://wordpress.org/plugins/post-draft-preview/ |
| `post-type-switcher` | Post Type Switcher | https://wordpress.org/plugins/post-type-switcher/ |
| `simple-custom-post-order` | Simple Custom Post Order | https://wordpress.org/plugins/simple-custom-post-order/ |
| `simple-icons` | Popular Brand SVG Icons | https://wordpress.org/plugins/simple-icons/ |
| `sticky-posts-switch` | Sticky Posts - Switch | https://wordpress.org/plugins/sticky-posts-switch/ |
| `super-speedy-imports` | Super Speedy Imports | https://wordpress.org/plugins/super-speedy-imports/ |
| `term-management-tools` | Term Management Tools | https://wordpress.org/plugins/term-management-tools/ |
| `the-paste` | The Paste | https://wordpress.org/plugins/the-paste/ |
| `wikipedia-preview` | Wikipedia Preview | https://wordpress.org/plugins/wikipedia-preview/ |

### Compliance (Privacy & Legal)

| Slug | Name | Source |
|------|------|--------|
| `avatar-privacy` | Avatar Privacy | https://wordpress.org/plugins/avatar-privacy/ |
| `complianz-gdpr` | Complianz GDPR | https://wordpress.org/plugins/complianz-gdpr/ |
| `complianz-gdpr-premium` | Complianz Privacy Suite Premium | https://complianz.io/ |
| `complianz-terms-conditions` | Complianz Terms & Conditions | https://wordpress.org/plugins/complianz-terms-conditions/ |
| `really-simple-ssl` | Really Simple SSL | https://wordpress.org/plugins/really-simple-ssl/ |
| `really-simple-ssl-pro` | Really Simple Security Pro | https://really-simple-ssl.com/pro/ |

### CRM & Forms (Fluent Ecosystem)

| Slug | Name | Source |
|------|------|--------|
| `fluent-boards` | Fluent Boards | https://wordpress.org/plugins/fluent-boards/ |
| `fluent-boards-pro` | Fluent Boards Pro | https://fluentboards.com/ |
| `fluent-booking` | FluentBooking | https://wordpress.org/plugins/fluent-booking/ |
| `fluent-booking-pro` | FluentBooking Pro | https://fluentbooking.com/ |
| `fluent-community` | FluentCommunity | https://wordpress.org/plugins/fluent-community/ |
| `fluent-community-pro` | FluentCommunity Pro | https://fluentcommunity.co/ |
| `fluent-crm` | FluentCRM | https://wordpress.org/plugins/fluent-crm/ |
| `fluentcampaign-pro` | FluentCRM Pro | https://fluentcrm.com/ |
| `fluent-roadmap` | Fluent Roadmap | https://wordpress.org/plugins/fluent-roadmap/ |
| `fluent-support` | Fluent Support | https://wordpress.org/plugins/fluent-support/ |
| `fluent-support-pro` | Fluent Support Pro | https://fluentsupport.com/ |
| `fluentform` | Fluent Forms | https://wordpress.org/plugins/fluentform/ |
| `fluentformpro` | Fluent Forms Pro | https://fluentforms.com/ |
| `fluentforms-pdf` | Fluent Forms PDF Generator | https://wordpress.org/plugins/fluentforms-pdf/ |
| `fluentform-signature` | Fluent Forms Signature Addon | https://fluentforms.com/ |

### eCommerce (WooCommerce)

| Slug | Name | Source |
|------|------|--------|
| `woocommerce` | WooCommerce | https://wordpress.org/plugins/woocommerce/ |
| `kadence-woocommerce-email-designer` | Kadence WooCommerce Email Designer | https://wordpress.org/plugins/kadence-woocommerce-email-designer/ |
| `kadence-woo-extras` | Kadence Shop Kit | https://www.kadencewp.com/ |
| `pymntpl-paypal-woocommerce` | Payment Plugins for PayPal | https://wordpress.org/plugins/pymntpl-paypal-woocommerce/ |
| `woo-stripe-payment` | Payment Plugins for Stripe | https://wordpress.org/plugins/woo-stripe-payment/ |

### LMS (Learning Management)

| Slug | Name | Source |
|------|------|--------|
| `tutor` | Tutor LMS | https://wordpress.org/plugins/tutor/ |
| `tutor-pro` | Tutor LMS Pro | https://www.themeum.com/product/tutor-lms/ |
| `tutor-lms-certificate-builder` | Tutor LMS Certificate Builder | https://www.themeum.com/product/tutor-lms-certificate-builder/ |

### Media

| Slug | Name | Source |
|------|------|--------|
| `easy-watermark` | Easy Watermark | https://wordpress.org/plugins/easy-watermark/ |
| `enable-media-replace` | Enable Media Replace | https://wordpress.org/plugins/enable-media-replace/ |
| `image-copytrack` | Image Copytrack | https://wordpress.org/plugins/image-copytrack/ |
| `imsanity` | Imsanity | https://wordpress.org/plugins/imsanity/ |
| `media-file-renamer` | Media File Renamer | https://wordpress.org/plugins/media-file-renamer/ |
| `media-file-renamer-pro` | Media File Renamer Pro | https://meowapps.com/plugin/media-file-renamer/ |
| `safe-svg` | Safe SVG | https://wordpress.org/plugins/safe-svg/ |

### SEO

| Slug | Name | Source |
|------|------|--------|
| `burst-statistics` | Burst Statistics | https://wordpress.org/plugins/burst-statistics/ |
| `hreflang-manager` | Hreflang Manager | https://wordpress.org/plugins/hreflang-manager/ |
| `link-insight` | Link Whisper | https://linkwhisper.com/ |
| `official-facebook-pixel` | Meta Pixel for WordPress | https://wordpress.org/plugins/official-facebook-pixel/ |
| `post-to-google-my-business` | Post to Google My Business | https://wordpress.org/plugins/post-to-google-my-business/ |
| `pretty-link` | PrettyLinks | https://wordpress.org/plugins/pretty-link/ |
| `seo-by-rank-math` | Rank Math SEO | https://wordpress.org/plugins/seo-by-rank-math/ |
| `rank-optimizer-pro` | Rank Math SEO PRO | https://rankmath.com/ |
| `readabler` | Readabler | https://wordpress.org/plugins/readabler/ |
| `remove-cpt-base` | Remove CPT base | https://wordpress.org/plugins/remove-cpt-base/ |
| `remove-old-slugspermalinks` | Slugs Manager | https://wordpress.org/plugins/remove-old-slugspermalinks/ |
| `syndication-links` | Syndication Links | https://wordpress.org/plugins/syndication-links/ |
| `ultimate-410` | Ultimate 410 | https://wordpress.org/plugins/ultimate-410/ |
| `webmention` | Webmention | https://wordpress.org/plugins/webmention/ |

### Setup & Import

| Slug | Name | Source |
|------|------|--------|
| `kadence-starter-templates` | Starter Templates by Kadence WP | https://wordpress.org/plugins/kadence-starter-templates/ |
| `wordpress-importer` | WordPress Importer | https://wordpress.org/plugins/wordpress-importer/ |

### Social

| Slug | Name | Source |
|------|------|--------|
| `social-engine` | Social Engine | https://wordpress.org/plugins/social-engine/ |
| `social-engine-pro` | Social Engine Pro | https://meowapps.com/plugin/social-engine/ |
| `wp-social-ninja` | WP Social Ninja | https://wordpress.org/plugins/wp-social-ninja/ |
| `wp-social-ninja-pro` | WP Social Ninja Pro | https://wpsocialninja.com/ |
| `wp-social-reviews` | WP Social Reviews | https://wordpress.org/plugins/wp-social-reviews/ |

### Speed & Performance

| Slug | Name | Source |
|------|------|--------|
| `compressx` | CompressX | https://wordpress.org/plugins/compressx/ |
| `disable-wordpress-updates` | Disable All WordPress Updates | https://wordpress.org/plugins/disable-wordpress-updates/ |
| `disable-dashboard-for-woocommerce-pro` | Disable Bloat PRO | https://disablebloat.com/ |
| `flying-analytics` | Flying Analytics | https://wordpress.org/plugins/flying-analytics/ |
| `flying-pages` | Flying Pages | https://wordpress.org/plugins/flying-pages/ |
| `flying-scripts` | Flying Scripts | https://wordpress.org/plugins/flying-scripts/ |
| `freesoul-deactivate-plugins` | Freesoul Deactivate Plugins | https://wordpress.org/plugins/freesoul-deactivate-plugins/ |
| `freesoul-deactivate-plugins-pro` | Freesoul Deactivate Plugins PRO | https://freesoul-deactivate-plugins.com/ |
| `growthboost` | Scalability Pro | https://scalability.pro/ |
| `http-requests-manager` | HTTP Requests Manager | https://wordpress.org/plugins/http-requests-manager/ |
| `index-wp-mysql-for-speed` | Index WP MySQL For Speed | https://wordpress.org/plugins/index-wp-mysql-for-speed/ |
| `litespeed-cache` | LiteSpeed Cache | https://wordpress.org/plugins/litespeed-cache/ |
| `performant-translations` | Performant Translations | https://wordpress.org/plugins/performant-translations/ |
| `wp-widget-disable` | Widget Disable | https://wordpress.org/plugins/wp-widget-disable/ |

### Translation

| Slug | Name | Source |
|------|------|--------|
| `hreflang-manager` | Hreflang Manager | https://wordpress.org/plugins/hreflang-manager/ |
| `performant-translations` | Performant Translations | https://wordpress.org/plugins/performant-translations/ |

### Advanced (Developer Tools)

| Slug | Name | Source |
|------|------|--------|
| `acf-better-search` | ACF: Better Search | https://wordpress.org/plugins/acf-better-search/ |
| `secure-custom-fields` | Secure Custom Fields | https://wordpress.org/plugins/secure-custom-fields/ |
| `code-snippets` | Code Snippets | https://wordpress.org/plugins/code-snippets/ |
| `code-snippets-pro` | Code Snippets Pro | https://codesnippets.pro/ |
| `git-updater` | Git Updater | https://wordpress.org/plugins/git-updater/ |
| `indieweb` | IndieWeb | https://wordpress.org/plugins/indieweb/ |
| `waspthemes-yellow-pencil` | YellowPencil Pro | https://yellowpencil.waspthemes.com/ |

### Debug & Troubleshooting

| Slug | Name | Source |
|------|------|--------|
| `advanced-database-cleaner` | Advanced Database Cleaner | https://wordpress.org/plugins/advanced-database-cleaner/ |
| `advanced-database-cleaner-pro` | Advanced Database Cleaner PRO | https://sigmaplugin.com/downloads/wordpress-advanced-database-cleaner |
| `code-profiler-pro` | Code Profiler Pro | https://codeprofiler.io/ |
| `debug-log-manager` | Debug Log Manager | https://wordpress.org/plugins/debug-log-manager/ |
| `gotmls` | Anti-Malware Security | https://wordpress.org/plugins/gotmls/ |
| `query-monitor` | Query Monitor | https://wordpress.org/plugins/query-monitor/ |
| `string-locator` | String Locator | https://wordpress.org/plugins/string-locator/ |
| `user-switching` | User Switching | https://wordpress.org/plugins/user-switching/ |
| `wp-crontrol` | WP Crontrol | https://wordpress.org/plugins/wp-crontrol/ |

### Security

| Slug | Name | Source |
|------|------|--------|
| `antispam-bee` | Antispam Bee | https://wordpress.org/plugins/antispam-bee/ |
| `comment_goblin` | Comment Goblin | https://commentgoblin.com/ |
| `gotmls` | Anti-Malware Security | https://wordpress.org/plugins/gotmls/ |
| `really-simple-ssl` | Really Simple SSL | https://wordpress.org/plugins/really-simple-ssl/ |
| `really-simple-ssl-pro` | Really Simple Security Pro | https://really-simple-ssl.com/pro/ |
| `simple-cloudflare-turnstile` | Simple Cloudflare Turnstile | https://wordpress.org/plugins/simple-cloudflare-turnstile/ |

### Kadence Ecosystem

| Slug | Name | Source |
|------|------|--------|
| `kadence-blocks` | Kadence Blocks | https://wordpress.org/plugins/kadence-blocks/ |
| `kadence-blocks-pro` | Kadence Blocks PRO | https://www.kadencewp.com/kadence-blocks/pro/ |
| `kadence-build-child-defaults` | Kadence Child Theme Builder | https://www.kadencewp.com/ |
| `kadence-cloud` | Kadence Pattern Hub | https://www.kadencewp.com/ |
| `kadence-conversions` | Kadence Conversions | https://www.kadencewp.com/ |
| `kadence-pro` | Kadence Pro | https://www.kadencewp.com/kadence-theme/pro/ |
| `kadence-simple-share` | Kadence Simple Share | https://wordpress.org/plugins/kadence-simple-share/ |
| `kadence-starter-templates` | Starter Templates by Kadence WP | https://wordpress.org/plugins/kadence-starter-templates/ |
| `kadence-woo-extras` | Kadence Shop Kit | https://www.kadencewp.com/ |
| `kadence-woocommerce-email-designer` | Kadence WooCommerce Email Designer | https://wordpress.org/plugins/kadence-woocommerce-email-designer/ |

### Migration & Backup

| Slug | Name | Source |
|------|------|--------|
| `wp-migrate-db-pro` | WP Migrate | https://deliciousbrains.com/wp-migrate-db-pro/ |
| `wp-migrate-db-pro-compatibility` | WP Migrate Compatibility | https://deliciousbrains.com/wp-migrate-db-pro/ |

### Multisite

| Slug | Name | Source |
|------|------|--------|
| `network-plugin-auditor` | Network Plugin Auditor | https://wordpress.org/plugins/network-plugin-auditor/ |
| `ultimate-multisite` | Ultimate Multisite | https://developer.developer.developer-developer-developer/ |

### Hosting-Specific

| Slug | Name | Source |
|------|------|--------|
| `closte-requirements` | Closte.com | Only for Closte.com hosting |
| `eos-deactivate-plugins` | Freesoul Deactivate Plugins [FDP] | Closte variant |

## WP-CLI Quick Install Commands

### Minimal Stack

```bash
wp plugin install antispam-bee compressx fluent-smtp kadence-blocks simple-cloudflare-turnstile --activate
wp theme install kadence --activate
```

### Admin Stack

```bash
wp plugin install admin-bar-dashboard-control hide-admin-notices manage-notification-emails plugin-toggle user-switching --activate
```

### Performance Stack

```bash
wp plugin install flying-analytics flying-pages flying-scripts freesoul-deactivate-plugins index-wp-mysql-for-speed performant-translations --activate
```

### SEO Stack

```bash
wp plugin install seo-by-rank-math burst-statistics syndication-links webmention --activate
```

### Forms & CRM Stack

```bash
wp plugin install fluentform fluent-crm fluent-smtp fluent-support --activate
```

### WooCommerce Stack

```bash
wp plugin install woocommerce kadence-woocommerce-email-designer pymntpl-paypal-woocommerce woo-stripe-payment --activate
```

### Debug Stack

```bash
wp plugin install query-monitor debug-log-manager string-locator wp-crontrol user-switching --activate
```

## Pro Plugin Vendor URLs

For premium plugins, use these vendor sites for purchase and license management:

| Ecosystem | Vendor URL |
|-----------|------------|
| Kadence | https://www.kadencewp.com/ |
| Fluent/WPManageNinja | https://wpmanageninja.com/ |
| Rank Math | https://rankmath.com/ |
| Meow Apps | https://meowapps.com/ |
| Really Simple | https://really-simple-ssl.com/ |
| Complianz | https://complianz.io/ |
| Tutor LMS | https://www.themeum.com/ |
| Admin Columns | https://www.admincolumns.com/ |
| Code Snippets | https://codesnippets.pro/ |
| Delicious Brains | https://deliciousbrains.com/ |

## Related Documentation

| Topic | File |
|-------|------|
| WordPress development | `workflows/wp-dev.md` |
| WordPress admin | `workflows/wp-admin.md` |
| LocalWP database access | `localwp.md` |
| MainWP fleet management | `mainwp.md` |
| API key management | `api-key-setup.md` |
