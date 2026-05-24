do $$
begin
  if not exists (
    select 1
    from pg_type
    where typname = 'task_frequency'
  ) then
    create type public.task_frequency as enum ('daily', 'weekly', 'monthly', 'one_time', 'custom_weekdays');
  end if;

  if not exists (
    select 1
    from pg_type
    where typname = 'task_category'
  ) then
    create type public.task_category as enum ('leisure', 'sport', 'commitment', 'children', 'routine', 'romantic_date');
  end if;

  if not exists (
    select 1
    from pg_type
    where typname = 'weekday'
  ) then
    create type public.weekday as enum ('monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday');
  end if;
end
$$;

alter table public.couple_tasks
  add column if not exists frequency public.task_frequency not null default 'one_time',
  add column if not exists custom_weekdays public.weekday[],
  add column if not exists category public.task_category not null default 'routine';

alter table public.couple_tasks
  drop constraint if exists couple_tasks_frequency_check;

alter table public.couple_tasks
  add constraint couple_tasks_frequency_check check (
    (
      frequency = 'custom_weekdays'
      and custom_weekdays is not null
      and cardinality(custom_weekdays) > 0
    )
    or (
      frequency <> 'custom_weekdays'
      and (custom_weekdays is null or cardinality(custom_weekdays) = 0)
    )
  );

create or replace function public.prepare_couple_task()
returns trigger
language plpgsql
as $$
begin
  new.title := btrim(new.title);
  new.points := public.task_points_for_difficulty(new.difficulty);

  if new.frequency <> 'custom_weekdays' then
    new.custom_weekdays := null;
  end if;

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