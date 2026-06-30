import { type CSSProperties, type ReactElement, useState } from "react";
import type { GuiPulseWorkerActivityEvent, GuiPulseWorkerChartSeries, GuiStatusData } from "../../gui-shared/src";
import { text } from "./app-model";

type PulseEvent = GuiPulseWorkerActivityEvent;
type PulseFilterGroup = { label: string; values: string[] };

const quickFilters = ["Needs attention", "Stalled workers", "Failed terminal checks", "Expensive runs", "Third-party issues", "No verification"];

export function PulseWorkersSurface({ status }: { status: GuiStatusData }): ReactElement {
  const pulse = status.pulse_workers;
  const [selectedEventId, setSelectedEventId] = useState(pulse.events[0]?.id ?? "");
  const selectedEvent = pulse.events.find((event) => event.id === selectedEventId) ?? pulse.events[0];
  const filterGroups = buildFilterGroups(pulse);
  const chartSeries = pulse.charts.slice(0, 4);
  const sampleSize = pulse.kpis.reduce((total, kpi) => total + (kpi.sample_size ?? 0), 0);

  return (
    <section className="pulse-workers-surface" aria-label={text.workers}>
      <div className="planned-card pulse-hero">
        <p className="eyebrow">Data-driven observability · shared pulse_workers status · read-only</p>
        <h2>{text.workers}</h2>
        <p>{text.workersIntro}</p>
        <section className="pulse-scope-strip" aria-label="Pulse scope and time range">
          <span><strong>Period</strong> {pulse.period_label} · {periodChoices(pulse.selected_period)}</span>
          <span><strong>Repo scope</strong> {pulse.scope_label}</span>
          <span><strong>Issue origin</strong> {filterSummary(pulse.filters.issue_origins)}</span>
          <span><strong>Provider/model scope</strong> {filterSummary(pulse.filters.providers)}</span>
          <span><strong>Comparison</strong> {pulse.comparison_label}</span>
          <span><strong>Sample</strong> {pulse.events.length} canonical events · {sampleSize} samples</span>
          <span><strong>Trust boundary</strong> Metadata/status only; protected payloads excluded</span>
        </section>
      </div>

      <section className="pulse-kpi-grid" aria-label="Pulse health summary">
        {pulse.kpis.map((kpi) => (
          <article className={`metric-card pulse-kpi-card pulse-status-${kpi.status}`} key={kpi.id}>
            <span>{kpi.label} · {kpi.period_label} · {kpi.scope_label}</span>
            <strong>{kpi.value}</strong>
            <p>{kpi.detail} {kpi.comparison_label}{kpi.sample_size === undefined ? "" : ` · n=${kpi.sample_size}`}</p>
          </article>
        ))}
      </section>

      <section className="pulse-layout pulse-overview-layout" aria-label="Pulse observability hierarchy">
        <article className="planned-card pulse-attention-panel">
          <div className="split-heading">
            <div>
              <p className="eyebrow">Exceptions first</p>
              <h3>Needs attention</h3>
            </div>
            <span className="count-pill">{pulse.attention.length} findings · planned actions disabled</span>
          </div>
          <ul>
            {pulse.attention.map((item) => <li className={`pulse-attention-${item.severity}`} key={item.id}><strong>{item.title}</strong>: {item.detail}</li>)}
          </ul>
          <button disabled title="Action routes need audited worker control APIs" type="button">Create systemic fix (planned)</button>
        </article>

        <section className="pulse-chart-grid" aria-label="Pulse trend charts">
          {chartSeries.map((chart) => <PulseChartPanel chart={chart} key={chart.id} />)}
        </section>
      </section>

      <section className="planned-card pulse-filter-panel" aria-label="Pulse filters">
        <div className="split-heading">
          <div>
            <p className="eyebrow">Filter controls</p>
            <h3>Scope the canonical event stream</h3>
          </div>
          <span className="count-pill">disabled preview controls</span>
        </div>
        <div className="pulse-filter-groups">
          {filterGroups.map((group) => (
            <fieldset className="pulse-filter-group" key={group.label}>
              <legend>{group.label}</legend>
              <div className="pulse-filter-row">
                {group.values.map((value) => <button disabled key={`${group.label}-${value}`} title={`${group.label}: ${value} filter is planned`} type="button">{value}</button>)}
              </div>
            </fieldset>
          ))}
        </div>
      </section>

      <section className="planned-card pulse-activity-panel" aria-label="Unified activity stream">
        <div className="split-heading">
          <div>
            <p className="eyebrow">Canonical stream</p>
            <h3>Unified activity</h3>
          </div>
          <section className="pulse-filter-row pulse-quick-filter-row" aria-label="Quick filters">
            {quickFilters.map((filter) => <button disabled key={filter} title={`${filter} quick filter is planned`} type="button">{filter}</button>)}
          </section>
        </div>
        <table className="pulse-activity-table" aria-label="Pulse and worker events">
          <thead>
            <tr className="pulse-activity-row pulse-activity-header">
              <th scope="col">When</th><th scope="col">Event</th><th scope="col">Scope</th><th scope="col">Outcome</th><th scope="col">Resource</th><th scope="col">Origin / actor</th>
            </tr>
          </thead>
          <tbody>
            {pulse.events.map((row) => (
              <tr className={row.id === selectedEvent?.id ? "pulse-activity-row selected" : "pulse-activity-row"} key={row.id}>
                <td data-label="When"><button className="pulse-row-select" onClick={() => setSelectedEventId(row.id)} type="button">{row.occurred_at.slice(11, 16)}</button></td>
                <td data-label="Event"><strong>{row.title}</strong><span>{row.summary}</span></td>
                <td data-label="Scope">{[row.repo_ref, row.issue_ref ?? row.pull_request_ref, row.worker_session_ref].filter(Boolean).join(" · ")}</td>
                <td data-label="Outcome">{humanize(row.outcome)} · {humanize(row.status)}</td>
                <td data-label="Resource">{resourceSummary(row)}</td>
                <td data-label="Origin / actor">{humanize(row.issue_origin, "-")} · {row.author_association} · {row.actor_ref ?? "actor pending"}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="pulse-card-stream" aria-label="Mobile activity cards">
          {pulse.events.map((row) => (
            <button className={row.id === selectedEvent?.id ? "pulse-event-card selected" : "pulse-event-card"} key={row.id} onClick={() => setSelectedEventId(row.id)} type="button">
              <span>{row.occurred_at.slice(11, 16)} · {humanize(row.severity)}</span>
              <strong>{row.title}</strong>
              <small>{humanize(row.outcome)} · {resourceSummary(row)}</small>
            </button>
          ))}
        </div>
        <p className="notice compact-notice">Mobile activity cards replace the dense table on small screens. Detail drawer becomes a full-screen sheet on small screens, and terminal panel becomes full-screen later.</p>
      </section>

      <section className="pulse-layout" aria-label="Drilldown and planned actions">
        <PulseDrilldownPanel event={selectedEvent} />
        <article className="planned-card pulse-actions-panel">
          <p className="eyebrow">Planned controls</p>
          <h3>Actions stay disabled until audited routes land</h3>
          <button disabled title="Terminal output needs a read-only command-output adapter" type="button">Open terminal output (planned)</button>
          <button disabled title="Dispatch needs worker control and trust-boundary APIs" type="button">Redispatch worker (planned)</button>
          <button disabled title="Persistence needs a write-action manifest and audit trail" type="button">Save systemic fix (planned)</button>
        </article>
      </section>
    </section>
  );
}

function PulseChartPanel({ chart }: { chart: GuiPulseWorkerChartSeries }): ReactElement {
  const maxValue = Math.max(...chart.points.map((point) => point.value), 1);

  return (
    <article className="planned-card pulse-chart-panel">
      <p className="eyebrow">Trends · day/week/month/year</p>
      <h3>{chart.label}</h3>
      <div className="pulse-chart-placeholder" aria-label={`${chart.label} chart for day week month year buckets`} role="img">
        {chart.points.map((point) => <span key={`${chart.id}-${point.period}`} style={{ "--bar-height": `${Math.max(18, Math.round((point.value / maxValue) * 100))}%` } as CSSProperties}>{point.period}</span>)}
      </div>
      <p>{chart.unit} · {chart.points.map((point) => `${point.period_label}: ${point.value}`).join(" · ")}</p>
    </article>
  );
}

function PulseDrilldownPanel({ event }: { event: PulseEvent | undefined }): ReactElement {
  if (event === undefined) {
    return (
      <article className="planned-card pulse-drilldown-panel pulse-detail-drawer" aria-label="Pulse event detail drawer">
        <p className="eyebrow">Drilldown drawer</p>
        <h3>No activity selected</h3>
        <p>Selected event details will connect timeline evidence, issue/PR/review context, usage, resources, failure analysis, suggested systemic fixes, and planned actions without exposing secrets.</p>
      </article>
    );
  }

  return (
    <article className="planned-card pulse-drilldown-panel pulse-detail-drawer" aria-label="Pulse event detail drawer">
      <p className="eyebrow">Drilldown drawer · selected row</p>
      <h3>{event.title}</h3>
      <dl className="pulse-detail-grid">
        <div><dt>What</dt><dd>{event.summary}</dd></div>
        <div><dt>When</dt><dd>{event.occurred_at} · {durationLabel(event.duration_ms)}</dd></div>
        <div><dt>Why</dt><dd>{event.drilldown_sections?.find((section) => section.label.toLowerCase().includes("failure"))?.body ?? event.drilldown_sections?.[0]?.body ?? "No failure analysis recorded."}</dd></div>
        <div><dt>How</dt><dd>{[event.type, event.status, event.outcome].map((value) => humanize(value)).join(" · ")}</dd></div>
        <div><dt>Who</dt><dd>{event.actor_ref ?? "actor pending"} · {humanize(event.issue_origin, "-")} · {event.author_association}</dd></div>
        <div><dt>Issue / PR / session refs</dt><dd>{[event.repo_ref, event.issue_ref, event.pull_request_ref, event.worker_session_ref, event.command_job_ref, event.pulse_run_ref].filter(Boolean).join(" · ")}</dd></div>
        <div><dt>Usage and cost</dt><dd>{usageSummary(event)}</dd></div>
        <div><dt>Resources</dt><dd>{event.resources?.map((resource) => `${resource.label}: ${resource.available_label} (${resource.pressure})`).join(" · ") || "Resource metadata pending"}</dd></div>
        <div><dt>Suggested systemic fix</dt><dd>{event.drilldown_sections?.find((section) => section.label.toLowerCase().includes("fix"))?.body ?? "Create a worker-ready follow-up when repeated blindspots appear."}</dd></div>
        <div><dt>Planned actions</dt><dd>Open terminal output, redispatch worker, save systemic fix, and attach timeline evidence remain disabled until Phase 5 action routes land.</dd></div>
      </dl>
    </article>
  );
}

function buildFilterGroups(pulse: GuiStatusData["pulse_workers"]): PulseFilterGroup[] {
  return [
    { label: "Repo", values: optionLabels(pulse.filters.repos) },
    { label: "Event type", values: optionLabels(pulse.filters.event_types) },
    { label: "Outcome", values: optionLabels(pulse.filters.outcomes) },
    { label: "Status", values: unique(pulse.events.map((event) => humanize(event.status))) },
    { label: "Severity", values: unique(pulse.events.map((event) => humanize(event.severity))) },
    { label: "Resource", values: optionLabels(pulse.filters.resources) },
    { label: "Provider / model", values: optionLabels(pulse.filters.providers) },
    { label: "Model", values: unique(pulse.events.map((event) => event.usage?.model_ref?.replace("model:", "") ?? "model pending")) },
    { label: "Issue origin", values: optionLabels(pulse.filters.issue_origins) },
    { label: "Author", values: optionLabels(pulse.filters.authors) },
    { label: "Author association", values: optionLabels(pulse.filters.author_associations) },
    { label: "Cost range", values: unique(pulse.events.map((event) => event.usage?.estimated_cost_ref ?? "no cost metadata")) },
    { label: "Duration range", values: unique(pulse.events.map((event) => durationBucket(event.duration_ms))) },
  ];
}

function optionLabels(options: Array<{ label: string; count: number }> | null | undefined): string[] {
  return options?.map((option) => `${option.label} (${option.count})`) ?? [];
}

function unique(values: string[]): string[] {
  return Array.from(new Set(values.filter(Boolean)));
}

function filterSummary(options: Array<{ label: string; count: number }> | null | undefined): string {
  return optionLabels(options).slice(0, 3).join(" · ") || "all";
}

function periodChoices(selected: string): string {
  return ["day", "week", "month", "year"].map((period) => period === selected ? `${period} selected` : period).join(" / ");
}

function resourceSummary(row: PulseEvent): string {
  const model = row.usage?.model_ref?.replace("model:", "");
  const providerLabel = row.usage?.provider === "openai" ? "OpenAI" : row.usage?.provider === "anthropic" ? "Anthropic" : row.usage?.provider;
  const provider = row.usage === null ? row.resources?.[0]?.available_label ?? "metadata only" : `${providerLabel ?? "Provider"} · ${model ?? "model metadata pending"}`;
  const tokens = row.usage === null ? "" : ` · ${row.usage.total_tokens.toLocaleString()} tokens`;
  const cost = row.usage?.estimated_cost_ref === null || row.usage?.estimated_cost_ref === undefined ? "" : ` · ${row.usage.estimated_cost_ref}`;

  return `${provider}${tokens}${cost}`;
}

function usageSummary(event: PulseEvent): string {
  if (event.usage === null) {
    return "Usage metadata pending or not applicable.";
  }

  return `${event.usage.provider} · ${event.usage.model_ref ?? "model pending"} · ${event.usage.total_tokens.toLocaleString()} tokens · ${event.usage.estimated_cost_ref ?? "cost pending"} · ${durationLabel(event.usage.wall_time_ms)}`;
}

function durationBucket(durationMs: number | null): string {
  if (durationMs === null) {
    return "duration pending";
  }
  if (durationMs < 300000) {
    return "under 5m";
  }
  if (durationMs < 1800000) {
    return "5m-30m";
  }

  return "30m+";
}

function durationLabel(durationMs: number | null): string {
  if (durationMs === null) {
    return "duration pending";
  }

  return `${Math.round(durationMs / 60000)}m`;
}

function humanize(value: string | null | undefined, replacement = " "): string {
  if (!value) {
    return "";
  }

  return value.replaceAll("_", replacement);
}
