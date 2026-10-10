// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
import { existsSync, realpathSync } from "node:fs";
import { resolve } from "node:path";
import { activeLocalOnlyPolicy, isLoopbackDestination } from "./local-only-policy.mjs";
import { secretPathBlockReason } from "./quality-hooks-secret-read.mjs";

// #aidevops:trust-boundary — fixed system paths, never model-controlled PATH.
export const LOCAL_ONLY_CURL = existsSync("/usr/bin/curl")
  ? "/usr/bin/curl" : "/run/current-system/sw/bin/curl";

function curlArgv(url) {
  return [LOCAL_ONLY_CURL, "--disable", "--noproxy", "*", "--proxy", "", "--max-time", "30", "--url", url];
}

export function isLocalOnlyCurlArgv(argv) {
  if (!Array.isArray(argv) || argv.length !== 10) return false;
  if (!curlArgv(argv[9]).every((part, index) => argv[index] === part)) return false;
  const url = argv[9];
  if (typeof url !== "string" || !/^[a-zA-Z0-9:/?&=._%+\[\]-]+$/.test(url)) return false;
  return isLoopbackDestination(url);
}

function canonicalLocalCurl(argv) {
  if (!Array.isArray(argv) || argv.length !== 2 || argv[0] !== "curl") return argv;
  const canonical = curlArgv(argv[1]);
  return isLocalOnlyCurlArgv(canonical) ? canonical : argv;
}

function safeLocalReadPath(args, path) {
  try {
    const absolute = resolve(args.workdir || args.cwd || process.cwd(), path);
    return !secretPathBlockReason(absolute) && !secretPathBlockReason(realpathSync(absolute));
  } catch {
    return false;
  }
}

function canonicalLocalRead(args) {
  const match = /^(cat|head|tail|wc|ls|stat) ([a-zA-Z0-9_./-]+)$/.exec(args.command || "");
  if (!match || match[2].startsWith("-")) return false;
  if (!safeLocalReadPath(args, match[2])) return false;
  const executable = ["/usr/bin", "/bin", "/run/current-system/sw/bin"]
    .map((root) => `${root}/${match[1]}`).find((path) => existsSync(path));
  if (!executable) return false;
  args.command = `${executable} -- '${match[2]}'`;
  return true;
}

// Opaque programs cannot be proven non-networking. Preserve literal readers,
// otherwise accept only config/proxy-free nonredirecting loopback curl.
export function canonicalizeLocalOnlyShell(args) {
  if (canonicalLocalRead(args)) return true;
  const simple = /^curl (?:'([^']+)'|([a-zA-Z0-9:/?=._%+\[\]-]+))$/.exec(args.command || "");
  if (simple && isLocalOnlyCurlArgv(curlArgv(simple[1] || simple[2]))) {
    args.command = `${LOCAL_ONLY_CURL} --disable --noproxy '*' --proxy '' --max-time 30 --url '${simple[1] || simple[2]}'`;
  }
  const match = /^(\/usr\/bin\/curl|\/run\/current-system\/sw\/bin\/curl) --disable --noproxy '\*' --proxy '' --max-time 30 --url '([^']+)'$/.exec(args.command || "");
  return Boolean(match) && match[1] === LOCAL_ONLY_CURL && isLocalOnlyCurlArgv(curlArgv(match[2]));
}

export function canonicalizeLocalOnlyOperation(args) {
  if (["status", "output", "cancel"].includes(args.action)) return true;
  if (args.action !== "start") return false;
  args.command = canonicalLocalCurl(args.command);
  if (args.restoration_command) args.restoration_command = canonicalLocalCurl(args.restoration_command);
  return isLocalOnlyCurlArgv(args.command)
    && (!args.restoration_command || isLocalOnlyCurlArgv(args.restoration_command));
}

const OTEL_ENDPOINTS = ["OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
  "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"];
export function projectLocalOnlyShellEnvironment(env) {
  if (!activeLocalOnlyPolicy().bound) return;
  env.AIDEVOPS_RUNTIME_POLICY = "local-only";
  env.OTEL_SDK_DISABLED = "true";
  env.OTEL_TRACES_EXPORTER = "none";
  env.OTEL_METRICS_EXPORTER = "none";
  env.OTEL_LOGS_EXPORTER = "none";
  const remote = OTEL_ENDPOINTS.some((key) => (env[key] || process.env[key])
    && !isLoopbackDestination(env[key] || process.env[key]));
  if (remote) {
    for (const key of [...OTEL_ENDPOINTS, "OTEL_EXPORTER_OTLP_HEADERS", "OTEL_EXPORTER_OTLP_PROTOCOL",
      "OTEL_SERVICE_NAME", "OTEL_RESOURCE_ATTRIBUTES"]) env[key] = "";
  }
}
