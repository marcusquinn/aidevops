import type { GuiAppActionJobSummary } from "@aidevops/gui-shared";
import { type ReactElement, type ReactNode, useEffect, useRef } from "react";
import { FiX } from "react-icons/fi";

const ANSI_PATTERN = /\x1b\[([0-9;]*)m/g;

export function AppActionTerminal({ job, onDismiss }: { job: GuiAppActionJobSummary; onDismiss: (jobId: string) => void }): ReactElement {
  const outputRef = useRef<HTMLPreElement | null>(null);

  useEffect(() => {
    if (outputRef.current !== null) {
      outputRef.current.scrollTop = outputRef.current.scrollHeight;
    }
  }, [job.output.length]);

  return (
    <section className="app-terminal" id={`app-job-${job.id}`} aria-label="App action terminal output">
      <header><strong>{job.app_id} {job.action}</strong><span>{terminalStatusLabel(job)}</span><button aria-label={`Dismiss ${job.app_id} ${job.action} terminal output`} className="terminal-close-button" onClick={() => onDismiss(job.id)} title="Dismiss terminal output" type="button"><FiX aria-hidden="true" /></button></header>
      <pre ref={outputRef}>{renderTerminalOutput(job.output)}</pre>
    </section>
  );
}

function terminalStatusLabel(job: GuiAppActionJobSummary): string {
  if (job.status === "running") {
    return "running";
  }
  if (job.exit_code === null) {
    return job.status;
  }
  return `${job.status} · exit ${job.exit_code}`;
}

function renderTerminalOutput(lines: string[]): ReactNode[] {
  return lines.flatMap((line, index) => [
    ...renderAnsiLine(line, `line-${index}`),
    index === lines.length - 1 ? null : "\n",
  ]).filter((node): node is ReactNode => node !== null);
}

function renderAnsiLine(line: string, keyPrefix: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  ANSI_PATTERN.lastIndex = 0;
  let activeClass = "";
  let lastIndex = 0;
  let match = ANSI_PATTERN.exec(line);

  while (match !== null) {
    if (match.index > lastIndex) {
      nodes.push(terminalSpan(line.slice(lastIndex, match.index), activeClass, `${keyPrefix}-${nodes.length}`));
    }
    activeClass = ansiClassForCodes(match[1]);
    lastIndex = ANSI_PATTERN.lastIndex;
    match = ANSI_PATTERN.exec(line);
  }

  if (lastIndex < line.length) {
    nodes.push(terminalSpan(line.slice(lastIndex), activeClass, `${keyPrefix}-${nodes.length}`));
  }

  if (nodes.length === 0) {
    nodes.push(terminalSpan(line, activeClass, `${keyPrefix}-0`));
  }

  return nodes;
}

function terminalSpan(textValue: string, className: string, key: string): ReactNode {
  const promptClass = textValue.startsWith("$ ") ? "ansi-prompt" : "";
  const combinedClass = [className, promptClass].filter(Boolean).join(" ");
  return combinedClass.length > 0 ? <span className={combinedClass} key={key}>{textValue}</span> : textValue;
}

function ansiClassForCodes(rawCodes: string): string {
  const codes = rawCodes.length === 0 ? [0] : rawCodes.split(";").map((code) => Number.parseInt(code, 10));
  const colorCode = [...codes].reverse().find((code) => (code >= 30 && code <= 37) || (code >= 90 && code <= 97));
  if (colorCode === undefined) {
    return "";
  }
  return `ansi-fg-${colorCode}`;
}
