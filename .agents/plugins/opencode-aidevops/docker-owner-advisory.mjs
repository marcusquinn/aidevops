// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
// Advisory-only literal Docker parsing, not a command permission boundary.
import { unquotedTokens } from "./quality-hooks-signature-shell-words.mjs";

const dockerAdvisedSessions = new Set();
const dockerAdvisoryCalls = new Set();
const DOCKER_ADVISORY = "Docker test resources need owner labels: use docker-resource-helper.sh labels / compose-labels; see tools/containers/disposable-resources.md. Advisory only; user-owned stacks are unchanged.";

export function appendDockerAdvisory(input, output) {
  if (dockerAdvisoryCalls.delete(input.callID)) {
    output.output = `${output.output || ""}\n\n${DOCKER_ADVISORY}`;
  }
}

export function adviseDockerCreation(log, input, command, sessionId) {
  if (!input.callID || !sessionId || dockerAdvisedSessions.has(sessionId)
    || !needsDockerOwnerAdvisory(command)) return;
  dockerAdvisedSessions.add(sessionId);
  dockerAdvisoryCalls.add(input.callID);
  log("WARN", DOCKER_ADVISORY);
}

const GLOBAL_VALUES = new Set(["--config", "--context", "-c", "--host", "-H", "--log-level", "-l", "--tlscacert", "--tlscert", "--tlskey"]);
const BOOLEAN_OPTIONS = new Set(["--detach", "--interactive", "--tty", "--init", "--privileged", "--read-only", "--publish-all", "--oom-kill-disable", "--sig-proxy", "--use-api-socket", "--help", "--internal", "--attachable", "--ingress", "--ipv6", "--config-only", "-q", "--quiet", "--no-healthcheck"]);

function creationArgs(words) {
  let index = 0;
  while (index < words.length && words[index].startsWith("-")) {
    const option = words[index].split("=")[0];
    index += GLOBAL_VALUES.has(option) && !words[index].includes("=") ? 2 : 1;
  }
  let args = words.slice(index);
  if (args[0] === "container") args = args.slice(1);
  if (["network", "volume"].includes(args[0]) && args[1] === "create") args = args.slice(1);
  return args;
}

function optionValue(args, index) {
  const token = args[index];
  const equal = token.indexOf("=");
  if (equal !== -1) return [token.slice(0, equal), token.slice(equal + 1), index];
  if (["--label", "-l"].includes(token)) return [token, args[index + 1] ?? "", index + 1];
  const takesValue = token !== "--rm" && !BOOLEAN_OPTIONS.has(token) && !/^-[ditP]+$/.test(token);
  return [token, "true", index + Number(takesValue)];
}

function creationHasOwner(args) {
  let owner = false;
  let remove = false;
  for (let index = 1; index < args.length; index++) {
    if (!args[index].startsWith("-") || args[index] === "--") break;
    const [option, value, consumed] = optionValue(args, index);
    index = consumed;
    if (option === "--rm") remove = value === "true";
    if (["--label", "-l"].includes(option) && value.startsWith("sh.aidevops.owner=")) {
      owner = value === "sh.aidevops.owner=1";
    }
  }
  return owner || (args[0] === "run" && remove);
}

function dockerCreationNeedsOwner(words) {
  // Expansions and Compose config may supply ownership labels externally.
  if (words.some((word) => /[$`]/.test(word))) return false;
  const args = creationArgs(words);
  return ["run", "create"].includes(args[0]) && !creationHasOwner(args);
}

function nextQuote(quote, char) {
  if (quote) return char === quote ? "" : quote;
  return ['"', "'"].includes(char) ? char : "";
}

function dockerShellParts(command) {
  const parts = [];
  let part = "";
  let quote = "";
  for (let index = 0; index < command.length; index++) {
    const char = command[index];
    if (char === "\\" && quote !== "'" && index + 1 < command.length) {
      const following = command[++index];
      if (following !== "\n") part += char + following;
      continue;
    }
    if (!quote && /[;&|\n]/.test(char)) {
      parts.push(part);
      part = "";
      continue;
    }
    quote = nextQuote(quote, char);
    part += char;
  }
  parts.push(part);
  return parts;
}

export function needsDockerOwnerAdvisory(command) {
  return dockerShellParts(String(command)).some((part) => {
    const match = part.match(/(?:^|\s)docker\s+([\s\S]+)/);
    if (!match) return false;
    return dockerCreationNeedsOwner(unquotedTokens(match[1]).map(({ text }) => text));
  });
}
