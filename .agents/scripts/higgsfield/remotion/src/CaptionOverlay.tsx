import {
  useCurrentFrame,
  useVideoConfig,
  interpolate,
  spring,
  AbsoluteFill,
} from "remotion";
import type { CaptionOverlayProps } from "./types";
import { CAPTION_STYLES, getPositionStyle } from "./styles";

// Typewriter: reveal characters one by one
function TypewriterText({ text, style }: { text: string; style: typeof CAPTION_STYLES["typewriter"] }) {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const charsPerSecond = 20;
  const visibleChars = Math.min(
    Math.floor((frame / fps) * charsPerSecond),
    text.length
  );
  const displayText = text.slice(0, visibleChars);
  const cursor = frame % (fps / 2) < fps / 4 ? "|" : "";

  return (
    <span
      style={{
        fontFamily: style.fontFamily,
        fontWeight: style.fontWeight,
        fontSize: style.fontSize,
        color: style.textColor,
        textShadow: style.textShadow,
        textTransform: style.textTransform as React.CSSProperties["textTransform"],
      }}
    >
      {displayText}
      <span style={{ opacity: visibleChars < text.length ? 1 : 0 }}>{cursor}</span>
    </span>
  );
}

// Highlight: color each word sequentially
function HighlightText({ text, style }: { text: string; style: typeof CAPTION_STYLES["highlight"] }) {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const words = text.split(" ");
  const wordsPerSecond = 3;
  const activeWordIndex = Math.floor((frame / fps) * wordsPerSecond);

  return (
    <span>
      {words.map((word, i) => {
        const isActive = i <= activeWordIndex;
        return (
          <span
            key={i}
            style={{
              fontFamily: style.fontFamily,
              fontWeight: style.fontWeight,
              fontSize: style.fontSize,
              color: isActive ? "#39E508" : style.textColor,
              textShadow: style.textShadow,
              textTransform: style.textTransform as React.CSSProperties["textTransform"],
              transition: "none", // Remotion: no CSS transitions
            }}
          >
            {word}
            {i < words.length - 1 ? " " : ""}
          </span>
        );
      })}
    </span>
  );
}

export const CaptionOverlay: React.FC<CaptionOverlayProps> = ({
  text,
  position,
  style: styleName,
  durationInFrames,
}) => {
  const frame = useCurrentFrame();
  const { fps, height } = useVideoConfig();
  const styleConfig = CAPTION_STYLES[styleName] || CAPTION_STYLES["bold-white"];

  // Entrance animation
  let opacity = 1;
  let translateY = 0;
  let scale = 1;

  if (styleConfig.animation === "spring") {
    const springVal = spring({ frame, fps, config: { damping: 200 } });
    scale = interpolate(springVal, [0, 1], [0.8, 1]);
    opacity = springVal;
    translateY = interpolate(springVal, [0, 1], [30, 0]);
  } else if (styleConfig.animation === "fade") {
    const fadeInEnd = Math.min(fps * 0.5, durationInFrames * 0.2);
    const fadeOutStart = durationInFrames - fadeInEnd;
    opacity = interpolate(
      frame,
      [0, fadeInEnd, fadeOutStart, durationInFrames],
      [0, 1, 1, 0],
      { extrapolateLeft: "clamp", extrapolateRight: "clamp" }
    );
  }
  // typewriter and highlight handle their own animation internally

  const positionStyle = getPositionStyle(position, height);

  return (
    <AbsoluteFill
      style={{
        display: "flex",
        position: "absolute",
        ...positionStyle,
        pointerEvents: "none",
        zIndex: 10,
      }}
    >
      <div
        style={{
          opacity,
          transform: `translateY(${translateY}px) scale(${scale})`,
          backgroundColor: styleConfig.backgroundColor,
          padding: styleConfig.backgroundPadding,
          borderRadius: styleConfig.backgroundBorderRadius,
          maxWidth: "85%",
          textAlign: "center",
        }}
      >
        {styleConfig.animation === "typewriter" ? (
          <TypewriterText text={text} style={styleConfig} />
        ) : styleConfig.animation === "highlight" ? (
          <HighlightText text={text} style={styleConfig} />
        ) : (
          <span
            style={{
              fontFamily: styleConfig.fontFamily,
              fontWeight: styleConfig.fontWeight,
              fontSize: styleConfig.fontSize,
              color: styleConfig.textColor,
              textShadow: styleConfig.textShadow,
              textTransform: styleConfig.textTransform as React.CSSProperties["textTransform"],
              lineHeight: 1.3,
            }}
          >
            {text}
          </span>
        )}
      </div>
    </AbsoluteFill>
  );
};
