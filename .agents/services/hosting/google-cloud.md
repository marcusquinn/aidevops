---
description: Google Cloud project operations - gcloud access options, automatable steps, console-only OAuth consent and verification
mode: subagent
tools:
  read: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Google Cloud Operations

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Preferred access**: a named `gcloud` configuration + `gcloud auth login` as the user. Revocable, no key file, leaves the default configuration alone.
- **Unattended automation only**: service-account key, least-privilege roles, stored with `aidevops secret set`.
- **API keys cannot manage anything.** They identify a project for public APIs; they carry no identity or IAM permission.
- **Console-only**: OAuth consent screen (Google Auth Platform), OAuth clients, scopes, verification submission. Hand the user exact steps; do not try APIs.
- **Secrets**: OAuth client ID/secret via `aidevops secret set`; inject with `aidevops secret NAME -- <cmd>`. Never paste values into chat.

<!-- AI-CONTEXT-END -->

## Access options (in order of preference)

### 1. Named gcloud configuration with user login

Many machines are already signed in to `gcloud` as a service account used by other tooling. Running `gcloud auth login` in the default configuration switches the active account and breaks that tooling. Use a named configuration instead:

```bash
gcloud config configurations list
gcloud config configurations create aidevops-<purpose>   # creates and activates
gcloud auth login                                        # user completes browser flow
gcloud config set project <project-id>
# Switch back when finished
gcloud config configurations activate default
```

Per-command alternative that never changes the active configuration: `gcloud --configuration=aidevops-<purpose> <command>`. Revoke with `gcloud auth revoke <account>`.

User credentials can create projects even when the Google account has no organization.

### 2. Service-account key (unattended automation only)

- Grant least-privilege roles for the specific task; never Owner by default.
- Store with `aidevops secret set NAME --from-file <path>`, then delete the plaintext file. Never commit or echo it.
- A service account cannot create projects when the account has no organization.
- Prefer impersonation or short-lived credentials over long-lived keys where possible.

### 3. API keys

An API key does not authenticate a principal, so it cannot create projects, change IAM, or manage OAuth. If a user asks for "an API key so the agent can manage everything", explain this and offer option 1 or 2.

## Automatable with gcloud

```bash
gcloud projects create <project-id> --name="<Display Name>"
gcloud projects update <project-id> --name="<New Name>"
gcloud services enable <api>.googleapis.com --project=<project-id>
gcloud projects add-iam-policy-binding <project-id> --member="user:<email>" --role="<role>"
```

gcloud prints a warning for projects without an `environment` tag; it is informational. Confirm project ID and billing impact with the user before creating projects or enabling paid APIs. Verify flags with `gcloud <command> --help` on the installed SDK.

## Console-only steps (give these to the user)

The only CLI/API for OAuth consent screens and clients (`gcloud iap oauth-brands`, IAP OAuth Admin API) is deprecated: the CLI warns it was discontinued for new projects on Jan 19, 2026 and shut down on March 19, 2026 (re-verify from the CLI warning), and it only ever created internal brands. Use Google Auth Platform in the Cloud Console, in this project:

1. **Branding**: app name, user support email, homepage, privacy policy link, authorized domains, developer contact email. Optional logo (120x120); adding a logo requires verification.
2. **Audience**: choose External (or Internal for Workspace-only). Set Testing vs In production; add test users while in Testing.
3. **Data access**: add the scopes the app requests (classify each as non-sensitive, sensitive or restricted).
4. **Clients**: Create client, type Web application; add exact authorized redirect URIs (and JavaScript origins if needed). Copy the client ID and secret into `aidevops secret set` (user types it in their terminal, not in chat).
5. **Verification**: Verification Center, submit for review when moving to In production with sensitive/restricted scopes.

## Testing-mode caveats

- Refresh tokens for External apps in Testing expire after 7 days.
- Unverified apps show a warning screen and are capped at 100 test users.
- Moving to In production without verification keeps the warning screen and user cap for sensitive scopes.

## Verification checklist for sensitive scopes

- Homepage on an authorized domain that describes the app and links to the privacy policy.
- Privacy policy on the same domain disclosing Google user data use, including Limited Use wording for Google API Services User Data Policy.
- Domain ownership verified in Search Console by an owner of the Cloud project.
- Scope justifications written per scope; request the minimum.
- Demo video (unlisted YouTube) showing the full OAuth consent flow, with the client ID visible in the URL, and each scope's use in the app.
- Expect days to weeks of review (longer for restricted scopes); respond to reviewer email promptly.

## Secrets

```bash
aidevops secret set GOOGLE_OAUTH_CLIENT_ID
aidevops secret set GOOGLE_OAUTH_CLIENT_SECRET
aidevops secret GOOGLE_OAUTH_CLIENT_SECRET -- <command>   # value never enters agent context
```

See `reference/secret-handling.md`.

## Related

- `services/analytics/google-analytics.md` - GA4 MCP with application-default credentials
- `seo/google-search-console.md` - Search Console API and domain verification
- `reference/secret-handling.md` - secret storage and injection
