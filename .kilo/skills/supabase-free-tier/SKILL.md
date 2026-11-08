---
name: supabase-free-tier
description: Check whether a World Canvas feature or design fits the Supabase free plan, and choose cheaper designs when it doesn't. Covers Realtime message fan-out, concurrent connections, egress, database size, auth limits, project pausing, and abuse/bot mitigation. Use this skill before adding any feature that sends more realtime messages, stores more data, loads more data per visit, or adds a backend service, and whenever the user asks about scaling, cost, limits, "what if lots of people join", spam or bots, even if they don't mention Supabase or pricing.
metadata:
  project: world-canvas
  version: "1.0"
---

# Supabase free-tier guardrails

The project must run on the Supabase **free plan**. Treat its quotas as product requirements.

## Quotas (verify before relying on them)

These numbers are approximate and change over time. Before a decision that depends on one,
check `https://supabase.com/pricing` and `https://supabase.com/docs/guides/realtime/quotas`.

| Resource | Free plan (approx.) | Why it matters here |
| - | - | - |
| Realtime concurrent connections | 200 | Each open tab is 1 connection |
| Realtime messages | 2 M / month | Counted **per delivered message**, so fan-out multiplies |
| Broadcast payload | small (KB range) | Keep pixel payloads at about 40 bytes |
| Database size | 500 MB | No unbounded logs |
| Egress | 5 GB / month | The snapshot is about 1.4 MB per full load |
| Monthly active users | 50,000 | Anonymous users count too |
| Inactivity | Project pauses after ~1 week without activity | Paused means the site is down |

## Budget math (do this for every relevant change)

- **Realtime:** `messages ≈ placements × concurrent_viewers`. With 2 M a month and 100 viewers,
  that is about 20 k placements per month in total. Cooldowns are the main lever.
- **Egress:** `bytes ≈ page_loads × snapshot_size + placements × viewers × ~100 B`. With 5 GB and
  1.4 MB per load, that is about 3.5 k full loads a month.
- **Database:** chunk storage is fixed (about 1 MB). Anything that grows per placement needs a cap or a prune job.

Write the estimate into your plan or review as one line, for example:
`+1 broadcast per placement × N viewers; no change to egress/DB`.

## Levers, cheapest first

1. **Cooldown length** is a single SQL constant plus `config.ts`. Raising it cuts every per-placement cost.
2. **Snapshot caching**: keep the decoded canvas in memory and resync only on reconnect or a long
   hidden tab. Do not poll `get_canvas()`.
3. **Visible-chunk loading**: fetch only the chunks in the viewport (add a filtered RPC) when egress dominates.
4. **Region topics**: broadcast to `canvas:<region>` topics and let clients subscribe only to visible
   regions. This cuts fan-out but adds complexity, so propose it only when the numbers demand it.
5. **Server-side batching**: collect placements and flush one broadcast per second (for example with
   `pg_cron`). This adds about 1 s of latency in exchange for far fewer messages.
6. **Static snapshot**: periodically write the canvas to Supabase Storage (CDN-cached) and have clients
   load that file plus recent events. This is the last resort and needs a scheduled job.

Recommend a single lever. Present it with the estimate. Do not hand over a menu.

## Abuse & bots

- Anonymous sign-in plus a per-user cooldown is the baseline (it lives in `place_pixel`).
- Bots can create many anonymous users. The next steps are Supabase Auth CAPTCHA (hCaptcha/Turnstile,
  which have free tiers) on `signInAnonymously`, then a per-IP limit if needed.
- Never move validation to the client to "save requests".

## Gotchas

- The `service_role` / `sb_secret_...` key bypasses RLS. It must never reach the browser. The client
  uses only the publishable/anon key, which is safe to expose.
- A paused project fails all requests. If the canvas shows nothing and errors appear on
  every call, check the dashboard for a paused project before debugging code.
- Postgres Changes runs an authorization check per change per subscriber and scales poorly. This is one reason
  the project uses database Broadcast. Do not "simplify" back to Postgres Changes.
- Free projects have limited compute. Avoid heavy per-request SQL such as full-table scans or
  generating the whole canvas image in SQL on each request.