---
name: supabase-free-tier
description: Checks whether a World Pixels feature fits the Supabase free plan - Realtime fan-out and rate limits, connections, egress, database size, auth limits, pausing, bots. Use before adding anything that sends more realtime messages, stores more rows, loads more data or adds a service, and for any question about scale, cost, limits, spam or "what if lots of people join".
---

# Supabase free-tier guardrails

The project must run on the free plan. Treat its quotas as product requirements.

## Quotas (free plan, checked 2026-11-08)

Re-check https://supabase.com/docs/guides/realtime/quotas and https://supabase.com/pricing before a decision that depends on a number.

| Resource | Free limit | Why it matters here |
| - | - | - |
| Realtime connections | 200 concurrent | One per open tab |
| Realtime messages | 100 / second, 2 M / month | Every delivery to every viewer counts |
| Broadcast payload | 256 KB | A pixel is ~40 bytes |
| Database | 500 MB | Chunks are fixed at ~1 MB. Nothing may grow per placement |
| Egress | 5 GB (+ 5 GB cached) / month | One full snapshot is ~1.4 MB |
| Auth MAU | 50,000 | Anonymous users count |
| Pausing | after 1 week inactive | A paused project fails every request |

Going over messages/second disconnects clients with `tenant_events`.

## Budget math (one line in every plan or review)

- **Rate (usually the binding limit):** `placements/s × viewers ≤ 100`. With the 10 s cooldown and V people all painting, that is `V²/10`, so about **30 active painters** saturates it.
- **Monthly:** `placements × viewers ≤ 2 M`. With 100 viewers, that is ~20k placements/month.
- **Egress:** `page loads × 1.4 MB ≤ 5 GB`, which is about 3.5k full loads/month.

Write it like this: `+1 broadcast per placement × N viewers; egress and DB unchanged`.

## Levers, cheapest first (recommend one, with its estimate)

1. **Cooldown length**: one SQL constant plus `config.ts`. Cuts every per-placement cost.
2. **Server-side batching**: one broadcast per second carrying all new pixels (for example via `pg_cron`). Makes the rate `1 × viewers`, at the cost of ~1 s of latency.
3. **Snapshot caching**: resync only on reconnect or a long-hidden tab. Never poll `get_canvas()`.
4. **Visible-chunk loading**: an RPC filtered to the viewport, when egress dominates.
5. **Region topics** (`canvas:<region>`) so viewers only receive what they see. Complex; only when the numbers demand it.
6. **Static snapshot** in Storage (CDN-cached) plus recent events. Last resort; needs a job.

## Abuse

- Baseline: anonymous sign-in plus the per-user cooldown in `place_pixel`.
- Next: CAPTCHA on anonymous sign-in (Supabase Auth supports hCaptcha / Turnstile), then a per-IP limit.
- Never move validation to the client to "save requests".

## Gotchas

- Postgres Changes runs an authorization check per change per subscriber. That is why this project broadcasts from the database. Don't "simplify" back to it.
- Free compute is small. No full-table scans or whole-canvas rendering in SQL per request.
