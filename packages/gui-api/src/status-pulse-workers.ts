import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import {
  type GuiPulseResourceKind,
  type GuiPulseResourceSnapshot,
  type GuiPulseWorkerActivityEvent,
  type GuiPulseWorkerChartSeries,
  type GuiPulseWorkerKpiCard,
  type GuiPulseWorkerSummary,
  type GuiPulseWorkerUsageSnapshot,
  type GuiPulsePeriodBucket,
  pulseWorkersFixture,
} from "../../gui-shared/src";
import { collapseHome, expandHome, formatEpochField, isRecord, readJsonObject, stringField } from "./status-adapter-utils";
import { type MetricRecord, authorAssociationFromRecord, collectUsageSamples, durationMsFromRecord, extractPulseCounters, filterWindow, hasAvailableProvider, isHealthyOutcome, issueOriginFromRecord, numberValue, outcomeFromRecord, recordTimeMs, severityFromStatus, statusFromOutcome, stringOrNumber, summaryFromRecord, usageFromRecord } from "./status-pulse-worker-records";

export interface PulseWorkersAdapterOptions {
  metricsPath?: string;
  pulseStatsPath?: string;
  resourceMetricsPath?: string;
  tokenReportsRoot?: string;
  oauthPoolPath?: string;
  observedAt?: string;
  nowMs?: number;
}

interface SourceState {
  path_ref: string;
  health: "present" | "missing" | "invalid";
  observed_at: string;
}

const DAY_MS = 86_400_000;
const WEEK_MS = 7 * DAY_MS;
const DEFAULT_SCOPE = "local aidevops telemetry";
const DEFAULT_METRICS_PATH_REF = "~/.aidevops/logs/headless-runtime-metrics.jsonl";
const DEFAULT_PULSE_STATS_PATH_REF = "~/.aidevops/logs/pulse-stats.json";
const DEFAULT_RESOURCE_METRICS_PATH_REF = "~/.aidevops/logs/resource-metrics.jsonl";
const DEFAULT_TOKEN_REPORTS_ROOT_REF = "~/.aidevops/_reports/token-use";

export function readPulseWorkersSummary(options: PulseWorkersAdapterOptions = {}): { summary: GuiPulseWorkerSummary; source_path_refs: string[] } {
  const nowMs = options.nowMs ?? Date.parse(options.observedAt ?? new Date().toISOString());
  const observedAt = new Date(Number.isFinite(nowMs) ? nowMs : Date.now()).toISOString();
  const metricsPath = options.metricsPath ?? expandHome(DEFAULT_METRICS_PATH_REF);
  const pulseStatsPath = options.pulseStatsPath ?? expandHome(DEFAULT_PULSE_STATS_PATH_REF);
  const resourceMetricsPath = options.resourceMetricsPath ?? expandHome(DEFAULT_RESOURCE_METRICS_PATH_REF);
  const tokenReportsRoot = options.tokenReportsRoot ?? expandHome(DEFAULT_TOKEN_REPORTS_ROOT_REF);
  const oauthPoolPath = options.oauthPoolPath ?? expandHome("~/.aidevops/oauth-pool.json");

  const metrics = readJsonLines(metricsPath);
  const resources = readJsonLines(resourceMetricsPath);
  const tokenReports = readTokenReports(tokenReportsRoot);
  const pulseStats = readJsonObject(pulseStatsPath);
  const oauthPool = readJsonObject(oauthPoolPath);
  const sourceStates: SourceState[] = [
    stateFor(metricsPath, metrics.health, observedAt),
    stateFor(pulseStatsPath, pulseStats.health, observedAt),
    stateFor(resourceMetricsPath, resources.health, observedAt),
    stateFor(tokenReportsRoot, tokenReports.health, observedAt),
    stateFor(oauthPoolPath, oauthPool.health, observedAt),
  ];

  const dayMetrics = filterWindow(metrics.records, nowMs, DAY_MS);
  const weekMetrics = filterWindow(metrics.records, nowMs, WEEK_MS);
  const pulseCounters = extractPulseCounters(pulseStats.value, nowMs, DAY_MS);
  const resourceSnapshots = resourceMetricsToSnapshots(resources.records, observedAt);
  const usageSamples = collectUsageSamples([...dayMetrics, ...tokenReports.records]);
  const events = buildEvents(dayMetrics, resourceSnapshots, usageSamples, observedAt);
  const warnings = buildAttention(sourceStates, pulseCounters, resourceSnapshots, oauthPool.value);

  const summary: GuiPulseWorkerSummary = {
    value_policy: "metadata_only_no_prompt_payloads_no_secrets",
    selected_period: "day",
    period_label: "Last 24h",
    scope_label: DEFAULT_SCOPE,
    comparison_label: "Prior local telemetry window",
    updated_at: observedAt,
    kpis: buildKpis(dayMetrics, weekMetrics, pulseCounters, usageSamples, resourceSnapshots),
    attention: warnings,
    filters: buildFilters(events),
    charts: buildCharts(metrics.records, pulseCounters, nowMs),
    events,
  };

  return { summary, source_path_refs: sourceStates.map((source) => source.path_ref) };
}

