import { type ReactElement, useEffect, useState } from "react";
import { FiChevronDown, FiChevronLeft, FiChevronRight, FiChevronUp, FiRotateCcw } from "react-icons/fi";
import type { ContrastPreference, FontPreference, FontSizePreference, ThemePreference } from "./app-model";
import { DEFAULT_ACCENT_HUE, contrastOptions, fontFamilyForPreference, fontOptions, fontSizeOptions, text } from "./app-model";

export function hueFromInputValue(value: string): number | null {
  const trimmedValue = value.trim();

  if (trimmedValue.length === 0) {
    return null;
  }

  const hue = Number(trimmedValue);

  if (!Number.isInteger(hue)) {
    return null;
  }

  return Math.min(359, Math.max(0, hue));
}

export function wrappedOptionIndex(currentIndex: number, optionCount: number, direction: -1 | 1): number {
  if (optionCount <= 0) {
    return 0;
  }

  return (currentIndex + direction + optionCount) % optionCount;
}

export function SidebarFooter(props: SidebarFooterProps): ReactElement {
  const [appearanceOpen, setAppearanceOpen] = useState(true);
  const AppearanceChevron = appearanceOpen ? FiChevronDown : FiChevronUp;

  return (
    <footer className="sidebar-footer">
      <section className={appearanceOpen ? "appearance-panel open" : "appearance-panel collapsed"}>
        <button
          aria-expanded={appearanceOpen}
          className="appearance-panel-tab"
          onClick={() => setAppearanceOpen((current) => !current)}
          type="button"
        >
          {text.appearance}
          <AppearanceChevron aria-hidden="true" className="appearance-chevron" />
        </button>
        {appearanceOpen ? <AppearancePanelBody {...props} /> : null}
      </section>
    </footer>
  );
}

interface SidebarFooterProps {
  accentHue: number;
  contrastPreference: ContrastPreference;
  fontPreference: FontPreference;
  fontSizePreference: FontSizePreference;
  setAccentHue: (hue: number) => void;
  setContrastPreference: (contrast: ContrastPreference) => void;
  setFontPreference: (font: FontPreference) => void;
  setFontSizePreference: (size: FontSizePreference) => void;
  setShowBorders: (show: boolean) => void;
  setShowNavCounts: (show: boolean) => void;
  setThemePreference: (theme: ThemePreference) => void;
  showBorders: boolean;
  showNavCounts: boolean;
  themePreference: ThemePreference;
}

function AppearancePanelBody({ accentHue, contrastPreference, fontPreference, fontSizePreference, setAccentHue, setContrastPreference, setFontPreference, setFontSizePreference, setShowBorders, setShowNavCounts, setThemePreference, showBorders, showNavCounts, themePreference }: SidebarFooterProps): ReactElement {
  return (
    <div className="appearance-panel-body">
      <ThemeControl setThemePreference={setThemePreference} themePreference={themePreference} />
      <HueControl accentHue={accentHue} setAccentHue={setAccentHue} />
      <ContrastControl contrastPreference={contrastPreference} setContrastPreference={setContrastPreference} />
      <AppearanceSwitches setShowBorders={setShowBorders} setShowNavCounts={setShowNavCounts} showBorders={showBorders} showNavCounts={showNavCounts} />
      <FontSizeControl fontSizePreference={fontSizePreference} setFontSizePreference={setFontSizePreference} />
      <FontControl fontPreference={fontPreference} setFontPreference={setFontPreference} />
    </div>
  );
}

function ThemeControl({ setThemePreference, themePreference }: { setThemePreference: (theme: ThemePreference) => void; themePreference: ThemePreference }): ReactElement {
  return (
    <fieldset className="theme-control compact appearance-segmented-control" aria-label={text.theme}>
      {(["system", "light", "dark"] as const).map((theme) => (
        <button
          aria-pressed={themePreference === theme}
          className={themePreference === theme ? "theme-option active" : "theme-option"}
          key={theme}
          onClick={() => setThemePreference(theme)}
          type="button"
        >
          {theme}
        </button>
      ))}
    </fieldset>
  );
}

function HueControl({ accentHue, setAccentHue }: { accentHue: number; setAccentHue: (hue: number) => void }): ReactElement {
  const [hueInput, setHueInput] = useState(() => String(accentHue));
  const updateAccentHue = (value: number) => {
    if (Number.isFinite(value)) {
      setAccentHue(Math.min(359, Math.max(0, value)));
    }
  };
  const updateHueInput = (value: string) => {
    setHueInput(value);
    const nextHue = hueFromInputValue(value);
    if (nextHue !== null) {
      updateAccentHue(nextHue);
    }
  };

  useEffect(() => {
    setHueInput(String(accentHue));
  }, [accentHue]);

  return (
    <div className="theme-hue-control">
      <div className="theme-control-heading">
        <div className="hue-label-row">
          <label htmlFor="theme-hue-slider">{text.hue}</label>
          <input
            aria-label="Hue value"
            className="hue-number-input"
            max="359"
            min="0"
            onChange={(event) => updateHueInput(event.currentTarget.value)}
            type="number"
            value={hueInput}
          />
        </div>
        <button aria-label="Reset hue to default" className="icon-reset-button" onClick={() => setAccentHue(DEFAULT_ACCENT_HUE)} title={text.reset} type="button"><FiRotateCcw aria-hidden="true" /></button>
      </div>
      <input
        id="theme-hue-slider"
        max="359"
        min="0"
        onChange={(event) => updateAccentHue(Number.parseInt(event.currentTarget.value, 10))}
        type="range"
        value={accentHue}
      />
    </div>
  );
}

