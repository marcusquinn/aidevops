import {
  type GuiPulseResourceSnapshot,
  type GuiPulseSystemicFinding,
  type GuiPulseWorkerActivityEvent,
} from "../../gui-shared/src";
import { type MetricRecord, numberValue } from "./status-pulse-workers-values";

const DEFAULT_SCOPE = "local aidevops telemetry";
const SLOW_EVENT_MS = 1_800_000;

interface FindingInput {
  id: string;
  kind: GuiPulseSystemicFinding["kind"];
  severity: GuiPulseSystemicFinding["severity"];
  title: string;
  detail: string;
  likelyCause: string;
  events: GuiPulseWorkerActivityEvent[];
  recommendation: string;
  metricLabel: string;
  sampleSize: number;
  confidence: GuiPulseSystemicFinding["confidence"];
  comparisonLabel?: string;
}

export function buildInsights(
  events: GuiPulseWorkerActivityEvent[],
  dayMetrics: MetricRecord[],
  previousDayMetrics: MetricRecord[],
  resources: GuiPulseResourceSnapshot[],
): GuiPulseSystemicFinding[] {
  const findings: GuiPulseSystemicFinding[] = [];
  findings.push(...thirdPartyFindings(events));
  findings.push(...repeatedFailureFindings(events));
  findings.push(...weakVerificationFindings(events));
  findings.push(...resourcePressureFindings(events, resources));
  findings.push(...costFindings(events, dayMetrics, previousDayMetrics));
  findings.push(...slowBottleneckFindings(events));
  return findings.slice(0, 8);
}

function thirdPartyFindings(events: GuiPulseWorkerActivityEvent[]): GuiPulseSystemicFinding[] {
  const waiting = events.filter(
    (event) =>
      event.issue_origin === "third_party" &&
      ["needs_maintainer_review", "blocked", "in_progress"].includes(event.outcome),
  );
  if (waiting.length === 0) return [];
  return [
    finding({
      id: "third-party-waiting",
      kind: "third_party_waiting",
      severity: "warning",
      title: "Third-party issues waiting",
      detail: `${waiting.length} community-origin issue events need triage or resolution in the selected period.`,
      likelyCause: "Community reports are separated from aidevops-created task handling and may need a maintainer decision before dispatch.",
      events: waiting,
      recommendation: "Create a systemic triage task that preserves non-collaborator trust boundaries and adds first-response thresholds.",
      metricLabel: "community waiting count",
      sampleSize: waiting.length,
      confidence: "high",
    }),
  ];
}

function repeatedFailureFindings(events: GuiPulseWorkerActivityEvent[]): GuiPulseSystemicFinding[] {
  const failedOrBlocked = events.filter((event) => event.outcome === "failed" || event.outcome === "blocked");
  return [...groupEvents(failedOrBlocked, repeatedFailureKey).entries()]
    .filter(([, group]) => group.length > 1)
    .map(([key, group]) =>
      finding({
        id: `repeated-${key}`,
        kind: "repeated_failure",
        severity: "critical",
        title: "Repeated failure pattern",
        detail: `${group.length} failed or blocked runs share repo/provider/resource context.`,
        likelyCause:
          "A repeated worker blindspot is likely being retried as individual failures instead of being converted into a shared guardrail or helper fix.",
        events: group,
        recommendation:
          "Create a systemic fix task with grouped evidence, affected repo/provider/resource, and a focused verification command.",
        metricLabel: key.replaceAll("|", " · "),
        sampleSize: group.length,
        confidence: "medium",
      }),
    );
}

function weakVerificationFindings(events: GuiPulseWorkerActivityEvent[]): GuiPulseSystemicFinding[] {
  const weakVerification = events.filter((event) =>
    event.drilldown_sections.some(
      (section) => section.label === "Verification" && /missing|weak|not recorded/i.test(section.body),
    ),
  );
  if (weakVerification.length === 0) return [];
  return [
    finding({
      id: "weak-verification",
      kind: "weak_verification",
      severity: "warning",
      title: "No-verification outcomes",
      detail: `${weakVerification.length} events lack strong verification metadata.`,
      likelyCause: "Workers may be completing or blocking without durable command evidence in the telemetry stream.",
      events: weakVerification,
      recommendation: "Create a systemic fix task to require verification command capture in worker outcome records.",
      metricLabel: "verification coverage",
      sampleSize: weakVerification.length,
      confidence: "medium",
    }),
  ];
}

function resourcePressureFindings(events: GuiPulseWorkerActivityEvent[], resources: GuiPulseResourceSnapshot[]): GuiPulseSystemicFinding[] {
  const pressureEvents = events.filter((event) => event.resources.some(hasPressure));
  if (pressureEvents.length === 0 && !resources.some(hasPressure)) return [];
  return [
    finding({
      id: "resource-pressure",
      kind: "resource_pressure",
      severity: resources.some((resource) => resource.pressure === "high") ? "critical" : "warning",
      title: "Resource allowance pressure",
      detail: `${pressureEvents.length} events overlapped medium/high resource pressure; ${resources.length} resource samples are in scope.`,
      likelyCause:
        "Provider quota, GitHub API, queue, CI, or local resource pressure can inflate retry cost and slow dispatch-to-merge cycles.",
      events: pressureEvents,
      recommendation: "Create a systemic capacity task that records allowance snapshots before redispatching failed workers.",
      metricLabel: "resource pressure",
      sampleSize: Math.max(pressureEvents.length, resources.length),
      confidence: "medium",
    }),
  ];
}

