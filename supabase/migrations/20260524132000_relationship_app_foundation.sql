create extension if not exists pgcrypto with schema extensions;

create type public.invitation_status as enum ('pending', 'accepted', 'declined', 'cancelled', 'expired');
create type public.relationship_stage as enum ('dating', 'engaged', 'married');
create type public.task_difficulty as enum ('easy', 'medium', 'hard');

create or replace function public.set_timestamp()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null,
  full_name text,
  age integer,
  personal_invite_code text not null unique,
  connected_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint profiles_age_check check (age is null or age between 13 and 120)
);

create or replace function public.generate_invite_code()
returns text
language plpgsql
set search_path = public
as $$
declare
  generated_code text;
begin
  loop
    generated_code := upper(encode(extensions.gen_random_bytes(4), 'hex'));
    exit when not exists (
      select 1
      from public.profiles
      where personal_invite_code = generated_code
    );
  end loop;

  return generated_code;
end;
$$;

create or replace function public.ensure_profile_invite_code()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.personal_invite_code is null or btrim(new.personal_invite_code) = '' then
    new.personal_invite_code := public.generate_invite_code();
  else
    new.personal_invite_code := upper(btrim(new.personal_invite_code));
  end if;

  return new;
end;
$$;

create trigger profiles_invite_code_trigger
before insert or update on public.profiles
for each row
execute function public.ensure_profile_invite_code();

create trigger profiles_timestamp_trigger
before update on public.profiles
for each row
execute function public.set_timestamp();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', '')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.handle_new_user();

create table public.couple_workspaces (
  id uuid primary key default extensions.gen_random_uuid(),
  created_by uuid not null references public.profiles (id) on delete restrict,
  relation_stage public.relationship_stage,
  dating_since date,
  engaged_since date,
  married_since date,
  has_children boolean,
  children_count integer,
  started_using_reason text,
  points_total integer not null default 0,
  level integer not null default 1,
  questionnaire_completed_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint couple_workspaces_children_check check (
    (has_children is null and children_count is null)
    or (has_children = false and coalesce(children_count, 0) = 0)
    or (has_children = true and children_count is not null and children_count >= 1)
  ),
  constraint couple_workspaces_timeline_check check (
    (relation_stage is null and dating_since is null and engaged_since is null and married_since is null)
    or (relation_stage = 'dating' and dating_since is not null and engaged_since is null and married_since is null)
    or (relation_stage = 'engaged' and dating_since is not null and engaged_since is not null and married_since is null)
    or (relation_stage = 'married' and dating_since is not null and engaged_since is not null and married_since is not null)
  )
);

create or replace function public.prepare_workspace_questionnaire()
returns trigger
language plpgsql
as $$
begin
  if new.has_children = false then
    new.children_count := 0;
  end if;

  if new.relation_stage is not null
    and new.dating_since is not null
    and ((new.relation_stage = 'dating')
      or (new.relation_stage = 'engaged' and new.engaged_since is not null)
      or (new.relation_stage = 'married' and new.engaged_since is not null and new.married_since is not null))
    and new.has_children is not null
    and ((new.has_children = false and coalesce(new.children_count, 0) = 0)
      or (new.has_children = true and new.children_count is not null and new.children_count >= 1))
    and new.started_using_reason is not null
    and btrim(new.started_using_reason) <> '' then
    new.questionnaire_completed_at := coalesce(new.questionnaire_completed_at, timezone('utc', now()));
  else
    new.questionnaire_completed_at := null;
  end if;

  return new;
end;
$$;

create trigger couple_workspaces_questionnaire_trigger
before insert or update on public.couple_workspaces
for each row
execute function public.prepare_workspace_questionnaire();

create trigger couple_workspaces_timestamp_trigger
before update on public.couple_workspaces
for each row
execute function public.set_timestamp();

create table public.couple_memberships (
  workspace_id uuid not null references public.couple_workspaces (id) on delete cascade,
  user_id uuid not null unique references public.profiles (id) on delete cascade,
  joined_at timestamptz not null default timezone('utc', now()),
  primary key (workspace_id, user_id)
);

