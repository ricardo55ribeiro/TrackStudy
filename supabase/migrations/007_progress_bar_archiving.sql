-- Apply once after 006_todo_list.sql, using the Supabase SQL Editor
-- Lifecycle baselines are created by clients in their local calendar week
-- Existing goals, entries, identities and historical snapshots are untouched
begin;

create table public.category_states (
 id uuid primary key, user_id uuid not null references auth.users(id) on delete cascade,
 category_id uuid not null, week_start date not null check(extract(isodow from week_start)=1),
 included boolean not null, is_baseline boolean not null,
 changed_at timestamptz not null, created_at timestamptz not null, updated_at timestamptz not null,
 revision bigint not null default 1,
 sync_version bigint not null default 0 check(sync_version between 0 and 9007199254740991),
 sync_writer text not null default '' check(length(sync_writer)<=64),
 sync_history jsonb not null default '{}'::jsonb check(jsonb_typeof(sync_history)='object'),
 foreign key(category_id,user_id) references public.categories(id,user_id),
 unique(category_id,week_start)
);
create index category_states_week on public.category_states(user_id,category_id,week_start);
alter table public.category_states enable row level security;
create policy own_select on public.category_states for select to authenticated using ((select auth.uid())=user_id);
create policy own_insert on public.category_states for insert to authenticated with check ((select auth.uid())=user_id);
create policy own_update on public.category_states for update to authenticated using ((select auth.uid())=user_id) with check ((select auth.uid())=user_id);
revoke all on public.category_states from public,anon,authenticated;
grant select,insert,update on public.category_states to authenticated;
create trigger touch_updated before update on public.category_states for each row execute function public.trackstudy_touch();
alter table public.sync_conflicts drop constraint sync_conflicts_table_name_check;
alter table public.sync_conflicts add constraint sync_conflicts_table_name_check
 check(table_name in ('categories','weekly_goals','entries','journal','reviews','schedule_blocks','academic_events','todo_topics','todo_tasks','category_states'));

-- Both local SQLite and PostgreSQL derive the old global flags from this order
create function public.trackstudy_category_state(p_category uuid,p_owner uuid)
returns public.category_states language sql stable security invoker set search_path='' as $$
 select s from public.category_states s where category_id=p_category and user_id=p_owner
 order by is_baseline asc, case when not is_baseline then week_start end desc, week_start asc,id limit 1
$$;
create function public.trackstudy_category_cache() returns trigger language plpgsql security invoker set search_path='' as $$
declare state public.category_states;
begin
 state := public.trackstudy_category_state(new.id,new.user_id);
 if state.id is not null then
  new.active := state.included;
  new.archived_at := case when state.included then null else state.changed_at end;
 end if;
 return new;
end;
$$;
create trigger category_cache before insert or update on public.categories for each row execute function public.trackstudy_category_cache();
create function public.trackstudy_state_guard() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if (new.category_id,new.week_start) is distinct from (old.category_id,old.week_start) then
  raise exception 'A bar state cannot change category or week';
 end if;
 return new;
end;
$$;
create trigger state_guard before update on public.category_states for each row execute function public.trackstudy_state_guard();
create function public.trackstudy_refresh_category_cache() returns trigger language plpgsql security invoker set search_path='' as $$
declare state public.category_states;
begin
 state := public.trackstudy_category_state(new.category_id,new.user_id);
 update public.categories set active=state.included,
  archived_at=case when state.included then null else state.changed_at end
 where id=new.category_id and user_id=new.user_id
  and (active,archived_at) is distinct from (state.included,case when state.included then null else state.changed_at end);
 return new;
end;
$$;
create trigger refresh_category_cache after insert or update on public.category_states for each row execute function public.trackstudy_refresh_category_cache();
revoke all on function public.trackstudy_category_state(uuid,uuid),public.trackstudy_category_cache(),public.trackstudy_state_guard(),public.trackstudy_refresh_category_cache() from public,anon;
grant execute on function public.trackstudy_category_state(uuid,uuid),public.trackstudy_category_cache(),public.trackstudy_state_guard(),public.trackstudy_refresh_category_cache() to authenticated;

create or replace function public.trackstudy_merge(p_table text,p_row jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  owner_id uuid := auth.uid(); existing jsonb; incoming jsonb; result jsonb;
  canonical uuid; assignments text; winner boolean; incoming_covers boolean; existing_covers boolean;
  ih jsonb; eh jsonb; joined jsonb;
begin
  if owner_id is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_table is null or p_table not in ('categories','weekly_goals','entries','journal','reviews','schedule_blocks','academic_events','todo_topics','todo_tasks','category_states') then raise exception 'Invalid sync table'; end if;
  if jsonb_typeof(p_row) is distinct from 'object'
     or coalesce((p_row->>'sync_version')::bigint,0) not between 1 and 9007199254740991
     or coalesce(length(p_row->>'sync_writer'),0) not between 1 and 64 then raise exception 'Invalid sync version'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(owner_id::text,0));
  canonical := (p_row->>'id')::uuid;
  if p_table in ('weekly_goals','category_states') then
    execute format('select id from public.%I where user_id=$1 and category_id=$2 and week_start=$3',p_table)
      into canonical using owner_id,(p_row->>'category_id')::uuid,(p_row->>'week_start')::date;
  elsif p_table='reviews' then
    select id into canonical from public.reviews where user_id=owner_id and week_start=(p_row->>'week_start')::date;
  end if;
  canonical := coalesce(canonical,(p_row->>'id')::uuid);
  ih := public.trackstudy_history(p_row);
  incoming := p_row || jsonb_build_object('id',canonical,'user_id',owner_id,'revision',1,'sync_history',ih);
  -- Normalize dates/JSON through the actual table type before comparing domain
  -- content; UTC offset spelling and server bookkeeping are not user edits
  execute format('select to_jsonb(r) from jsonb_populate_record(null::public.%I,$1) r',p_table) into incoming using incoming;
  execute format('select to_jsonb(t) from public.%I t where id=$1 and user_id=$2',p_table) into existing using canonical,owner_id;
  -- Older clients omit these optional fields. Preserve them instead of
  -- treating omission as an explicit clear; new clients send null to clear
  if existing is not null then
    if p_table='journal' and not (p_row ? 'answer') then
      incoming := incoming || jsonb_build_object(
        'answer',case when btrim(incoming->>'question')='' then null else existing->'answer' end,
        'answered_at',case when btrim(incoming->>'question')='' then null else existing->'answered_at' end);
    elsif p_table='schedule_blocks' and not (p_row ? 'description') then
      incoming := incoming || jsonb_build_object('description',existing->'description');
    end if;
  end if;
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
  -- Permanent deletion wins even against a later offline edit
  if p_table in ('todo_topics','todo_tasks') and
     (incoming->>'deleted_at' is not null) <> (existing->>'deleted_at' is not null) then
    winner := incoming->>'deleted_at' is not null;
  end if;
  -- An upgrade baseline cannot override an explicit archive or restore
  if p_table='category_states' and
     (incoming->>'is_baseline')::boolean <> (existing->>'is_baseline')::boolean then
    winner := not (incoming->>'is_baseline')::boolean;
  end if;
  -- Only incomparable histories with different user content are conflicts
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
