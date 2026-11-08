# World Pixels — v1 Implementation Plan

A shared pixel canvas: anyone opens the page, picks a color, paints one pixel (10 s per-user
cooldown), and sees everyone else's pixels live. Backend is Supabase free tier only
(Postgres + Realtime Broadcast + anonymous sign-ins). No custom server, no UI framework.

## Resolved decisions

- **Persistent canvas** — 1024×1024, never resets. "First load of the day" = the normal
  `get_canvas()` snapshot path. No daily reset in v1.
- **Drag = pan, click = one pixel.** A pointer with < 5 px total movement between down and up
  places a pixel; anything else pans (two pointers pinch, wheel zooms). Multi-cell drag-paint is
  impossible by design: every cell needs its own `place_pixel` RPC and the 10 s per-user cooldown
  is enforced server-side.
- **No Supabase keys** → static setup banner, no crash (see edge cases).
- Follow AGENTS.md rules and the four skills in `.kilo/skills/` (canvas-database,
  realtime-sync, pixel-canvas-rendering, supabase-free-tier) exactly. The reference migration at
  `.kilo/skills/canvas-database/references/schema.sql` is the starting point for the real one.

## Files to create

### Root scaffolding

| File | What it does |
| - | - |
| `package.json` | Deps: `@supabase/supabase-js`. Dev: `typescript`, `vite`. Scripts: `dev`, `build`, `typecheck` (`tsc --noEmit`), `preview`. |
| `tsconfig.json` | `strict: true`, `target` ES2022, `module`/`moduleResolution` ESNext/bundler, `lib` DOM + ES2022, `noEmit`. |
| `vite.config.ts` | Minimal `defineConfig({})` — plain TS, no plugins. |
| `index.html` | Mounts the app: full-viewport `<canvas>`, palette bar, status/cooldown banner element. Loads `src/main.ts`. |
| `.gitignore` | `node_modules`, `dist`, `.env.local`. |
| `.env.local.example` | Documents the two vars: `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`. The real `.env.local` is gitignored and never committed. |
| `README.md` (update) | How to run: `npx supabase start`, copy `.env.local.example` → `.env.local`, `npm run dev`. |

### `src/` — frontend

