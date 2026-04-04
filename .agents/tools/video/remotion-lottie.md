---
name: lottie
mode: subagent
description: Embedding Lottie animations in Remotion.
metadata:
  category: Animation
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Install

```bash
npx remotion add @remotion/lottie # npm
bunx remotion add @remotion/lottie # bun
yarn remotion add @remotion/lottie # yarn
pnpm exec remotion add @remotion/lottie # pnpm
```

## Displaying a Lottie file

Fetch the asset inside `delayRender()`/`continueRender()`, store in state, render with `<Lottie>`:

```tsx
import {Lottie, LottieAnimationData} from '@remotion/lottie';
import {useEffect, useState} from 'react';
import {cancelRender, continueRender, delayRender} from 'remotion';

export const MyAnimation = () => {
  const [handle] = useState(() => delayRender('Loading Lottie animation'));

  const [animationData, setAnimationData] = useState<LottieAnimationData | null>(null);

  useEffect(() => {
    fetch('https://assets4.lottiefiles.com/packages/lf20_zyquagfl.json')
      .then((data) => data.json())
      .then((json) => {
        setAnimationData(json);
        continueRender(handle);
      })
      .catch((err) => {
        cancelRender(err);
      });
  }, [handle]);

  if (!animationData) {
    return null;
  }

  return <Lottie animationData={animationData} />;
};
```

## Styling and animating

Use the `style` prop:

```tsx
return <Lottie animationData={animationData} style={{width: 400, height: 400}} />;
```
