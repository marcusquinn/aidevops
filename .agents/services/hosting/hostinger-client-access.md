<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Hostinger Client Access (Account Sharing)

Use this to manage or develop a site on a client's own Hostinger account without
their password. Keep client emails, account and order IDs, hostnames and usernames
out of public issues, PRs and docs.

## How access works

- hPanel **Profile → Account sharing** has two tabs. **Request access** sends a
  request to the client's account email. **Give access** grants someone access to
  your own account. Roles: **Admin** (manage services and buy with the stored
  payment method) or **Collaborator** (manage services, no purchases). Hostinger's
  page: <https://docs.hostinger.com/agency-hosting/access-sharing.md>.
- The list shows each shared account with its access type, services and status.
  **N service(s)** opens "Services shared by …" with the shared plans. **Manage
  services** switches hPanel into that client's account. An **Exit** button in the
  top bar returns to your own account; billing calls answer 403 in that mode.
- **No API.** The public API (OpenAPI spec at
  `https://developers.hostinger.com/openapi/openapi.json`) has no endpoint to
  request, grant, list or revoke shared access. Do it in hPanel.
- **The agency token manages the shared plan's hosting account.** Observed
  2026-11-09 with Collaborator access, once the plan has a website:
  - Works: `GET /api/hosting/v1/orders` (shared order listed),
    `GET /api/hosting/v1/websites?order_id=<it>` (domain, hosting username, root
    directory), and account-scoped calls under
    `/api/hosting/v1/accounts/<username>/…` such as `php/details`,
    `cache/status` and `cron-jobs`. A no-op write,
    `PATCH …/websites/<domain>/php/version` with the current version, returned
    `Request accepted` (no authorisation error); the site stayed on that
    version.
  - Does not work: `GET /api/hosting/v1/datacenters?order_id=<it>` returns
    `[Hosting:9999] Not found.` before and after setup, and
    `GET /api/billing/v1/subscriptions` lists only the agency's own
    subscriptions.
  - Before setup, the websites list is empty, so there is no username for
    account-scoped calls.

  Prefer the API for hosting settings (PHP, cache, cron, SSL, databases, Git
  deploy), SSH for site work, and hPanel for what the API lacks (sharing, SSH
  access and keys). Creating a site on a shared plan through the API
  (`POST /api/hosting/v1/websites`) is untested; the hPanel path below works.
  With Collaborator access these change the client's live hosting; treat them
  like any production change. A token the client creates
  carries their whole account's permissions; use one only when needed, with an
  expiry, stored as a secret.

## Drive hPanel without taking over the screen

The user's everyday browser holds the hPanel login. With OpenCode browse paired
(`aidevops opencode-browse pair --list`), work in a background tab group:

```bash
aidevops opencode-browse run -- session new hpanel --allow-origin hpanel.hostinger.com --allow-origin '*.hostinger.com'
aidevops opencode-browse run -- execute --session hpanel 'await page.goto("https://hpanel.hostinger.com/profile/account-access/account-sharing"); return await snapshot()'
```

Observed behaviour (browse 0.0.15, Brave):

- `page.goto` on hPanel often fails with "Target page, context or browser has
  been closed" because the debugger is re-attached. The navigation still happens;
  read the page in the next `execute` and do not navigate again.
- A `--read-only` session cannot open a tab, so it cannot start a flow.
- After browse updates itself, commands report a relay/CLI build mismatch; run
  `aidevops opencode-browse run -- relay restart`, then continue. Snapshot refs
  reset, so select by role and name.
- Turn console capture off (`await pageConsole.stop()`); hPanel logs many blocked
  tracker requests.
- Clicks on hPanel list rows and side-menu links can be blocked by overlays
  (`h-list-item__title`, `side-menu__container`). For rows, click
  `.h-list-item__row` or the row's heading filtered by text. For menu links, read
  the link's `href` and `page.goto` it.
- "The browser isn't responding" (`browser-unresponsive`) after a long flow
  usually clears on a retry a few seconds later.