create or replace function public.validate_workspace_member_limit()
returns trigger
language plpgsql
as $$
declare
  member_count integer;
begin
  select count(*)
  into member_count
  from public.couple_memberships
  where workspace_id = new.workspace_id;

  if member_count >= 2 then
    raise exception 'workspace already has two members';
  end if;

  return new;
end;
$$;

create trigger couple_memberships_limit_trigger
before insert on public.couple_memberships
for each row
execute function public.validate_workspace_member_limit();

create table public.user_questionnaires (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  partner_admired_trait text not null,
  self_trait_partner_admires text not null,
  relationship_definition text not null,
  completed_at timestamptz not null default timezone('utc', now()),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create trigger user_questionnaires_timestamp_trigger
before update on public.user_questionnaires
for each row
execute function public.set_timestamp();

create table public.partnership_invitations (
  id uuid primary key default extensions.gen_random_uuid(),
  inviter_id uuid not null references public.profiles (id) on delete cascade,
  invitee_id uuid not null references public.profiles (id) on delete cascade,
  workspace_id uuid references public.couple_workspaces (id) on delete set null,
  status public.invitation_status not null default 'pending',
  responded_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint partnership_invitations_distinct_users_check check (inviter_id <> invitee_id)
);

create unique index partnership_invitations_pending_pair_idx
  on public.partnership_invitations (inviter_id, invitee_id)
  where status = 'pending';

create index partnership_invitations_status_idx
  on public.partnership_invitations (invitee_id, inviter_id, status);

create trigger partnership_invitations_timestamp_trigger
before update on public.partnership_invitations
for each row
execute function public.set_timestamp();

create table public.couple_tasks (
  id uuid primary key default extensions.gen_random_uuid(),
  workspace_id uuid not null references public.couple_workspaces (id) on delete cascade,
  title text not null,
  description text,
  difficulty public.task_difficulty not null default 'easy',
  points integer not null default 10,
  completed boolean not null default false,
  completed_at timestamptz,
  completed_by uuid references public.profiles (id) on delete set null,
  created_by uuid not null references public.profiles (id) on delete restrict,
  updated_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  constraint couple_tasks_title_check check (char_length(btrim(title)) > 0),
  constraint couple_tasks_points_check check (points >= 0),
  constraint couple_tasks_completion_check check (
    (completed = false and completed_at is null and completed_by is null)
    or (completed = true and completed_at is not null and completed_by is not null)
  )
);

create index couple_tasks_workspace_idx
  on public.couple_tasks (workspace_id, completed, created_at desc);

create or replace function public.task_points_for_difficulty(target_difficulty public.task_difficulty)
returns integer
language sql
immutable
as $$
  select case target_difficulty
    when 'easy' then 10
    when 'medium' then 25
    when 'hard' then 50
  end;
$$;

create or replace function public.prepare_couple_task()
returns trigger
language plpgsql
as $$
begin
  new.title := btrim(new.title);
  new.points := public.task_points_for_difficulty(new.difficulty);

  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, auth.uid());
  end if;

  new.updated_by := auth.uid();

  if tg_op = 'INSERT' then
    if new.completed then
      new.completed_at := timezone('utc', now());
      new.completed_by := auth.uid();
    else
      new.completed_at := null;
      new.completed_by := null;
    end if;
  else
    if new.completed and not old.completed then
      new.completed_at := timezone('utc', now());
      new.completed_by := auth.uid();
    elsif new.completed and old.completed then
      new.completed_at := old.completed_at;
      new.completed_by := old.completed_by;
    else
      new.completed_at := null;
      new.completed_by := null;
    end if;
  end if;

  return new;
end;
$$;

create trigger couple_tasks_prepare_trigger
before insert or update on public.couple_tasks
for each row
execute function public.prepare_couple_task();

create or replace function public.recalculate_workspace_progress(target_workspace_id uuid)
returns void
language plpgsql
set search_path = public
as $$
declare
  total_points integer;
