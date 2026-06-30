import {
  type GuiPulseAuthorAssociation,
  type GuiPulseIssueOrigin,
  type GuiPulseProviderId,
  type GuiPulseWorkerOutcome,
  type GuiPulseWorkerSeverity,
  type GuiPulseWorkerStatus,
  type GuiPulseWorkerUsageSnapshot,
} from "../../gui-shared/src";
import { stringField } from "./status-adapter-utils";

export type MetricRecord = Record<string, unknown>;

const DIRECT_WORKER_OUTCOMES = new Set<string>(["merged", "closed", "in_progress", "needs_maintainer_review", "blocked", "failed", "deferred", "created_followup"]);
const WORKER_OUTCOME_KEYWORDS: Array<[string, GuiPulseWorkerOutcome]> = [["success", "merged"], ["complete", "merged"], ["follow", "created_followup"], ["defer", "deferred"], ["block", "blocked"], ["fail", "failed"], ["kill", "failed"]];
const STATUS_BY_OUTCOME: Partial<Record<GuiPulseWorkerOutcome, GuiPulseWorkerStatus>> = { failed: "failed", blocked: "blocked", needs_maintainer_review: "blocked", in_progress: "running", deferred: "deferred" };
const SEVERITY_BY_STATUS: Partial<Record<GuiPulseWorkerStatus, GuiPulseWorkerSeverity>> = { failed: "critical", blocked: "critical", attention: "warning", deferred: "warning", completed: "success", healthy: "success" };
const DIRECT_ISSUE_ORIGINS = new Set<string>(["aidevops_created", "maintainer_created", "origin_interactive", "third_party", "unknown"]);
const ISSUE_ORIGIN_KEYWORDS: Array<[string, GuiPulseIssueOrigin]> = [["interactive", "origin_interactive"], ["third", "third_party"], ["community", "third_party"], ["maintainer", "maintainer_created"], ["aidevops", "aidevops_created"]];
const DIRECT_AUTHOR_ASSOCIATIONS = new Set<string>(["OWNER", "MEMBER", "COLLABORATOR", "CONTRIBUTOR", "FIRST_TIME_CONTRIBUTOR", "NONE", "UNKNOWN"]);
const KNOWN_PROVIDER_IDS: readonly GuiPulseProviderId[] = ["anthropic", "openai", "cursor", "google", "local"];

export function filterWindow(records: MetricRecord[], nowMs: number, windowMs: number): MetricRecord[] {
  const cutoff = nowMs - windowMs;
  return records.filter((record) => {
    const time = recordTimeMs(record);
    return time !== null && time >= cutoff && time <= nowMs;
  });
}

export function recordTimeMs(record: MetricRecord): number | null {
  for (const key of ["ts", "timestamp", "started_at", "finished_at", "created_at", "updated_at"]) {
    const value = record[key];
    if (typeof value === "number" && Number.isFinite(value)) {
      return value > 9_999_999_999 ? value : value * 1000;
    }
    if (typeof value === "string" && value.length > 0) {
      const parsed = Date.parse(value);
      if (Number.isFinite(parsed)) {
        return parsed;
      }
    }
  }
  return null;
}

export function extractPulseCounters(value: Record<string, unknown>, nowMs: number, windowMs: number): Record<string, number> {
  const counters = isRecordLike(value.counters) ? value.counters : {};
  return Object.fromEntries(Object.entries(counters).map(([name, entries]) => [name, countRecentTimestamps(entries, nowMs, windowMs)]));
}

export function collectUsageSamples(records: MetricRecord[]): GuiPulseWorkerUsageSnapshot[] {
  return records.map(usageFromRecord).filter((usage): usage is GuiPulseWorkerUsageSnapshot => usage !== null);
}

export function usageFromRecord(record: MetricRecord): GuiPulseWorkerUsageSnapshot | null {
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

export function outcomeFromRecord(record: MetricRecord): GuiPulseWorkerOutcome {
  const raw = String(record.outcome ?? record.result ?? record.status ?? "in_progress").toLowerCase();
  if (DIRECT_WORKER_OUTCOMES.has(raw)) {
    return raw as GuiPulseWorkerOutcome;
  }
  const match = WORKER_OUTCOME_KEYWORDS.find(([keyword]) => raw.includes(keyword));
  return match?.[1] ?? "in_progress";
}

export function statusFromOutcome(outcome: GuiPulseWorkerOutcome): GuiPulseWorkerStatus {
  return STATUS_BY_OUTCOME[outcome] ?? "completed";
}

export function severityFromStatus(status: GuiPulseWorkerStatus): GuiPulseWorkerSeverity {
  return SEVERITY_BY_STATUS[status] ?? "info";
}

export function isHealthyOutcome(outcome: GuiPulseWorkerOutcome): boolean {
  return ["merged", "closed", "deferred", "created_followup"].includes(outcome);
}

export function issueOriginFromRecord(record: MetricRecord): GuiPulseIssueOrigin {
  const raw = String(record.issue_origin ?? record.origin ?? "unknown").toLowerCase();
  if (DIRECT_ISSUE_ORIGINS.has(raw)) return raw as GuiPulseIssueOrigin;
  const match = ISSUE_ORIGIN_KEYWORDS.find(([keyword]) => raw.includes(keyword));
  return match?.[1] ?? "unknown";
}

export function authorAssociationFromRecord(record: MetricRecord): GuiPulseAuthorAssociation {
  const raw = String(record.author_association ?? "UNKNOWN").toUpperCase();
  if (DIRECT_AUTHOR_ASSOCIATIONS.has(raw)) return raw as GuiPulseAuthorAssociation;
  return "UNKNOWN";
}

export function durationMsFromRecord(record: MetricRecord): number | null {
  const duration = numberValue(record.duration_ms ?? record.wall_time_ms);
  if (duration !== null) return duration;
  const elapsed = numberValue(record.elapsed_s);
  return elapsed === null ? null : elapsed * 1000;
}

export function summaryFromRecord(record: MetricRecord, outcome: GuiPulseWorkerOutcome): string {
  const issue = stringOrNumber(record.issue ?? record.issue_number);
  return issue === null ? `Worker outcome: ${outcome}.` : `Worker outcome for #${issue.replace(/^#/, "")}: ${outcome}.`;
}

export function stringOrNumber(value: unknown): string | null {
  if (typeof value === "string" && value.length > 0) return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return null;
}

export function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

export function hasAvailableProvider(value: Record<string, unknown>): boolean {
  const providers = Array.isArray(value.providers) ? value.providers : [];
  return providers.some((provider) => isRecordLike(provider) && (numberValue(provider.available) ?? 0) > 0);
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

function costRef(record: MetricRecord): string | null {
  const cost = record.estimated_cost_ref ?? record.cost_ref;
  if (typeof cost === "string" && cost.length > 0 && !cost.includes("/")) return cost;
  const amount = numberValue(record.estimated_cost_usd ?? record.cost_usd);
  return amount === null ? null : `$${amount.toFixed(2)} estimated`;
}

function providerFromString(value: string | undefined): GuiPulseProviderId {
  if (KNOWN_PROVIDER_IDS.includes(value as GuiPulseProviderId)) return value as GuiPulseProviderId;
  return "unknown";
}

function isRecordLike(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
