import { validateTamboComponentPayload, type GuiConversationMessagePart, type GuiConversationScope, type GuiTamboValidationResult } from "../../gui-shared/src";

export function TamboConversationPart({ part, scope }: { part: GuiConversationMessagePart; scope: GuiConversationScope }) {
  const validation = validateTamboComponentPayload(part.payload_json, scope);

  if (!validation.ok) {
    return <div className="genui-card genui-card-invalid" data-genui-component={validation.component ?? "unknown"} role="note"><strong>Unsupported DevOps card</strong><small>{validation.errors.join(", ")}</small></div>;
  }

  return <DevOpsCard validation={validation} />;
}

function DevOpsCard({ validation }: { validation: GuiTamboValidationResult }) {
  const props = validation.props;
  const entries = Object.entries(props).filter(([key]) => key !== "title" && key !== "disabled");

  return (
    <section className="genui-card" data-genui-component={validation.component ?? "unknown"} aria-label={`${validation.component} DevOps card`}>
      <header>
        <p className="eyebrow">Tambo GenUI · read-only</p>
        <h3>{stringProp(props.title) ?? validation.component}</h3>
      </header>
      <dl>
        {entries.map(([key, value]) => <CardProperty key={key} name={key} value={value} />)}
      </dl>
      {validation.component === "ApprovalPromptCard" ? <p className="genui-deferred">Approval execution is deferred until audited approval tooling exists.</p> : null}
    </section>
  );
}

function CardProperty({ name, value }: { name: string; value: unknown }) {
  return (
    <div>
      <dt>{name.replaceAll("_", " ")}</dt>
      <dd>{formatValue(value)}</dd>
    </div>
  );
}

function formatValue(value: unknown): string {
  if (Array.isArray(value)) {
    return value.join(", ");
  }
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  return "—";
}

function stringProp(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}