| File | What it does |
| - | - |
| `main.ts` | Bootstrap, in order: (0) check env vars → if missing render the setup banner and stop; (1) `createClient`; (2) `getSession()`, `signInAnonymously()` only when no session (reuse persisted session — anon sign-in is IP-rate-limited); (3) `realtime.setAuth()`; (4) subscribe + start buffering; (5) snapshot; (6) render; wire input/palette/UI. Owns the "canvas is busy" read-only banner too. |
| `config.ts` | `CANVAS_W=1024`, `CANVAS_H=1024`, `CHUNK=64`, `PALETTE` (16 hex), `COOLDOWN_MS=10_000`, precomputed `PALETTE_U32` (ABGR little-endian encoding from the rendering skill). MUST mirror the SQL constants. |
| `supabase.ts` | Single `createClient(VITE_SUPABASE_URL, VITE_SUPABASE_PUBLISHABLE_KEY)` instance. Never exports anything else; no service-role key anywhere. |
| `database.types.ts` | Generated, never hand-edited: `npx supabase gen types typescript --local > src/database.types.ts`. |
| `types.ts` | Shared types: `PixelEvent {x, y, c, s}`, chunk row `{cx, cy, data, seq}`, `Viewport {scale, ox, oy}`, pending-write record. |
| `canvas/world.ts` | World buffer: `ImageData(1024,1024)` + `Uint32Array` view; `applyPixel(x, y, colorIdx)` (idempotent, marks dirty rect, never draws); base64 chunk decode into the buffer with `PALETTE_U32[b] ?? PALETTE_U32[0]` fallback; `chunkSeq: Map<key, seq>` tracking; flush dirty rects to the offscreen world canvas via `putImageData` with source rect. |
| `canvas/viewport.ts` | `{scale, ox, oy}` in CSS px; `screenToWorld`/`worldToScreen` (always `Math.floor`, reject out-of-bounds); `zoomAtCursor` with clamp between "whole canvas fits" and ~40×; `fitToScreen()` for initial view. |
| `canvas/renderer.ts` | Visible `<canvas>` sized to CSS box × `devicePixelRatio`; draw-on-demand loop (`needsDraw` → one `requestAnimationFrame`); `drawImage(worldCanvas, 0, 0)` under `setTransform(dpr*scale, 0, 0, dpr*scale, dpr*ox, dpr*oy)`; `imageSmoothingEnabled = false` re-set after every resize; hover outline + grid only when `scale >= 8`; listens for DPR changes (window moving between monitors). Never draws from inside realtime callbacks. |
| `canvas/input.ts` | Pointer Events + `setPointerCapture`: press → **click** if movement < 5 px else **pan**; two active pointers → pinch zoom; wheel zoom with `{passive: false}`; CSS `touch-action: none`. Emits `place(x, y)` or pan/zoom deltas; ignores out-of-bounds coords. |
| `canvas/palette.ts` | 16 swatches, current-color state, selection highlight; optional digit-key shortcuts. |
| `canvas/ui.ts` | Status/cooldown banner: remaining-cooldown countdown, friendly messages for `cooldown_active` / `out_of_bounds` / `invalid_color` / `not_authenticated`, "canvas is busy" read-only banner, setup banner for missing keys. |
| `realtime/sync.ts` | Private channel `canvas` subscription with `{config: {private: true}}`; buffers every `pixel` broadcast until the snapshot is applied; `resync()` on **every** `SUBSCRIBED` (broadcast never replays missed events) and on `visibilitychange` after the tab was hidden > ~60 s; drains the buffer applying only events with `s > chunkSeq[chunkOf(x,y)]`; flips to live mode; sets `live = false` on `CHANNEL_ERROR`/`TIMED_OUT`. Repeated subscribe failures (connection-limit) → callback that triggers the read-only banner + slow (≥ 30 s) snapshot poll, never a tight retry loop. |
| `realtime/pixel.ts` | Write path: local cooldown gate; optimistic paint (remember `prev`, write new color, mark dirty, record pending `{x, y, prev, color}`); `supabase.rpc('place_pixel', {p_x, p_y, p_color})`; on success start the cooldown timer; on error revert `prev` **unless** a broadcast for that `(x, y)` with a newer seq arrived meanwhile, and resync the timer on `cooldown_active`. Also exposes echo reconciliation: when a broadcast lands for a pending `(x, y)`, clear the pending record (server confirmed; the apply itself is idempotent). |

### `supabase/` — backend

| File | What it does |
| - | - |
| `config.toml` | Local stack config; `[auth] enable_anonymous_sign_ins = true`; api/realtime defaults. |
| `migrations/<timestamp>_init_canvas.sql` | The only schema change. Based on the skill's `references/schema.sql`: `canvas_chunks(cx, cy, data bytea, seq bigint)` PK `(cx, cy)`; `placements(user_id, last_placed_at)`; `pixel_seq` sequence; RLS enabled on both tables; `select`-only policy on `canvas_chunks` (anon + authenticated); **no** policies on `placements`; `select` policy on `realtime.messages` for the private `canvas` topic (receive only — never an `insert` policy); seed of 256 all-zero chunks; `get_canvas()` returning `encode(data,'base64')`; `place_pixel(int,int,int)` `security definer`, `search_path=''`, with in-order: auth check → bounds → palette range → cooldown upsert → `select ... for update` on the chunk **before** `nextval` → `set_byte` + seq → `realtime.send('{x,y,c,s}', 'pixel', 'canvas', true)`; `revoke execute ... from public, anon` + `grant execute ... to authenticated` on `place_pixel`. Stable error messages: `not_authenticated`, `out_of_bounds`, `invalid_color`, `cooldown_active`. |

## Data flow: click → canvas → Supabase → other browsers