function readJsonLines(pathName: string): { health: "present" | "missing" | "invalid"; records: MetricRecord[] } {
  if (!existsSync(pathName)) {
    return { health: "missing", records: [] };
  }
  try {
    const records = readFileSync(pathName, "utf8")
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => JSON.parse(line))
      .filter(isRecord);
    return { health: "present", records };
  } catch {
    return { health: "invalid", records: [] };
  }
}

function readTokenReports(root: string): { health: "present" | "missing" | "invalid"; records: MetricRecord[] } {
  if (!existsSync(root)) {
    return { health: "missing", records: [] };
  }
  try {
    const records = readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => join(root, entry.name, "report.json"))
      .filter((pathName) => existsSync(pathName))
      .slice(-25)
      .map((pathName) => JSON.parse(readFileSync(pathName, "utf8")))
      .filter(isRecord);
    return { health: "present", records };
  } catch {
    return { health: "invalid", records: [] };
  }
}

function stateFor(pathName: string, health: SourceState["health"], observedAt: string): SourceState {
  return { path_ref: collapseHome(pathName), health, observed_at: observedAt };
}

function buildKpis(dayMetrics: MetricRecord[], weekMetrics: MetricRecord[], counters: Record<string, number>, usage: GuiPulseWorkerUsageSnapshot[], resources: GuiPulseResourceSnapshot[]): GuiPulseWorkerKpiCard[] {
  const total = dayMetrics.length;
  const healthy = dayMetrics.filter((record) => isHealthyOutcome(outcomeFromRecord(record))).length;
  const rate = total === 0 ? 0 : Math.round((healthy / total) * 100);
  const totalTokens = usage.reduce((sum, item) => sum + item.total_tokens, 0);
  const costRefs = usage.map((item) => item.estimated_cost_ref).filter((item): item is string => item !== null);
  const attentionCount = Object.values(counters).reduce((sum, count) => sum + count, 0) + resources.filter((resource) => resource.pressure !== "low" && resource.pressure !== "unknown").length;

  return [
    { id: "worker-outcomes-24h", label: "Healthy worker outcomes", value: total === 0 ? "unknown" : `${rate}%`, period_label: "Last 24h", scope_label: DEFAULT_SCOPE, comparison_label: "computed from local worker metrics", sample_size: total, status: total === 0 ? "attention" : rate >= 80 ? "healthy" : "attention", detail: total === 0 ? "No local worker outcome records were available for the last 24h." : `${healthy} of ${total} local worker sessions ended merged, closed, completed, or deferred.` },
    { id: "attention-signals", label: "Attention signals", value: String(attentionCount), period_label: "Last 24h", scope_label: DEFAULT_SCOPE, comparison_label: "pulse counters plus resource pressure", sample_size: Object.keys(counters).length + resources.length, status: attentionCount > 0 ? "attention" : "healthy", detail: "Counts canonical Pulse counters and observed resource pressure without treating missing telemetry as failure." },
    { id: "token-cost", label: "Token and cost sample", value: totalTokens > 0 ? `${totalTokens.toLocaleString()} tokens` : "unknown", period_label: "Last 24h", scope_label: "provider/model metadata", comparison_label: costRefs.length > 0 ? "cost refs observed" : "cost unavailable", sample_size: usage.length, status: usage.length > 0 ? "healthy" : "attention", detail: "Token usage is derived from metadata fields only; prompts, command output, credential paths, and message payloads are excluded." },
    { id: "systemic-fixes", label: "Systemic fixes observed", value: String(weekMetrics.filter((record) => outcomeFromRecord(record) === "created_followup").length), period_label: "Trailing 7d", scope_label: DEFAULT_SCOPE, comparison_label: "worker outcome metadata", sample_size: weekMetrics.length, status: "completed", detail: "Follow-up/systemic-fix outcomes are counted only when canonical local metrics record them." },
  ];
}

