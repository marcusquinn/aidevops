---
description: WordPress change plans - reviewed field-level changes to posts and terms with dry run, backup, read-back and restore
mode: subagent
temperature: 0.2
tools:
  write: true
  edit: true
  bash: true
  read: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# WordPress Change Plans

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `scripts/wp-change-plan.php`, a WP-CLI `eval-file` script. Needs no plugin.
- **Command**: `wp-helper.sh --change-plan <site> PLAN.json [apply | restore BACKUP.json] [--user=<id>]`
- **Modes**: dry run (default), `apply`, `restore BACKUP.json`.
- **Exit codes**: `0` done; `1` something was skipped, stopped or left; `2` usage, plan or permission error.
- **Backups**: `~/backups/wp-change-plan/before-<UTC>-<pid>.json` on the site (mode 600, outside the web root; override with `WP_CHANGE_PLAN_BACKUP_DIR`).
- **Local copies**: `~/.aidevops/.agent-workspace/work/wp-change-plan/<site>-<UTC>-<pid>/` (`run.log` plus the backup).

Use it for reviewed changes on live sites: titles, slugs, statuses, excerpts, SEO meta, ACF/SCF fields, terms, featured images, alt text, term names and descriptions, and term deletions. For URL rewrites use `wp search-replace --dry-run`. For whole-site rollback use a database backup.

```bash
wp-helper.sh --change-plan client-site plan.json                    # dry run: review every line
wp-helper.sh --change-plan client-site plan.json apply --user=2     # back up, write, read back
wp-helper.sh --change-plan client-site plan.json restore BACKUP.json --user=2   # BACKUP.json: path printed by apply
```

Without `wp-helper.sh`, run the script from the WordPress root: `wp eval-file wp-change-plan.php PLAN.json [apply | restore BACKUP.json] --user=<id>`.

<!-- AI-CONTEXT-END -->

## Plan Format

Every change is a pair `[now, new]`: `now` is the value you reviewed on the site, `new` is the value to write.

```json
{
  "posts": [{
    "id": 123, "note": "why (printed)",
    "post":      {"post_title": ["Old", "New"], "post_name": ["old", "new"], "post_status": ["draft", "publish"], "post_excerpt": ["", "Short summary"]},
    "meta":      {"rank_math_focus_keyword": ["", "new phrase"]},
    "acf":       {"close_date": ["", "20261016"], "regions": [["884"], ["1070", "890"]]},
    "terms":     {"category": [["news"], ["news", "guides"]]},
    "thumbnail": [0, 456],
    "alt":       {"456": ["", "Example logo"]}
  }],
  "terms": [{
    "taxonomy": "category", "id": 12, "note": "why",
    "term": {"name": ["How-tos", "Guides"], "description": ["", "<p>Intro</p>"]},
    "meta": {"rank_math_title": ["", "Guides and how-tos"]}
  }],
  "delete_terms": [{"taxonomy": "region", "id": 34, "slug": "old-region"}]
}
```

| Entry | Values |
|-------|--------|
| `post` | `post_title`, `post_name`, `post_status`, `post_excerpt`, `post_content`, `post_date` (`YYYY-MM-DD HH:MM:SS`, site time), `post_parent`, `menu_order`, `comment_status`, `ping_status`, `post_author` |
| `meta` | Single-value post meta. An absent key reads as `""`. |
| `acf` | ACF/SCF top-level fields as stored, e.g. taxonomy fields as term ids. Repeater, flexible content, group and clone fields are refused. |
| `terms` | The post's complete term slugs in that taxonomy, before and after. Order does not matter. Terms must exist; the script does not create them. |
| `thumbnail` | Attachment ids; `0` means none. |
| `alt` | Attachment id to alt text. |
| `term` | `name`, `slug`, `description`, `parent`. |
| `delete_terms` | `taxonomy`, `id` and the `slug` you reviewed. |

## Rules

