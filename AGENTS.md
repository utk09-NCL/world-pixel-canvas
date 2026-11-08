# AGENTS.md — World Canvas

A huge shared pixel canvas on the web. Anyone can open the page, pick a color, and
paint one pixel at a time (with a cooldown). Everyone sees everyone else's pixels
appear live. The backend is a **Supabase free-tier project** (Postgres + Realtime +
Anonymous Auth). There is no custom server.

## Status

The project is new: only agent tooling exists so far (this file, `.agents/skills/`,
`.github/agents/`). The stack and layout below are the **chosen defaults**. Follow
them when you scaffold, and update this file if the team decides differently.

## Stack (defaults)

- Frontend: **Vite + TypeScript (strict)**, plain DOM + `<canvas>`, no UI framework.
- Backend: **Supabase**: Postgres (schema via migrations), Realtime **Broadcast**
  (private channel, sent from the database), **Anonymous sign-ins** for identity/cooldowns.
- Client SDK: `@supabase/supabase-js` v2.
- Tooling: Supabase CLI via `npx supabase` (local stack needs Docker).

## Target layout

```text
src/
  main.ts                 # bootstraps auth → realtime → snapshot → render
  config.ts               # CANVAS_W/H, CHUNK, PALETTE, COOLDOWN_MS (mirrors SQL constants)
  supabase.ts             # single createClient() instance
  database.types.ts       # generated, never hand-edit
  canvas/                 # renderer, viewport (pan/zoom), input, palette UI
  realtime/               # snapshot loading, channel subscription, resync
supabase/
  config.toml
  migrations/             # the ONLY place schema changes live
.env.local                # VITE_SUPABASE_URL, VITE_SUPABASE_PUBLISHABLE_KEY (gitignored)
```

## Commands (once scaffolded)

| Task | Command |
| - | - |
| Dev server | `npm run dev` |
| Type check | `npx tsc --noEmit` |
| Build | `npm run build` |
| Local Supabase | `npx supabase start` / `npx supabase stop` |
| New migration | `npx supabase migration new <snake_case_name>` |
| Rebuild local DB from migrations | `npx supabase db reset` |
| Push migrations to hosted project | `npx supabase db push` (ask the user first) |
| Regenerate types | `npx supabase gen types typescript --local > src/database.types.ts` |

Before you call a task done, run the type check and, if you touched SQL, `npx supabase db reset`.

## Core architecture rules

1. **All pixel writes go through the `place_pixel` RPC** (a `security definer` function).
   Clients never `insert`/`update` canvas tables directly, and RLS must block that.
2. **The canvas is stored as chunks**: `canvas_chunks(cx, cy, data bytea, seq)`. Each pixel
   is one byte holding a palette index. Do not create one row per pixel or a pixel history log.
3. **Live updates are Realtime Broadcast sent by Postgres** (`realtime.send`) on the
   private topic `canvas`. Do not use Postgres Changes, and never let clients broadcast pixels.
4. **Clients load in this order:** sign in anonymously → subscribe (buffer events) → load snapshot →
   apply the buffered events newer than each chunk's `seq` → render. After any reconnect,
   load the snapshot again.
5. **Constants are defined twice**: in SQL (inside `place_pixel`) and in `src/config.ts`.
   Change both in the same task.
6. **Free tier is a hard constraint.** Every feature must fit the quotas. Think about
   Realtime message fan-out, egress, and database size before adding anything. See the
   `supabase-free-tier` skill.

## Security boundaries

- Only the **publishable/anon key** goes in the client. Never put the `service_role` / `sb_secret_...`
  key in `src/`, `.env*` files that Vite exposes (`VITE_*`), or a commit.
- RLS is enabled on every table in `public`. A table with RLS on and no policies is intentional
  (only definer functions may touch it).
- Every `security definer` function sets `search_path = ''` and uses schema-qualified names.
- Server-side checks are the authority for bounds, palette range, and cooldown. Client checks are only for UX.

## Never without asking the user

- `supabase db push`, `supabase link`, or any command against the **hosted** project.
- Editing a migration that may already be applied. Add a new migration instead.
- Adding paid services, new third-party backends, or anything that breaks the free-tier constraint.

## Skills (`.agents/skills/`)

| Skill | Use when |
| - | - |
| `canvas-database` | schema, migrations, RLS, the `place_pixel` / `get_canvas` RPCs, cooldowns |
| `realtime-sync` | subscribing to live pixels, snapshot + buffering, reconnect/resync |
| `pixel-canvas-rendering` | drawing the canvas, pan/zoom, click-to-pixel mapping, palette, optimistic paint |
| `supabase-free-tier` | quota checks, scaling/abuse decisions, "will this fit the free plan?" |

## Agents (`.github/agents/`)

- **canvas-planner**: read-only. Turns a feature request into a step-by-step plan, then hands off to the builder.
- **canvas-builder**: implements the plan with the skills above, then hands off to the reviewer.
- **canvas-reviewer**: read-only review for security, correctness, and free-tier impact, then hands fixes back to the builder.