function buildAttention(sources: SourceState[], counters: Record<string, number>, resources: GuiPulseResourceSnapshot[], oauthPool: Record<string, unknown>): GuiPulseWorkerSummary["attention"] {
  const missing = sources.filter((source) => source.health !== "present");
  const attention: GuiPulseWorkerSummary["attention"] = missing.map((source) => ({ id: `source-${source.health}-${slug(source.path_ref)}`, severity: source.health === "invalid" ? "warning" : "info", title: `Telemetry source ${source.health}`, detail: `${source.path_ref} was ${source.health}; the GUI used safe empty summaries for that source.`, event_ref: null }));
  for (const [name, count] of Object.entries(counters).filter(([, count]) => count > 0)) {
    attention.push({ id: `pulse-counter-${slug(name)}`, severity: "warning", title: `Pulse counter active: ${name}`, detail: `${count} events observed in the selected local period.`, event_ref: null });
  }
  for (const resource of resources.filter((item) => item.pressure === "medium" || item.pressure === "high")) {
    attention.push({ id: `resource-${slug(resource.kind)}-${slug(resource.label)}`, severity: resource.pressure === "high" ? "critical" : "warning", title: `${resource.label} pressure ${resource.pressure}`, detail: resource.available_label, event_ref: null });
  }
  if (!hasAvailableProvider(oauthPool)) {
    attention.push({ id: "provider-availability-unknown", severity: "info", title: "Provider availability unknown", detail: "OAuth pool metadata did not expose an available provider account count; the GUI marks provider capacity as unknown.", event_ref: null });
  }
  return attention.slice(0, 12);
}

function buildEvents(records: MetricRecord[], resources: GuiPulseResourceSnapshot[], usage: GuiPulseWorkerUsageSnapshot[], observedAt: string): GuiPulseWorkerActivityEvent[] {
  return records.slice(-25).sort((left, right) => (recordTimeMs(right) ?? 0) - (recordTimeMs(left) ?? 0)).map((record, index) => {
    const outcome = outcomeFromRecord(record);
    const status = statusFromOutcome(outcome);
    const issue = stringOrNumber(record.issue ?? record.issue_number);
    const pr = stringOrNumber(record.pr ?? record.pr_number ?? record.pull_request);
    const repo = stringField(record, "repo") ?? null;
    return {
      id: `event:worker:${issue ?? index}:${recordTimeMs(record) ?? index}`,
      type: "worker_session",
      status,
      outcome,
      severity: severityFromStatus(status),
      occurred_at: recordTimeMs(record) === null ? observedAt : new Date(recordTimeMs(record) as number).toISOString(),
      title: "Worker session",
      summary: summaryFromRecord(record, outcome),
      pulse_run_ref: stringField(record, "pulse_run_ref") ?? null,
      worker_session_ref: stringField(record, "session_key") ?? stringField(record, "worker_session_ref") ?? null,
      issue_ref: issue === null ? null : `#${issue.replace(/^#/, "")}`,
      pull_request_ref: pr === null ? null : `#${pr.replace(/^#/, "")}`,
      command_job_ref: stringField(record, "command_job_ref") ?? null,
      repo_ref: repo,
      actor_ref: stringField(record, "actor") ?? "worker:auto-dispatch",
      issue_origin: issueOriginFromRecord(record),
      author_association: authorAssociationFromRecord(record),
      duration_ms: durationMsFromRecord(record),
      usage: usageFromRecord(record) ?? usage[index] ?? null,
      resources,
      drilldown_sections: [
        { label: "Evidence", body: "Derived from local worker outcome/resource metadata; prompt text and command payloads are not exposed." },
        { label: "Outcome", body: outcome },
      ],
    };
  });
}

