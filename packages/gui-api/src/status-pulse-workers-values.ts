import type { GuiPulseWorkerOutcome } from "../../gui-shared/src";

export type MetricRecord = Record<string, unknown>;

const TIME_FIELDS = ["ts", "timestamp", "started_at", "finished_at", "created_at", "updated_at"];

export function recordTimeMs(record: MetricRecord): number | null {
  for (const key of TIME_FIELDS) {
    const parsed = timeValueMs(record[key]);
    if (parsed !== null) return parsed;
  }
  return null;
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

export function countOptions(values: string[], prefix = ""): Array<{ id: string; label: string; count: number }> {
  const counts = new Map<string, number>();
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1);
  return [...counts.entries()].map(([label, count]) => ({ id: `${prefix}${slug(label)}`, label, count })).sort((a, b) => b.count - a.count || a.label.localeCompare(b.label));
}

export function costRef(record: MetricRecord): string | null {
  const cost = record.estimated_cost_ref ?? record.cost_ref;
  if (typeof cost === "string" && cost.length > 0 && !cost.includes("/")) return cost;
  const amount = numberValue(record.estimated_cost_usd ?? record.cost_usd);
  return amount === null ? null : `$${amount.toFixed(2)} estimated`;
}

export function stringOrNumber(value: unknown): string | null {
  if (typeof value === "string" && value.length > 0) return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return null;
}

export function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

export function slug(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "unknown";
}

function timeValueMs(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value > 9_999_999_999 ? value : value * 1000;
  if (typeof value !== "string" || value.length === 0) return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}
