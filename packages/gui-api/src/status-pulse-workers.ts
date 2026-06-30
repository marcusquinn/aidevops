import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import {
  type GuiPulseResourceKind,
  type GuiPulseResourceSnapshot,
  type GuiPulseSystemicFinding,
  type GuiPulseWorkerActionSummary,
  type GuiPulseWorkerActivityEvent,
  type GuiPulseWorkerChartSeries,
  type GuiPulseWorkerKpiCard,
  type GuiPulseWorkerSummary,
  type GuiPulseWorkerUsageSnapshot,
  type GuiPulsePeriodBucket,
  pulseWorkersFixture,
} from "../../gui-shared/src";
import { collapseHome, expandHome, formatEpochField, isRecord, readJsonObject, stringField } from "./status-adapter-utils";
import { buildAttention } from "./status-pulse-workers-attention";
import { authorAssociationFromRecord, isHealthyOutcome, issueOriginFromRecord, outcomeFromRecord, providerFromString, severityFromStatus, statusFromOutcome } from "./status-pulse-workers-classifiers";
import { costRef, countOptions, durationMsFromRecord, type MetricRecord, numberValue, recordTimeMs, stringOrNumber, summaryFromRecord } from "./status-pulse-workers-values";

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
const PULSE_WORKER_ACTIONS: GuiPulseWorkerActionSummary[] = pulseWorkersFixture.actions;

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
  const previousDayMetrics = filterWindowBetween(metrics.records, nowMs - (2 * DAY_MS), nowMs - DAY_MS);
  const weekMetrics = filterWindow(metrics.records, nowMs, WEEK_MS);
  const pulseCounters = extractPulseCounters(pulseStats.value, nowMs);
  const resourceSnapshots = resourceMetricsToSnapshots(resources.records, observedAt);
  const usageSamples = collectUsageSamples([...dayMetrics, ...tokenReports.records]);
  const events = buildEvents(dayMetrics, resourceSnapshots, usageSamples, observedAt);
  const insights = buildInsights(events, dayMetrics, previousDayMetrics, resourceSnapshots);
  const warnings = [...buildAttention(sourceStates, pulseCounters, resourceSnapshots, oauthPool.value), ...insights.map((finding) => ({ id: finding.id, severity: finding.severity, title: finding.title, detail: `${finding.detail} Recommended fix: ${finding.recommendation}`, event_ref: finding.event_refs[0] ?? null }))].slice(0, 12);

  const summary: GuiPulseWorkerSummary = {
    value_policy: "metadata_only_no_prompt_payloads_no_secrets",
    selected_period: "day",
    period_label: "Last 24h",
    scope_label: DEFAULT_SCOPE,
    comparison_label: "Prior local telemetry window",
    updated_at: observedAt,
    kpis: buildKpis(dayMetrics, weekMetrics, pulseCounters, usageSamples, resourceSnapshots),
    attention: warnings,
    insights,
    filters: buildFilters(events),
    charts: buildCharts(metrics.records, pulseCounters, nowMs),
    events,
    actions: PULSE_WORKER_ACTIONS,
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

function filterWindow(records: MetricRecord[], nowMs: number, windowMs: number): MetricRecord[] {
  const cutoff = nowMs - windowMs;
  return records.filter((record) => {
    const time = recordTimeMs(record);
    return time !== null && time >= cutoff && time <= nowMs;
  });
}

function filterWindowBetween(records: MetricRecord[], startMs: number, endMs: number): MetricRecord[] {
  return records.filter((record) => {
    const time = recordTimeMs(record);
    return time !== null && time >= startMs && time < endMs;
  });
}

function extractPulseCounters(value: Record<string, unknown>, nowMs: number): Record<string, number> {
  const counters = isRecord(value.counters) ? value.counters : {};
  return Object.fromEntries(Object.entries(counters).map(([name, entries]) => [name, countRecentTimestamps(entries, nowMs, DAY_MS)]));
}

function countRecentTimestamps(value: unknown, nowMs: number, windowMs: number): number {
  if (!Array.isArray(value)) {
    return 0;
  }
  const cutoff = nowMs - windowMs;
  return value.filter((entry) => {
    const ms = typeof entry === "number" ? (entry > 9_999_999_999 ? entry : entry * 1000) : Date.parse(String(entry));
    return Number.isFinite(ms) && ms >= cutoff && ms <= nowMs;
  }).length;
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
        { label: "Verification", body: verificationSummary(record) },
        { label: "Systemic fix", body: systemicFixRecommendation(record, outcome) },
      ],
    };
  });
}

