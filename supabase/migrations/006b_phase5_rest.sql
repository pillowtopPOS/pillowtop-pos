-- PillowTop POS Phase 5, part B: multi-product line items and sale-price display
-- Run 006a_phase5_enum.sql first so the new event enum values exist.

-- 1. Line items table

create table if not exists public.journey_line_items (
  id uuid primary key default gen_random_uuid(),
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  product_id uuid references public.products (id) on delete set null,
  item_name text not null,
  quantity integer not null default 1,
  unit_price numeric not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_journey_line_items_journey on public.journey_line_items (journey_id);
create index if not exists idx_journey_line_items_product on public.journey_line_items (product_id);

-- 2. RLS on line items (visible/writable if parent journey is visible)

alter table public.journey_line_items enable row level security;

drop policy if exists "Journey line items viewable by authenticated users" on public.journey_line_items;
create policy "Journey line items viewable by authenticated users"
  on public.journey_line_items for select
  to authenticated
  using (public.is_journey_visible(journey_id));

drop policy if exists "Journey line items insertable by authenticated users" on public.journey_line_items;
create policy "Journey line items insertable by authenticated users"
  on public.journey_line_items for insert
  to authenticated
  with check (public.is_journey_visible(journey_id));

drop policy if exists "Journey line items updatable by authenticated users" on public.journey_line_items;
create policy "Journey line items updatable by authenticated users"
  on public.journey_line_items for update
  to authenticated
  using (public.is_journey_visible(journey_id))
  with check (public.is_journey_visible(journey_id));

drop policy if exists "Journey line items deletable by authenticated users" on public.journey_line_items;
create policy "Journey line items deletable by authenticated users"
  on public.journey_line_items for delete
  to authenticated
  using (public.is_journey_visible(journey_id));

-- 3. Update event-to-state mapping (additive; hard-fought Sold logic in derive_journey_state is untouched)

create or replace function public.event_to_state(evt public.journey_event_type)
returns public.journey_state
language plpgsql
stable
as $$
begin
  return case evt
    when 'quote_created' then 'Quoted'::public.journey_state
    when 'quote_sent' then 'Quoted'::public.journey_state
    when 'deposit_received' then 'Quoted'::public.journey_state
    when 'payment_completed' then 'Quoted'::public.journey_state
    when 'inventory_required' then 'Waiting for Inventory'::public.journey_state
    when 'inventory_received' then 'Ready to Schedule'::public.journey_state
    when 'delivery_scheduled' then 'Scheduled'::public.journey_state
    when 'delivery_completed' then 'Sleep Trial'::public.journey_state
    when 'trial_completed' then 'Completed'::public.journey_state
    when 'journey_updated_to_sold' then 'Sold'::public.journey_state
    when 'line_items_changed_balance_due' then 'Quoted'::public.journey_state
    else null
  end;
end;
$$;

-- 4. Re-evaluate Quoted/Sold balance whenever line items change the price

create or replace function public.reevaluate_journey_balance(p_journey_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current public.journey_state;
  journey_price numeric;
  paid numeric;
  new_state public.journey_state;
  emp_id text;
begin
  select current_state, price into current, journey_price
  from public.sleep_journeys
  where id = p_journey_id;

  if journey_price is null or current not in ('Quoted'::public.journey_state, 'Sold'::public.journey_state) then
    return;
  end if;

  select id::text into emp_id
  from public.employees
  where auth_user_id = auth.uid();

  paid := public.total_paid(p_journey_id);

  if paid >= journey_price then
    new_state := 'Sold'::public.journey_state;
  else
    new_state := 'Quoted'::public.journey_state;
  end if;

  if new_state = current then
    return;
  end if;

  update public.sleep_journeys
  set current_state = new_state,
      updated_at = now()
  where id = p_journey_id;

  if new_state = 'Sold' then
    insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
    values (
      p_journey_id,
      'journey_updated_to_sold',
      jsonb_build_object(
        'total_paid', paid,
        'price', journey_price,
        'balance_due', journey_price - paid
      ),
      coalesce(emp_id, 'system')
    );
  else
    insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
    values (
      p_journey_id,
      'line_items_changed_balance_due',
      jsonb_build_object(
        'total_paid', paid,
        'price', journey_price,
        'balance_due', journey_price - paid
      ),
      coalesce(emp_id, 'system')
    );
  end if;
end;
$$;

-- 5. Auto-sync sleep_journeys.price/product_summary from line items and log line-item events

create or replace function public.sync_journey_price()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target_journey_id uuid;
  new_total numeric;
  first_item_name text;
  item_count int;
  new_summary text;
  event_type public.journey_event_type;
  event_data jsonb;
  emp_id text;
begin
  target_journey_id := coalesce(new.journey_id, old.journey_id);

  select id::text into emp_id
  from public.employees
  where auth_user_id = auth.uid();

  select coalesce(sum(quantity * unit_price), 0)
  into new_total
  from public.journey_line_items
  where journey_id = target_journey_id;

  select count(*)
  into item_count
  from public.journey_line_items
  where journey_id = target_journey_id;

  select item_name
  into first_item_name
  from public.journey_line_items
  where journey_id = target_journey_id
  order by created_at
  limit 1;

  if item_count is not null and item_count > 0 then
    new_summary := first_item_name;
    if item_count > 1 then
      new_summary := new_summary || ' + ' || (item_count - 1) || ' more';
    end if;
  else
    new_summary := null;
  end if;

  update public.sleep_journeys
  set price = new_total,
      product_summary = coalesce(new_summary, product_summary),
      updated_at = now()
  where id = target_journey_id;

  event_type := case tg_op
    when 'INSERT' then 'line_item_added'
    when 'UPDATE' then 'line_item_updated'
    when 'DELETE' then 'line_item_removed'
  end;

  if tg_op = 'DELETE' then
    event_data := jsonb_build_object(
      'product_id', old.product_id,
      'item_name', old.item_name,
      'quantity', old.quantity,
      'unit_price', old.unit_price
    );
  else
    event_data := jsonb_build_object(
      'product_id', new.product_id,
      'item_name', new.item_name,
      'quantity', new.quantity,
      'unit_price', new.unit_price
    );
  end if;

  insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
  values (target_journey_id, event_type, event_data, coalesce(emp_id, 'system'));

  perform public.reevaluate_journey_balance(target_journey_id);

  return coalesce(new, old);
end;
$$;

drop trigger if exists sync_journey_price on public.journey_line_items;
create trigger sync_journey_price
  after insert or update or delete on public.journey_line_items
  for each row
  execute function public.sync_journey_price();

-- 6. Backfill: one line item for each existing journey that has a price, so historical journeys display consistently

insert into public.journey_line_items (
  journey_id,
  product_id,
  item_name,
  quantity,
  unit_price,
  created_at
)
select
  sj.id,
  sj.product_id,
  coalesce(sj.product_summary, 'Unknown'),
  1,
  coalesce(sj.price, 0),
  sj.created_at
from public.sleep_journeys sj
where sj.price is not null
  and not exists (
    select 1 from public.journey_line_items jli
    where jli.journey_id = sj.id
  );