- Delete the session when done (`session delete hpanel`).

Without browse, use `chromium-debug-use-helper.sh launch <url>` (dedicated profile,
one manual login); see `tools/browser/browser-automation.md`.

## Set up access to a client plan

1. **Account sharing → Manage services** for the client.
2. **Websites.** A plan showing **Setup** has no hosting account yet, so it has no
   SSH. Setup ("Create a new site", "Migrate an existing site" or "I hired someone
   to build my site") creates the first website and fixes the plan's datacenter.
   That is the owner's decision; ask before starting it. A temporary
   `*.hostingersite.com` domain is enough to get SSH before a migration. Empty
   site, no purchase prompt (observed 2026-11-09): **Create a new site → Upload
   your PHP or HTML → Use temporary domain → Start empty →** pick the datacenter
   **→ Next**. The build starts straight away and opens the website dashboard
   within about a minute. hPanel pre-selects the datacenter by latency from the
   operator's location, not the visitors'; choose by where the visitors are (US
   West: United States, Arizona).
3. **SSH.** On the plan's website, open **Advanced → SSH Access**, press
   **Enable**, then **Add SSH key** with a name per person or agency (for example
   `<agency>-<person>`) and the contents of the `.pub` file only. Read the port,
   username and IP from the `ssh -p <port> <user>@<ip>` line under **Log in to
   SSH**. Never handle the private key or a password in the browser.
4. **Store the details** (account-level, named by client alias; host, port and user
   are not secret but are kept with the rest). For place-based clients, build
   `<CLIENT>` as `<PLACE>_<REGION>_<COUNTRY>`: upper case, underscores, ISO 3166
   region and country codes, so places with the same name stay distinct (for
   example `PORTLAND_OR_US` and `PORTLAND_ME_US`). Use the lower-case,
   hyphenated form for the SSH alias: `hostinger-portland-or-us`.

   The agent stores these itself, since it read them from hPanel and they are not
   secret (`secret set` reads piped stdin):

   ```bash
   printf '%s' '<ip>'   | aidevops secret set HOSTINGER_<CLIENT>_SSH_HOST
   printf '%s' '<port>' | aidevops secret set HOSTINGER_<CLIENT>_SSH_PORT
   printf '%s' '<user>' | aidevops secret set HOSTINGER_<CLIENT>_SSH_USER
   aidevops secret check HOSTINGER_<CLIENT>_SSH_HOST   # exit status only
   ```

   Real secrets (an SSH password, only when key auth is impossible; client-made
   tokens) are entered by the user at the hidden prompt:
   `aidevops secret set HOSTINGER_<CLIENT>_SSH_PASSWORD`.

   Per WordPress site, once it exists, a dedicated user with an Application
   Password: `<CLIENT>_<SITE>_WP_USER` and `<CLIENT>_<SITE>_WP_APP_PASSWORD`
   (`tools/wordpress/fluent-mcp.md`). Optional: `HOSTINGER_<CLIENT>_API_TOKEN`
   (client-created) and `CLOUDFLARE_<CLIENT>_API_TOKEN` (limited to the client's
   zone). No database secrets: WP-CLI over SSH reads `wp-config.php`.
5. **SSH alias and verify.** Add a `Host hostinger-<place>-<region>-<country>`
   block (`HostName`, `Port`, `User`, `IdentityFile`, `IdentitiesOnly yes`) to
   `~/.ssh/config.d/hostinger-clients`. The agent cannot read `~/.ssh/config`
   (`secret-read-guard`), so it checks with `ssh -G <alias>`. If the alias does
   not resolve, back up the config with `cp -p`, then prepend only
   `Include ~/.ssh/config.d/hostinger-clients`; a line placed after a `Host`
   block would be scoped to that block. Then run
   `ssh -o BatchMode=yes <alias> 'whoami; ls ~/domains; command -v wp'`. One SSH
   login covers every site on that hosting account; each site lives in
   `~/domains/<domain>/public_html`.
6. **Exit** the client's account in hPanel and delete the browse session.