1. **Click → coordinates.** `input.ts` detects a click (pointer up, < 5 px moved), maps screen →
   world with `Math.floor((clientX - rect.left - ox) / scale)`, rejects out-of-bounds, emits
   `place(x, y)` with the selected palette index `c`.
2. **Coordinates → local canvas (optimistic).** `pixel.ts` gates on the local cooldown timer
   (show remaining time, stop). Otherwise: `prev = u32[y*W+x]`; `u32[...] = PALETTE_U32[c]`; mark
   dirty rect; record pending `{x, y, prev, c}`; the user sees the change on the next
   `requestAnimationFrame` (renderer flushes the dirty rect to the offscreen world canvas, then
   `drawImage`s it into the view).
3. **Local canvas → Supabase.** `supabase.rpc('place_pixel', {p_x, p_y, p_color})`. Inside the
   function (one transaction): validate auth/bounds/palette, pass the cooldown upsert, lock the
   chunk row, take `nextval(pixel_seq)` as `s`, `set_byte` the chunk, update its `seq`, and call
   `realtime.send({x, y, c, s}, 'pixel', 'canvas', private)`. Returning `s` and broadcasting in
   the same transaction is what guarantees broadcast order == seq order.
4. **Supabase → other browsers.** Realtime delivers the broadcast to every connected subscriber on
   the private topic `canvas` (the `realtime.messages` select policy authorizes authenticated
   receivers). A client already in live mode applies the event immediately:
   `u32[y*W+x] = PALETTE_U32[c]`, dirty rect, next frame draws it. A client still bootstrapping
   puts the event in the buffer; after the snapshot is applied it drains the buffer, applying an
   event only if `s > chunkSeq` for that chunk — so no pixel is lost (subscribe happens *before*
   the snapshot) and none is applied twice.
5. **Back to the originator (echo).** The same broadcast is also delivered to the painter's own
   socket. Applying it is idempotent (same value), and it clears the pending record — the server
   is now the source of truth for that pixel. The local cooldown timer comes from the RPC result,
   not from the echo.
6. **Failure path.** If the RPC fails (`cooldown_active` etc.), `pixel.ts` restores `prev`
   — unless an echo/broadcast for that exact `(x, y)` with a newer seq arrived in the meantime —
   and shows the mapped UI message. The server is always the authority; client checks are UX only.

## Edge cases

1. **User's own Realtime echo.** Handled by design: optimistic paint + idempotent `applyPixel` +
   pending map keyed by `(x, y)`. Echo confirms (clears pending); error reverts unless a newer
   seq for that pixel already arrived. The timer is never driven by the echo.
2. **Drag that paints many cells.** Not a paint — it's a pan. Only < 5 px movement counts as a
   click, so one gesture places at most one pixel. Even if a buggy client fired several RPCs, the
   server's per-user cooldown rejects all but the first (`cooldown_active`) and the client reverts
   the unconfirmed optimistic writes. Per-cell cooldowns / batched multi-cell RPCs are explicitly
   out of scope.
3. **First load of the day's blocks.** No daily state exists — the canvas is persistent. First
   load is the bootstrap order: sign in anonymously (reuse stored session) → subscribe and buffer
   → `get_canvas()` (256 chunks, ~1.4 MB base64 total) → decode into the world buffer, recording
   per-chunk `seq` → drain buffer with the `s > chunkSeq` filter → live mode. Later in the day,
   reloads and reconnects take the identical path (`resync()` runs on every `SUBSCRIBED`).
   Budget: ~3.5 k full loads fit the 5 GB/month egress, so no polling — resync only on reconnect
   or after a hidden tab is resurfaced (> 60 s).
4. **Browser with no Supabase keys.** `main.ts` checks `import.meta.env.VITE_SUPABASE_URL` and
   `VITE_SUPABASE_PUBLISHABLE_KEY` before anything else. If either is missing it renders a static
   setup banner (the two variable names, "put them in `.env.local`, restart the dev server", plus
   "enable anonymous sign-ins in the Supabase dashboard") and stops: no `createClient`, no
   subscribe, no retry loops, no unhandled rejections.

