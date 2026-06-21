import { useState } from "react";
import { appRows, installationRows, text, type InventorySurfaceDefinition } from "./app-model";

export function AppsSurface() {
  return (
    <section className="panel" aria-label={text.apps}>
      <div className="section-heading">
        <p className="eyebrow">{text.inventory}</p>
        <h2>{text.apps}</h2>
        <p>{text.appsIntro}</p>
      </div>
      <div className="data-table">
        <div className="data-row header-row"><span>{text.name}</span><span>{text.latest}</span><span>{text.channel}</span><span>{text.website}</span></div>
        {appRows.map((row) => (
          <div className="data-row" key={row.name}><span>{row.name}</span><span>{row.latest}</span><span>{row.channel}</span><span>{row.website}</span></div>
        ))}
      </div>
    </section>
  );
}

export function InstallationSurface() {
  return (
    <section className="panel" aria-label={text.installation}>
      <div className="section-heading">
        <p className="eyebrow">{text.setup}</p>
        <h2>{text.installation}</h2>
        <p>{text.installationIntro}</p>
      </div>
      <div className="installation-list">
        {installationRows.map((row) => (
          <article className="install-row" key={row.name}>
            <div><strong>{row.name}</strong><small>{row.scope}</small></div>
            <TogglePill checked={row.install} label={text.install} />
            <TogglePill checked={row.update} label={text.update} />
          </article>
        ))}
      </div>
      <p className="empty-state">{text.plannedNotice}</p>
    </section>
  );
}

export function EditableInventorySurface({ definition }: { definition: InventorySurfaceDefinition }) {
  const [draftRows, setDraftRows] = useState(definition.initialRows);

  function updateDraftRow(rowIndex: number, key: string, value: string): void {
    setDraftRows((currentRows) => currentRows.map((row, index) => index === rowIndex ? { ...row, [key]: value } : row));
  }

  function addDraftRow(): void {
    setDraftRows((currentRows) => [...currentRows, emptyRow(definition)]);
  }

  return (
    <section className="panel" aria-label={definition.title}>
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{text.inventory}</p>
          <h2>{definition.title}</h2>
          <p>{definition.intro}</p>
        </div>
        <button className="secondary-action" onClick={addDraftRow} type="button">{text.addRow}</button>
      </div>
      <p className="notice compact-notice">{text.draftOnly}</p>
      <div className="editable-table">
        <div className="editable-row header-row">
          {definition.columns.map((column) => <span key={column.key}>{column.label}</span>)}
        </div>
        {draftRows.map((row, rowIndex) => (
          <div className="editable-row" key={`${definition.title}:${rowIndex}`}>
            {definition.columns.map((column) => (
              <input
                aria-label={`${definition.title} ${column.label}`}
                key={column.key}
                onChange={(event) => updateDraftRow(rowIndex, column.key, event.currentTarget.value)}
                placeholder={column.label}
                value={row[column.key] ?? ""}
              />
            ))}
          </div>
        ))}
      </div>
    </section>
  );
}

function TogglePill({ checked, label }: { checked: boolean; label: string }) {
  return <span className={checked ? "toggle-pill checked" : "toggle-pill"}>{label}</span>;
}

function emptyRow(definition: InventorySurfaceDefinition): Record<string, string> {
  const row: Record<string, string> = {};
  for (const column of definition.columns) {
    row[column.key] = "";
  }

  return row;
}
