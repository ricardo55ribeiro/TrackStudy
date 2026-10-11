-- Run once after migration 003. Additive: existing rows, policies and history stay intact.
begin;
create table public.schedule_blocks (
 id uuid primary key, user_id uuid not null references auth.users(id) on delete cascade,
 title text not null check(length(btrim(title)) between 1 and 120),
 weekday integer not null check(weekday between 1 and 7),
 start_minute integer not null check(start_minute>=0 and start_minute<1440),
 end_minute integer not null check(end_minute>start_minute and end_minute<=1440),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), deleted_at timestamptz,
 revision bigint not null default 1,
 sync_version bigint not null default 0 check(sync_version between 0 and 9007199254740991),
 sync_writer text not null default '' check(length(sync_writer)<=64),
 sync_history jsonb not null default '{}'::jsonb check(jsonb_typeof(sync_history)='object')
);
create table public.academic_events (
 id uuid primary key, user_id uuid not null references auth.users(id) on delete cascade,
 title text not null check(length(btrim(title)) between 1 and 120),
 event_date date not null check(event_date between date '1900-01-01' and date '9999-12-31'),
 event_type text not null check(event_type in ('exam','test','project','presentation','deadline','other')),
 note text not null default '' check(length(note)<=2000),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), deleted_at timestamptz,
 revision bigint not null default 1,
 sync_version bigint not null default 0 check(sync_version between 0 and 9007199254740991),
 sync_writer text not null default '' check(length(sync_writer)<=64),
 sync_history jsonb not null default '{}'::jsonb check(jsonb_typeof(sync_history)='object')
);
create index schedule_blocks_day on public.schedule_blocks(user_id,weekday,start_minute);
create index academic_events_date on public.academic_events(user_id,event_date);
do $$
declare t text;
begin
 foreach t in array array['schedule_blocks','academic_events'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('create policy own_select on public.%I for select to authenticated using ((select auth.uid())=user_id)',t);
  execute format('create policy own_insert on public.%I for insert to authenticated with check ((select auth.uid())=user_id)',t);
  execute format('create policy own_update on public.%I for update to authenticated using ((select auth.uid())=user_id) with check ((select auth.uid())=user_id)',t);
  execute format('revoke all on public.%I from public,anon,authenticated',t);
  execute format('grant select,insert,update on public.%I to authenticated',t);
  execute format('create index %I on public.%I(user_id,updated_at,id)',t||'_sync_cursor',t);
  execute format('create trigger touch_updated before update on public.%I for each row execute function public.trackstudy_touch()',t);
 end loop;
end;
$$;
alter table public.sync_conflicts drop constraint sync_conflicts_table_name_check;
alter table public.sync_conflicts add constraint sync_conflicts_table_name_check
 check(table_name in ('categories','weekly_goals','entries','journal','reviews','schedule_blocks','academic_events'));

-- The existing causal merge body is retained; only its table allowlist expands.
create or replace function public.trackstudy_merge(p_table text,p_row jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  owner_id uuid := auth.uid(); existing jsonb; incoming jsonb; result jsonb;
  canonical uuid; assignments text; winner boolean; incoming_covers boolean; existing_covers boolean;
  ih jsonb; eh jsonb; joined jsonb;
begin
  if owner_id is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_table is null or p_table not in ('categories','weekly_goals','entries','journal','reviews','schedule_blocks','academic_events') then raise exception 'Invalid sync table'; end if;
  if jsonb_typeof(p_row) is distinct from 'object'
     or coalesce((p_row->>'sync_version')::bigint,0) not between 1 and 9007199254740991
     or coalesce(length(p_row->>'sync_writer'),0) not between 1 and 64 then raise exception 'Invalid sync version'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(owner_id::text,0));
  canonical := (p_row->>'id')::uuid;
  if p_table='weekly_goals' then
    select id into canonical from public.weekly_goals where user_id=owner_id
      and category_id=(p_row->>'category_id')::uuid and week_start=(p_row->>'week_start')::date;
  elsif p_table='reviews' then
    select id into canonical from public.reviews where user_id=owner_id and week_start=(p_row->>'week_start')::date;
  end if;
  canonical := coalesce(canonical,(p_row->>'id')::uuid);
  ih := public.trackstudy_history(p_row);
  incoming := p_row || jsonb_build_object('id',canonical,'user_id',owner_id,'revision',1,'sync_history',ih);
  -- Normalize dates/JSON through the actual table type before comparing domain
  -- content; UTC offset spelling and server bookkeeping are not user edits.
  execute format('select to_jsonb(r) from jsonb_populate_record(null::public.%I,$1) r',p_table) into incoming using incoming;
  execute format('select to_jsonb(t) from public.%I t where id=$1 and user_id=$2',p_table) into existing using canonical,owner_id;
  if existing is null then
    execute format('insert into public.%I select * from jsonb_populate_record(null::public.%I,$1) returning to_jsonb(%I.*)',p_table,p_table,p_table)
      into result using incoming;
    return result;
  end if;
  eh := public.trackstudy_history(existing);
  joined := public.trackstudy_history_union(ih,eh);
  incoming_covers := public.trackstudy_covers(ih,eh);
  existing_covers := public.trackstudy_covers(eh,ih);
  winner := case
    when incoming_covers and not existing_covers then true
    when existing_covers and not incoming_covers then false
    else ((incoming->>'sync_version')::bigint,(incoming->>'sync_writer') collate "C") >
         ((existing->>'sync_version')::bigint,(existing->>'sync_writer') collate "C") end;
  -- Only incomparable histories with different user content are conflicts.
  if not incoming_covers and not existing_covers and public.trackstudy_content(incoming)<>public.trackstudy_content(existing) then
    insert into public.sync_conflicts(user_id,table_name,record_id,version,writer,payload)
    values(owner_id,p_table,canonical,
      ((case when winner then existing else incoming end)->>'sync_version')::bigint,
      (case when winner then existing else incoming end)->>'sync_writer',
      case when winner then existing else incoming end) on conflict do nothing;
  end if;
  if not winner then
    if joined <> existing->'sync_history' then
      execute format('update public.%I t set sync_history=$1 where id=$2 and user_id=$3 returning to_jsonb(t)',p_table)
        into existing using joined,canonical,owner_id;
    end if;
    return existing;
  end if;
  if p_table='entries' and (incoming->>'amount',incoming->>'goal_id') is distinct from (existing->>'amount',existing->>'goal_id') then
    raise exception 'Ledger amount and weekly goal are immutable; undo the original and add a new entry';
  end if;
  if p_table='weekly_goals' and (incoming->>'measurement',incoming->>'unit') is distinct from (existing->>'measurement',existing->>'unit')
    and exists(select 1 from public.entries where user_id=owner_id and goal_id=canonical) then
    raise exception 'Cannot reinterpret a weekly goal that contains entries';
  end if;
  incoming := incoming || jsonb_build_object('sync_history',joined);
  select string_agg(format('%I=r.%I',column_name,column_name),',') into assignments from information_schema.columns
    where table_schema='public' and table_name=p_table and column_name not in ('id','user_id','created_at','revision');
  execute format('update public.%I t set %s from jsonb_populate_record(null::public.%I,$1) r where t.id=$2 and t.user_id=$3 returning to_jsonb(t)',p_table,assignments,p_table)
    into result using incoming,canonical,owner_id;
  return result;
end;
$$;


commit;

