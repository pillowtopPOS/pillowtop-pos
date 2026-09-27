-- PillowTop POS Phase 7c: reservation and journey readiness

-- A readiness timestamp is the minimal visible, durable notification marker.
alter table public.sleep_journeys
  add column if not exists inventory_ready_notified_at timestamptz;

create table if not exists public.reservation_policies (
  company_id uuid primary key references public.companies(id) on delete cascade,
  trigger_type text not null default 'paid_in_full'
    check (trigger_type in ('order_creation', 'deposit_received', 'order_confirmed', 'paid_in_full')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.reservation_policies (company_id)
select id from public.companies
on conflict (company_id) do nothing;

create table if not exists public.journey_inventory_requirements (
  id uuid primary key default gen_random_uuid(),
  journey_id uuid not null references public.sleep_journeys(id) on delete cascade,
  variant_id uuid not null references public.products(id) on delete restrict,
  location_id uuid not null references public.stores(id) on delete restrict,
  quantity_required integer not null check (quantity_required > 0),
  quantity_reserved integer not null default 0 check (quantity_reserved >= 0),
  status text not null default 'pending' check (status in ('pending', 'ready', 'cancelled')),
  created_at timestamptz not null default now(),
  unique (journey_id, variant_id)
);

alter table public.journey_inventory_requirements
  add column if not exists location_id uuid references public.stores(id) on delete restrict;

update public.journey_inventory_requirements jir
set location_id = sj.store_id
from public.sleep_journeys sj
where sj.id = jir.journey_id and jir.location_id is null;

alter table public.journey_inventory_requirements
  alter column location_id set not null;

create index if not exists idx_journey_inventory_requirements_variant
  on public.journey_inventory_requirements (variant_id);
create index if not exists idx_journey_inventory_requirements_journey
  on public.journey_inventory_requirements (journey_id);

-- Direct clients may not inject trusted readiness events. The security-definer
-- evaluator below is the only application path that emits these event types.
drop policy if exists "Journey events insertable by authenticated users" on public.journey_events;
create policy "Journey events insertable by authenticated users"
  on public.journey_events for insert
  to authenticated
  with check (
    public.is_journey_visible(journey_id)
    and event_type not in ('inventory_required', 'inventory_received')
  );

-- The snapshot is intentional: edits to line items after requirements exist do
-- not reserve newly-added items or release no-longer-needed quantities. This
-- mirrors WrittenSaleAdjusted, which currently handles cancellation but not
-- arbitrary order edits.

-- For order_creation, evaluation is triggered by the first catalog-backed line
-- item present at insert time. Items added afterward under this policy do not
-- receive their own requirement. The default paid_in_full policy is unaffected.

create or replace function public.evaluate_journey_inventory(p_journey_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_journey public.sleep_journeys%rowtype;
  v_company uuid;
  v_trigger text;
  v_paid numeric;
  v_should_run boolean := false;
  v_any_short boolean := false;
  v_req record;
  v_available integer;
  v_needed integer;
  v_ready boolean;
  v_old_state public.journey_state;
  v_new_state public.journey_state;
  v_event_type public.journey_event_type;
begin
  select sj.*
  into v_journey
  from public.sleep_journeys sj
  where sj.id = p_journey_id
  for update;

  select company_id into v_company
  from public.stores
  where id = v_journey.store_id;

  if not found or v_journey.cancelled_at is not null then
    return;
  end if;

  select trigger_type into v_trigger
  from public.reservation_policies
  where company_id = v_company;
  v_trigger := coalesce(v_trigger, 'paid_in_full');

  if v_trigger = 'order_creation' then
    v_should_run := exists (
      select 1 from public.journey_line_items
      where journey_id = p_journey_id and product_id is not null
    );
  elsif v_trigger = 'deposit_received' then
    v_should_run := exists (
      select 1 from public.journey_events
      where journey_id = p_journey_id and event_type = 'deposit_received' and outcome = 'SUCCEEDED'
    );
  elsif v_trigger = 'order_confirmed' then
    v_should_run := exists (
      select 1 from public.journey_events
      where journey_id = p_journey_id and event_type::text = 'order_confirmed'
    );
  else
    v_paid := public.total_paid(p_journey_id);
    v_should_run := v_journey.price is not null and v_paid >= v_journey.price;
  end if;

  if not v_should_run then
    return;
  end if;

  if not exists (select 1 from public.journey_inventory_requirements where journey_id = p_journey_id) then
    insert into public.journey_inventory_requirements (journey_id, variant_id, location_id, quantity_required)
    select p_journey_id, product_id, v_journey.store_id, sum(quantity)
    from public.journey_line_items
    where journey_id = p_journey_id and product_id is not null
    group by product_id;
  end if;

  -- Resource rows are locked before any reservation is calculated. A stable
  -- journey advisory lock serializes competing evaluations for this order.
  perform pg_advisory_xact_lock(hashtextextended(p_journey_id::text, 7137));

  for v_req in
    select * from public.journey_inventory_requirements
    where journey_id = p_journey_id and status = 'pending'
    order by variant_id
  loop
    perform pg_advisory_xact_lock(hashtextextended(v_req.variant_id::text || ':' || v_req.location_id::text || ':Prime', 7137));
    v_needed := v_req.quantity_required - v_req.quantity_reserved;
    if v_needed <= 0 then
      update public.journey_inventory_requirements set status = 'ready' where id = v_req.id;
      continue;
    end if;

    select coalesce(on_hand_quantity - committed_quantity, 0)
    into v_available
    from public.inventory_positions
    where variant_id = v_req.variant_id
      and location_id = v_req.location_id
      and disposition = 'Prime'
      and sublocation_id is null
    for update;

    -- Default oversell behavior: reserve the entire remaining requirement or
    -- none of it. Prime and Clearance are never combined.
    if coalesce(v_available, 0) >= v_needed then
      update public.inventory_positions
      set committed_quantity = committed_quantity + v_needed,
          updated_at = now()
      where variant_id = v_req.variant_id
        and location_id = v_req.location_id
        and disposition = 'Prime'
        and sublocation_id is null;
      update public.journey_inventory_requirements
      set quantity_reserved = quantity_reserved + v_needed, status = 'ready'
      where id = v_req.id;
    else
      v_any_short := true;
    end if;
  end loop;

  select exists (
    select 1 from public.journey_inventory_requirements
    where journey_id = p_journey_id and status = 'pending'
  ) into v_any_short;

  v_old_state := v_journey.current_state;
  v_new_state := case when v_any_short then 'Waiting for Inventory' else 'Ready to Schedule' end;

  update public.sleep_journeys
  set current_state = v_new_state,
      inventory_ready_notified_at = case
        when not v_any_short and inventory_ready_notified_at is null then now()
        else inventory_ready_notified_at
      end,
      updated_at = now()
  where id = p_journey_id;

  if v_old_state is distinct from v_new_state then
    v_event_type := case when v_any_short then 'inventory_required' else 'inventory_received' end;
    insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
    values (
      p_journey_id, v_event_type,
      jsonb_build_object('automated', true, 'requirements_ready', not v_any_short),
      'system'
    );
  end if;
end;
$$;

revoke execute on function public.evaluate_journey_inventory(uuid) from authenticated, anon;

create or replace function public.evaluate_pending_inventory_for_variant(
  p_variant_id uuid, p_location_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare r record;
begin
  for r in
    select distinct jir.journey_id
    from public.journey_inventory_requirements jir
    join public.sleep_journeys sj on sj.id = jir.journey_id
    where jir.variant_id = p_variant_id
      and jir.location_id = p_location_id
      and jir.status = 'pending'
      and sj.cancelled_at is null
  loop
    perform public.evaluate_journey_inventory(r.journey_id);
  end loop;
end;
$$;
revoke execute on function public.evaluate_pending_inventory_for_variant(uuid, uuid) from authenticated, anon;

-- Replace the Phase 7b writer so restocks re-evaluate pending requirements in
-- the same transaction as the position and ledger write.
create or replace function public.adjust_inventory_position(
  p_variant_id uuid, p_location_id uuid, p_sublocation_id text,
  p_disposition public.disposition, p_new_quantity integer,
  p_reason text, p_reference_type text, p_actor_id text
)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_role public.employee_role; v_caller_company uuid; v_location_company uuid;
  v_allowed boolean := false; v_position_id uuid; v_old integer;
begin
  v_role := public.current_employee_role();
  select s.company_id into v_caller_company from public.employees e join public.stores s on s.id = e.home_store_id where e.auth_user_id = auth.uid();
  select company_id into v_location_company from public.stores where id = p_location_id;
  if v_caller_company is null then raise exception 'Could not determine employee company'; end if;
  if v_caller_company is distinct from v_location_company then raise exception 'Location does not belong to employee company'; end if;
  if v_role::text in ('owner', 'admin') then v_allowed := true;
  elsif v_role::text = 'manager' then select coalesce(managers_can_adjust_inventory, false) into v_allowed from public.companies where id = v_caller_company; end if;
  if not v_allowed then raise exception 'Employee is not authorized to adjust inventory'; end if;
  if p_new_quantity < 0 then raise exception 'Quantity cannot be negative'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_variant_id::text || ':' || p_location_id::text || ':' || p_disposition::text, 7137));
  select id, on_hand_quantity into v_position_id, v_old from public.inventory_positions
  where variant_id = p_variant_id and location_id = p_location_id
    and sublocation_id is not distinct from p_sublocation_id and disposition = p_disposition for update;
  if not found then
    insert into public.inventory_positions (variant_id, location_id, sublocation_id, disposition, on_hand_quantity, committed_quantity)
    values (p_variant_id, p_location_id, p_sublocation_id, p_disposition, p_new_quantity, 0) returning id into v_position_id;
    v_old := 0;
  else
    update public.inventory_positions set on_hand_quantity = p_new_quantity, updated_at = now() where id = v_position_id;
  end if;
  if p_new_quantity <> v_old then
    insert into public.stock_ledger_entries (variant_id, location_id, disposition, quantity_delta, reason, reference_type, actor_id)
    values (p_variant_id, p_location_id, p_disposition, p_new_quantity - v_old, p_reason, p_reference_type, p_actor_id);
  end if;
  if p_new_quantity > v_old and p_disposition = 'Prime' then
    perform public.evaluate_pending_inventory_for_variant(p_variant_id, p_location_id);
  end if;
  return v_position_id;
end;
$$;

grant execute on function public.adjust_inventory_position(uuid, uuid, text, public.disposition, integer, text, text, text) to authenticated;

-- Cancellation releases all committed quantities for this journey in the same
-- journey_events trigger transaction used by WrittenSaleAdjusted.
create or replace function public.release_journey_inventory(p_journey_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare r record;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_journey_id::text, 7137));
  for r in select * from public.journey_inventory_requirements where journey_id = p_journey_id and status <> 'cancelled' for update loop
    if r.quantity_reserved > 0 then
      perform pg_advisory_xact_lock(hashtextextended(r.variant_id::text || ':' || r.location_id::text || ':Prime', 7137));
      update public.inventory_positions
      set committed_quantity = committed_quantity - r.quantity_reserved, updated_at = now()
      where variant_id = r.variant_id
        and location_id = r.location_id
        and disposition = 'Prime' and sublocation_id is null;
    end if;
    update public.journey_inventory_requirements set status = 'cancelled' where id = r.id;
  end loop;
end;
$$;
revoke execute on function public.release_journey_inventory(uuid) from authenticated, anon;

create or replace function public.inventory_journey_event_hook()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.event_type = 'journey_cancelled' then
    perform public.release_journey_inventory(new.journey_id);
  elsif new.event_type in ('payment_completed', 'deposit_received')
    and new.outcome = 'SUCCEEDED' then
    perform public.evaluate_journey_inventory(new.journey_id);
  end if;
  return new;
end;
$$;
revoke execute on function public.inventory_journey_event_hook() from authenticated, anon;

drop trigger if exists journey_inventory_event_hook on public.journey_events;
drop trigger if exists zz_inventory_event_hook on public.journey_events;
create trigger zz_inventory_event_hook
after insert on public.journey_events for each row
execute function public.inventory_journey_event_hook();

-- Line-item insertion is the order_creation hook. This intentionally snapshots
-- only the first catalog-backed item present at insert time, as documented above.
create or replace function public.inventory_line_item_hook()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform public.evaluate_journey_inventory(new.journey_id);
  return new;
end;
$$;
revoke execute on function public.inventory_line_item_hook() from authenticated, anon;
drop trigger if exists journey_inventory_line_item_hook on public.journey_line_items;
create trigger journey_inventory_line_item_hook
after insert on public.journey_line_items for each row
execute function public.inventory_line_item_hook();

-- 8. Read-only company-scoped visibility for requirements.
alter table public.reservation_policies enable row level security;
alter table public.journey_inventory_requirements enable row level security;
create policy "Reservation policies viewable by company" on public.reservation_policies for select to authenticated
using (exists (select 1 from public.stores s where s.company_id = reservation_policies.company_id and public.is_store_visible(s.id)));
create policy "Reservation policies updatable by owner/admin" on public.reservation_policies for update to authenticated
using (public.current_employee_role()::text in ('owner', 'admin'))
with check (public.current_employee_role()::text in ('owner', 'admin'));
create policy "Journey inventory requirements viewable" on public.journey_inventory_requirements for select to authenticated
using (public.is_journey_visible(journey_id));

-- Reconciliation updates an existing payment row, so its UPDATE does not
-- fire the journey_events INSERT hook. Keep the existing reconciliation logic
-- and explicitly evaluate inventory after a successful reconciliation.
create or replace function public.reconcile_payment_event(
  p_event_id uuid, p_new_outcome text, p_source text default 'manual',
  p_actor_id text default 'system', p_notes text default null
)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_current public.payment_outcome; v_current_event_type public.journey_event_type;
  v_journey_id uuid; v_event_data jsonb; v_created_at timestamptz;
  v_log_id uuid; v_new public.payment_outcome; v_new_event_type public.journey_event_type;
  v_price numeric; v_amount numeric; v_running numeric; v_total numeric;
  v_emp_id uuid; v_store_rec public.stores%rowtype;
  v_follow_up_due timestamptz; v_max_due timestamptz;
begin
  select je.outcome, je.event_type, je.journey_id, je.event_data, je.created_at
  into v_current, v_current_event_type, v_journey_id, v_event_data, v_created_at
  from public.journey_events je where je.id = p_event_id;
  if v_current is null then raise exception 'Payment event not found'; end if;
  if not exists (
    select 1 from public.employees e
    join public.stores es on es.id = e.home_store_id
    join public.sleep_journeys sj on sj.id = v_journey_id
    join public.stores js on js.id = sj.store_id
    where e.auth_user_id = auth.uid() and es.company_id = js.company_id
      and e.role::text in ('owner', 'admin', 'manager')
  ) then raise exception 'Only owner, admin, or manager may reconcile this payment'; end if;
  select id into v_emp_id from public.employees where auth_user_id = auth.uid();
  v_new := p_new_outcome::public.payment_outcome;
  v_new_event_type := v_current_event_type;

  if v_current = v_new then
    insert into public.payment_reconciliation_events (
      payment_id, previous_outcome, new_outcome, previous_event_type,
      new_event_type, reconciliation_source, actor_id, notes
    ) values (p_event_id, v_current, v_new, v_current_event_type,
      v_new_event_type, p_source, p_actor_id, p_notes) returning id into v_log_id;
    return p_event_id;
  end if;

  if v_new = 'SUCCEEDED' then
    v_amount := coalesce((v_event_data->>'amount')::numeric, 0);
    v_running := public.total_paid(v_journey_id);
    select price into v_price from public.sleep_journeys where id = v_journey_id;
    v_total := v_running + v_amount;
    if v_total >= v_price then v_new_event_type := 'payment_completed';
    else v_new_event_type := 'deposit_received'; end if;
  end if;

  update public.journey_events set outcome = v_new,
    event_type = v_new_event_type, reconciled_at = now() where id = p_event_id;

  insert into public.payment_reconciliation_events (
    payment_id, previous_outcome, new_outcome, previous_event_type,
    new_event_type, reconciliation_source, actor_id, notes
  ) values (p_event_id, v_current, v_new, v_current_event_type,
    v_new_event_type, p_source, p_actor_id, p_notes) returning id into v_log_id;

  if v_new = 'SUCCEEDED' then
    perform public.ensure_written_sale_established(v_journey_id, p_event_id);
    perform public.reevaluate_journey_balance(v_journey_id);
    perform public.evaluate_journey_inventory(v_journey_id);

    if v_new_event_type = 'payment_completed' then
      update public.follow_ups set completed_at = now()
      where journey_id = v_journey_id and completed_at is null;
    elsif v_new_event_type = 'deposit_received' then
      select * into v_store_rec from public.stores
      where id = (select store_id from public.sleep_journeys where id = v_journey_id);
      v_follow_up_due := v_created_at + (v_store_rec.deposit_follow_up_default_days || ' days')::interval;
      v_max_due := v_created_at + (v_store_rec.deposit_follow_up_max_days || ' days')::interval;
      if v_event_data->>'follow_up_due_at' is not null then
        begin v_follow_up_due := (v_event_data->>'follow_up_due_at')::timestamptz;
        exception when others then
          v_follow_up_due := v_created_at + (v_store_rec.deposit_follow_up_default_days || ' days')::interval;
        end;
        if v_follow_up_due > v_max_due then v_follow_up_due := v_max_due; end if;
        if v_follow_up_due < v_created_at then v_follow_up_due := v_created_at; end if;
      end if;
      insert into public.follow_ups (journey_id, employee_id, type, due_at, notes)
      values (v_journey_id, v_emp_id, 'deposit', v_follow_up_due, 'Deposit follow-up: balance due');
    end if;
  end if;
  return p_event_id;
end;
$$;
