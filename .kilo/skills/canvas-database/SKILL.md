---
name: canvas-database
description: World Pixels Postgres on Supabase - migrations, RLS, canvas_chunks, the place_pixel / get_canvas RPCs, cooldowns, Realtime authorization. Use for any SQL, supabase/migrations, policy or database function, and for pixel validation, canvas size, palette or cooldown changes.
---

# Canvas database

Start from [references/schema.sql](references/schema.sql). It is tested: read it before you write the first migration or change `place_pixel`.

## Model

- `canvas_chunks(cx, cy, data bytea, seq)`: 16×16 chunks of 64×64 bytes (1024×1024 canvas, ~1 MB). One byte per pixel holds a palette index, row-major. `seq` is the `pixel_seq` of the chunk's last write.
- `placements(user_id, last_placed_at)`: cooldown state, RLS on, no policies.
- Pixel `(x, y)` lives in chunk `(x / 64, y / 64)` at byte offset `(y % 64) * 64 + (x % 64)` (0-based).

## Workflow

0. First time only: `npx supabase init` creates `supabase/config.toml`. Then `npm run db:start` (needs Docker).
1. `npm run db:migration -- <snake_case_name>`. Never edit a migration that may be applied.
2. `npm run db:reset` until it applies cleanly.
3. Run the test below.
4. `npm run db:types` regenerates `src/database.types.ts`. `npm run check` must still pass.
5. If you changed a constant, update `src/config.ts` in the same task.

## Rules

- `place_pixel` is the only writer: `security definer`, `set search_path = ''`, schema-qualified names.
- Error messages are an API that the client matches on: `not_authenticated`, `out_of_bounds`, `invalid_color`, `cooldown_active`.
- `revoke execute ... from public, anon`, then `grant ... to authenticated`. Anonymous users have the `authenticated` role.
- Lock the chunk row (`for update`) **before** `nextval`. Otherwise concurrent writes commit out of seq order and clients drop the newer pixel.
- Broadcast from inside the same function: `realtime.send(jsonb, 'pixel', 'canvas', true)`. Keep the payload to `{x, y, c, s}`.

## Gotchas

- `realtime.messages` needs a `select` policy for topic `canvas`. Without it, clients subscribe fine and receive nothing. Never add an `insert` policy, because it would let clients forge pixels.
- `get_canvas()` returns base64 text: PostgREST sends `bytea` as hex (2× size), and `encode()` wraps lines every 76 chars, so strip the newlines.
- PostgREST returns at most 1000 rows by default. 256 chunks fit; recheck if chunks shrink.
- After `insert ... on conflict do update ... where`, `FOUND` is false when the `where` blocked the update. That is the cooldown check.
- No per-placement history table: it grows toward the 500 MB cap. Check `supabase-free-tier` first.
- Local anonymous sign-in needs `[auth] enable_anonymous_sign_ins = true` in `supabase/config.toml`.

## Test (local)

Connect with `psql postgresql://postgres:postgres@127.0.0.1:54322/postgres`. `placements.user_id` references `auth.users`, so sign in anonymously once from the app and use that user's id.

```sql
set role authenticated;
set request.jwt.claims = '{"sub":"<user-id>","role":"authenticated"}';
select public.place_pixel(10, 10, 3);   -- returns seq
select public.place_pixel(10, 11, 4);   -- ERROR cooldown_active (within 10 s)
select public.place_pixel(5000, 0, 1);  -- ERROR out_of_bounds
select get_byte(data, 10 * 64 + 10) from public.canvas_chunks where cx = 0 and cy = 0;  -- 3
reset role;
set role anon;
select public.place_pixel(1, 1, 1);         -- ERROR permission denied
update public.canvas_chunks set seq = seq;  -- UPDATE 0 (RLS)
reset role;
```
