---
name: realtime-sync
description: Live pixel sync for World Pixels via Supabase Realtime Broadcast - anonymous sign-in, the private "canvas" channel, snapshot plus buffered events, reconnect and resync, the place_pixel write path, start/stop under React StrictMode. Use for src/realtime, live updates, missing or stale pixels, channel errors, or "other users can't see my pixels".
---

# Realtime sync

Plain TS in `src/realtime/`. `startWorld()` in `src/engine.ts` calls `startSync(world, writer.onBroadcast)` and calls its `stop()` on unmount. Never import React here,
and never call this code from a component. UI state goes out through `setState()` from `src/store.ts`.

Two sources must agree: the snapshot `get_canvas()` (chunks plus `seq`) and the broadcast event `pixel` on the private topic `canvas` (payload `{x, y, c, s}`).

## Bootstrap (exact order)

1. `getSupabase()` from `src/supabase.ts`. It creates the one client; never call `createClient` anywhere else.
2. `getSession()`. Call `signInAnonymously()` only when there is no session: it is rate-limited per IP (~30/hour).
3. `await supabase.realtime.setAuth()`. Private channels need the user's JWT.
4. Subscribe and buffer every event.
5. On `SUBSCRIBED`: load the snapshot, drain the buffer keeping only `ev.s > chunkSeq`, then go live.

Subscribe **before** loading the snapshot. Otherwise pixels placed between the two calls are lost.

```ts
// src/realtime/sync.ts
import type { RealtimeChannel } from '@supabase/supabase-js'
import type { World } from '../canvas/world.ts'
import { setState } from '../store.ts'
import { getSupabase } from '../supabase.ts'
import type { PixelEvent } from '../types.ts'

// Module-level, so StrictMode's start-stop-start in dev reuses one sign-in instead of creating two anonymous users.
let sessionReady: Promise<boolean> | undefined

function ensureSession(): Promise<boolean> {
  sessionReady ??= (async () => {
    const supabase = getSupabase()
    const { data } = await supabase.auth.getSession()
    if (!data.session) {
      const { error } = await supabase.auth.signInAnonymously()
      if (error) {
        sessionReady = undefined // allow a later retry
        return false
      }
    }
    await supabase.realtime.setAuth()
    return true
  })()
  return sessionReady
}

// onPixel: called after each applied event. The engine passes the pixel writer's echo handler (confirms or drops a pending optimistic paint).
export function startSync(world: World, onPixel: (ev: PixelEvent) => void): () => void {
  const supabase = getSupabase()
  const buffer: PixelEvent[] = []
  let live = false
  let stopped = false
  let channel: RealtimeChannel | undefined

  function apply(ev: PixelEvent) {
    world.applyPixel(ev)
    onPixel(ev)
  }

  async function resync() {
    live = false
    const { data, error } = await supabase.rpc('get_canvas')
    if (stopped) return
    if (error) {
      setState({ status: 'offline', notice: 'Could not load the canvas.' })
      return
    }
    const seqs = world.loadChunks(data) // writes pixels, returns Map<chunkKey, seq>
    for (const ev of buffer.splice(0)) {
      if (ev.s > (seqs.get(world.chunkKey(ev.x, ev.y)) ?? 0)) apply(ev)
    }
    live = true
    setState({ status: 'live', notice: null })
  }

  void ensureSession().then((ok) => {
    if (stopped) return // unmounted while signing in
    if (!ok) {
      setState({ status: 'offline', notice: 'Could not sign in. Reload the page to try again.' })
      return
    }
    channel = supabase
      .channel('canvas', { config: { private: true } })
      .on('broadcast', { event: 'pixel' }, ({ payload }) => {
        const ev = payload as PixelEvent // { x, y, c, s }
        if (live) apply(ev)
        else buffer.push(ev)
      })
      .subscribe((status) => {
        if (status === 'SUBSCRIBED') void resync()
        if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') live = false // the client rejoins by itself
      })
  })

  return () => {
    stopped = true
    if (channel) void supabase.removeChannel(channel)
  }
}
```

## Rules

- Resync on **every** `SUBSCRIBED`, and when a tab becomes visible after more than ~60 s hidden. Broadcast does not resend missed messages by default. Opt-in replay is capped at 25 messages per request, so it can't replace the snapshot.
- `world.applyPixel` is idempotent and only writes the buffer and marks the area dirty. The renderer draws on the next frame. Never draw inside the callback, and never call `setState` per pixel.
- To write: `supabase.rpc('place_pixel', { p_x, p_y, p_color })` in `src/realtime/pixel.ts`. Map each error message to `setState({ notice })`. Your own pixel comes back as a broadcast, and applying it again must be harmless.
- Clients never `channel.send()` pixels. Only the database broadcasts.
- If subscribing keeps failing (the 200-connection limit), `setState({ status: 'busy' })` (StatusBar shows the read-only banner) and poll the snapshot every >= 30 s. No tight retry loop.
- Every timer, listener and channel that `startSync` creates is removed by its `stop()`.

## Gotchas

- `SUBSCRIBED` but no events means a missing `select` policy on `realtime.messages`, or a client without `private: true`. Topic and privacy must both match.
- `payload` is the object passed to `realtime.send`. There is no `.record` / `.new`: those belong to Postgres Changes, which this project does not use.
- Events arriving twice in dev means `stop()` did not remove the channel (StrictMode mounts twice).
- Every full snapshot is ~1.4 MB of egress. Keep the decoded state and don't refetch without a reason.

## Debug

Fake a broadcast from SQL to test the client on its own: `select realtime.send('{"x":1,"y":1,"c":5,"s":0}'::jsonb, 'pixel', 'canvas', true);` With `s: 0`, the event is dropped while buffering and applied when live. That is expected.
