---
name: pixel-canvas-rendering
description: Render and interact with the large World Canvas in the browser using HTML canvas. Covers the pixel buffer, palette encoding, crisp pixelated scaling, pan and zoom (mouse, wheel, touch pinch), mapping a click to a pixel coordinate, hover highlight, the color picker, cooldown UI, and optimistic painting. Use this skill for anything under src/canvas or any visual or interaction bug: blurry pixels, wrong pixel clicked, slow redraws, zoom jumping, mobile touch issues, even if the user just says "the board looks off" or "make zooming nicer".
metadata:
  project: world-canvas
  version: "1.0"
---

# Pixel canvas rendering

## Architecture

- **World buffer**: one `ImageData(CANVAS_W, CANVAS_H)` plus a `Uint32Array` view `u32` over
  its buffer. A pixel `(x, y)` lives at `u32[y * CANVAS_W + x]`.
- **World canvas**: an offscreen canvas (`OffscreenCanvas` or a detached `<canvas>`) at 1:1 size.
  Dirty regions are copied into it with `putImageData(imageData, 0, 0, dx, dy, dw, dh)`.
- **View canvas**: the visible `<canvas>`, sized to its CSS box × `devicePixelRatio`. Each frame it
  draws the world canvas through the viewport transform with `drawImage`.
- **Viewport**: `{ scale, ox, oy }` in CSS pixels, where `screen = world * scale + offset`.
- **Render loop**: draw only when needed. Any change sets `needsDraw = true` and a single
  `requestAnimationFrame` flushes the dirty rect and redraws the view.

## Palette encoding

`PALETTE` (16 hex strings) lives in `src/config.ts`. Precompute it as Uint32 once:

```ts
// ImageData is RGBA bytes; a Uint32Array over it on little-endian (all real browsers) reads ABGR.
export const PALETTE_U32 = PALETTE.map((hex) => {
  const n = parseInt(hex.slice(1), 16);
  return ((0xff << 24) | ((n & 0xff) << 16) | (n & 0xff00) | ((n >> 16) & 0xff)) >>> 0;
});
```

Decoding a snapshot chunk (base64 → bytes → pixels):

```ts
const bytes = Uint8Array.from(atob(row.data), (ch) => ch.charCodeAt(0));
for (let i = 0; i < bytes.length; i++) {
  const x = row.cx * CHUNK + (i % CHUNK);
  const y = row.cy * CHUNK + ((i / CHUNK) | 0);
  u32[y * CANVAS_W + x] = PALETTE_U32[bytes[i]] ?? PALETTE_U32[0];
}
```

## Coordinates & interaction

- Screen to world: `x = Math.floor((clientX - rect.left - ox) / scale)`, and likewise for y. Reject
  values outside `[0, CANVAS_W)` / `[0, CANVAS_H)`. Always use `Math.floor`. `Math.round` or `| 0`
  are wrong for negative values and at half-pixels.
- Zoom around the cursor: `ox = cx - (cx - ox) * (newScale / scale)` (same for y), where
  `cx` is the cursor position relative to the canvas. Clamp `scale` between "whole canvas fits"
  and about 40.
- Use Pointer Events with `setPointerCapture`. A press counts as a **click** (place pixel) only when the pointer
  moved less than 5 px. Otherwise it is a **pan**. Track two active pointers for pinch zoom.
- Set CSS `touch-action: none` on the view canvas, or mobile browsers will scroll or zoom the page.
- Draw the view with `ctx.setTransform(dpr * scale, 0, 0, dpr * scale, dpr * ox, dpr * oy)`, then
  `ctx.drawImage(worldCanvas, 0, 0)`. Draw the hover outline and grid (only when `scale >= 8`) in the same pass.

## Placing a pixel (optimistic)

1. If the local cooldown timer is running, show the remaining time and stop.
2. Remember `prev = u32[i]`, write the new color, and mark it dirty. The user sees the change instantly.
3. Call `place_pixel`. On error, put `prev` back **unless** a broadcast for that pixel arrived in the
   meantime. Show a friendly message for `cooldown_active` and resync the timer.
4. On success, start the cooldown timer from `COOLDOWN_MS`. The server is still the authority.

## Gotchas

- Setting `canvas.width` / `height` (on resize or DPR change) **resets the context state**. Set
  `ctx.imageSmoothingEnabled = false` again after every resize, or pixels turn blurry.
- Add CSS `image-rendering: pixelated` to the view canvas as a backup for any CSS-scaled path.
- Never call `putImageData` on the view canvas. It ignores transforms. Use it only on the world canvas.
- Do not draw from inside the realtime callback. A burst of events must turn into one frame.
- Listen for `matchMedia(`(resolution: ${devicePixelRatio}dppx)`)` changes (moving a window to
  another monitor) and resize the backing store.
- A wheel listener must be `{ passive: false }` to call `preventDefault()` and stop the page from zooming.

## Verify

Manually: zoom to maximum, then click pixel edges and corners. The highlighted pixel must match
what gets painted. Open two browser windows and confirm a pixel shows in both. Resize the window
and move it between monitors, and pixels must stay sharp.