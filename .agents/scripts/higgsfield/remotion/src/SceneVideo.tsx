import { Video } from "@remotion/media";
import { AbsoluteFill } from "remotion";
import type { SceneVideoProps } from "./types";

export const SceneVideo: React.FC<SceneVideoProps> = ({ src, durationInSeconds: _durationInSeconds }) => {
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
