-- Reference migration for World Canvas. Copy into supabase/migrations/<timestamp>_init_canvas.sql
-- and adapt. Constants here MUST match src/config.ts.
-- ─── Tables ────────────────────────────────────────────────────────────────
create table public.canvas_chunks (
  cx smallint not null,
  cy smallint not null,
  data bytea not null,
  -- 64*64 bytes, row-major, one palette index per pixel
  seq bigint not null default 0,
  -- pixel_seq value of the last write to this chunk
  primary key (cx, cy)
);
create table public.placements (
  user_id uuid primary key references auth.users (id) on delete cascade,
  last_placed_at timestamptz not null
);
create sequence public.pixel_seq;
-- ─── RLS ───────────────────────────────────────────────────────────────────
alter table public.canvas_chunks enable row level security;
alter table public.placements enable row level security;
create policy "canvas chunks are readable by everyone" on public.canvas_chunks for
select to anon,
  authenticated using (true);
-- placements: intentionally no policies (only place_pixel touches it)
-- Realtime authorization for the private "canvas" topic: receive only, never send.
create policy "authenticated users receive canvas broadcasts" on realtime.messages for
select to authenticated using (
    realtime.topic() = 'canvas'
    and realtime.messages.extension = 'broadcast'
  );
-- ─── Seed: 16 x 16 chunks of 64 x 64, all palette index 0 (white) ─────────
insert into public.canvas_chunks (cx, cy, data)
select cx,
  cy,
  decode(repeat('00', 64 * 64), 'hex')
from generate_series(0, 15) as cx,
  generate_series(0, 15) as cy;
-- ─── Snapshot RPC ──────────────────────────────────────────────────────────
create or replace function public.get_canvas() returns table (cx smallint, cy smallint, data text, seq bigint) language sql stable
set search_path = '' as $$
select c.cx,
  c.cy,
  encode(c.data, 'base64'),
  c.seq
from public.canvas_chunks c
order by c.cy,
  c.cx;
$$;
-- ─── Write RPC ─────────────────────────────────────────────────────────────
create or replace function public.place_pixel(p_x int, p_y int, p_color int) returns bigint language plpgsql security definer
set search_path = '' as $$
declare c_width constant int := 1024;
c_height constant int := 1024;
c_chunk constant int := 64;
c_palette constant int := 16;
c_cooldown constant interval := interval '10 seconds';
v_uid uuid := auth.uid();
v_cx int;
v_cy int;
v_seq bigint;
begin if v_uid is null then raise exception 'not_authenticated';
end if;
if p_x < 0
or p_x >= c_width
or p_y < 0
or p_y >= c_height then raise exception 'out_of_bounds';
end if;
if p_color < 0
or p_color >= c_palette then raise exception 'invalid_color';
end if;
-- Cooldown: upsert only succeeds if the previous placement is old enough.
insert into public.placements as p (user_id, last_placed_at)
values (v_uid, now()) on conflict (user_id) do
update
set last_placed_at = excluded.last_placed_at
where p.last_placed_at <= now() - c_cooldown;
if not found then raise exception 'cooldown_active';
end if;
v_cx := p_x / c_chunk;
v_cy := p_y / c_chunk;
-- Lock the chunk BEFORE taking a seq so seq order == commit order per chunk.
perform 1
from public.canvas_chunks
where cx = v_cx
  and cy = v_cy for
update;
v_seq := nextval('public.pixel_seq');
update public.canvas_chunks
set data = set_byte(
    data,
    (p_y % c_chunk) * c_chunk + (p_x % c_chunk),
    p_color
  ),
  seq = v_seq
where cx = v_cx
  and cy = v_cy;
perform realtime.send(
  jsonb_build_object('x', p_x, 'y', p_y, 'c', p_color, 's', v_seq),
  'pixel',
  -- event
  'canvas',
  -- topic
  true -- private channel
);
return v_seq;
end;
$$;
revoke execute on function public.place_pixel(int, int, int)
from public,
  anon;
grant execute on function public.place_pixel(int, int, int) to authenticated;