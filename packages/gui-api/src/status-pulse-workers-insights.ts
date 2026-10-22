import type { GuiPulseResourceSnapshot, GuiPulseSystemicFinding, GuiPulseWorkerActivityEvent } from "../../gui-shared/src";
import { type MetricRecord, numberValue } from "./status-pulse-workers-values";

const DEFAULT_SCOPE = "local aidevops telemetry";
const SLOW_EVENT_MS = 1_800_000;

type Finding = GuiPulseSystemicFinding;
type PulseEvent = GuiPulseWorkerActivityEvent;

function finding(...args: [string, Finding["kind"], Finding["severity"], string, string, string, PulseEvent[], string, string, number, Finding["confidence"], string?]): Finding {
  const [id, kind, severity, title, detail, likelyCause, events, recommendation, metricLabel, sampleSize, confidence, comparisonLabel = "selected period scoped to active filters"] = args;
  return { id: `insight-${id.replace(/[^a-z0-9-]+/gi, "-").toLowerCase()}`, kind, severity, title, detail, likely_cause: likelyCause, evidence_refs: evidenceRefs(events), event_refs: events.map((event) => event.id).slice(0, 6), confidence, recommendation, metric_label: metricLabel, period_label: "Last 24h", scope_label: DEFAULT_SCOPE, comparison_label: comparisonLabel, sample_size: sampleSize, primary_action: "create_systemic_fix" };
}

function groupEvents(events: PulseEvent[], keyFor: (event: PulseEvent) => string): Map<string, PulseEvent[]> {
  const groups = new Map<string, PulseEvent[]>();
  for (const event of events) {
    const key = keyFor(event);
    groups.set(key, [...(groups.get(key) ?? []), event]);
  }
  return groups;
}

function evidenceRefs(events: PulseEvent[]): string[] {
  return events.flatMap((event) => [event.repo_ref, event.issue_ref, event.pull_request_ref, event.worker_session_ref, event.command_job_ref].filter(Boolean) as string[]).slice(0, 8);
}

function sumCost(records: MetricRecord[]): number {
  return records.reduce((sum, record) => sum + (numberValue(record.estimated_cost_usd ?? record.cost_usd) ?? 0), 0);
}

function isElevated(resource: GuiPulseResourceSnapshot): boolean {
  return resource.pressure === "medium" || resource.pressure === "high";
}

function isFailedOrBlocked(event: PulseEvent): boolean {
  return event.outcome === "failed" || event.outcome === "blocked";
}

function thirdPartyWaitingFinding(events: PulseEvent[]): Finding[] {
  const waiting = events.filter((event) => event.issue_origin === "third_party" && (event.outcome === "needs_maintainer_review" || event.outcome === "blocked" || event.outcome === "in_progress"));
  if (waiting.length === 0) {
    return [];
  }
  return [finding("third-party-waiting", "third_party_waiting", "warning", "Third-party issues waiting", `${waiting.length} community-origin issue events need triage or resolution in the selected period.`, "Community reports are separated from aidevops-created task handling and may need a maintainer decision before dispatch.", waiting, "Create a systemic triage task that preserves non-collaborator trust boundaries and adds first-response thresholds.", "community waiting count", waiting.length, "high")];
}

function repeatedFailureFindings(events: PulseEvent[]): Finding[] {
  const failedOrBlocked = events.filter(isFailedOrBlocked);
  const groups = groupEvents(failedOrBlocked, (event) => [event.repo_ref ?? "repo:unknown", event.usage?.provider ?? "provider:unknown", event.resources[0]?.kind ?? "resource:unknown"].join("|"));
  const findings: Finding[] = [];
  for (const [key, group] of groups) {
    if (group.length > 1) {
      findings.push(finding(`repeated-${key}`, "repeated_failure", "critical", "Repeated failure pattern", `${group.length} failed or blocked runs share repo/provider/resource context.`, "A repeated worker blindspot is likely being retried as individual failures instead of being converted into a shared guardrail or helper fix.", group, "Create a systemic fix task with grouped evidence, affected repo/provider/resource, and a focused verification command.", key.replaceAll("|", " · "), group.length, "medium"));
    }
  }
  return findings;
}