function buildInsights(events: GuiPulseWorkerActivityEvent[], dayMetrics: MetricRecord[], previousDayMetrics: MetricRecord[], resources: GuiPulseResourceSnapshot[]): GuiPulseSystemicFinding[] {
  const findings: GuiPulseSystemicFinding[] = [];
  const thirdPartyWaiting = events.filter((event) => event.issue_origin === "third_party" && (event.outcome === "needs_maintainer_review" || event.outcome === "blocked" || event.outcome === "in_progress"));
  if (thirdPartyWaiting.length > 0) {
    findings.push(finding("third-party-waiting", "third_party_waiting", "warning", "Third-party issues waiting", `${thirdPartyWaiting.length} community-origin issue events need triage or resolution in the selected period.`, "Community reports are separated from aidevops-created task handling and may need a maintainer decision before dispatch.", thirdPartyWaiting, "Create a systemic triage task that preserves non-collaborator trust boundaries and adds first-response thresholds.", "community waiting count", thirdPartyWaiting.length, "high"));
  }

  const failedOrBlocked = events.filter((event) => event.outcome === "failed" || event.outcome === "blocked");
  for (const [key, group] of groupEvents(failedOrBlocked, (event) => [event.repo_ref ?? "repo:unknown", event.usage?.provider ?? "provider:unknown", event.resources[0]?.kind ?? "resource:unknown"].join("|"))) {
    if (group.length > 1) {
      findings.push(finding(`repeated-${key}`, "repeated_failure", "critical", "Repeated failure pattern", `${group.length} failed or blocked runs share repo/provider/resource context.`, "A repeated worker blindspot is likely being retried as individual failures instead of being converted into a shared guardrail or helper fix.", group, "Create a systemic fix task with grouped evidence, affected repo/provider/resource, and a focused verification command.", key.replaceAll("|", " · "), group.length, "medium"));
    }
  }

  const weakVerification = events.filter((event) => event.drilldown_sections.some((section) => section.label === "Verification" && /missing|weak|not recorded/i.test(section.body)));
  if (weakVerification.length > 0) {
    findings.push(finding("weak-verification", "weak_verification", "warning", "No-verification outcomes", `${weakVerification.length} events lack strong verification metadata.`, "Workers may be completing or blocking without durable command evidence in the telemetry stream.", weakVerification, "Create a systemic fix task to require verification command capture in worker outcome records.", "verification coverage", weakVerification.length, "medium"));
  }

  const pressureEvents = events.filter((event) => event.resources.some((resource) => resource.pressure === "medium" || resource.pressure === "high"));
  if (pressureEvents.length > 0 || resources.some((resource) => resource.pressure === "medium" || resource.pressure === "high")) {
    findings.push(finding("resource-pressure", "resource_pressure", resources.some((resource) => resource.pressure === "high") ? "critical" : "warning", "Resource allowance pressure", `${pressureEvents.length} events overlapped medium/high resource pressure; ${resources.length} resource samples are in scope.`, "Provider quota, GitHub API, queue, CI, or local resource pressure can inflate retry cost and slow dispatch-to-merge cycles.", pressureEvents, "Create a systemic capacity task that records allowance snapshots before redispatching failed workers.", "resource pressure", Math.max(pressureEvents.length, resources.length), "medium"));
  }

  const currentCost = sumCost(dayMetrics);
  const previousCost = sumCost(previousDayMetrics);
  const failedCostEvents = events.filter((event) => (event.outcome === "failed" || event.outcome === "blocked") && event.usage?.estimated_cost_ref !== null && event.usage !== null);
  if (currentCost > 0 && previousCost > 0 && currentCost >= previousCost * 1.5) {
    findings.push(finding("cost-spike", "cost_spike", "warning", "Cost spike versus previous period", `Estimated selected-period cost is ${currentCost.toFixed(2)} versus ${previousCost.toFixed(2)} in the previous equivalent window.`, "Retry loops or expensive models may be consuming allowance faster than successful outcomes justify.", events, "Create a systemic cost-control task that ties model/provider selection to outcome quality and retry count.", "estimated USD", dayMetrics.length, "medium", `previous equivalent period: ${previousCost.toFixed(2)}`));
  } else if (failedCostEvents.length > 0) {
    findings.push(finding("failed-run-cost", "high_retry_cost", "warning", "Failed-run cost attached to outcomes", `${failedCostEvents.length} failed or blocked events include token/cost metadata.`, "Cost is being spent on outcomes that did not merge, close, defer, or create follow-up work.", failedCostEvents, "Create a systemic retry-budget task that escalates or changes strategy before another costly rerun.", "failed-run cost samples", failedCostEvents.length, "medium"));
  }

  const slowEvents = events.filter((event) => (event.duration_ms ?? 0) >= 1_800_000);
  if (slowEvents.length > 0) {
    findings.push(finding("slow-bottlenecks", "slow_bottleneck", "warning", "Slow dispatch-to-outcome bottlenecks", `${slowEvents.length} events exceeded 30 minutes.`, "Long-running dispatch, review, or merge gates can hide queue/concurrency or CI runner bottlenecks.", slowEvents, "Create a systemic bottleneck task that separates dispatch-to-PR and PR-to-merge timing evidence.", "duration >=30m", slowEvents.length, "medium"));
  }

  return findings.slice(0, 8);
}

