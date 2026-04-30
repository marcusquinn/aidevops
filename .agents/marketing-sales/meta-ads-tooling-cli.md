<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Meta Ads CLI — Execution Layer

The official `meta ads` CLI (announced 2026-04-29) wraps the Meta Marketing API in predictable commands designed for AI agents and CI/CD. It turns the strategies in the rest of this agent into actual campaigns, ad sets, ads, creatives, catalogs, products, and pixels.

**Source of truth:** [Introducing Ads CLI](https://developers.facebook.com/blog/post/2026/04/29/introducing-ads-cli/) (Meta Developers blog, John Holstein et al.). API surface: [Meta Marketing API docs](https://developers.facebook.com/docs/marketing-apis).

## When to Use

- Programmatic campaign create/update/launch from a script or agent.
- Insights pulls into JSON for downstream analysis (jq, BI, dashboards).
- Catalog/product sync from a CSV/CRM source.
- Pixel + dataset wiring during onboarding.
- CI/CD: nightly insights snapshots, weekly creative refresh, automated kill rules.

**Use the Ads Manager UI for:** first-time exploration, advantage+ campaign auditioning, asset uploads from desktop, anything where a human is reviewing before launch.

## Install

```bash
# Requires Python 3.12+. Pick one:
uv tool install meta-ads-cli      # uv (recommended, isolated)
pipx install meta-ads-cli         # pipx (isolated)
pip install meta-ads-cli          # pip (global; only if no other Python projects on path)

meta ads --version                # verify
meta ads --help                   # top-level help
meta ads campaign --help          # subcommand help
```

Confirm exact package name on the Meta developer documentation page before installing — package name conventions evolve. If the announcement-time package differs, `meta ads --version` is still the truth-test.

## Authentication

All credentials via environment variables — never inline, never in command history, never committed.

```bash
# Required for any call
export META_ACCESS_TOKEN="…"         # long-lived system user token preferred
export META_AD_ACCOUNT_ID="act_…"    # default ad account; overridable per-command

# Optional but common
export META_APP_ID="…"
export META_APP_SECRET="…"
export META_BUSINESS_ID="…"

# Verify
meta ads ad-account list
```

**Transcript exposure rule:** if you must run a one-off with a different token, source it from a file or pipe from a secret manager — never paste the token into the chat or shell:

```bash
# Good
META_ACCESS_TOKEN=$(aidevops secret get meta-ads-staging) meta ads campaign list

# Bad (token ends up in shell history AND your chat transcript)
META_ACCESS_TOKEN="EAAB..." meta ads campaign list
```

For the aidevops framework: store via `aidevops secret set meta-ads-<env>` (gopass-backed), retrieve via `aidevops secret get meta-ads-<env>`. Plaintext fallback: `~/.config/aidevops/credentials.sh` (chmod 600). See `tools/credentials/gopass.md`.

## Output Formats

Three formats, pick by consumer:

| Format | Flag | Use for |
|--------|------|---------|
| `table` | default | Interactive shell, human review |
| `json`  | `--format json` | Pipe to `jq`, store in S3, feed downstream tools |
| `plain` | `--format plain` | Tab-separated; pipe to `awk`/`cut`/`sort` in shell scripts |

```bash
# Top 5 campaigns by spend, last 7 days
meta ads insights get --date-preset last_7d --level campaign --format json \
  | jq -r '.[] | [.campaign_name, .spend] | @tsv' \
  | sort -k2 -nr | head -5

# Plain-text grep over campaign names
meta ads campaign list --format plain | awk -F'\t' '$2 ~ /Summer/ {print $1}'
```

## Common Workflows

### Launch an ABO test (see `meta-ads-campaigns-testing-abo.md`)

```bash
# 1. Campaign — paused by default until you flip status
meta ads campaign create \
  --name "ABO Test — UGC angles — 2026-W19" \
  --objective OUTCOME_SALES \
  --daily-budget 5000          # cents in account currency

# Capture the campaign id from output, e.g. 23856...
CAMPAIGN_ID=...

# 2. Ad sets — one per creative angle, ABO budget per set
for angle in "founder-story" "testimonial" "product-demo"; do
  meta ads adset create "$CAMPAIGN_ID" \
    --name "ABO — $angle" \
    --optimization-goal OFFSITE_CONVERSIONS \
    --billing-event IMPRESSIONS \
    --daily-budget 2000 \
    --targeting-countries US
done

# 3. Creatives + ads, then go live (only after review)
meta ads creative create --name "Hero — founder" --page-id "$META_PAGE_ID" \
  --image ./creatives/founder-hero.jpg --body "…" --title "…" \
  --link-url https://example.com/lp --call-to-action SHOP_NOW

meta ads ad create ADSET_ID --name "Founder hero" --creative-id CREATIVE_ID

# 4. Activate (separate step on purpose — review first)
meta ads campaign update "$CAMPAIGN_ID" --status ACTIVE
```

### Pull insights for a weekly review (see `meta-ads-optimization-metrics.md`, `meta-ads-checklists-weekly-review.md`)

```bash
# Account-level top line
meta ads insights get --date-preset last_7d --format json \
  --fields spend,impressions,clicks,ctr,cpc,actions,action_values,roas

# Campaign-level breakdown
meta ads insights get --level campaign --date-preset last_7d --format json \
  --fields campaign_name,spend,impressions,ctr,cpa,roas

# Hook/hold rate per ad (video) — feeds creative scoring
meta ads insights get --level ad --date-preset last_7d --format json \
  --fields ad_name,video_p25_watched_actions,video_p75_watched_actions,impressions
```

### Catalog and product sync (commerce campaigns)

```bash
meta ads catalog create --name "Main — 2026"
CATALOG_ID=...

meta ads product-item create --catalog-id "$CATALOG_ID" \
  --retailer-id sku-blue-shirt \
  --name "Blue Shirt" \
  --url https://example.com/products/blue-shirt \
  --price "2999" --currency "USD" \
  --image-url https://example.com/img/blue-shirt.jpg

meta ads product-set list --catalog-id "$CATALOG_ID"
```

### Pixel and dataset wiring

```bash
meta ads dataset create --name "Website pixel — 2026"
PIXEL_ID=...

meta ads dataset connect "$PIXEL_ID" \
  --ad-account-id "$META_AD_ACCOUNT_ID" \
  --catalog-id "$CATALOG_ID"
```

CAPI is mandatory in 2026 (see `meta-ads-foundations-attribution.md`); pixel-only loses 30-50% of conversions. The CLI sets up the pixel side; CAPI events still flow from your server (or a partner like Stape/Segment).

## Automation Patterns

```bash
# CI/CD-safe defaults
meta ads … --no-input --force --format json

# Exit codes (use in shell scripts)
#   0 — success
#   3 — auth error (token expired / wrong account)
#   4 — API error (rate limit, validation, server-side)
#   non-zero & not 3/4 — generic CLI/usage error

if ! meta ads campaign list --format json > /tmp/campaigns.json; then
  case $? in
    3) echo "auth"; aidevops secret rotate meta-ads-prod ;;
    4) echo "api"; sleep 30; retry ;;
    *) echo "cli"; exit 1 ;;
  esac
fi
```

## Safety Rules

1. **Resources are PAUSED on create.** Activation is always a separate `--status ACTIVE` call. Never combine create + activate in one command — leave a review step.
2. **Verify spend before going live.** `meta ads campaign get $ID --format json | jq '.daily_budget,.lifetime_budget'` — confirm currency unit (cents vs dollars varies by ad account).
3. **Destructive ops require confirmation.** Before `meta ads campaign delete`, `meta ads ad delete`, or any bulk update on >5 entities: run `verify-operation-helper.sh check --operation "<cmd>"` (framework rule, not CLI rule).
4. **Stay in your ad account.** Always set `META_AD_ACCOUNT_ID` per session; never rely on a default. If you manage multiple accounts (agency model), prefix every command with `--ad-account-id "$ACCOUNT"` explicitly.
5. **Audit trail.** Pipe writes through a logger: `meta ads campaign create … --format json | tee -a ~/.aidevops/logs/meta-ads-writes.jsonl`. Combine with `audit-log-helper.sh log meta-ads "<msg>"` for security ops (creative deletes, dataset disconnects).
6. **No tokens in commit messages or PR bodies.** Reference accounts by id, not by token.

## AI Agent Execution Notes

- **Default to dry/list before write.** When asked to "launch a campaign," first `campaign list` and `insights get` to verify the user isn't duplicating an active one.
- **Surface the exact command.** Print the command you're about to run to the user. They are accountable for the budget; they should approve.
- **Don't activate on first run.** New campaigns stay PAUSED. Tell the user the campaign id and ask them to flip ACTIVE explicitly, or do a `--status ACTIVE` only after they confirm.
- **Read insights as JSON, summarise as table.** Pull `--format json`, do the analysis, present the conclusion in 3-5 bullets — don't dump the full JSON to the user.
- **Cross-link strategy.** When recommending a CLI command, cite the relevant strategy doc (`meta-ads-campaigns-testing-abo.md`, `meta-ads-optimization-metrics.md`, `meta-ads-foundations-attribution.md`) so the user can verify the reasoning.

## References

- Announcement: <https://developers.facebook.com/blog/post/2026/04/29/introducing-ads-cli/>
- API surface: <https://developers.facebook.com/docs/marketing-apis>
- Strategy: `meta-ads.md` (this agent's index)
- Adjacent tools: `ad-creative-ai-tools-reference.md` (creative generation), `meta-ads-creative-production.md` (creative pipeline that feeds `creative create`)
