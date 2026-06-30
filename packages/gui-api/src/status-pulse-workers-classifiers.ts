import {
  type GuiPulseAuthorAssociation,
  type GuiPulseIssueOrigin,
  type GuiPulseProviderId,
  type GuiPulseWorkerOutcome,
  type GuiPulseWorkerSeverity,
  type GuiPulseWorkerStatus,
} from "../../gui-shared/src";

type MetricRecord = Record<string, unknown>;

const KNOWN_WORKER_OUTCOMES = new Set<GuiPulseWorkerOutcome>(["merged", "closed", "in_progress", "needs_maintainer_review", "blocked", "failed", "deferred", "created_followup"]);
const HEALTHY_WORKER_OUTCOMES = new Set<GuiPulseWorkerOutcome>(["merged", "closed", "deferred", "created_followup"]);
const OUTCOME_MATCHERS: Array<{ pattern: RegExp; outcome: GuiPulseWorkerOutcome }> = [
  { pattern: /success|complete/, outcome: "merged" },
  { pattern: /follow/, outcome: "created_followup" },
  { pattern: /defer/, outcome: "deferred" },
  { pattern: /block/, outcome: "blocked" },
  { pattern: /fail|kill/, outcome: "failed" },
];
const KNOWN_ISSUE_ORIGINS = new Set<GuiPulseIssueOrigin>(["aidevops_created", "maintainer_created", "origin_interactive", "third_party", "unknown"]);
const ISSUE_ORIGIN_MATCHERS: Array<{ pattern: RegExp; origin: GuiPulseIssueOrigin }> = [
  { pattern: /interactive/, origin: "origin_interactive" },
  { pattern: /third|community/, origin: "third_party" },
  { pattern: /maintainer/, origin: "maintainer_created" },
  { pattern: /aidevops/, origin: "aidevops_created" },
];
const STATUS_BY_OUTCOME: Partial<Record<GuiPulseWorkerOutcome, GuiPulseWorkerStatus>> = {
  failed: "failed",
  blocked: "blocked",
  needs_maintainer_review: "blocked",
  in_progress: "running",
  deferred: "deferred",
};
const SEVERITY_BY_STATUS: Partial<Record<GuiPulseWorkerStatus, GuiPulseWorkerSeverity>> = {
  failed: "critical",
  blocked: "critical",
  attention: "warning",
  deferred: "warning",
  completed: "success",
  healthy: "success",
};
const KNOWN_AUTHOR_ASSOCIATIONS = new Set<GuiPulseAuthorAssociation>(["OWNER", "MEMBER", "COLLABORATOR", "CONTRIBUTOR", "FIRST_TIME_CONTRIBUTOR", "NONE", "UNKNOWN"]);
const KNOWN_PROVIDER_IDS = new Set<GuiPulseProviderId>(["anthropic", "openai", "cursor", "google", "local"]);

export function outcomeFromRecord(record: MetricRecord): GuiPulseWorkerOutcome {
  const raw = String(record.outcome ?? record.result ?? record.status ?? "in_progress").toLowerCase();
  if (KNOWN_WORKER_OUTCOMES.has(raw as GuiPulseWorkerOutcome)) {
    return raw as GuiPulseWorkerOutcome;
  }
  return OUTCOME_MATCHERS.find((matcher) => matcher.pattern.test(raw))?.outcome ?? "in_progress";
}

export function statusFromOutcome(outcome: GuiPulseWorkerOutcome): GuiPulseWorkerStatus {
  return STATUS_BY_OUTCOME[outcome] ?? "completed";
}

export function severityFromStatus(status: GuiPulseWorkerStatus): GuiPulseWorkerSeverity {
  return SEVERITY_BY_STATUS[status] ?? "info";
}

export function isHealthyOutcome(outcome: GuiPulseWorkerOutcome): boolean {
  return HEALTHY_WORKER_OUTCOMES.has(outcome);
}

export function issueOriginFromRecord(record: MetricRecord): GuiPulseIssueOrigin {
  const raw = String(record.issue_origin ?? record.origin ?? "unknown").toLowerCase();
  if (KNOWN_ISSUE_ORIGINS.has(raw as GuiPulseIssueOrigin)) return raw as GuiPulseIssueOrigin;
  return ISSUE_ORIGIN_MATCHERS.find((matcher) => matcher.pattern.test(raw))?.origin ?? "unknown";
}

export function authorAssociationFromRecord(record: MetricRecord): GuiPulseAuthorAssociation {
  const raw = String(record.author_association ?? "UNKNOWN").toUpperCase();
  if (KNOWN_AUTHOR_ASSOCIATIONS.has(raw as GuiPulseAuthorAssociation)) return raw as GuiPulseAuthorAssociation;
  return "UNKNOWN";
}

export function hasAvailableProvider(record: MetricRecord): boolean {
  const providers = Array.isArray(record.providers) ? record.providers : [];
  return providers.some((provider) => providerAvailability(provider) > 0);
}

function providerAvailability(provider: unknown): number {
  const record = providerRecord(provider);
  const available = record?.available;
  return typeof available === "number" && Number.isFinite(available) ? available : 0;
}

function providerRecord(value: unknown): MetricRecord | null {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return null;
  return value as MetricRecord;
}

export function providerFromString(value: string | undefined): GuiPulseProviderId {
  if (KNOWN_PROVIDER_IDS.has(value as GuiPulseProviderId)) return value as GuiPulseProviderId;
  return "unknown";
}
