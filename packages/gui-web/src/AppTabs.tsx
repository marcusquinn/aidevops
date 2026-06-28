import type { ReactElement } from "react";

export interface TabOption<T extends string> {
  id: T;
  label: string;
}

export function TabNav<T extends string>({ label, onChange, tabs, value }: { label: string; onChange: (value: T) => void; tabs: TabOption<T>[]; value: T }): ReactElement {
  return <div aria-label={label} className="pill-tabs app-subnav" role="tablist">{tabs.map((tab) => <button aria-selected={value === tab.id} className={value === tab.id ? "active" : ""} key={tab.id} onClick={() => onChange(tab.id)} role="tab" type="button">{tab.label}</button>)}</div>;
}