function finding(id: string, kind: GuiPulseSystemicFinding["kind"], severity: GuiPulseSystemicFinding["severity"], title: string, detail: string, likelyCause: string, events: GuiPulseWorkerActivityEvent[], recommendation: string, metricLabel: string, sampleSize: number, confidence: GuiPulseSystemicFinding["confidence"], comparisonLabel = "selected period scoped to active filters"): GuiPulseSystemicFinding {
  return { id: `insight-${id.replace(/[^a-z0-9-]+/gi, "-").toLowerCase()}`, kind, severity, title, detail, likely_cause: likelyCause, evidence_refs: evidenceRefs(events), event_refs: events.map((event) => event.id).slice(0, 6), confidence, recommendation, metric_label: metricLabel, period_label: "Last 24h", scope_label: DEFAULT_SCOPE, comparison_label: comparisonLabel, sample_size: sampleSize, primary_action: "create_systemic_fix" };
}

function groupEvents(events: GuiPulseWorkerActivityEvent[], keyFor: (event: GuiPulseWorkerActivityEvent) => string): Map<string, GuiPulseWorkerActivityEvent[]> {
  const groups = new Map<string, GuiPulseWorkerActivityEvent[]>();
  for (const event of events) {
    const key = keyFor(event);
    groups.set(key, [...(groups.get(key) ?? []), event]);
  }
  return groups;
}

function evidenceRefs(events: GuiPulseWorkerActivityEvent[]): string[] {
  return events.flatMap((event) => [event.repo_ref, event.issue_ref, event.pull_request_ref, event.worker_session_ref, event.command_job_ref].filter(Boolean) as string[]).slice(0, 8);
}

function verificationSummary(record: MetricRecord): string {
  const value = stringField(record, "verification") ?? stringField(record, "testing") ?? stringField(record, "verification_status");
  if (value !== undefined && value.length > 0) return value;
  return "Verification missing or weak in local telemetry; outcome should carry command evidence before completion claims.";
}

function systemicFixRecommendation(record: MetricRecord, outcome: string): string {
  if (/missing|weak|none/i.test(verificationSummary(record))) return "Require worker outcome telemetry to include verification commands and results.";
  if (outcome === "failed" || outcome === "blocked") return "Group repeated failure evidence and create a worker-ready helper or validator fix.";
  return "Create follow-up only when the same blindspot repeats across events in the selected period.";
}

function sumCost(records: MetricRecord[]): number {
  return records.reduce((sum, record) => sum + (numberValue(record.estimated_cost_usd ?? record.cost_usd) ?? 0), 0);
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

function collectUsageSamples(records: MetricRecord[]): GuiPulseWorkerUsageSnapshot[] {
  return records.map(usageFromRecord).filter((usage): usage is GuiPulseWorkerUsageSnapshot => usage !== null);
}

function usageFromRecord(record: MetricRecord): GuiPulseWorkerUsageSnapshot | null {
  const input = numberValue(record.input_tokens ?? record.prompt_tokens);
  const output = numberValue(record.output_tokens ?? record.completion_tokens);
  const total = numberValue(record.total_tokens) ?? (input ?? 0) + (output ?? 0);
  if (total <= 0 && input === null && output === null) {
    return null;
  }
  const provider = providerFromString(stringField(record, "provider") ?? stringField(record, "provider_id"));
  const model = stringField(record, "model") ?? stringField(record, "model_ref") ?? null;
  return { provider, provider_ref: `provider:${provider}`, model_ref: model, input_tokens: input ?? 0, output_tokens: output ?? 0, cached_tokens: numberValue(record.cached_tokens) ?? 0, total_tokens: total, cost_ref: costRef(record), estimated_cost_ref: costRef(record), wall_time_ms: numberValue(record.wall_time_ms ?? record.duration_ms) ?? 0 };
}
