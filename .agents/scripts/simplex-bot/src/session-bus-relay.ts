/** Correlated SimpleX sends; only confirmed delivery may clear the outbox. */
import { redactLeaks, scanForLeaks } from "./leak-detector";
import type { BotConfig } from "./types";

interface RelayDependencies {
  socket: WebSocket | null;
  pending: Map<string, (ok: boolean) => void>;
  nextCorrelationId: () => string;
  redact: (text: string) => string;
  leakDetection: BotConfig["leakDetection"];
}

/** Send by numeric chat reference and wait for its correlated response. */
export async function sendRelayMessage(channel: string, text: string, deps: RelayDependencies): Promise<void> {
  const ws = deps.socket;
  if (!ws || ws.readyState !== WebSocket.OPEN) throw new Error("SimpleX disconnected");
  const target = `${channel[0] === "c" ? "@" : "#"}${channel.slice(1)}`;
  // Group replies are scanned even when optional DM scanning is disabled.
  const scan = channel[0] === "g" ? scanForLeaks(text, deps.leakDetection) : null;
  const safeText = scan?.hasLeaks ? redactLeaks(text, scan) : deps.redact(text);
  const content = [{ msgContent: { type: "text", text: safeText }, mentions: {} }];
  const corrId = deps.nextCorrelationId();
  const ok = await new Promise<boolean>((resolve) => {
    const timer = setTimeout(() => { deps.pending.delete(corrId); resolve(false); }, 30000);
    deps.pending.set(corrId, value => { clearTimeout(timer); resolve(value); });
    try { ws.send(JSON.stringify({ corrId, cmd: `/_send ${target} json ${JSON.stringify(content)}` })); }
    catch { deps.pending.delete(corrId); clearTimeout(timer); resolve(false); }
  });
  if (!ok) throw new Error("SimpleX send was not confirmed");
}
