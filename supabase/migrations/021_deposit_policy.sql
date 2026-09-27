-- PillowTop POS Phase 6b: Company deposit policy

create table if not exists public.deposit_policies (
  company_id uuid primary key references public.companies (id) on delete cascade,
  policy_type text not null check (policy_type in ('none','fixed_amount','percentage','greater_of_fixed_or_percentage')),
  fixed_amount numeric,
  percentage numeric,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id)
);

alter table public.deposit_policies enable row level security;

drop policy if exists "Deposit policies viewable by authenticated users"
  on public.deposit_policies;
create policy "Deposit policies viewable by authenticated users"
  on public.deposit_policies for select
  to authenticated
  using (
    exists (
      select 1
      from public.employees e
      join public.stores es on es.id = e.home_store_id
      where e.auth_user_id = auth.uid()
        and es.company_id = deposit_policies.company_id
    )
  );

drop policy if exists "Deposit policies manageable by owner or admin"
  on public.deposit_policies;
create policy "Deposit policies manageable by owner or admin"
  on public.deposit_policies for all
  to authenticated
  using (
    exists (
      select 1
      from public.employees e
      join public.stores es on es.id = e.home_store_id
      where e.auth_user_id = auth.uid()
        and es.company_id = deposit_policies.company_id
        and e.role::text in ('owner', 'admin')
    )
  )
  with check (
    exists (
      select 1
      from public.employees e
      join public.stores es on es.id = e.home_store_id
      where e.auth_user_id = auth.uid()
        and es.company_id = deposit_policies.company_id
        and e.role::text in ('owner', 'admin')
    )
  );

create or replace function public.calculate_required_deposit(p_journey_id uuid)
returns numeric
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(
    case dp.policy_type
      when 'none' then 0
      when 'fixed_amount' then dp.fixed_amount
      when 'percentage' then (sj.price * dp.percentage / 100)
      when 'greater_of_fixed_or_percentage' then greatest(dp.fixed_amount, sj.price * dp.percentage / 100)
    end,
    0
  )
  from public.sleep_journeys sj
  join public.stores s on s.id = sj.store_id
  left join public.deposit_policies dp on dp.company_id = s.company_id
  where sj.id = p_journey_id;
$$;
