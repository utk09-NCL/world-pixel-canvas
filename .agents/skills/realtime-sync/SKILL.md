---
name: realtime-sync
description: Keep every World Canvas client in sync with live pixel updates using Supabase Realtime Broadcast. Covers anonymous sign-in, subscribing to the private "canvas" channel, loading the chunk snapshot without losing or double-applying pixels, reconnect and resync, and tab-visibility handling. Use this skill when working on src/realtime, live updates, "pixels not showing up for other users", stale or missing pixels after reconnecting, websocket/channel errors, or the app bootstrap order, even if the user doesn't say "realtime" or "Supabase".
metadata:
  project: world-canvas
  version: "1.0"
---

# Realtime sync

The server is the source of truth. Pixels reach clients two ways: the **snapshot** RPC
`get_canvas()` (chunks plus their `seq`) and the **broadcast** event `pixel` on the private topic
`canvas`, with payload `{ x, y, c, s }`. This skill makes those two streams agree.

## Bootstrap sequence (follow exactly)

1. `createClient(VITE_SUPABASE_URL, VITE_SUPABASE_PUBLISHABLE_KEY)`. Create it once, in `src/supabase.ts`.
2. If `getSession()` returns no session, call `supabase.auth.signInAnonymously()`.
3. `await supabase.realtime.setAuth()`. Private channels need the user JWT.
4. Subscribe and **buffer**: push every `pixel` event into an array until the snapshot is applied.
5. When the status reaches `SUBSCRIBED`, call `supabase.rpc('get_canvas')`, decode the chunks, and keep `chunkSeq[cx,cy]`.
6. Drain the buffer and apply each event only if `event.s > chunkSeq[chunkOf(event)]`.
7. Switch to live mode: apply incoming events right away. They arrive in commit order.

Subscribing **before** you load the snapshot is the whole point. If you reverse steps 4 and 5,
any pixel placed between the two calls is lost.

```ts
const buffer: PixelEvent[] = [];
let live = false;

const channel = supabase
  .channel('canvas', { config: { private: true } })
  .on('broadcast', { event: 'pixel' }, ({ payload }) => {
    const ev = payload as PixelEvent;           // { x, y, c, s }
    live ? applyPixel(ev) : buffer.push(ev);
  })
  .subscribe(async (status) => {
    if (status === 'SUBSCRIBED') await resync();
    if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') live = false; // client auto-rejoins
  });

async function resync() {
  live = false;
  const { data, error } = await supabase.rpc('get_canvas');
  if (error) throw error;
  const seqs = loadChunks(data);                // writes pixels, returns Map<chunkKey, seq>
  for (const ev of buffer.splice(0)) {
    if (ev.s > seqs.get(chunkKey(ev.x, ev.y))!) applyPixel(ev);
  }
  live = true;
}
```

## Rules

- `resync()` runs on **every** `SUBSCRIBED`, not just the first one. Broadcast does not replay
  messages missed while disconnected.
- Also resync when `document.visibilityState` becomes `visible` after the tab was hidden for more than about 60 s.
  Browsers throttle background sockets.
- `applyPixel` must be idempotent and cheap. It writes into the pixel buffer and marks a dirty
  rect, and the renderer draws on the next animation frame (see `pixel-canvas-rendering`). Never draw
  synchronously inside the callback.
- Placing a pixel means calling `supabase.rpc('place_pixel', { p_x, p_y, p_color })`. Map the error
  message (`cooldown_active`, `out_of_bounds`, `invalid_color`, `not_authenticated`) to UI states.
  The server also echoes your own pixel back as a broadcast, so do not apply it twice in a way that
  breaks anything.
- Clients **never** call `channel.send()` for pixels. RLS blocks it anyway, and only the database broadcasts.
- If the subscribe fails because the project hit its concurrent-connection limit, show a read-only
  "canvas is busy" banner. Load the snapshot once and poll it slowly (≥ 30 s) instead of retrying the socket in a tight loop.

## Gotchas

- When a private channel has no `select` policy on `realtime.messages`, the subscribe still reports
  `SUBSCRIBED` but no events ever arrive. Check the policy before you debug client code.
- If Realtime settings allow public access, a missing `private: true` on the client still
  connects and then receives nothing from `realtime.send(..., true)`. Topic name **and** privacy must both match.
- `payload` in the callback is the JSON object passed to `realtime.send`. Do not unwrap
  `.record` / `.new`, because those belong to Postgres Changes, which this project does not use.
- Supabase does not compress chunk base64. The snapshot is about 1.4 MB, so cache the decoded state and avoid
  calling `get_canvas()` more than needed (egress quota).
- `signInAnonymously()` is rate-limited per IP (the default is about 30 per hour). Reuse the stored session.
  Never sign in again on every page load.

## Debugging

Fire a fake event from SQL (local or Studio) to test the client path in isolation:

```sql
select realtime.send('{"x":1,"y":1,"c":5,"s":0}'::jsonb, 'pixel', 'canvas', true);
```

`s: 0` is ignored during buffering (chunk seq ≥ 0) but applied in live mode. That is expected.