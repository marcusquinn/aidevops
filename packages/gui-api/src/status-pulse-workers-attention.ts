import type { GuiPulseResourceSnapshot, GuiPulseWorkerSummary } from "../../gui-shared/src";
import { hasAvailableProvider } from "./status-pulse-workers-classifiers";
import { slug } from "./status-pulse-workers-values";

interface SourceState {
  path_ref: string;
  health: "present" | "missing" | "invalid";
  observed_at: string;
}

export function buildAttention(sources: SourceState[], counters: Record<string, number>, resources: GuiPulseResourceSnapshot[], oauthPool: Record<string, unknown>): GuiPulseWorkerSummary["attention"] {
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
