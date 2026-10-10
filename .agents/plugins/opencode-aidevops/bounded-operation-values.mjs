// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { basename } from "node:path";

const SHELL_INTERPRETERS = new Set(["bash", "sh", "zsh", "dash", "ksh"]);
const DETACHING_PULSE_COMMANDS = new Set(["dispatch", "dispatch-foss"]);

// Reaches the launched program's argv through a leading
// `env [-i] [-u NAME] [--] [NAME=value]...` and a direct `bash script.sh` form.
function launchedArgv(command) {
  let argv = command;
  if (basename(argv[0]) === "env") {
    let index = 1;
    while (index < argv.length) {
      const part = argv[index];
      if (part === "-u" || part === "--unset") {
        index += 2;
      } else if (part === "--") {
        index += 1;
        break;
      } else if (part.startsWith("-") || part.includes("=")) {
        index += 1;
      } else {
        break;
      }
    }
    argv = argv.slice(index);
  }
  if (argv.length > 1 && SHELL_INTERPRETERS.has(basename(argv[0])) && !argv[1].startsWith("-")) {
    argv = argv.slice(1);
  }
  return argv;
}

// GH#34047: worker dispatch intentionally detaches a long-lived worker, while
// this tool drains every owned descendant when its command exits. Reject the
// known detaching launchers before spawn so no claim or worker is created.
// Unknown wrappers (for example `bash -c`) remain visible through the
// post_exit_descendants_terminated receipt field instead.
export function detachingLauncherError(command) {
  const argv = launchedArgv(command);
  if (argv.length === 0 || basename(argv[0]) !== "pulse-wrapper.sh") return "";
  const commandIndex = argv.indexOf("--command");
  const subcommand = commandIndex >= 0 ? argv[commandIndex + 1] : "";
  if (!DETACHING_PULSE_COMMANDS.has(subcommand)) return "";
  return `pulse-wrapper.sh --command ${subcommand} launches a detached worker that bounded operations would drain on exit; ` +
    "run it through the normal shell tool and verify liveness through the exact-attempt worker status, not the launch exit code";
}

export function scalar(value) {
  return typeof value === "string" ? value.trim() : "";
}

export function withinRoot(path, root) {
  return path === root || path.startsWith(`${root}/`);
}

export function commandError(command) {
  if (!Array.isArray(command) || command.length === 0) return "command must be a non-empty string array";
  if (command.some((part) => typeof part !== "string" || !part || part.includes("\0"))) {
    return "command entries must be non-empty strings without NUL bytes";
  }
  if (Buffer.byteLength(JSON.stringify(command)) > 64 * 1024) return "encoded command exceeds 64 KiB";
  return detachingLauncherError(command);
}

export function boundedInteger(value, fallback, minimum, maximum) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(minimum, Math.min(maximum, Math.floor(parsed)));
}

export function canTerminate(operation) {
  if (!operation.child) return false;
  if (operation.childExited) return false;
  if (operation.child.exitCode !== null) return false;
  if (operation.child.signalCode !== null) return false;
  return ["running", "starting"].includes(operation.state);
}
