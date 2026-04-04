---
name: 3d
mode: subagent
description: 3D content in Remotion using Three.js and React Three Fiber.
metadata:
  tags: 3d, three, threejs
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Follow normal React Three Fiber / Three.js practices, plus these Remotion-specific rules.

## Install `@remotion/three`

```bash
npx remotion add @remotion/three # If project uses npm
bunx remotion add @remotion/three # If project uses bun
yarn remotion add @remotion/three # If project uses yarn
pnpm exec remotion add @remotion/three # If project uses pnpm
```

## `ThreeCanvas` required

Wrap 3D content in `<ThreeCanvas>`, pass `width` and `height`, and add lighting.

```tsx
import { ThreeCanvas } from "@remotion/three";
import { useVideoConfig } from "remotion";

const { width, height } = useVideoConfig();

<ThreeCanvas width={width} height={height}>
  <ambientLight intensity={0.4} />
  <directionalLight position={[5, 5, 5]} intensity={0.8} />
  <mesh>
    <sphereGeometry args={[1, 32, 32]} />
    <meshStandardMaterial color="red" />
  </mesh>
</ThreeCanvas>
```

## Animation rule

Drive all animation from `useCurrentFrame()`. Shaders, models, and other scene elements must not animate on their own or renders may flicker.

Never use `useFrame()` from `@react-three/fiber`.

## Animation example

```tsx
const frame = useCurrentFrame();
const rotationY = frame * 0.02;

<mesh rotation={[0, rotationY, 0]}>
  <boxGeometry args={[2, 2, 2]} />
  <meshStandardMaterial color="#4a9eff" />
</mesh>
```

## `Sequence` inside `ThreeCanvas`

Any `<Sequence>` inside `<ThreeCanvas>` must set `layout="none"`.

```tsx
import { Sequence } from "remotion";
import { ThreeCanvas } from "@remotion/three";

const { width, height } = useVideoConfig();

<ThreeCanvas width={width} height={height}>
  <Sequence layout="none">
    <mesh>
      <boxGeometry args={[2, 2, 2]} />
      <meshStandardMaterial color="#4a9eff" />
    </mesh>
  </Sequence>
</ThreeCanvas>
```
