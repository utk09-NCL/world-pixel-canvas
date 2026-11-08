---
name: canvas-database
description: Design and change the World Canvas Postgres schema on Supabase. Covers migrations, RLS policies, the canvas_chunks table, the place_pixel and get_canvas RPCs, cooldown/rate limiting, and Realtime authorization policies. Use this skill whenever a task touches SQL, supabase/migrations, tables, policies, database functions, pixel validation, cooldown rules, canvas size or palette size, even if the user only says "store pixels", "save colors", or "stop people spamming".
metadata:
  project: world-canvas
  version: "1.0"
---

# Canvas database (Supabase Postgres)

## Data model (do not deviate without updating AGENTS.md)

- `public.canvas_chunks(cx smallint, cy smallint, data bytea, seq bigint)`, primary key `(cx, cy)`.
  Each `data` value holds `CHUNK*CHUNK` bytes in row-major order, one palette index per pixel.
  `seq` is the global sequence number of the last write to that chunk.
- `public.placements(user_id uuid pk → auth.users, last_placed_at timestamptz)` stores cooldown state.
- `public.pixel_seq` is a sequence that orders all writes.
- Defaults: canvas `1024×1024`, chunk `64` (so 16×16 = 256 chunks of 4 KB each, ~1 MB total),
  palette `16`, cooldown `10 seconds`.

The full reference migration is in [references/schema.sql](references/schema.sql). Read it
before you write the first migration or change `place_pixel`.

## Workflow

1. Create a migration: `npx supabase migration new <snake_case_name>`. Never edit a migration
   that may already be applied. Write a new one instead.
2. Write idempotent-where-cheap SQL (`create or replace function`, `drop policy if exists`).
3. Apply it locally: `npx supabase db reset`. Fix errors and repeat until it applies cleanly.
4. Smoke-test in `psql` / Studio SQL editor (see "Testing" below).
5. Regenerate types: `npx supabase gen types typescript --local > src/database.types.ts`.
6. If you changed a constant (size, chunk, palette, cooldown), update `src/config.ts` too.
7. Do **not** run `supabase db push` without the user's explicit OK.

## Rules

- Writes happen **only** inside `place_pixel` (`security definer`, `set search_path = ''`,
  schema-qualified names). `canvas_chunks` gets a `select` policy and nothing else.
  `placements` gets no policies at all.
- `revoke execute ... from public, anon` and then `grant execute ... to authenticated`.
  Supabase grants `anon` execute on new functions by default, so the revoke must name `anon`.
  Anonymous-sign-in users have the `authenticated` role.
- Validate bounds, color range, and cooldown on the server. Raise errors with stable messages
  (`not_authenticated`, `out_of_bounds`, `invalid_color`, `cooldown_active`) because the client matches on them.
- Lock the chunk row (`select ... for update`) **before** calling `nextval`. Otherwise two concurrent
  writes to one chunk can commit in the opposite order to their `seq`, and clients will drop the newer pixel.
- Broadcast from inside the same function with
  `realtime.send(payload, 'pixel', 'canvas', true)`. The last argument `true` makes it a private channel.
  Keep the payload tiny: `{x, y, c, s}`.

## Gotchas

- PostgREST serializes `bytea` as hex (`\x...`), which doubles the size. `get_canvas()` must return
  `encode(data, 'base64')` as `text`.
- PostgREST caps rows per response (default 1000). 256 chunks fit. If you shrink chunks or grow the
  canvas past that, page the request or raise the limit on purpose.
- `set_byte` offsets are 0-based. The offset is `(y % CHUNK) * CHUNK + (x % CHUNK)`, and the chunk is `(x / CHUNK, y / CHUNK)`
  (integer division).
- In PL/pgSQL, after `insert ... on conflict do update ... where <cooldown passed>`, `FOUND` is
  `false` when the `where` blocked the update. That is how the function detects the cooldown.
- Do not add a per-placement history table "just in case". It grows without limit toward the 500 MB
  free-tier database cap. If history is required, consult the `supabase-free-tier` skill first.
- Private channels need an RLS policy on `realtime.messages`. Without a `select` policy, clients
  subscribe successfully but **receive nothing**. Do not add an `insert` policy: that would let clients
  forge pixel broadcasts.
- Anonymous sign-ins must be enabled in the dashboard (Auth → Providers / Sign In settings), or
  `signInAnonymously()` fails. Locally, set `[auth] enable_anonymous_sign_ins = true` in `supabase/config.toml`.

## Testing

```sql
-- as an authenticated user (Studio "role" selector, or set request.jwt.claims locally)
select public.place_pixel(10, 10, 3);      -- returns seq
select public.place_pixel(10, 10, 4);      -- second call within cooldown → ERROR cooldown_active
select public.place_pixel(5000, 0, 1);     -- ERROR out_of_bounds
select get_byte(data, (10 % 64) * 64 + (10 % 64)) from public.canvas_chunks where cx = 0 and cy = 0; -- 3
```

As the `anon` role, `place_pixel` must fail with a permission error, and a direct
`update public.canvas_chunks ...` must affect 0 rows.