function costFindings(
  events: GuiPulseWorkerActivityEvent[],
  dayMetrics: MetricRecord[],
  previousDayMetrics: MetricRecord[],
): GuiPulseSystemicFinding[] {
  const currentCost = sumCost(dayMetrics);
  const previousCost = sumCost(previousDayMetrics);
  if (currentCost > 0 && previousCost > 0 && currentCost >= previousCost * 1.5) {
    return [costSpikeFinding(events, dayMetrics.length, currentCost, previousCost)];
  }

  const failedCostEvents = events.filter(
    (event) =>
      (event.outcome === "failed" || event.outcome === "blocked") &&
      event.usage !== null &&
      event.usage.estimated_cost_ref !== null,
  );
  if (failedCostEvents.length === 0) return [];
  return [
    finding({
      id: "failed-run-cost",
      kind: "high_retry_cost",
      severity: "warning",
      title: "Failed-run cost attached to outcomes",
      detail: `${failedCostEvents.length} failed or blocked events include token/cost metadata.`,
      likelyCause: "Cost is being spent on outcomes that did not merge, close, defer, or create follow-up work.",
      events: failedCostEvents,
      recommendation: "Create a systemic retry-budget task that escalates or changes strategy before another costly rerun.",
      metricLabel: "failed-run cost samples",
      sampleSize: failedCostEvents.length,
      confidence: "medium",
    }),
  ];
}

function costSpikeFinding(
  events: GuiPulseWorkerActivityEvent[],
  sampleSize: number,
  currentCost: number,
  previousCost: number,
): GuiPulseSystemicFinding {
  return finding({
    id: "cost-spike",
    kind: "cost_spike",
    severity: "warning",
    title: "Cost spike versus previous period",
    detail: `Estimated selected-period cost is ${currentCost.toFixed(2)} versus ${previousCost.toFixed(2)} in the previous equivalent window.`,
    likelyCause: "Retry loops or expensive models may be consuming allowance faster than successful outcomes justify.",
    events,
    recommendation: "Create a systemic cost-control task that ties model/provider selection to outcome quality and retry count.",
    metricLabel: "estimated USD",
    sampleSize,
    confidence: "medium",
    comparisonLabel: `previous equivalent period: ${previousCost.toFixed(2)}`,
  });
}

function slowBottleneckFindings(events: GuiPulseWorkerActivityEvent[]): GuiPulseSystemicFinding[] {
  const slowEvents = events.filter((event) => (event.duration_ms ?? 0) >= SLOW_EVENT_MS);
  if (slowEvents.length === 0) return [];
  return [
    finding({
      id: "slow-bottlenecks",
      kind: "slow_bottleneck",
      severity: "warning",
      title: "Slow dispatch-to-outcome bottlenecks",
      detail: `${slowEvents.length} events exceeded 30 minutes.`,
      likelyCause: "Long-running dispatch, review, or merge gates can hide queue/concurrency or CI runner bottlenecks.",
      events: slowEvents,
      recommendation: "Create a systemic bottleneck task that separates dispatch-to-PR and PR-to-merge timing evidence.",
      metricLabel: "duration >=30m",
      sampleSize: slowEvents.length,
      confidence: "medium",
    }),
  ];
}

function finding(input: FindingInput): GuiPulseSystemicFinding {
  return {
    id: `insight-${input.id.replace(/[^a-z0-9-]+/gi, "-").toLowerCase()}`,
    kind: input.kind,
    severity: input.severity,
    title: input.title,
    detail: input.detail,
    likely_cause: input.likelyCause,
    evidence_refs: evidenceRefs(input.events),
    event_refs: input.events.map((event) => event.id).slice(0, 6),
    confidence: input.confidence,
    recommendation: input.recommendation,
    metric_label: input.metricLabel,
    period_label: "Last 24h",
    scope_label: DEFAULT_SCOPE,
    comparison_label: input.comparisonLabel ?? "selected period scoped to active filters",
    sample_size: input.sampleSize,
    primary_action: "create_systemic_fix",
  };
}

function repeatedFailureKey(event: GuiPulseWorkerActivityEvent): string {
  return [
    event.repo_ref ?? "repo:unknown",
    event.usage?.provider ?? "provider:unknown",
    event.resources[0]?.kind ?? "resource:unknown",
  ].join("|");
}

function groupEvents(
  events: GuiPulseWorkerActivityEvent[],
  keyFor: (event: GuiPulseWorkerActivityEvent) => string,
): Map<string, GuiPulseWorkerActivityEvent[]> {
  const groups = new Map<string, GuiPulseWorkerActivityEvent[]>();
  for (const event of events) {
    const key = keyFor(event);
    groups.set(key, [...(groups.get(key) ?? []), event]);
  }
  return groups;
}

function evidenceRefs(events: GuiPulseWorkerActivityEvent[]): string[] {
  return events
    .flatMap(
      (event) =>
        [event.repo_ref, event.issue_ref, event.pull_request_ref, event.worker_session_ref, event.command_job_ref].filter(
          Boolean,
        ) as string[],
    )
    .slice(0, 8);
}

function hasPressure(resource: GuiPulseResourceSnapshot): boolean {
  return resource.pressure === "medium" || resource.pressure === "high";
}

function sumCost(records: MetricRecord[]): number {
  return records.reduce((sum, record) => sum + (numberValue(record.estimated_cost_usd ?? record.cost_usd) ?? 0), 0);
}
