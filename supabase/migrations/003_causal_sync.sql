-- Run once AFTER 001_initial.sql and 002_sync.sql. Preserves all rows and
-- conflict evidence. No table resets, data backfill or global seeds.
begin;
do $$
declare t text;
begin
  foreach t in array array['categories','weekly_goals','entries','journal','reviews'] loop
    execute format('alter table public.%I add column sync_history jsonb not null default ''{}''::jsonb check (jsonb_typeof(sync_history)=''object'')',t);
  end loop;
end;
$$;

create function public.trackstudy_history_union(a jsonb,b jsonb)
returns jsonb language plpgsql immutable set search_path='' as $$
declare e record; result jsonb := coalesce(a,'{}'::jsonb);
begin
  if jsonb_typeof(result)<>'object' or jsonb_typeof(b)<>'object' then
    raise exception 'Invalid sync history';
  end if;
  for e in select * from jsonb_each(result || b) loop
    if length(e.key) not between 1 and 64 or jsonb_typeof(e.value)<>'number'
       or e.value::text !~ '^(0|[1-9][0-9]{0,15})$'
       or (e.value::text)::numeric > 9007199254740991 then
      raise exception 'Invalid sync history';
    end if;
  end loop;
  for e in select * from jsonb_each(b) loop
    result := jsonb_set(result,array[e.key],to_jsonb(greatest(coalesce((result->>e.key)::bigint,0),(e.value::text)::bigint)));
  end loop;
  return result;
end;
$$;

create function public.trackstudy_history(r jsonb)
returns jsonb language sql immutable set search_path='' as $$
  select public.trackstudy_history_union(coalesce(r->'sync_history','{}'::jsonb),
    case when coalesce(r->>'sync_writer','')='' then '{}'::jsonb
    else jsonb_build_object(r->>'sync_writer',(r->>'sync_version')::bigint) end)
$$;

create function public.trackstudy_covers(a jsonb,b jsonb)
returns boolean language sql immutable set search_path='' as $$
  select not exists(select 1 from jsonb_each_text(b) e where coalesce((a->>e.key)::bigint,0)<e.value::bigint)
$$;

create function public.trackstudy_content(r jsonb)
returns jsonb language sql immutable set search_path='' as $$
  select r - array['id','user_id','revision','created_at','updated_at','sync_version','sync_writer','sync_history','dirty']
$$;

create or replace function public.trackstudy_merge(p_table text,p_row jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  owner_id uuid := auth.uid(); existing jsonb; incoming jsonb; result jsonb;
  canonical uuid; assignments text; winner boolean; incoming_covers boolean; existing_covers boolean;
  ih jsonb; eh jsonb; joined jsonb;
begin
  if owner_id is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if p_table is null or p_table not in ('categories','weekly_goals','entries','journal','reviews') then raise exception 'Invalid sync table'; end if;
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

-- Explicit, reversible archival of verified obsolete same-installation entry
-- copies. Keeps payload evidence; never edits/deletes any tracking record.
alter table public.sync_conflicts add column archived_at timestamptz;
create policy own_archive on public.sync_conflicts for update to authenticated
  using ((select auth.uid())=user_id) with check ((select auth.uid())=user_id);
grant update(archived_at) on public.sync_conflicts to authenticated;

create function public.trackstudy_archive_entry_copy(p_entry jsonb,p_version bigint,p_writer text)
returns boolean language plpgsql security invoker set search_path='' as $$
declare current_row jsonb; old_copy jsonb; supplied jsonb; owner_id uuid := auth.uid();
begin
  if owner_id is null then raise exception 'Authentication required' using errcode='42501'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(owner_id::text,0));
  select to_jsonb(e) into current_row from public.entries e where id=(p_entry->>'id')::uuid and user_id=owner_id;
  select payload into old_copy from public.sync_conflicts where user_id=owner_id and table_name='entries'
    and record_id=(p_entry->>'id')::uuid and version=p_version and writer=p_writer;
  select to_jsonb(r) into supplied from jsonb_populate_record(null::public.entries,p_entry) r;
  if current_row is null or old_copy is null
    or public.trackstudy_content(current_row) is distinct from public.trackstudy_content(supplied)
    or (current_row->>'sync_version',current_row->>'sync_writer') is distinct from (p_entry->>'sync_version',p_entry->>'sync_writer')
    or p_writer is distinct from current_row->>'sync_writer'
    or p_version > (current_row->>'sync_version')::bigint
    or (old_copy->>'goal_id',old_copy->>'amount',old_copy->>'source') is distinct from (current_row->>'goal_id',current_row->>'amount',current_row->>'source')
    then return false; end if;
  update public.sync_conflicts set archived_at=coalesce(archived_at,now()) where user_id=owner_id and table_name='entries'
    and record_id=(p_entry->>'id')::uuid and version=p_version and writer=p_writer;
  return true;
end;
$$;

revoke all on function public.trackstudy_history_union(jsonb,jsonb),public.trackstudy_history(jsonb),public.trackstudy_covers(jsonb,jsonb),public.trackstudy_content(jsonb),public.trackstudy_archive_entry_copy(jsonb,bigint,text) from public,anon;
grant execute on function public.trackstudy_history_union(jsonb,jsonb),public.trackstudy_history(jsonb),public.trackstudy_covers(jsonb,jsonb),public.trackstudy_content(jsonb),public.trackstudy_archive_entry_copy(jsonb,bigint,text) to authenticated;
-- CREATE OR REPLACE retains the existing merge function's restricted grants.
commit;
