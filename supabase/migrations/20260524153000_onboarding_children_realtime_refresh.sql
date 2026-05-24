do $$
begin
  if not exists (
    select 1
    from pg_type
    where typname = 'child_gender'
  ) then
    create type public.child_gender as enum ('female', 'male', 'nonbinary', 'prefer_not_to_say');
  end if;
end
$$;

alter table public.profiles
  add column if not exists birth_date date;

alter table public.profiles
  drop constraint if exists profiles_age_check;

alter table public.profiles
  drop column if exists age;

alter table public.profiles
  add constraint profiles_birth_date_check
  check (birth_date is null or birth_date <= current_date);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, birth_date)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(new.raw_user_meta_data ->> 'birth_date', '')::date
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

create table public.couple_children (
  id uuid primary key default extensions.gen_random_uuid(),
  workspace_id uuid not null references public.couple_workspaces (id) on delete cascade,
  name text not null,
  gender public.child_gender not null,
  birth_date date not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint couple_children_name_check check (char_length(btrim(name)) > 0),
  constraint couple_children_birth_date_check check (birth_date <= current_date),
  constraint couple_children_sort_order_check check (sort_order >= 0)
);

create unique index couple_children_workspace_sort_idx
  on public.couple_children (workspace_id, sort_order);

create trigger couple_children_timestamp_trigger
before update on public.couple_children
for each row
execute function public.set_timestamp();

create or replace function public.save_couple_questionnaire(
  target_workspace_id uuid,
  target_relation_stage public.relationship_stage,
  target_dating_since date,
  target_engaged_since date,
  target_married_since date,
  target_has_children boolean,
  target_started_using_reason text,
  target_children jsonb default '[]'::jsonb
)
returns public.couple_workspaces
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_id uuid := auth.uid();
  child_item jsonb;
  child_index integer := 0;
  child_total integer;
  saved_workspace public.couple_workspaces;
begin
  if actor_id is null then
    raise exception 'authentication required';
  end if;

  if not public.is_workspace_member(target_workspace_id, actor_id) then
    raise exception 'workspace access denied';
  end if;

  if jsonb_typeof(target_children) is distinct from 'array' then
    raise exception 'children payload must be an array';
  end if;

  child_total := case
    when target_has_children then jsonb_array_length(target_children)
    else 0
  end;

  if target_has_children and child_total = 0 then
    raise exception 'children details are required';
  end if;

  update public.couple_workspaces
  set relation_stage = target_relation_stage,
      dating_since = target_dating_since,
      engaged_since = case when target_relation_stage = 'dating' then null else target_engaged_since end,
      married_since = case when target_relation_stage = 'married' then target_married_since else null end,
      has_children = target_has_children,
      children_count = child_total,
      started_using_reason = btrim(target_started_using_reason)
  where id = target_workspace_id
  returning * into saved_workspace;

  if saved_workspace.id is null then
    raise exception 'workspace not found';
  end if;

  delete from public.couple_children
  where workspace_id = target_workspace_id;

  if target_has_children then
    for child_item in
      select value
      from jsonb_array_elements(target_children)
    loop
      if coalesce(btrim(child_item ->> 'name'), '') = '' then
        raise exception 'child name is required';
      end if;

      if nullif(child_item ->> 'birth_date', '') is null then
        raise exception 'child birth date is required';
      end if;

      insert into public.couple_children (
        workspace_id,
        name,
        gender,
        birth_date,
        sort_order
      )
      values (
        target_workspace_id,
        btrim(child_item ->> 'name'),
        (child_item ->> 'gender')::public.child_gender,
        (child_item ->> 'birth_date')::date,
        child_index
      );

      child_index := child_index + 1;
    end loop;
  end if;

  select *
  into saved_workspace
  from public.couple_workspaces
  where id = target_workspace_id;

  return saved_workspace;
end;
$$;

alter table public.couple_workspaces
  rename column points_total to xp_total;

alter table public.couple_tasks
  add column if not exists due_at timestamptz;

create or replace function public.xp_to_reach_level(target_level integer)
returns integer
language sql
immutable
as $$
  select case
    when target_level <= 1 then 0
    else 25 * ((power(2, target_level - 1))::integer - 1)
  end;
$$;

create or replace function public.calculate_level_from_xp(total_xp integer)
returns integer
language plpgsql
immutable
as $$
declare
  calculated_level integer := 1;
begin
  while total_xp >= public.xp_to_reach_level(calculated_level + 1) loop
    calculated_level := calculated_level + 1;
  end loop;

  return calculated_level;
end;
$$;

create or replace function public.recalculate_workspace_progress(target_workspace_id uuid)
returns void
language plpgsql
set search_path = public
as $$
declare
  total_xp integer;
begin
  select coalesce(sum(points), 0)
  into total_xp
  from public.couple_tasks
  where workspace_id = target_workspace_id
    and completed = true;

  update public.couple_workspaces
  set xp_total = total_xp,
      level = public.calculate_level_from_xp(total_xp),
      updated_at = timezone('utc', now())
  where id = target_workspace_id;
end;
$$;

alter publication supabase_realtime add table public.couple_tasks;
alter publication supabase_realtime add table public.couple_workspaces;

alter table public.couple_children enable row level security;

create policy "children_select_member"
  on public.couple_children
  for select
  to authenticated
  using (public.is_workspace_member(workspace_id));

create policy "children_insert_member"
  on public.couple_children
  for insert
  to authenticated
  with check (public.is_workspace_member(workspace_id));

create policy "children_update_member"
  on public.couple_children
  for update
  to authenticated
  using (public.is_workspace_member(workspace_id))
  with check (public.is_workspace_member(workspace_id));

create policy "children_delete_member"
  on public.couple_children
  for delete
  to authenticated
  using (public.is_workspace_member(workspace_id));

grant select, insert, update, delete on public.couple_children to authenticated;

grant execute on function public.save_couple_questionnaire(uuid, public.relationship_stage, date, date, date, boolean, text, jsonb)
to authenticated;