function buildFilters(events: GuiPulseWorkerActivityEvent[]): GuiPulseWorkerSummary["filters"] {
  return {
    repos: countOptions(events.map((event) => event.repo_ref).filter(Boolean) as string[], "repo:"),
    event_types: countOptions(events.map((event) => event.type)),
    outcomes: countOptions(events.map((event) => event.outcome)),
    resources: countOptions(events.flatMap((event) => event.resources.map((resource) => resource.kind))),
    providers: countOptions(events.map((event) => event.usage === null ? null : `${event.usage.provider}:${event.usage.model_ref ?? "unknown"}`).filter(Boolean) as string[]),
    issue_origins: countOptions(events.map((event) => event.issue_origin)),
    authors: countOptions(events.map((event) => event.actor_ref).filter(Boolean) as string[], "actor:"),
    author_associations: countOptions(events.map((event) => event.author_association)),
  };
}

function buildCharts(records: MetricRecord[], counters: Record<string, number>, nowMs: number): GuiPulseWorkerChartSeries[] {
  const specs: Array<[GuiPulsePeriodBucket, number, string]> = [["day", DAY_MS, "Last 24h"], ["week", WEEK_MS, "Trailing 7d"], ["month", 30 * DAY_MS, "Trailing 30d"], ["year", 365 * DAY_MS, "Trailing 365d"]];
  const counterTotal = Object.values(counters).reduce((sum, count) => sum + count, 0);
  return [{ id: "worker-events", label: "Worker events", unit: "count", points: specs.map(([period, windowMs, label]) => ({ period, period_label: label, scope_label: DEFAULT_SCOPE, bucket_start: new Date(nowMs - windowMs).toISOString(), bucket_end: new Date(nowMs).toISOString(), value: filterWindow(records, nowMs, windowMs).length + (period === "day" ? counterTotal : 0) })) }];
}

function resourceMetricsToSnapshots(records: MetricRecord[], observedAt: string): GuiPulseResourceSnapshot[] {
  return records.slice(-5).map((record) => {
    const rssKb = numberValue(record.rss_kb ?? record.peak_rss_kb);
    return { kind: "memory" as GuiPulseResourceKind, label: stringField(record, "role") ?? "Process memory", available_label: rssKb === null ? "unknown" : `${Math.round(rssKb / 1024)} MB RSS`, pressure: rssKb === null ? "unknown" : rssKb > 2_000_000 ? "high" : rssKb > 750_000 ? "medium" : "low", observed_at: recordTimeMs(record) === null ? observedAt : new Date(recordTimeMs(record) as number).toISOString(), reset_at: null };
  });
}

function countOptions(values: string[], prefix = ""): Array<{ id: string; label: string; count: number }> {
  const counts = new Map<string, number>();
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1);
  return [...counts.entries()].map(([label, count]) => ({ id: `${prefix}${slug(label)}`, label, count })).sort((a, b) => b.count - a.count || a.label.localeCompare(b.label));
}

function slug(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "unknown";
}
