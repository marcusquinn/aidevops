<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Report Templates

Premium report templates for evidence-led outputs. `llm-visibility-report.css` implements the Editorial Evidence Report profile from `.agents/tools/design/library/styles/editorial-evidence-report/DESIGN.md`.

## Minimal semantic structure

```html
<body class="report-body">
  <div class="report-shell">
    <main id="report" class="report-main">
      <header class="report-cover" aria-labelledby="report-title">
        <p class="report-kicker">LLM Visibility Report</p>
        <h1 id="report-title" class="report-title">Evidence-led visibility audit</h1>
        <p class="report-subtitle">Prepared summary of findings, risks, and recommended actions.</p>
        <dl class="report-meta-grid" aria-label="Report metadata">
          <div class="meta-item"><dt class="meta-label">Prepared for</dt><dd class="meta-value">Client name</dd></div>
          <div class="meta-item"><dt class="meta-label">Prepared by</dt><dd class="meta-value">Team name</dd></div>
          <div class="meta-item"><dt class="meta-label">Date</dt><dd class="meta-value">2026-05-23</dd></div>
          <div class="meta-item"><dt class="meta-label">Version</dt><dd class="meta-value">v1</dd></div>
        </dl>
      </header>

      <section id="findings" class="chapter-hero" aria-labelledby="findings-title">
        <p class="eyebrow">Chapter 1</p>
        <h2 id="findings-title" class="chapter-title">Findings that change priorities</h2>
        <p class="chapter-summary">Short outcome-focused summary with evidence badges.</p>
        <div class="badge-row" aria-label="Evidence strength">
          <span class="badge badge--strong">Strong</span>
          <span class="badge badge--hygiene">Hygiene</span>
        </div>
      </section>

      <article class="tactic-card" aria-labelledby="tactic-title">
        <h3 id="tactic-title">Add source-backed answer blocks</h3>
        <div class="tactic-grid">
          <section><h4>What</h4><p>Describe the recommended change.</p></section>
          <section><h4>Why</h4><p>Connect the change to the observed evidence.</p></section>
          <section><h4>How</h4><p>List implementation steps and owners.</p></section>
        </div>
      </article>
    </main>

    <nav class="sticky-toc" aria-label="Report contents">
      <h2>Contents</h2>
      <ol>
        <li><a href="#findings" aria-current="true">Findings</a></li>
      </ol>
    </nav>
  </div>
</body>
```

## Accessibility notes

- Use semantic landmarks: one `main`, a labelled `nav`, section headings in order, and tables only for tabular facts.
- Do not rely on colour alone; badges and status dots need readable text labels or adjacent status copy.
- Keep sticky navigation optional. The CSS disables sticky behaviour on small screens and print.
- Ensure all source cards and evidence badges have meaningful labels, observed dates, sensitivity states, and citation targets.
- Preserve visible focus states and readable link text; print CSS exposes link URLs for non-navigation links.
