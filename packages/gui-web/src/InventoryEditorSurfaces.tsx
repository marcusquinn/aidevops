import { type ReactElement, useState } from "react";
import type { InventoryColumn } from "./app-model";
import { installationRows, text } from "./app-model";

interface DraftInventoryRow {
  id: string;
  values: Record<string, string>;
}

let draftRowCounter = 0;

export function InstallationSurface(): ReactElement {
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

export function EditableInventorySurface({ columns, initialRows, intro, title }: {
  columns: InventoryColumn[];
  initialRows: Record<string, string>[];
  intro: string;
  title: string;
}): ReactElement {
  const [draftRows, setDraftRows] = useState(() => initialRows.map((row) => createDraftRow(row)));

  function updateDraftRow(rowId: string, key: string, value: string): void {
    setDraftRows((currentRows) => currentRows.map((row) => row.id === rowId ? { ...row, values: { ...row.values, [key]: value } } : row));
  }

  function addDraftRow(): void {
    setDraftRows((currentRows) => [...currentRows, createDraftRow(emptyRow(columns))]);
  }

  return (
    <section className="panel" aria-label={title}>
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{text.infrastructure}</p>
          <h2>{title}</h2>
          <p>{intro}</p>
        </div>
        <button className="secondary-action" onClick={addDraftRow} type="button">{text.addRow}</button>
      </div>
      <p className="notice compact-notice">{text.draftOnly}</p>
      <div className="editable-table">
        <div className="editable-row header-row">
          {columns.map((column) => <span key={column.key}>{column.label}</span>)}
        </div>
        {draftRows.map((row) => (
          <div className="editable-row" key={row.id}>
            {columns.map((column) => (
              <input
                aria-label={`${title} ${column.label}`}
                key={column.key}
                onChange={(event) => updateDraftRow(row.id, column.key, event.currentTarget.value)}
                placeholder={column.label}
                value={row.values[column.key] ?? ""}
              />
            ))}
          </div>
        ))}
      </div>
    </section>
  );
}

function TogglePill({ checked, label }: { checked: boolean; label: string }): ReactElement {
  return <span className={checked ? "toggle-pill checked" : "toggle-pill"}>{label}</span>;
}

function createDraftRow(values: Record<string, string>): DraftInventoryRow {
  draftRowCounter += 1;
  return { id: `draft-row-${draftRowCounter}`, values };
}

function emptyRow(columns: InventoryColumn[]): Record<string, string> {
  const row: Record<string, string> = {};
  for (const column of columns) {
    row[column.key] = "";
  }

  return row;
}