begin
  select coalesce(sum(points), 0)
  into total_points
  from public.couple_tasks
  where workspace_id = target_workspace_id
    and completed = true;

  update public.couple_workspaces
  set points_total = total_points,
      level = greatest(1, floor(total_points / 100.0)::integer + 1),
      updated_at = timezone('utc', now())
  where id = target_workspace_id;
end;
$$;

create or replace function public.sync_workspace_progress()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform public.recalculate_workspace_progress(old.workspace_id);
    return null;
  end if;

  if tg_op = 'UPDATE' and old.workspace_id is distinct from new.workspace_id then
    perform public.recalculate_workspace_progress(old.workspace_id);
  end if;

  perform public.recalculate_workspace_progress(new.workspace_id);
  return null;
end;
$$;

create trigger couple_tasks_progress_trigger
after insert or update or delete on public.couple_tasks
for each row
execute function public.sync_workspace_progress();

create or replace function public.is_workspace_member(target_workspace_id uuid, target_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.couple_memberships
    where workspace_id = target_workspace_id
      and user_id = coalesce(target_user_id, auth.uid())
  );
$$;

create or replace function public.lookup_partner_by_invite_code(partner_invite_code text)
returns table (
  profile_id uuid,
  full_name text,
  personal_invite_code text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id as profile_id,
    coalesce(nullif(btrim(p.full_name), ''), split_part(p.email, '@', 1)) as full_name,
    p.personal_invite_code
  from public.profiles p
  where upper(p.personal_invite_code) = upper(btrim(partner_invite_code))
    and p.id <> auth.uid()
  limit 1;
$$;

create or replace function public.send_partnership_invite(partner_invite_code text)
returns public.partnership_invitations
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_id uuid := auth.uid();
  target_profile_id uuid;
  created_invitation public.partnership_invitations;
begin
  if actor_id is null then
    raise exception 'authentication required';
  end if;

  select id
  into target_profile_id
  from public.profiles
  where upper(personal_invite_code) = upper(btrim(partner_invite_code));

  if target_profile_id is null then
    raise exception 'partner token not found';
  end if;

  if target_profile_id = actor_id then
    raise exception 'you cannot invite yourself';
  end if;

  if exists (
    select 1
    from public.couple_memberships
    where user_id in (actor_id, target_profile_id)
  ) then
    raise exception 'one of the users is already connected to a workspace';
  end if;

  if exists (
    select 1
    from public.partnership_invitations
    where status = 'pending'
      and (
        inviter_id in (actor_id, target_profile_id)
        or invitee_id in (actor_id, target_profile_id)
      )
  ) then
    raise exception 'there is already a pending invitation involving one of these users';
  end if;

  insert into public.partnership_invitations (inviter_id, invitee_id)
  values (actor_id, target_profile_id)
  returning * into created_invitation;

  return created_invitation;
end;
$$;

create or replace function public.respond_to_partnership_invite(target_invitation_id uuid, accept_invitation boolean)
returns table (
  workspace_id uuid,
  invitation_status public.invitation_status
)
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_id uuid := auth.uid();
  target_invitation public.partnership_invitations;
  created_workspace_id uuid;
begin
  if actor_id is null then
    raise exception 'authentication required';
  end if;

  select *
  into target_invitation
  from public.partnership_invitations
  where id = target_invitation_id
  for update;

  if target_invitation.id is null then
    raise exception 'invitation not found';
  end if;

  if target_invitation.invitee_id <> actor_id then
    raise exception 'only the invitee can answer this invitation';
  end if;

  if target_invitation.status <> 'pending' then
    raise exception 'invitation already processed';
  end if;

  if exists (
    select 1
    from public.couple_memberships
    where user_id in (target_invitation.inviter_id, target_invitation.invitee_id)
  ) then
    raise exception 'one of the users is already connected to a workspace';
  end if;

  if accept_invitation then
    insert into public.couple_workspaces (created_by)
    values (target_invitation.inviter_id)
    returning id into created_workspace_id;

    insert into public.couple_memberships (workspace_id, user_id)
    values
      (created_workspace_id, target_invitation.inviter_id),
      (created_workspace_id, target_invitation.invitee_id);

    update public.partnership_invitations
    set status = 'accepted',
        workspace_id = created_workspace_id,
        responded_at = timezone('utc', now()),
        updated_at = timezone('utc', now())
    where id = target_invitation_id;

    update public.partnership_invitations
    set status = 'cancelled',
        responded_at = timezone('utc', now()),
        updated_at = timezone('utc', now())
    where status = 'pending'
      and id <> target_invitation_id
      and (
        inviter_id in (target_invitation.inviter_id, target_invitation.invitee_id)
        or invitee_id in (target_invitation.inviter_id, target_invitation.invitee_id)
      );

    update public.profiles
    set connected_at = timezone('utc', now())
    where id in (target_invitation.inviter_id, target_invitation.invitee_id);

    return query
    select created_workspace_id, 'accepted'::public.invitation_status;
  else
    update public.partnership_invitations
    set status = 'declined',
        responded_at = timezone('utc', now()),
        updated_at = timezone('utc', now())
    where id = target_invitation_id;

    return query
    select null::uuid, 'declined'::public.invitation_status;
  end if;
end;
$$;

alter table public.profiles enable row level security;
alter table public.couple_workspaces enable row level security;
alter table public.couple_memberships enable row level security;
alter table public.user_questionnaires enable row level security;
alter table public.partnership_invitations enable row level security;
alter table public.couple_tasks enable row level security;

create policy "profiles_select_own"
  on public.profiles
  for select
  to authenticated
  using (auth.uid() = id);

create policy "profiles_update_own"
  on public.profiles
  for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

create policy "workspaces_select_member"
  on public.couple_workspaces
  for select
  to authenticated
  using (public.is_workspace_member(id));

create policy "workspaces_update_member"
  on public.couple_workspaces
  for update
  to authenticated
  using (public.is_workspace_member(id))
  with check (public.is_workspace_member(id));

create policy "memberships_select_own_workspace"
  on public.couple_memberships
  for select
  to authenticated
  using (
    user_id = auth.uid()
    or public.is_workspace_member(workspace_id)
  );

create policy "user_questionnaires_select_own"
  on public.user_questionnaires
  for select
  to authenticated
  using (user_id = auth.uid());

create policy "user_questionnaires_insert_own"
  on public.user_questionnaires
  for insert
  to authenticated
  with check (user_id = auth.uid());

create policy "user_questionnaires_update_own"
  on public.user_questionnaires
  for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "invitations_select_related"
  on public.partnership_invitations
  for select
  to authenticated
  using (auth.uid() in (inviter_id, invitee_id));

create policy "tasks_select_member"
  on public.couple_tasks
  for select
  to authenticated
  using (public.is_workspace_member(workspace_id));

create policy "tasks_insert_member"
  on public.couple_tasks
  for insert
  to authenticated
  with check (public.is_workspace_member(workspace_id));

create policy "tasks_update_member"
  on public.couple_tasks
  for update
  to authenticated
  using (public.is_workspace_member(workspace_id))
  with check (public.is_workspace_member(workspace_id));

create policy "tasks_delete_member"
  on public.couple_tasks
  for delete
  to authenticated
  using (public.is_workspace_member(workspace_id));

grant select, update on public.profiles to authenticated;
grant select, update on public.couple_workspaces to authenticated;
grant select on public.couple_memberships to authenticated;
grant select, insert, update on public.user_questionnaires to authenticated;
grant select on public.partnership_invitations to authenticated;
grant select, insert, update, delete on public.couple_tasks to authenticated;

grant execute on function public.lookup_partner_by_invite_code(text) to authenticated;
grant execute on function public.send_partnership_invite(text) to authenticated;
grant execute on function public.respond_to_partnership_invite(uuid, boolean) to authenticated;