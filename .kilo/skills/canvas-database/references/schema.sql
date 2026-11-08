-- World Pixels: reference migration. Copy to supabase/migrations/<timestamp>_init_canvas.sql.
-- Constants (1024x1024, chunk 64, palette 16, cooldown 10 s) MUST match src/config.ts.

-- Tables ---------------------------------------------------------------------
create table public.canvas_chunks (
  cx   smallint not null,
  cy   smallint not null,
  data bytea    not null,            -- 64*64 bytes, row-major, one palette index per pixel
  seq  bigint   not null default 0,  -- pixel_seq value of the last write to this chunk
  primary key (cx, cy)
);

create table public.placements (
  user_id        uuid primary key references auth.users (id) on delete cascade,
  last_placed_at timestamptz not null
);

create sequence public.pixel_seq;

-- RLS ------------------------------------------------------------------------
alter table public.canvas_chunks enable row level security;
alter table public.placements    enable row level security;  -- no policies: only place_pixel touches it

create policy "canvas chunks are readable by everyone"
  on public.canvas_chunks for select to anon, authenticated using (true);

-- Private "canvas" topic: receive only. Never add an insert policy (clients could forge pixels).
create policy "authenticated users receive canvas broadcasts"
  on realtime.messages for select to authenticated
  using (realtime.topic() = 'canvas' and realtime.messages.extension = 'broadcast');

-- Seed: 16 x 16 chunks, every pixel palette index 0 --------------------------
insert into public.canvas_chunks (cx, cy, data)
select cx, cy, decode(repeat('00', 64 * 64), 'hex')
from generate_series(0, 15) as cx, generate_series(0, 15) as cy;

-- Snapshot RPC: base64 text, because PostgREST sends bytea as hex (2x size).
-- encode() wraps base64 every 76 chars; strip the newlines (less egress).
create or replace function public.get_canvas()
returns table (cx smallint, cy smallint, data text, seq bigint)
language sql stable
set search_path = ''
as $$
  select c.cx, c.cy, replace(encode(c.data, 'base64'), E'\n', ''), c.seq
  from public.canvas_chunks c
  order by c.cy, c.cx;
$$;

-- Write RPC: the ONLY way a pixel changes ------------------------------------
create or replace function public.place_pixel(p_x int, p_y int, p_color int)
returns bigint
language plpgsql security definer
set search_path = ''
as $$
declare
  c_width    constant int      := 1024;
  c_height   constant int      := 1024;
  c_chunk    constant int      := 64;
  c_palette  constant int      := 16;
  c_cooldown constant interval := interval '10 seconds';
  v_uid uuid := auth.uid();
  v_cx  int  := p_x / c_chunk;
  v_cy  int  := p_y / c_chunk;
  v_seq bigint;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  if p_x < 0 or p_x >= c_width or p_y < 0 or p_y >= c_height then
    raise exception 'out_of_bounds';
  end if;
  if p_color < 0 or p_color >= c_palette then
    raise exception 'invalid_color';
  end if;

  -- Cooldown: the update only runs when the last placement is old enough.
  insert into public.placements as p (user_id, last_placed_at)
  values (v_uid, now())
  on conflict (user_id) do update
    set last_placed_at = excluded.last_placed_at
    where p.last_placed_at <= now() - c_cooldown;
  if not found then
    raise exception 'cooldown_active';
  end if;

  -- Lock the chunk BEFORE taking a seq, so per-chunk seq order = commit order.
  perform 1 from public.canvas_chunks where cx = v_cx and cy = v_cy for update;
  v_seq := nextval('public.pixel_seq');

  update public.canvas_chunks
  set data = set_byte(data, (p_y % c_chunk) * c_chunk + (p_x % c_chunk), p_color),
      seq  = v_seq
  where cx = v_cx and cy = v_cy;

  perform realtime.send(                     -- (payload, event, topic, private)
    jsonb_build_object('x', p_x, 'y', p_y, 'c', p_color, 's', v_seq),
    'pixel', 'canvas', true);
  return v_seq;
end;
$$;

-- New functions are executable by PUBLIC, and Supabase also grants anon. Revoke both.
revoke execute on function public.place_pixel(int, int, int) from public, anon;
grant  execute on function public.place_pixel(int, int, int) to authenticated;
