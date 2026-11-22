# t18784: hostinger.md: ImageMagick escalation outcome, CloudLinux changelog check, install dates, maintained OpenSSL 1.1.1w, WPVulnerability hidden = unchecked

## Origin

- Issue: GH#35914 (interactive session, follow-up to the owner's October 2026 Hostinger ImageMagick escalation)

## What

Update the "Read-only audit notes" in `.agents/services/hosting/hostinger.md` with the outcome of the October 2026 ImageMagick escalation, plus three checks that would have answered open questions sooner:

1. **Shared image library**: chat support said the shared ImageMagick could not be updated on a Cloud plan. After a written security escalation listing the advisories, Hostinger installed CloudLinux's `alt-ImageMagick` 7.1.2-34.1 nine days later, while CloudLinux still listed that build as beta. CloudLinux's package changelog API shows which builds exist and their release channel.
2. **Package build dates without `rpm`**: `stat -c '%n built %y installed %z'` shows the build time, which rpm keeps as the modification time, and roughly when the host installed the file (its change time). The guide shows only the build date today.
3. **Libraries linked into PHP**:
   - OpenSSL 1.1.1w is CloudLinux's maintained `alt-openssl11` build, and its changelog lists backported CVE fixes. Check that changelog before treating 1.1.1w as unpatched.
   - Hiding a component in WPVulnerability's settings also stops it being checked, so its stored count stays at its value when hidden.

## Why

Evidence from one Hostinger Cloud account (CloudLinux 8, kernel `4.18.0-553.121.1.lve.el8`), 2026-10-29 03:51 UTC:

- **ImageMagick:** `Imagick::getVersion()` on PHP 7.4–8.5 prints ImageMagick 7.1.2-34 (`RELEASE_DATE` 2026-10-15). It printed 7.1.2-31 on 2026-10-18. The escalation was sent on 2026-10-16.
- **Install dates:** the change time of `policy.xml` and `delegates.xml` is 2026-10-25 18:54 UTC, and of `imagick.so` 18:57. The `lsphp` builds with PHP 8.3.36 and 8.5.12 were installed at 18:57 too, and every running `lsphp` worker used them.
- **Unchanged:**
  - Ghostscript 9.27: `/usr/bin/gs` built 2026-10-06, installed 2026-10-13.
  - OpenSSL 1.1.1w (`/opt/alt/openssl11`): built 2026-10-06, installed 2026-10-13.
  - `policy.xml`: still holds only `<policy domain="Undefined" rights="none"/>`.
- **Rebuilt at the same version:** libxml2 2.10.2 (`/opt/alt/libxml2`, built 2026-10-20, installed 2026-10-22) and curl 8.22.0 (`/opt/alt/curlssl11`, installed 2026-10-22).
- **CloudLinux changelog** (`https://changelog.cloudlinux.com/api/packages/alt-ImageMagick`, JSON, with fields `version`, `channels`, `released_at`, `is_security`, `changelog` and `os`):
  - `alt-ImageMagick`: 7.1.2-34.1 is `beta`, released 2026-10-15.
  - `alt-openssl11`: 1.1.1w-3.4 is `is_security=true`, fixing CVE-2026-45447 (2026-06-12), and 1.1.1w-3.5 is `stable` (2026-07-24).
  - `alt-libxml2`: the latest listed build is 2.10.2-5 (2025-01-30), although the host's copy was built 2026-10-20.
  - `alt-curlssl11`: 8.22.0-3 is `stable` (2026-10-12).
- **WPVulnerability 5.1.6:**
  - `wpvulnerability_get_vulnerabilities_clean()` returns before detection when `wpvulnerability_analyze_filter()` reports a component hidden, by the analysis settings or a `WPVULNERABILITY_HIDE_*` constant (`wpvulnerability-software.php:265-273`).
  - On two sites, hidden ImageMagick and curl data stayed valid only until 2026-10-18 22:46 UTC, while WordPress, plugin, theme and PHP data refreshed twice a day.
  - The stored ImageMagick count stayed at 35 after the host moved to 7.1.2-34.

## How

Edit the "Shared image library", "Package build dates without `rpm`", "Libraries linked into PHP" and "Site PHP builds" bullets. Keep observed values dated, and keep private site names out.

### Files Scope

- `.agents/services/hosting/hostinger.md`

## Acceptance

- The guide records:
  - the escalation outcome;
  - the CloudLinux changelog check;
  - install dates from the change time;
  - that CloudLinux maintains the OpenSSL 1.1.1w build;
  - that WPVulnerability does not check hidden components.
- `markdownlint` with the repository's `.markdownlint.json` is clean for the file.
