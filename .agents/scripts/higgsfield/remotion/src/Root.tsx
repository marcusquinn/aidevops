import React from "react";
import { Composition, Still } from "remotion";
import { loadFont as loadBangers } from "@remotion/google-fonts/Bangers";
import { loadFont as loadInter } from "@remotion/google-fonts/Inter";
import { loadFont as loadOswald } from "@remotion/google-fonts/Oswald";
import { loadFont as loadMontserrat } from "@remotion/google-fonts/Montserrat";
import { loadFont as loadIBMPlexMono } from "@remotion/google-fonts/IBMPlexMono";
import { FullVideo } from "./FullVideo";
import { SceneGraphic } from "./SceneGraphic";
import { ASPECT_DIMENSIONS } from "./types";
import type { BriefProps, SceneGraphicProps } from "./types";

// Load only needed font weights/subsets to minimize network requests
loadBangers("normal", { weights: ["400"], subsets: ["latin"] });
loadInter("normal", { weights: ["300", "400", "700"], subsets: ["latin"] });
loadOswald("normal", { weights: ["700"], subsets: ["latin"] });
loadMontserrat("normal", { weights: ["800"], subsets: ["latin"] });
loadIBMPlexMono("normal", { weights: ["500"], subsets: ["latin"] });

// Default props for studio preview
const defaultBriefProps: BriefProps = {
  title: "Preview Video",
  scenes: [
    { prompt: "Scene 1", duration: 5 },
    { prompt: "Scene 2", duration: 5 },
  ],
  aspect: "9:16",
  captions: [
    { scene: 0, text: "This is a caption", position: "bottom", style: "bold-white" },
    { scene: 1, text: "Second caption", position: "center", style: "impact" },
  ],
  sceneVideos: [],
  transitionStyle: "fade",
  transitionDuration: 15,
};

const defaultGraphicProps: SceneGraphicProps = {
  text: "Title Card",
  subtitle: "Subtitle text here",
  width: 1080,
  height: 1920,
  backgroundColor: "#0a0a0a",
  textColor: "#ffffff",
  fontFamily: "Inter",
};

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- Remotion v4 Composition requires Zod schema as first type arg; we use runtime props instead
const AnyFullVideo = FullVideo as any;
const AnySceneGraphic = SceneGraphic as any;

// Calculate duration and dimensions from actual props (handles --props override)
const FPS = 30;

function calcFrames(props: BriefProps): number {
  const totalSceneDuration = props.scenes.reduce((sum, s) => sum + s.duration, 0);
  const transitionOverlap =
    props.transitionStyle !== "none" && props.scenes.length > 1
      ? (props.scenes.length - 1) * (props.transitionDuration || 15)
      : 0;
  return totalSceneDuration * FPS - transitionOverlap;
}

function calcDims(props: BriefProps): { width: number; height: number } {
  return ASPECT_DIMENSIONS[props.aspect] || ASPECT_DIMENSIONS["9:16"];
}

// calculateMetadata dynamically computes duration/dimensions from --props at render time
const calculateVideoMetadata = ({ props }: { props: BriefProps }) => {
  const dims = calcDims(props);
  return {
    durationInFrames: calcFrames(props),
    width: dims.width,
    height: dims.height,
    fps: FPS,
    props,
  };
};

export const RemotionRoot: React.FC = () => {
  const defaultFrames = calcFrames(defaultBriefProps);
  const defaultDims = calcDims(defaultBriefProps);

  return (
    <>
      <Composition
        id="FullVideo"
        component={AnyFullVideo}
        calculateMetadata={calculateVideoMetadata as any}
        durationInFrames={defaultFrames}
        fps={FPS}
        width={defaultDims.width}
        height={defaultDims.height}
        defaultProps={defaultBriefProps}
      />

      <Still
        id="SceneGraphic"
        component={AnySceneGraphic}
        width={defaultGraphicProps.width}
        height={defaultGraphicProps.height}
        defaultProps={defaultGraphicProps}
      />

      <Composition
        id="FullVideo-16x9"
        component={AnyFullVideo}
        calculateMetadata={calculateVideoMetadata as any}
        durationInFrames={defaultFrames}
        fps={FPS}
        width={1920}
        height={1080}
        defaultProps={{ ...defaultBriefProps, aspect: "16:9" }}
      />
      <Composition
        id="FullVideo-1x1"
        component={AnyFullVideo}
        calculateMetadata={calculateVideoMetadata as any}
        durationInFrames={defaultFrames}
        fps={FPS}
        width={1080}
        height={1080}
        defaultProps={{ ...defaultBriefProps, aspect: "1:1" }}
      />
    </>
  );
};
