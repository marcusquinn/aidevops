// Caption style presets — inspired by CaptionThis app patterns
// Each style defines font, colors, animation, and background treatment

import type { CSSProperties } from "react";
import type { CaptionStyle, CaptionPosition } from "./types";

export interface CaptionStyleConfig {
  fontFamily: string;
  fontWeight: string;
  fontSize: number;
  textColor: string;
  textShadow: string;
  backgroundColor: string;
  backgroundPadding: string;
  backgroundBorderRadius: number;
  animation: "spring" | "fade" | "typewriter" | "highlight" | "none";
  textTransform: "none" | "uppercase";
}

export const CAPTION_STYLES: Record<CaptionStyle, CaptionStyleConfig> = {
  "bold-white": {
    fontFamily: "Bangers",
    fontWeight: "400",
    fontSize: 72,
    textColor: "#FFFFFF",
    textShadow: "3px 3px 6px rgba(0,0,0,0.9), -1px -1px 3px rgba(0,0,0,0.5)",
    backgroundColor: "transparent",
    backgroundPadding: "0",
    backgroundBorderRadius: 0,
    animation: "spring",
    textTransform: "uppercase",
  },
  minimal: {
    fontFamily: "Inter",
    fontWeight: "300",
    fontSize: 48,
    textColor: "rgba(255,255,255,0.95)",
    textShadow: "1px 1px 4px rgba(0,0,0,0.6)",
    backgroundColor: "transparent",
    backgroundPadding: "0",
    backgroundBorderRadius: 0,
    animation: "fade",
    textTransform: "none",
  },
  impact: {
    fontFamily: "Oswald",
    fontWeight: "700",
    fontSize: 80,
    textColor: "#FFFFFF",
    textShadow: "none",
    backgroundColor: "rgba(0,0,0,0.75)",
    backgroundPadding: "16px 32px",
    backgroundBorderRadius: 8,
    animation: "spring",
    textTransform: "uppercase",
  },
  typewriter: {
    fontFamily: "IBM Plex Mono",
    fontWeight: "500",
    fontSize: 44,
    textColor: "#00FF88",
    textShadow: "0 0 10px rgba(0,255,136,0.4)",
    backgroundColor: "rgba(0,0,0,0.6)",
    backgroundPadding: "12px 24px",
    backgroundBorderRadius: 4,
    animation: "typewriter",
    textTransform: "none",
  },
  highlight: {
    fontFamily: "Montserrat",
    fontWeight: "800",
    fontSize: 64,
    textColor: "#FFFFFF",
    textShadow: "2px 2px 4px rgba(0,0,0,0.8)",
    backgroundColor: "transparent",
    backgroundPadding: "0",
    backgroundBorderRadius: 0,
    animation: "highlight",
    textTransform: "none",
  },
};

// Position CSS mapping
export function getPositionStyle(
  position: CaptionPosition,
  videoHeight: number
): CSSProperties {
  const margin = Math.round(videoHeight * 0.08);
  switch (position) {
    case "top":
      return {
        top: margin,
        left: 0,
        right: 0,
        justifyContent: "flex-start",
        alignItems: "center",
      };
    case "center":
      return {
        top: 0,
        bottom: 0,
        left: 0,
        right: 0,
        justifyContent: "center",
        alignItems: "center",
      };
    case "bottom":
    default:
      return {
        bottom: margin,
        left: 0,
        right: 0,
        justifyContent: "flex-end",
        alignItems: "center",
      };
  }
}