1. **Dry run.** Every target is read, and each change prints as `unchanged`, `will change` (with the stored form when WordPress saves it differently) or `differs` (with the site's value). A target with a differing `now`, an unknown key or field, or a refused value is skipped as a whole. The dry run exits 1 if anything would be skipped.
2. **User.** `apply` and `restore` need `--user` with `unfiltered_html` and edit rights on each target. Otherwise KSES rewrites markup and the read-back fails. Run the dry run with the same `--user` so the stored forms match.
3. **Backup first.** Before the first write, apply saves one JSON backup: the plan, and for each target its row, all its meta and its terms in every touched taxonomy, each image's alt text, and each term's row and meta. The backup also records, per target, the old value and the value written, so restore works after a stopped run.
4. **Core APIs.** Writes go through core APIs so save hooks run. For each post: `update_field()`, then `wp_set_object_terms()`, `update_post_meta()`, `set_post_thumbnail()` and `_wp_attachment_image_alt`, then one `wp_update_post()`. Terms use `wp_update_term()` and `wp_delete_term()`.
5. **Read-back.** After each target, every value in it is read back and compared with the stored form. The first difference stops the run, leaves later targets untouched and prints the restore command.
6. **Restore.** `restore BACKUP.json` decides every value against the site first, then puts back each value that still holds what apply wrote: post status first, ACF fields before terms. Values changed since are reported and left. An absent value is deleted again. A restored draft also gets its original dates back.
7. **Deletions.** `delete_terms` must be a plan of its own. A deletion is refused while any post of any status, child term, nav menu item or ACF/SCF field value (post, term, user meta or options) uses the term. Restore recreates the term with its meta, but with a new id because WordPress does not reuse term ids; it prints the new id.
8. **Hidden meta.** Keys starting with `_` are refused. The featured image and alt text have their own entries.
9. **Follow-ups.** The script prints what it does not do: purge page caches, recount touched taxonomies where counts are deferred (`wp term recount <taxonomy>`), and check the sitemaps.

## Transport (`wp-helper.sh --change-plan`)

- **Files**: `wp-change-plan.php` loads `wp-change-plan-values.php` and `wp-change-plan-term-usage.php` from its own directory; keep the three together.
- **LocalWP**: runs the script in place from the site's `path`.
- **SSH sites** (Hostinger, Hetzner, Cloudways, Cloudron): uses the site's SSH settings as `run_wp_command` resolves them (`server_ref`, `~/.ssh/config`, identity file, `ssh_password_env`, password file, port). The three scripts and the plan go to a private `mktemp -d` directory, `wp eval-file` runs from `wp_path`, the run output and backup are downloaded, and the uploaded copies are deleted. Removal is checked.
- **Restore** takes a local backup copy (uploaded for the run) or the backup path on the site.
- Password auth: `aidevops secret HOSTINGER_SSH_PASSWORD -- wp-helper.sh --change-plan ...`.

## Verifying planner changes

Run the offline transport regression (no network, PHP or WordPress required):

```bash
bash .agents/scripts/tests/test-wp-helper-change-plan-ssh.sh
```

It reads `WPCP_PHP_FILES` from the transport helper and checks every upload,
planner execution, and remote cleanup on success, planner failure and upload
failure. SSH/SCP stubs are executable (755). This is CI-safe, but not added to
`path-portability.yml`: that workflow explicitly enumerates runtime/PATH tests,
not WordPress transport tests. Run this check when changing the planner transport.

For behavioral comparisons, use `wp-change-plan-differential-helper.sh` **only on
an isolated, disposable, single-site LocalWP installation**. It refuses all CI
environments with a CI marker and requires both `--fixture` and a selected site
with `"type": "localwp"` and `"verification_fixture": true` in
`~/.config/aidevops/wordpress-sites.json`. Never mark a live/client site as a
fixture. Use an administrator with `unfiltered_html`.

```bash
# From Local's site shell (a working wp must already be on PATH):
bash .agents/scripts/wp-change-plan-differential-helper.sh create planner-fixture --fixture --user 1
# Copy the printed ARTIFACTS directory into the following commands:
bash .agents/scripts/wp-change-plan-differential-helper.sh compare planner-fixture ARTIFACTS --fixture --user 1 --base origin/main
bash .agents/scripts/wp-change-plan-differential-helper.sh cleanup planner-fixture ARTIFACTS --fixture --user 1
```

Outside Local's site shell, pass **all four** runtime flags to each command:
`--php PATH --php-ini PATH --wp-cli PATH --mysql-bin DIRECTORY`. Use Local's PHP
executable, the site's generated `run/<id>/conf/php/php.ini`, bundled
`wp-cli.phar`, and MySQL client `bin` directory. See `localwp.md` for locations;
paths are machine-specific and may contain spaces (quote them). Do not dump
Local's credential-bearing registry to discover them; project only its paths.

`create` makes a unique draft post, two assignment terms and an unused deletion
term. `compare` copies the base-ref planner PHP siblings and working-tree PHP
siblings into separate directories, then runs dry run → apply → restore for an
update plan and a separate term-deletion plan with each version. It regenerates
term IDs from slugs before each round. It normalises backup/planner paths and
recreated term identity labels, then diffs the logs. It also compares fixture
post fields, tested meta, assignments, term values and term meta against the
starting snapshot after **each** restored plan. WordPress-generated modification
timestamps and recreated term IDs are intentionally excluded from snapshots.
This is a focused regression fixture, not an exhaustive planner test suite or a
whole-database rollback check; plugin hooks can have other effects, hence the
disposable-site requirement.

For a single version, use `round SITE ARTIFACTS PLANNER_DIR --fixture --user ID`.
All artifacts remain under `${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}`
in a private directory, including on failure. A failed apply still attempts
restore from its emitted backup, and a non-restored snapshot stops subsequent
rounds. For interruption or missing backup, inspect the retained logs/backup and
restore the fixture before retrying; do not run cleanup blindly. `cleanup`
requires a matching starting snapshot before deleting only the created fixture;
it retains the evidence directory. Exit zero from `compare` means no output
differences **and** restored fixture values. No live site is used for verification.

## Traps Met on Production Sites

- **`wp db export` can lie.** It exits 0 but writes no file where PHP `proc_open()` is disabled, which is common on shared hosting. That is why backups come from PHP as JSON.
- **Publishing gives today's date.** Publishing a draft through `wp_update_post()` sets the current date unless the plan sets `post_date`. The dry run adds a note.
- **"Save Terms" replaces terms.** An ACF/SCF taxonomy field with "Save Terms" replaces all the post's terms in that taxonomy when saved. A plan that changes such a field must also list that taxonomy's complete terms, which are written after the fields. The dry run refuses a missing `terms` entry.
- **Slugs can change on save.** Plugins with slug patterns, and `wp_unique_post_slug()` (`-2` suffixes), can change a slug on save. The slug read-back catches this and stops the run.
- **Term names and descriptions are filtered.** Term names always pass through `sanitize_text_field` and `_wp_specialchars` (`&` becomes `&amp;`). Descriptions pass KSES with a small tag list, even for administrators, so `<p>` is stripped. The dry run prints the stored form, and the read-back compares with it.

## Related

- `wp-admin.md`: site configuration and `wp-helper.sh`
- `wp-cli-reference.md`: Backup & Restore
- `scf.md`: ACF/SCF field storage
- `localwp.md`: local test sites
