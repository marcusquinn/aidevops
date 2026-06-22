import { existsSync, readFileSync, realpathSync } from "node:fs";
import { join } from "node:path";

export function readJsonObject(pathName: string): { health: "present" | "missing" | "invalid"; value: Record<string, unknown> } {
  if (!existsSync(pathName)) {
    return { health: "missing", value: {} };
  }

  try {
    const parsed = JSON.parse(readFileSync(pathName, "utf8"));
    return isRecord(parsed) ? { health: "present", value: parsed } : { health: "invalid", value: {} };
  } catch {
    return { health: "invalid", value: {} };
  }
}

export function safeRealpath(pathName: string): string | null {
  try {
    return realpathSync(pathName);
  } catch {
    return null;
  }
}

export function collapseHome(pathName: string): string {
  const home = process.env.HOME ?? "";
  if (home.length > 0 && pathName === home) {
    return "~";
  }
  if (home.length > 0 && pathName.startsWith(`${home}/`)) {
    return `~/${pathName.slice(home.length + 1)}`;
  }
  return pathName;
}

export function booleanField(value: Record<string, unknown>, key: string): boolean | null {
  const field = value[key];
  return typeof field === "boolean" ? field : null;
}

export function numberField(value: Record<string, unknown>, key: string): number | null {
  const field = value[key];
  return typeof field === "number" && Number.isFinite(field) ? field : null;
}

export function featureList(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value.filter((entry): entry is string => typeof entry === "string" && entry.length > 0).sort();
  }
  if (typeof value === "string" && value.length > 0) {
    return value.split(",").map((entry) => entry.trim()).filter(Boolean).sort();
  }
  if (isRecord(value)) {
    return Object.entries(value)
      .filter(([, enabled]) => enabled === true)
      .map(([feature]) => feature)
      .sort();
  }
  return [];
}

export function formatNullableEpochField(value: unknown): string | null {
  if (value === null || value === undefined || value === 0) {
    return null;
  }
  return formatEpochField(value);
}

export function formatEpochField(value: unknown): string {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    return "unknown";
  }
  const millis = value > 9_999_999_999 ? value : value * 1000;
  return new Date(millis).toISOString();
}

export function cooldownReady(cooldownUntil: string | null, now: number): boolean {
  if (cooldownUntil === null) {
    return true;
  }
  const parsed = Date.parse(cooldownUntil);
  return Number.isNaN(parsed) || parsed <= now;
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function stringField(value: Record<string, unknown>, key: string): string | undefined {
  const field = value[key];
  return typeof field === "string" && field.length > 0 ? field : undefined;
}

export function expandHome(pathRef: string): string {
  if (!pathRef.startsWith("~/")) {
    return pathRef;
  }

  return join(process.env.HOME ?? "", pathRef.slice(2));
}

export function readOptionalText(pathName: string): string | null {
  if (!existsSync(pathName)) {
    return null;
  }

  return readFileSync(pathName, "utf8").trim();
}
