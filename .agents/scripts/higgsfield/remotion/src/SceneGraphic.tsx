import { AbsoluteFill, useCurrentFrame, useVideoConfig, interpolate, spring } from "remotion";
import type { SceneGraphicProps } from "./types";

// Renders a static title card / graphic that can be:
// 1. Exported as a still image (for Higgsfield to animate)
// 2. Used as a scene in the video composition

export const SceneGraphic: React.FC<SceneGraphicProps> = ({
  text,
  subtitle,
  width,
  height,
  backgroundColor = "#0a0a0a",
  textColor = "#ffffff",
  fontFamily = "Inter",
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  // Title entrance: spring scale
  const titleSpring = spring({ frame, fps, config: { damping: 200 } });
  const titleScale = interpolate(titleSpring, [0, 1], [0.85, 1]);
  const titleOpacity = titleSpring;

  // Subtitle entrance: delayed fade
  const subtitleDelay = Math.round(fps * 0.4);
  const subtitleOpacity = interpolate(
    frame,
    [subtitleDelay, subtitleDelay + fps * 0.6],
    [0, 1],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" }
  );

  // Responsive font sizing based on dimensions
  const isVertical = height > width;
  const titleSize = isVertical ? Math.round(width * 0.08) : Math.round(height * 0.08);
  const subtitleSize = Math.round(titleSize * 0.5);

  return (
    <AbsoluteFill
      style={{
        backgroundColor,
        display: "flex",
        flexDirection: "column",
        justifyContent: "center",
        alignItems: "center",
        padding: "10%",
      }}
    >
      <div
        style={{
          opacity: titleOpacity,
          transform: `scale(${titleScale})`,
          fontFamily,
          fontWeight: "700",
          fontSize: titleSize,
          color: textColor,
          textAlign: "center",
          lineHeight: 1.2,
          maxWidth: "90%",
        }}
      >
        {text}
      </div>
      {subtitle && (
        <div
          style={{
            opacity: subtitleOpacity,
            fontFamily,
            fontWeight: "300",
            fontSize: subtitleSize,
            color: `${textColor}cc`,
            textAlign: "center",
            marginTop: Math.round(titleSize * 0.4),
            maxWidth: "80%",
          }}
        >
          {subtitle}
        </div>
      )}
    </AbsoluteFill>
  );
};