function weakVerificationFinding(events: PulseEvent[]): Finding[] {
  const weak = events.filter((event) => event.drilldown_sections.some((section) => section.label === "Verification" && /missing|weak|not recorded/i.test(section.body)));
  if (weak.length === 0) {
    return [];
  }
  return [finding("weak-verification", "weak_verification", "warning", "No-verification outcomes", `${weak.length} events lack strong verification metadata.`, "Workers may be completing or blocking without durable command evidence in the telemetry stream.", weak, "Create a systemic fix task to require verification command capture in worker outcome records.", "verification coverage", weak.length, "medium")];
}

function resourcePressureFinding(events: PulseEvent[], resources: GuiPulseResourceSnapshot[]): Finding[] {
  const pressureEvents = events.filter((event) => event.resources.some(isElevated));
  if (pressureEvents.length === 0 && !resources.some(isElevated)) {
    return [];
  }
  const severity = resources.some((resource) => resource.pressure === "high") ? "critical" : "warning";
  return [finding("resource-pressure", "resource_pressure", severity, "Resource allowance pressure", `${pressureEvents.length} events overlapped medium/high resource pressure; ${resources.length} resource samples are in scope.`, "Provider quota, GitHub API, queue, CI, or local resource pressure can inflate retry cost and slow dispatch-to-merge cycles.", pressureEvents, "Create a systemic capacity task that records allowance snapshots before redispatching failed workers.", "resource pressure", Math.max(pressureEvents.length, resources.length), "medium")];
}

function costFindings(events: PulseEvent[], dayMetrics: MetricRecord[], previousDayMetrics: MetricRecord[]): Finding[] {
  const currentCost = sumCost(dayMetrics);
  const previousCost = sumCost(previousDayMetrics);
  const failedCostEvents = events.filter((event) => isFailedOrBlocked(event) && event.usage?.estimated_cost_ref != null);
  if (currentCost > 0 && previousCost > 0 && currentCost >= previousCost * 1.5) {
    return [finding("cost-spike", "cost_spike", "warning", "Cost spike versus previous period", `Estimated selected-period cost is ${currentCost.toFixed(2)} versus ${previousCost.toFixed(2)} in the previous equivalent window.`, "Retry loops or expensive models may be consuming allowance faster than successful outcomes justify.", events, "Create a systemic cost-control task that ties model/provider selection to outcome quality and retry count.", "estimated USD", dayMetrics.length, "medium", `previous equivalent period: ${previousCost.toFixed(2)}`)];
  }
  if (failedCostEvents.length > 0) {
    return [finding("failed-run-cost", "high_retry_cost", "warning", "Failed-run cost attached to outcomes", `${failedCostEvents.length} failed or blocked events include token/cost metadata.`, "Cost is being spent on outcomes that did not merge, close, defer, or create follow-up work.", failedCostEvents, "Create a systemic retry-budget task that escalates or changes strategy before another costly rerun.", "failed-run cost samples", failedCostEvents.length, "medium")];
  }
  return [];
}

function slowBottleneckFinding(events: PulseEvent[]): Finding[] {
  const slow = events.filter((event) => (event.duration_ms ?? 0) >= SLOW_EVENT_MS);
  if (slow.length === 0) {
    return [];
  }
  return [finding("slow-bottlenecks", "slow_bottleneck", "warning", "Slow dispatch-to-outcome bottlenecks", `${slow.length} events exceeded 30 minutes.`, "Long-running dispatch, review, or merge gates can hide queue/concurrency or CI runner bottlenecks.", slow, "Create a systemic bottleneck task that separates dispatch-to-PR and PR-to-merge timing evidence.", "duration >=30m", slow.length, "medium")];
}

export function buildInsights(events: PulseEvent[], dayMetrics: MetricRecord[], previousDayMetrics: MetricRecord[], resources: GuiPulseResourceSnapshot[]): Finding[] {
  return [
    ...thirdPartyWaitingFinding(events),
    ...repeatedFailureFindings(events),
    ...weakVerificationFinding(events),
    ...resourcePressureFinding(events, resources),
    ...costFindings(events, dayMetrics, previousDayMetrics),
    ...slowBottleneckFinding(events),
  ].slice(0, 8);
}