Secondary edge cases, each already covered by the design above:

- **Reconnect** (`CHANNEL_ERROR`/`TIMED_OUT` → `SUBSCRIBED`): full `resync()`; broadcast does not
  replay missed events.
- **Tab hidden > 60 s**: background sockets are throttled → resync on `visibilitychange`.
- **Realtime connection limit (200)**: subscribe failures → read-only "canvas is busy" banner +
  ≥ 30 s snapshot poll, never a tight socket retry loop.
- **Paused project** (free tier, ~1 week inactivity): every RPC/snapshot fails → banner; the
  first thing to check in the dashboard before debugging code.
- **Anon sign-in IP rate limit (~30/h)**: never re-sign-in per page load — reuse the
  localStorage-persisted session.
- **PostgREST 1000-row cap**: 256 chunks fit; no paging needed (revisit only if chunk size changes).
- **Corrupt/foreign palette byte in a chunk**: decode falls back to `PALETTE_U32[0]`.

## Free-tier budget

+1 broadcast per placement × concurrent viewers (≤ 200 connections); ~1.4 MB egress per full
load (~3.5 k loads/month of 5 GB); database stays fixed at ~1 MB (no per-placement tables, no
history log). Cooldown (10 s) is the main cost lever; no changes to it are planned.

## Out of scope for v1

Daily reset, drag-paint, user accounts/avatars, undo/history, pixel deletion, region-based
topics, CAPTCHA/anti-bot beyond the cooldown, hosted `supabase db push` / `supabase link`
(requires explicit user OK), anything using the service-role key.

## Ordered tasks

1. Scaffold root files (`package.json`, `tsconfig.json`, `vite.config.ts`, `index.html`,
   `.gitignore`, `.env.local.example`); `npm install`.
2. `supabase/config.toml` + migration from the skill's reference schema (adapt, don't copy
   blindly); `npx supabase start`; `npx supabase db reset` until it applies cleanly.
3. SQL smoke tests (as authenticated and as `anon`, per the skill's Testing section).
4. `src/config.ts`, `src/supabase.ts`, `src/types.ts`, `src/canvas/world.ts`,
   `src/canvas/viewport.ts`, `src/canvas/renderer.ts`.
5. `src/realtime/sync.ts` (bootstrap order + buffer + resync) and `src/realtime/pixel.ts`
   (optimistic write + echo reconciliation + error mapping).
6. `src/canvas/input.ts`, `src/canvas/palette.ts`, `src/canvas/ui.ts`.
7. `src/main.ts` wiring, including the missing-keys banner.
8. `npx supabase gen types typescript --local > src/database.types.ts`.
9. Validation (below).

## Validation plan

- `npx tsc --noEmit` and `npm run build` clean.
- `npx supabase db reset` applies the migration with no errors.
- SQL smoke tests (skill): `place_pixel(10,10,3)` returns a seq; immediate second call →
  `cooldown_active`; `place_pixel(5000,0,1)` → `out_of_bounds`; `get_byte` on chunk (0,0) reads
  3; as `anon`, `place_pixel` is denied and a direct `update canvas_chunks` affects 0 rows.
- Manual, two browser windows (per the rendering skill's Verify section):
  - Paint in window A → appears in window B on the next frame.
  - Zoom to max, click pixel edges/corners → highlighted pixel matches painted pixel.
  - Drag pans; pinch/wheel zoom is stable; resize + move between monitors keeps pixels sharp.
  - Paint, then refresh immediately: optimistic paint confirmed (no flicker back), cooldown
    timer shown.
  - Trigger `cooldown_active` (double-click fast) → friendly message, timer resynced, no
    permanent wrong color.
  - Kill the network, place pixels elsewhere, restore → reconnect resyncs; no missing or
    duplicated pixels (test the buffer path by loading the page while another window is painting).
  - Run the dev server without `.env.local` → setup banner, empty console errors.
