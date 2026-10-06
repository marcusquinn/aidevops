// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

// Search-engine definitions and in-page detectors for serp-captcha-probe.mjs.
// The organic/detect callbacks run inside the page via page.evaluate().

export const ENGINES = {
  google: {
    home: ({ gl, hl }) => `https://www.google.com/?hl=${encodeURIComponent(hl)}&gl=${encodeURIComponent(gl)}`,
    input: 'textarea[name="q"], input[name="q"]',
    results: '#search, #rso',
    // Organic links may be direct, /url?q=<dest>, or opaque /goto?url=<token>
    // (seen 2026-10-05). For opaque links, fall back to the displayed <cite>
    // (domain + breadcrumb path), which is what a person sees.
    organic: () => [...document.querySelectorAll('#search a h3')]
      .map((h3) => {
        const a = h3.closest('a');
        if (!a?.href) return null;
        const url = new URL(a.href, location.href);
        if (!/(^|\.)google\./.test(url.hostname)) return url.href;
        const q = url.searchParams.get('q') || url.searchParams.get('url');
        if (q && /^https?:\/\//.test(q)) return q;
        const cite = a.closest('.MjjYud, [data-hveid]')?.querySelector('cite') || a.querySelector('cite');
        return cite?.textContent?.split(' · ')[0].trim().replace(/\s*›\s*/g, '/') || null;
      })
      .filter(Boolean),
  },
  bing: {
    home: ({ gl, hl }) => `https://www.bing.com/?cc=${encodeURIComponent(gl)}&setlang=${encodeURIComponent(hl)}`,
    input: 'textarea[name="q"], input[name="q"]',
    results: '#b_results',
    // Bing wraps links as /ck/a?...&u=a1<base64url destination>.
    organic: () => [...document.querySelectorAll('#b_results li.b_algo h2 a')]
      .map((a) => {
        if (!a.href) return null;
        const url = new URL(a.href, location.href);
        const u = url.searchParams.get('u');
        if (!/(^|\.)bing\.com$/.test(url.hostname) || !u?.startsWith('a1')) return url.href;
        try {
          const b64 = u.slice(2).replace(/-/g, '+').replace(/_/g, '/');
          const dest = atob(b64 + '='.repeat((4 - (b64.length % 4)) % 4));
          return /^https?:\/\//.test(dest) ? dest : url.href;
        } catch {
          return url.href;
        }
      })
      .filter(Boolean),
  },
};

// Returns a challenge kind, or null when the page is an ordinary result page.
export async function detectBlock(page) {
  return page.evaluate(() => {
    const text = (document.body?.innerText || '').slice(0, 6000).toLowerCase();
    if (location.pathname.startsWith('/sorry') || document.querySelector('#captcha-form, form[action*="sorry"]')) return 'google_sorry';
    if (document.querySelector('iframe[src*="recaptcha"], iframe[title*="reCAPTCHA"]')) return 'recaptcha';
    if (document.querySelector('iframe[src*="challenges.cloudflare.com"]')) return 'turnstile';
    if (text.includes('unusual traffic from your computer network')) return 'unusual_traffic';
    if (text.includes('verify you are human') || text.includes('solve the challenge')) return 'challenge';
    return null;
  }).catch(() => null);
}

export async function detectConsent(page) {
  if (page.url().includes('consent.')) return true;
  return page.evaluate(() => [...document.querySelectorAll('button, [role="button"]')]
    .some((el) => /^(reject all|accept all|i agree)$/i.test((el.textContent || '').trim()))).catch(() => false);
}

// A zero is not evidence of an empty SERP: first-visit pages may be consent
// interstitials or layouts we cannot parse. Keep this diagnostic out of blocks.
export async function describeZeroResults(page, engine) {
  if (await detectConsent(page)) return 'consent_required';
  return page.evaluate((selector) => {
    const results = document.querySelector(selector);
    if (!results) return 'no_results_container';
    return results.textContent?.trim() ? 'unrecognized_or_empty_results' : 'empty_results_container';
  }, engine.results).catch(() => 'page_inspection_error');
}
