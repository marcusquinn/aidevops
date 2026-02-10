import { AbsoluteFill } from "remotion";
import { Video } from "@remotion/media";
import type { SceneVideoProps } from "./types";

export const SceneVideo: React.FC<SceneVideoProps> = ({ src, durationInSeconds }) => {
  return (
    <AbsoluteFill style={{ backgroundColor: "black" }}>
      <Video
        src={src}
        style={{
          width: "100%",
          height: "100%",
          objectFit: "cover",
        }}
      />
    </AbsoluteFill>
  );
};