function ContrastControl({ contrastPreference, setContrastPreference }: { contrastPreference: ContrastPreference; setContrastPreference: (contrast: ContrastPreference) => void }): ReactElement {
  return (
    <fieldset className="contrast-control" aria-label={text.contrast}>
      <legend>{text.contrast}</legend>
      <div className="contrast-options appearance-segmented-control">
        {contrastOptions.map((option) => (
          <button
            aria-pressed={contrastPreference === option.value}
            className={contrastPreference === option.value ? "active" : ""}
            key={option.value}
            onClick={() => setContrastPreference(option.value)}
            type="button"
          >
            {option.label}
          </button>
        ))}
      </div>
    </fieldset>
  );
}

function AppearanceSwitches({ setShowBorders, setShowNavCounts, showBorders, showNavCounts }: { setShowBorders: (show: boolean) => void; setShowNavCounts: (show: boolean) => void; showBorders: boolean; showNavCounts: boolean }): ReactElement {
  return (
    <>
      <label className="switch-control appearance-switch">
        <strong>{text.showBorders}</strong>
        <input checked={showBorders} onChange={(event) => setShowBorders(event.currentTarget.checked)} type="checkbox" />
        <span aria-hidden="true" />
      </label>
      <label className="switch-control appearance-switch">
        <strong>{text.showCounts}</strong>
        <input checked={showNavCounts} onChange={(event) => setShowNavCounts(event.currentTarget.checked)} type="checkbox" />
        <span aria-hidden="true" />
      </label>
    </>
  );
}

function FontSizeControl({ fontSizePreference, setFontSizePreference }: { fontSizePreference: FontSizePreference; setFontSizePreference: (size: FontSizePreference) => void }): ReactElement {
  const fontSizeIndex = Math.max(0, fontSizeOptions.findIndex((option) => option.value === fontSizePreference));

  return (
    <div className="font-size-control">
      <label htmlFor="font-size-slider">{text.fontSize}</label>
      <input
        id="font-size-slider"
        max={fontSizeOptions.length - 1}
        min="0"
        onChange={(event) => setFontSizePreference(fontSizeOptions[Number.parseInt(event.currentTarget.value, 10)]?.value ?? "xs")}
        step="1"
        type="range"
        value={fontSizeIndex}
      />
      <fieldset className="range-labels">
        <legend className="sr-only">Font size shortcuts</legend>
        {fontSizeOptions.map((option) => (
          <button
            aria-pressed={option.value === fontSizePreference}
            className={option.value === fontSizePreference ? "active" : ""}
            key={option.value}
            onClick={() => setFontSizePreference(option.value)}
            type="button"
          >
            {option.label}
          </button>
        ))}
      </fieldset>
    </div>
  );
}

function FontControl({ fontPreference, setFontPreference }: { fontPreference: FontPreference; setFontPreference: (font: FontPreference) => void }): ReactElement {
  const selectedFontFamily = fontFamilyForPreference(fontPreference);
  const fontIndex = Math.max(0, fontOptions.findIndex((option) => option.value === fontPreference));
  const setFontByIndex = (index: number) => {
    const nextFont = fontOptions[index]?.value;
    if (nextFont !== undefined) {
      setFontPreference(nextFont);
    }
  };

  return (
    <div className="font-control">
      <span id="appearance-font-selector-label">{text.font}</span>
      <div className="selector-with-stepper font-selector-row">
        <button aria-label="Previous font" className="selector-step-button" onClick={() => setFontByIndex(wrappedOptionIndex(fontIndex, fontOptions.length, -1))} type="button"><FiChevronLeft aria-hidden="true" /></button>
        <select
          aria-labelledby="appearance-font-selector-label"
          onChange={(event) => setFontPreference(event.currentTarget.value as FontPreference)}
          style={{ fontFamily: selectedFontFamily }}
          value={fontPreference}
        >
          {fontOptions.map((option) => (
            <option key={option.value} style={{ fontFamily: option.fontFamily }} value={option.value}>
              {option.label}
            </option>
          ))}
        </select>
        <button aria-label="Next font" className="selector-step-button" onClick={() => setFontByIndex(wrappedOptionIndex(fontIndex, fontOptions.length, 1))} type="button"><FiChevronRight aria-hidden="true" /></button>
      </div>
    </div>
  );
}
