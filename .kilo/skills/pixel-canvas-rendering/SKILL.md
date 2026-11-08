---
name: pixel-canvas-rendering
description: Drawing and interacting with the World Pixels canvas in the browser - pixel buffer, palette encoding, crisp scaling, pan/zoom/pinch, click-to-pixel mapping, hover, optimistic paint. Use for anything in src/canvas and any visual or input bug (blurry pixels, wrong pixel painted, zoom jumps, slow redraws, touch issues).
---

# Pixel canvas rendering

Plain TS in `src/canvas/`, started by `startWorld()` in `src/engine.ts`. Never import React here. The palette and status bar are React components
(see `vite-app`): this code reads the selected color with `getState().selectedColor` and never renders UI.

## Architecture

- **World buffer**: one `ImageData(CANVAS_W, CANVAS_H)` with a `Uint32Array` view `u32`. Pixel `(x, y)` is `u32[y * CANVAS_W + x]`.
- **World canvas**: an offscreen 1:1 canvas. Copy only dirty regions in, using `putImageData(img, 0, 0, dx, dy, dw, dh)`.
- **View canvas**: the visible `<canvas>`, sized to its CSS box × `devicePixelRatio`.
- **Viewport** `{ scale, ox, oy }` in CSS px: `screen = world * scale + offset`.
- **Draw on demand**: any change sets `needsDraw`, and a single `requestAnimationFrame` flushes the dirty region and redraws. Bursts of events become one frame.

## Palette and snapshot decoding

```ts
// ImageData is RGBA bytes; a Uint32Array over it reads ABGR on little-endian (all real browsers).
export const PALETTE_U32 = PALETTE.map((hex) => {
  const n = parseInt(hex.slice(1), 16)
  return ((0xff << 24) | ((n & 0xff) << 16) | (n & 0xff00) | ((n >> 16) & 0xff)) >>> 0
})

const bytes = Uint8Array.from(atob(row.data), (ch) => ch.charCodeAt(0))
for (let i = 0; i < bytes.length; i++) {
  const x = row.cx * CHUNK + (i % CHUNK)
  const y = row.cy * CHUNK + ((i / CHUNK) | 0)
  u32[y * CANVAS_W + x] = PALETTE_U32[bytes[i]] ?? PALETTE_U32[0] // unknown byte → color 0
}
```

## Coordinates and input

- Screen to world: `x = Math.floor((clientX - rect.left - ox) / scale)`, and the same for y. Reject anything outside the canvas. Always use `Math.floor`; `Math.round` and `| 0` are wrong at half-pixels and for negative values.
- Zoom around the cursor: `ox = cx - (cx - ox) * (newScale / scale)`, and the same for y. Clamp the scale between "whole canvas fits" and ~40.
- Use Pointer Events with `setPointerCapture`. Movement under 5 px is a **click** (place a pixel); more is a **pan**. Two pointers mean pinch zoom.
- Draw with `ctx.setTransform(dpr * scale, 0, 0, dpr * scale, dpr * ox, dpr * oy)`, then `ctx.drawImage(worldCanvas, 0, 0)`. Draw the hover outline in the same pass, and the grid only when `scale >= 8`.

## Optimistic paint

1. If `getState().cooldownLeft > 0`, stop. The StatusBar already shows the seconds left.
2. Save `prev = u32[i]`, write the new color, and mark the pixel dirty.
3. Call `place_pixel`. On error, restore `prev` **unless** a broadcast for that pixel arrived in the meantime, and `setState({ notice })` with the mapped message. On `cooldown_active`, restart the timer.
4. On success, start the cooldown from `COOLDOWN_MS`. The engine's timer writes `cooldownLeft` (whole seconds) into the store only when the number changes, and the timer is cleared by `stop()`. The server stays the authority.

## Gotchas

- Resizing a canvas resets its context. Set `ctx.imageSmoothingEnabled = false` again after every resize, and add CSS `image-rendering: pixelated`.
- Never `putImageData` on the view canvas, because it ignores transforms.
- The view canvas needs CSS `touch-action: none` (in `CanvasView.module.css`). Attach pointer and wheel listeners natively in `input.ts`, the wheel one with `{ passive: false }`. React's `onWheel` prop is passive, so `preventDefault()` would be ignored and the page would zoom.
- `input.ts` returns a `detach()` that removes every listener. `stop()` calls it, or StrictMode leaves a second set attached in dev.
- Watch `matchMedia(`(resolution: ${devicePixelRatio}dppx)`)`: moving the window to another monitor changes the DPR.

## Verify

Zoom to max and click pixel edges: the highlighted pixel must be the one painted. A pixel painted in one window must show in a second window. To check visually as an agent, run `npm run dev`, open `http://localhost:5173` with the chrome-devtools tools, and take a screenshot.
