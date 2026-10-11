-- Run AFTER 001_initial.sql. No global seeds, destructive changes or service keys.
begin;

do $$
declare t text;
begin
  foreach t in array array['categories','weekly_goals','entries','journal','reviews'] loop
    execute format('alter table public.%I add column sync_version bigint not null default 0 check (sync_version between 0 and 9007199254740991)', t);
    execute format('alter table public.%I add column sync_writer text not null default '''' check (length(sync_writer) <= 64)', t);
    execute format('revoke delete, truncate, references, trigger on public.%I from authenticated', t);
  end loop;
end;
$$;

create table public.sync_conflicts (
  user_id uuid not null references auth.users(id) on delete cascade,
  table_name text not null check (table_name in ('categories','weekly_goals','entries','journal','reviews')),
  record_id uuid not null,
  version bigint not null,
  writer text not null,
  payload jsonb not null,
  saved_at timestamptz not null default now(),
  primary key (user_id,table_name,record_id,version,writer)
);
alter table public.sync_conflicts enable row level security;
create policy own_select on public.sync_conflicts for select to authenticated using ((select auth.uid())=user_id);
create policy own_insert on public.sync_conflicts for insert to authenticated with check ((select auth.uid())=user_id);
revoke all on public.sync_conflicts from anon, authenticated;
grant select,insert on public.sync_conflicts to authenticated;

-- One atomic merge per record. Logical versions avoid dependence on wall-clock
-- accuracy. Equal-version concurrent edits are resolved by the device identifier.
-- The losing version is retained, including journal/review text and undo state.
create function public.trackstudy_merge(p_table text, p_row jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  owner_id uuid := auth.uid();
  existing jsonb;
  incoming jsonb;
  result jsonb;
  canonical uuid;
  assignments text;
  winner boolean;
begin
  if owner_id is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_table not in ('categories','weekly_goals','entries','journal','reviews') then
    raise exception 'Invalid sync table';
  end if;
  if jsonb_typeof(p_row) <> 'object' or (p_row->>'sync_version')::bigint not between 1 and 9007199254740991
     or coalesce(length(p_row->>'sync_writer'),0) not between 1 and 64 then
    raise exception 'Invalid sync version';
  end if;
  -- Serializes natural-key creation and compare/write for this account, including
  -- two requests arriving simultaneously from different offline devices.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(owner_id::text,0));
  canonical := (p_row->>'id')::uuid;
  if p_table='weekly_goals' then
    select id into canonical from public.weekly_goals
      where user_id=owner_id and category_id=(p_row->>'category_id')::uuid and week_start=(p_row->>'week_start')::date;
  elsif p_table='reviews' then
    select id into canonical from public.reviews where user_id=owner_id and week_start=(p_row->>'week_start')::date;
  end if;
  canonical := coalesce(canonical,(p_row->>'id')::uuid);
  incoming := p_row || jsonb_build_object('id',canonical,'user_id',owner_id,'revision',1);
  execute format('select to_jsonb(t) from public.%I t where id=$1 and user_id=$2',p_table)
    into existing using canonical,owner_id;
  if existing is null then
    execute format('insert into public.%I select * from jsonb_populate_record(null::public.%I,$1) returning to_jsonb(%I.*)',p_table,p_table,p_table)
      into result using incoming;
    return result;
  end if;
  winner := ((incoming->>'sync_version')::bigint,(incoming->>'sync_writer') collate "C") >
            ((existing->>'sync_version')::bigint,(existing->>'sync_writer') collate "C");
  if (incoming->>'sync_version',incoming->>'sync_writer') = (existing->>'sync_version',existing->>'sync_writer') then
    return existing; -- Retrying a committed request never increments or duplicates.
  end if;
  insert into public.sync_conflicts(user_id,table_name,record_id,version,writer,payload)
    values (owner_id,p_table,canonical,
      ((case when winner then existing else incoming end)->>'sync_version')::bigint,
      (case when winner then existing else incoming end)->>'sync_writer',
      case when winner then existing else incoming end)
    on conflict do nothing;
  if not winner then return existing; end if;
  if p_table='entries' and (incoming->>'amount',incoming->>'goal_id') is distinct from (existing->>'amount',existing->>'goal_id') then
    raise exception 'Ledger amount and weekly goal are immutable; undo the original and add a new entry';
  end if;
  if p_table='weekly_goals' and (incoming->>'measurement',incoming->>'unit') is distinct from (existing->>'measurement',existing->>'unit')
     and exists(select 1 from public.entries where user_id=owner_id and goal_id=canonical) then
    raise exception 'Cannot reinterpret a weekly goal that contains entries';
  end if;
  select string_agg(format('%I=r.%I',column_name,column_name),',') into assignments
    from information_schema.columns where table_schema='public' and table_name=p_table
    and column_name not in ('id','user_id','created_at','revision');
  execute format('update public.%I t set %s from jsonb_populate_record(null::public.%I,$1) r where t.id=$2 and t.user_id=$3 returning to_jsonb(t)',p_table,assignments,p_table)
    into result using incoming,canonical,owner_id;
  return result;
end;
$$;
revoke all on function public.trackstudy_merge(text,jsonb) from public, anon;
grant execute on function public.trackstudy_merge(text,jsonb) to authenticated;
commit;
