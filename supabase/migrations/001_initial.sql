-- Optional remote schema. Never needed for local operation.
-- All amounts are exact integer hundredths of the configured display unit.
begin;

create table public.categories (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  measurement text not null check (measurement in ('continuous','discrete')),
  unit text not null check (length(unit) <= 20),
  floor bigint not null check (floor >= 0),
  target bigint not null check (target > 0 and target >= floor and target <= 100000000),
  increment bigint not null check (increment between 1 and 100000000),
  step bigint not null check (step between 1 and 100000000),
  position integer not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  revision bigint not null default 1,
  unique (id, user_id),
  check (measurement <> 'discrete' or (floor % 100 = 0 and target % 100 = 0 and increment % 100 = 0 and step % 100 = 0))
);

create table public.weekly_goals (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  category_id uuid not null,
  week_start date not null check (extract(isodow from week_start) = 1),
  name text not null check (length(trim(name)) between 1 and 80),
  measurement text not null check (measurement in ('continuous','discrete')),
  unit text not null check (length(unit) <= 20),
  floor bigint not null check (floor >= 0),
  target bigint not null check (target > 0 and target >= floor and target <= 100000000),
  increment bigint not null check (increment between 1 and 100000000),
  step bigint not null check (step between 1 and 100000000),
  position integer not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revision bigint not null default 1,
  foreign key (category_id, user_id) references public.categories(id, user_id),
  unique (category_id, week_start),
  unique (id, user_id),
  check (measurement <> 'discrete' or (floor % 100 = 0 and target % 100 = 0 and increment % 100 = 0 and step % 100 = 0))
);

create table public.entries (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  goal_id uuid not null,
  amount bigint not null check (amount between 1 and 100000000),
  source text not null default 'manual',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  undone_at timestamptz,
  revision bigint not null default 1,
  foreign key (goal_id, user_id) references public.weekly_goals(id, user_id)
);

create table public.journal (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  learned text not null default '',
  question text not null default '',
  next text not null default '',
  experiment jsonb not null default '{}'::jsonb check (jsonb_typeof(experiment) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  revision bigint not null default 1
);

create table public.reviews (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  week_start date not null check (extract(isodow from week_start) = 1),
  content jsonb not null check (
    jsonb_typeof(content) = 'object'
    and content ?& array['wentWrong','change','upcoming','danger','countermeasure','wins','done']
    and jsonb_typeof(content->'wins') = 'array' and jsonb_array_length(content->'wins') = 3
    and jsonb_typeof(content->'done') = 'array' and jsonb_array_length(content->'done') = 3
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  revision bigint not null default 1,
  unique(user_id, week_start)
);

create function public.trackstudy_touch() returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at = now();
  new.revision = old.revision + 1;
  if new.user_id <> old.user_id then raise exception 'Record ownership cannot change'; end if;
  return new;
end;
$$;

create function public.trackstudy_validate_entry() returns trigger language plpgsql set search_path = '' as $$
declare kind text;
begin
  select measurement into kind from public.weekly_goals where id = new.goal_id and user_id = new.user_id;
  if kind is null then raise exception 'Weekly goal is unavailable'; end if;
  if kind = 'discrete' and new.amount % 100 <> 0 then raise exception 'Discrete entries must use whole units'; end if;
  return new;
end;
$$;
create trigger entries_validate before insert or update on public.entries for each row execute function public.trackstudy_validate_entry();

do $$
declare table_name text;
begin
  foreach table_name in array array['categories','weekly_goals','entries','journal','reviews'] loop
    execute format('alter table public.%I enable row level security', table_name);
    execute format('create policy own_select on public.%I for select to authenticated using ((select auth.uid()) = user_id)', table_name);
    execute format('create policy own_insert on public.%I for insert to authenticated with check ((select auth.uid()) = user_id)', table_name);
    execute format('create policy own_update on public.%I for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)', table_name);
    -- No DELETE policy: use archival / undo / deletion timestamps for replication.
    execute format('revoke all on public.%I from anon', table_name);
    execute format('grant select, insert, update on public.%I to authenticated', table_name);
    execute format('create index %I on public.%I (user_id, updated_at, id)', table_name || '_sync_cursor', table_name);
    execute format('create trigger touch_updated before update on public.%I for each row execute function public.trackstudy_touch()', table_name);
  end loop;
end;
$$;

create index entries_goal_active on public.entries(user_id, goal_id, undone_at, created_at);
create index goals_week on public.weekly_goals(user_id, week_start, position);
create index journal_date on public.journal(user_id, created_at desc);
commit;
