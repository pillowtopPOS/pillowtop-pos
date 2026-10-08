-- 084_stock_shortage_reconcile.sql
--
-- When stock is reduced below committed_quantity, today the only feedback is
-- a raw RPC error (manual adjust) or silent oversell (count finalize). This
-- migration adds:
--
--   preview_committed_shortfall    — who would lose reserved stock (read-only)
--   reconcile_committed_shortfall  — release ready requirements back to
--                                    pending, move journeys to Waiting for
--                                    Inventory via inventory_required event,
--                                    create follow-up + timeline entry
--   adjust_inventory_position      — adds p_override_below_committed /
--                                    p_override_reason; guard error gains the
--                                    COMMITTED_SHORTFALL: prefix
--   finalize_inventory_count       — reconciles automatically on a downward
--                                    count and records released journeys in
--                                    the count's audit trail
--   permission inventory.reduce_below_committed (owner + manager by default)
--   follow_ups.type CHECK gains 'inventory_shortage'
--
-- Release order (shared by preview and reconcile): Waiting for Inventory
-- journeys first (newest requirement created_at first — their state does
-- not change, so their leftover reservations are released before real
-- customers are affected), then Ready to Schedule (newest first), then
-- Scheduled (latest delivery date first). Other states are never touched.
-- After all journey-held reservations are released, any committed units
-- still above on-hand are unattributed and cleared to on_hand.

-- ============================================================================
-- 1. Permission: inventory.reduce_below_committed
--    Same seed mechanism as 066 — extended defaults apply to existing and
--    future companies. Owner is already implicitly allowed by has_permission.
-- ============================================================================

create or replace function public.seed_sleep_trial_permission_defaults(p_company_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.role_permission_grants (company_id, role, permission_key)
  select p_company_id, g.role, g.permission_key
  from (
    values
      -- manage_concerns: all roles
      ('owner',    'sleep_trial.manage_concerns'),
      ('admin',    'sleep_trial.manage_concerns'),
      ('manager',  'sleep_trial.manage_concerns'),
      ('sales',    'sleep_trial.manage_concerns'),
      ('employee', 'sleep_trial.manage_concerns'),
      -- start_exchange: all roles
      ('owner',    'sleep_trial.start_exchange'),
      ('admin',    'sleep_trial.start_exchange'),
      ('manager',  'sleep_trial.start_exchange'),
      ('sales',    'sleep_trial.start_exchange'),
      ('employee', 'sleep_trial.start_exchange'),
      -- start_return: owner, admin, manager
      ('owner',    'sleep_trial.start_return'),
      ('admin',    'sleep_trial.start_return'),
      ('manager',  'sleep_trial.start_return'),
      -- request_exceptions: all roles
      ('owner',    'sleep_trial.request_exceptions'),
      ('admin',    'sleep_trial.request_exceptions'),
      ('manager',  'sleep_trial.request_exceptions'),
      ('sales',    'sleep_trial.request_exceptions'),
      ('employee', 'sleep_trial.request_exceptions'),
      -- approve_exceptions: owner, admin, manager
      ('owner',    'sleep_trial.approve_exceptions'),
      ('admin',    'sleep_trial.approve_exceptions'),
      ('manager',  'sleep_trial.approve_exceptions'),
      -- approve_own_exceptions: owner, admin
      ('owner',    'sleep_trial.approve_own_exceptions'),
      ('admin',    'sleep_trial.approve_own_exceptions'),
      -- override_protector: owner, admin
      ('owner',    'sleep_trial.override_protector'),
      ('admin',    'sleep_trial.override_protector'),
      -- correct_dates: owner, admin, manager
      ('owner',    'sleep_trial.correct_dates'),
      ('admin',    'sleep_trial.correct_dates'),
      ('manager',  'sleep_trial.correct_dates'),
      -- manage_policy: owner, admin
      ('owner',    'sleep_trial.manage_policy'),
      ('admin',    'sleep_trial.manage_policy'),
      -- view_policy_details: all roles
      ('owner',    'sleep_trial.view_policy_details'),
      ('admin',    'sleep_trial.view_policy_details'),
      ('manager',  'sleep_trial.view_policy_details'),
      ('sales',    'sleep_trial.view_policy_details'),
      ('employee', 'sleep_trial.view_policy_details'),
      -- reduce_below_committed (084): owner, manager
      ('owner',    'inventory.reduce_below_committed'),
      ('manager',  'inventory.reduce_below_committed')
  ) as g(role, permission_key)
  on conflict (company_id, role, permission_key) do nothing;
end;
$$;

revoke execute on function public.seed_sleep_trial_permission_defaults(uuid)
  from public, anon, authenticated;

-- Backfill existing companies (the companies-insert trigger already calls
-- this function for new ones).
select public.seed_sleep_trial_permission_defaults(id) from public.companies;

-- ============================================================================
-- 2. follow_ups.type CHECK gains 'inventory_shortage' (056:195-196)
-- ============================================================================

alter table public.follow_ups drop constraint if exists follow_ups_type_check;
alter table public.follow_ups
  add constraint follow_ups_type_check
  check (type in ('quote','deposit','interaction','sleep_concern','inventory_shortage'));

-- ============================================================================
-- 3. preview_committed_shortfall — who would lose stock (read-only)
-- ============================================================================

create or replace function public.preview_committed_shortfall(
  p_variant_id uuid,
  p_location_id uuid,
  p_new_on_hand integer
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_committed integer;
  v_deficit integer;
  v_items jsonb;
  v_total_reserved integer;
  v_unattributed integer;
begin
  if not public.is_store_visible(p_location_id) then
    return jsonb_build_object('items', '[]'::jsonb, 'unattributed_units', 0);
  end if;

  select committed_quantity into v_committed
  from public.inventory_positions
  where variant_id = p_variant_id
    and location_id = p_location_id
    and disposition = 'Prime'
    and sublocation_id is null;

  v_deficit := coalesce(v_committed, 0) - greatest(p_new_on_hand, 0);
  if v_deficit <= 0 then
    return jsonb_build_object('items', '[]'::jsonb, 'unattributed_units', 0);
  end if;

  -- Release order shared with reconcile_committed_shortfall: Waiting for
  -- Inventory first (newest created_at first — releasing their leftover
  -- reservations changes no journey state), then Ready to Schedule (newest
  -- first), then Scheduled (latest delivery date first). will_release
  -- walks the deficit so the UI shows exactly which journeys lose units;
  -- already_waiting flags rows whose journey state stays put.
  with candidates as (
    select
      jir.id as requirement_id,
      sj.id as journey_id,
      (c.first_name || ' ' || c.last_name) as customer_name,
      sj.current_state,
      jir.quantity_reserved,
      jir.created_at,
      (select (je.event_data ->> 'delivery_date')::date
       from public.journey_events je
       where je.journey_id = sj.id
         and je.event_type = 'delivery_scheduled'
       order by je.created_at desc
       limit 1) as delivery_date
    from public.journey_inventory_requirements jir
    join public.sleep_journeys sj on sj.id = jir.journey_id
    join public.customers c on c.id = sj.customer_id
    where jir.variant_id = p_variant_id
      and jir.location_id = p_location_id
      and jir.status = 'ready'
      and jir.quantity_reserved > 0
      and sj.cancelled_at is null
      and sj.delivered_at is null
      and sj.current_state in ('Waiting for Inventory', 'Ready to Schedule', 'Scheduled')
  ),
  running as (
    select
      c.*,
      coalesce(sum(c.quantity_reserved) over (
        order by
          case c.current_state
            when 'Waiting for Inventory' then 0
            when 'Ready to Schedule' then 1
            else 2 end,
          case when c.current_state in ('Waiting for Inventory', 'Ready to Schedule')
               then c.created_at end desc,
          case when c.current_state = 'Scheduled'
               then c.delivery_date end desc nulls last,
          c.created_at desc
        rows between unbounded preceding and 1 preceding
      ), 0) as prior_released
    from candidates c
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'journey_id', r.journey_id,
        'requirement_id', r.requirement_id,
        'customer_name', r.customer_name,
        'current_state', r.current_state,
        'quantity_reserved', r.quantity_reserved,
        'delivery_date', r.delivery_date,
        'already_waiting', r.current_state = 'Waiting for Inventory',
        'will_release', r.prior_released < v_deficit
      )
      order by
        case r.current_state
          when 'Waiting for Inventory' then 0
          when 'Ready to Schedule' then 1
          else 2 end,
        case when r.current_state in ('Waiting for Inventory', 'Ready to Schedule')
             then r.created_at end desc,
        case when r.current_state = 'Scheduled'
             then r.delivery_date end desc nulls last,
        r.created_at desc
    ), '[]'::jsonb),
    coalesce(sum(r.quantity_reserved), 0)
  into v_items, v_total_reserved
  from running r;

  -- Reserved units left over after every journey-held reservation is
  -- released are unattributed (cancelled/delivered journeys, legacy rows).
  v_unattributed := greatest(0, v_deficit - coalesce(v_total_reserved, 0));

  return jsonb_build_object(
    'items', v_items,
    'unattributed_units', v_unattributed
  );
end;
$$;

grant execute on function public.preview_committed_shortfall(uuid, uuid, integer)
  to authenticated;

-- ============================================================================
-- 4. reconcile_committed_shortfall — release ready requirements until
--    on_hand >= committed. Called inside the caller's transaction; the
--    caller already holds the variant:location advisory lock
--    (hashtextextended(variant:location:'Prime', 7137)).
-- ============================================================================

create or replace function public.reconcile_committed_shortfall(
  p_variant_id uuid,
  p_location_id uuid,
  p_reason text,
  p_correlation uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pos public.inventory_positions%rowtype;
  v_deficit integer;
  v_req record;
  v_employee uuid;
  v_interaction uuid;
  v_released jsonb := '[]'::jsonb;
  v_unattributed integer := 0;
begin
  select * into v_pos
  from public.inventory_positions
  where variant_id = p_variant_id
    and location_id = p_location_id
    and disposition = 'Prime'
    and sublocation_id is null
  for update;

  if not found then
    return jsonb_build_object('released', '[]'::jsonb, 'unattributed_units', 0);
  end if;

  v_deficit := v_pos.committed_quantity - v_pos.on_hand_quantity;
  if v_deficit <= 0 then
    return jsonb_build_object('released', '[]'::jsonb, 'unattributed_units', 0);
  end if;

  select e.id into v_employee
  from public.employees e
  where e.auth_user_id = auth.uid();

  for v_req in
    select
      jir.id, jir.journey_id, jir.quantity_reserved, jir.created_at,
      sj.current_state, sj.assigned_employee_id,
      (select (je.event_data ->> 'delivery_date')::date
       from public.journey_events je
       where je.journey_id = sj.id
         and je.event_type = 'delivery_scheduled'
       order by je.created_at desc
       limit 1) as delivery_date
    from public.journey_inventory_requirements jir
    join public.sleep_journeys sj on sj.id = jir.journey_id
    where jir.variant_id = p_variant_id
      and jir.location_id = p_location_id
      and jir.status = 'ready'
      and jir.quantity_reserved > 0
      and sj.cancelled_at is null
      and sj.delivered_at is null
      and sj.current_state in ('Waiting for Inventory', 'Ready to Schedule', 'Scheduled')
    order by
      case sj.current_state
        when 'Waiting for Inventory' then 0
        when 'Ready to Schedule' then 1
        else 2 end,
      case when sj.current_state in ('Waiting for Inventory', 'Ready to Schedule')
           then jir.created_at end desc,
      case when sj.current_state = 'Scheduled'
           then delivery_date end desc nulls last,
      jir.created_at desc
  loop
    exit when v_deficit <= 0;

    -- Deterministic journey lock order = the release order above; callers
    -- already hold the variant:location lock so this is variant -> journey,
    -- same as the stock-arrival paths.
    perform pg_advisory_xact_lock(
      hashtextextended(v_req.journey_id::text, 7137)
    );

    -- Re-check under the journey lock: a concurrent release/fulfillment may
    -- have moved the row while we waited.
    if not exists (
      select 1
      from public.journey_inventory_requirements
      where id = v_req.id
        and status = 'ready'
        and quantity_reserved = v_req.quantity_reserved
    ) then
      continue;
    end if;

    update public.journey_inventory_requirements
    set status = 'pending', quantity_reserved = 0
    where id = v_req.id;

    update public.inventory_positions
    set committed_quantity = greatest(0, committed_quantity - v_req.quantity_reserved),
        updated_at = now()
    where id = v_pos.id;

    v_deficit := v_deficit - v_req.quantity_reserved;

    -- State moves via the event trigger, not a direct update: Scheduled and
    -- Ready to Schedule both land on Waiting for Inventory. The
    -- delivery_scheduled event stays in history unmodified. Journeys
    -- already in Waiting for Inventory get no event — their state does not
    -- change — and no follow-up, since no customer promise was broken.
    if v_req.current_state <> 'Waiting for Inventory' then
      insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
      values (
        v_req.journey_id,
        'inventory_required',
        jsonb_build_object(
          'automated', true,
          'requirements_ready', false,
          'reason', coalesce(p_reason, 'stock reduced below committed'),
          'correlation_id', p_correlation,
          'released_quantity', v_req.quantity_reserved,
          'released_from_state', v_req.current_state),
        'system'
      );
    end if;

    -- Timeline entry: who reduced the stock and why.
    insert into public.journey_interactions (
      journey_id, customer_id, interaction_type, channel, direction,
      topic, summary, created_by_employee_id, source_domain, source_record_id,
      is_internal
    )
    select
      v_req.journey_id, sj.customer_id, 'internal_note', 'internal', 'internal',
      'inventory_eta',
      'Stock reduced below committed: ' || v_req.quantity_reserved
        || ' reserved unit(s) released'
        || case when v_req.current_state = 'Waiting for Inventory'
             then ' (journey already in Waiting for Inventory; no state change).'
             else ' and the journey moved back to Waiting for Inventory.'
           end
        || coalesce(' Reason: ' || btrim(p_reason) || '.', ''),
      v_employee, 'inventory', v_req.id, true
    from public.sleep_journeys sj
    where sj.id = v_req.journey_id
    returning id into v_interaction;

    if v_req.current_state <> 'Waiting for Inventory' then
      insert into public.follow_ups (
        journey_id, employee_id, type, due_at, notes, method,
        journey_interaction_id, idempotency_key
      ) values (
        v_req.journey_id,
        v_req.assigned_employee_id,
        'inventory_shortage',
        now(),
        case when v_req.current_state = 'Scheduled'
          then 'Delivery on '
               || coalesce(to_char(v_req.delivery_date, 'Mon DD, YYYY'),
                           'the scheduled date')
               || ' cannot happen: inventory was off. Call the customer.'
          else 'Reserved stock was pulled and this journey is back to Waiting for Inventory. Tell the customer if they were told it was ready.'
        end,
        'phone',
        v_interaction,
        'inventory_shortage:' || v_req.id::text || ':'
          || coalesce(p_correlation::text, 'none')
      )
      on conflict (idempotency_key) where idempotency_key is not null
      do nothing;
    end if;

    v_released := v_released || jsonb_build_object(
      'journey_id', v_req.journey_id,
      'requirement_id', v_req.id,
      'current_state', v_req.current_state,
      'already_waiting', v_req.current_state = 'Waiting for Inventory',
      'quantity_released', v_req.quantity_reserved,
      'delivery_date', v_req.delivery_date);
  end loop;

  -- Reserved units left over after every journey-held reservation has been
  -- released are unattributed (fulfilled/cancelled journeys, legacy rows).
  -- Clear them so committed never exceeds what is physically on hand.
  if v_deficit > 0 then
    update public.inventory_positions
    set committed_quantity = greatest(0, on_hand_quantity),
        updated_at = now()
    where id = v_pos.id;
    v_unattributed := v_deficit;
  end if;

  return jsonb_build_object(
    'released', v_released,
    'unattributed_units', v_unattributed
  );
end;
$$;

revoke execute on function public.reconcile_committed_shortfall(uuid, uuid, text, uuid)
  from public, anon, authenticated;

-- ============================================================================
-- 5. adjust_inventory_position — 029 definition plus the override path.
--    New params have defaults; the old 8-arg signature is dropped so named-arg
--    callers land on this version.
-- ============================================================================

drop function if exists public.adjust_inventory_position(
  uuid, uuid, text, public.disposition, integer, text, text, text);

create or replace function public.adjust_inventory_position(
  p_variant_id uuid,
  p_location_id uuid,
  p_sublocation_id text,
  p_disposition public.disposition,
  p_new_quantity integer,
  p_reason text,
  p_reference_type text,
  p_actor_id text,
  p_override_below_committed boolean default false,
  p_override_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role public.employee_role;
  v_caller_company uuid;
  v_location_company uuid;
  v_allowed boolean := false;
  v_position_id uuid;
  v_old integer;
  v_committed integer;
  v_correlation uuid;
  v_reconcile jsonb;
  v_employee uuid;
begin
  v_role := public.current_employee_role();

  select s.company_id
  into v_caller_company
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid();

  select company_id
  into v_location_company
  from public.stores
  where id = p_location_id;

  if v_caller_company is null then
    raise exception 'Could not determine employee company';
  end if;

  if v_caller_company is distinct from v_location_company then
    raise exception 'Location does not belong to employee company';
  end if;

  if v_role::text in ('owner', 'admin') then
    v_allowed := true;
  elsif v_role::text = 'manager' then
    select coalesce(managers_can_adjust_inventory, false)
    into v_allowed
    from public.companies
    where id = v_caller_company;
  end if;

  if not v_allowed then
    raise exception 'Employee is not authorized to adjust inventory';
  end if;

  if p_new_quantity < 0 then
    raise exception 'Quantity cannot be negative';
  end if;

  if p_override_below_committed then
    if p_override_reason is null or btrim(p_override_reason) = '' then
      raise exception 'A reason is required to reduce stock below committed quantity';
    end if;
    if not public.has_permission('inventory.reduce_below_committed') then
      raise exception 'Employee is not authorized to reduce stock below committed quantity';
    end if;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      p_variant_id::text || ':' || p_location_id::text || ':' || p_disposition::text,
      7137
    )
  );

  select id, on_hand_quantity, committed_quantity
  into v_position_id, v_old, v_committed
  from public.inventory_positions
  where variant_id = p_variant_id
    and location_id = p_location_id
    and sublocation_id is not distinct from p_sublocation_id
    and disposition = p_disposition
  for update;

  if not found then
    insert into public.inventory_positions (
      variant_id,
      location_id,
      sublocation_id,
      disposition,
      on_hand_quantity,
      committed_quantity
    ) values (
      p_variant_id,
      p_location_id,
      p_sublocation_id,
      p_disposition,
      p_new_quantity,
      0
    )
    returning id into v_position_id;

    v_old := 0;
    v_committed := 0;
  else
    if p_new_quantity < v_committed and not p_override_below_committed then
      -- Fixed prefix so the client can open the shortage dialog instead of
      -- showing a raw alert.
      raise exception
        'COMMITTED_SHORTFALL: Cannot set on-hand to % — % units are already committed to open orders at this location.',
        p_new_quantity,
        v_committed;
    end if;

    update public.inventory_positions
    set on_hand_quantity = p_new_quantity,
        updated_at = now()
    where id = v_position_id;
  end if;

  if p_new_quantity <> v_old then
    -- One correlation id ties the ledger row to the released requirements,
    -- follow-ups, and journey events produced by the reconcile below.
    v_correlation := gen_random_uuid();
    insert into public.stock_ledger_entries (
      variant_id,
      location_id,
      disposition,
      quantity_delta,
      reason,
      reference_type,
      actor_id,
      correlation_id
    ) values (
      p_variant_id,
      p_location_id,
      p_disposition,
      p_new_quantity - v_old,
      case when p_new_quantity < v_committed
           then p_reason || ' [below-committed override: ' || btrim(p_override_reason) || ']'
           else p_reason end,
      p_reference_type,
      p_actor_id,
      v_correlation
    );
  end if;

  if p_new_quantity > v_old and p_disposition = 'Prime' then
    perform public.evaluate_pending_inventory_for_variant(
      p_variant_id,
      p_location_id
    );
  end if;

  -- Release uncovered reservations (committed only ever lives on Prime).
  -- Called after the position write, under the advisory lock taken above.
  if p_disposition = 'Prime' and p_new_quantity < v_committed then
    v_reconcile := public.reconcile_committed_shortfall(
      p_variant_id,
      p_location_id,
      p_override_reason,
      coalesce(v_correlation, gen_random_uuid())
    );

    if coalesce((v_reconcile ->> 'unattributed_units')::integer, 0) > 0 then
      select e.id into v_employee
      from public.employees e
      where e.auth_user_id = auth.uid();

      perform public.log_audit_event(
        v_caller_company,
        'inventory_position',
        v_position_id,
        'UNATTRIBUTED_COMMITTED_CLEARED',
        null,
        jsonb_build_object(
          'unattributed_units', (v_reconcile ->> 'unattributed_units')::integer,
          'variant_id', p_variant_id,
          'location_id', p_location_id),
        'COMMITTED_SHORTFALL',
        'Override cleared ' || (v_reconcile ->> 'unattributed_units')
          || ' reserved unit(s) not tied to any open journey. Reason: '
          || btrim(p_override_reason),
        null,
        'EMPLOYEE',
        v_employee,
        null
      );
    end if;
  end if;

  return v_position_id;
end;
$$;

grant execute on function public.adjust_inventory_position(
  uuid,
  uuid,
  text,
  public.disposition,
  integer,
  text,
  text,
  text,
  boolean,
  text
) to authenticated;

-- ============================================================================
-- 6. finalize_inventory_count — 078 definition plus: a downward count below
--    committed auto-reconciles and the released journeys are recorded in the
--    count's audit trail (audit_events, entity_type 'inventory_count').
-- ============================================================================

create or replace function public.finalize_inventory_count(
  p_count_id uuid,
  p_employee_id uuid,
  p_counts jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
  v_count public.inventory_counts%rowtype;
  v_item public.inventory_count_items%rowtype;
  v_qty integer;
  v_pos public.inventory_positions%rowtype;
  v_old_on_hand integer;
  v_item_total integer;
  v_released jsonb := '[]'::jsonb;
  v_reconcile jsonb;
begin
  v_emp := public.verify_count_employee(p_employee_id);

  select * into v_count
  from public.inventory_counts
  where id = p_count_id
  for update;

  if not found then raise exception 'Count not found'; end if;
  if v_count.status <> 'submitted' then
    raise exception 'Only submitted counts can be finalized';
  end if;
  if not public.can_finalize_count(v_emp, v_count) then
    raise exception 'Only a manager of this store or an owner/admin can finalize a count';
  end if;

  select count(*) into v_item_total
  from public.inventory_count_items
  where count_id = p_count_id;

  for v_item in
    select * from public.inventory_count_items
    where count_id = p_count_id
    order by id
    for update
  loop
    if p_counts is null or not (p_counts ? v_item.id::text) then
      raise exception 'A counted quantity is required for every item';
    end if;

    v_qty := (p_counts ->> v_item.id::text)::integer;
    if v_qty is null or v_qty < 0 then
      raise exception 'Invalid counted quantity';
    end if;

    perform pg_advisory_xact_lock(
      hashtextextended(v_item.variant_id::text || ':' || v_count.store_id::text || ':Prime', 7137)
    );

    select * into v_pos
    from public.inventory_positions
    where variant_id = v_item.variant_id
      and location_id = v_count.store_id
      and disposition = 'Prime'
      and sublocation_id is null
    for update;

    if not found then
      insert into public.inventory_positions (
        variant_id, location_id, sublocation_id, disposition,
        on_hand_quantity, committed_quantity
      ) values (
        v_item.variant_id, v_count.store_id, null, 'Prime', v_qty, 0
      );
      v_old_on_hand := 0;
    else
      v_old_on_hand := v_pos.on_hand_quantity;
      update public.inventory_positions
        set on_hand_quantity = v_qty,
            updated_at = now()
      where id = v_pos.id;
    end if;

    if v_qty <> v_old_on_hand then
      insert into public.stock_ledger_entries (
        variant_id, location_id, disposition, quantity_delta,
        reason, reference_type, actor_id, correlation_id
      ) values (
        v_item.variant_id, v_count.store_id, 'Prime',
        v_qty - v_old_on_hand,
        'inventory_count', 'inventory_count_item', v_emp.id::text,
        p_count_id
      );
    end if;

    update public.inventory_count_items
      set counted_quantity = v_qty,
          entered_by = v_emp.id,
          entered_at = now()
    where id = v_item.id;

    -- A downward count can drop on-hand below committed: release uncovered
    -- reservations and move those journeys back to Waiting for Inventory.
    -- The caller holds the variant:location advisory lock for this item.
    if v_qty < coalesce(v_pos.committed_quantity, 0) then
      v_reconcile := public.reconcile_committed_shortfall(
        v_item.variant_id, v_count.store_id,
        'Physical inventory count', p_count_id);
      v_released := v_released
        || coalesce(v_reconcile -> 'released', '[]'::jsonb);

      if coalesce((v_reconcile ->> 'unattributed_units')::integer, 0) > 0 then
        perform public.log_audit_event(
          v_count.company_id,
          'inventory_position',
          v_pos.id,
          'UNATTRIBUTED_COMMITTED_CLEARED',
          null,
          jsonb_build_object(
            'unattributed_units', (v_reconcile ->> 'unattributed_units')::integer,
            'variant_id', v_item.variant_id,
            'location_id', v_count.store_id,
            'inventory_count_id', p_count_id),
          'COMMITTED_SHORTFALL',
          'Physical inventory count cleared '
            || (v_reconcile ->> 'unattributed_units')
            || ' reserved unit(s) not tied to any open journey.',
          null,
          'EMPLOYEE',
          v_emp.id,
          null
        );
      end if;
    end if;

    -- Only an upward correction can satisfy a waiting Journey; a downward
    -- count does not add stock, so it does not re-evaluate.
    if v_qty > v_old_on_hand then
      perform public.evaluate_pending_inventory_for_variant(
        v_item.variant_id, v_count.store_id
      );
    end if;
  end loop;

  update public.inventory_counts
    set status = 'approved',
        approved_by = v_emp.id,
        approved_at = now(),
        updated_at = now()
  where id = p_count_id;

  -- Count audit trail: which journeys lost reserved stock and why.
  if jsonb_array_length(v_released) > 0 then
    perform public.log_audit_event(
      v_count.company_id,
      'inventory_count',
      p_count_id,
      'COMMITTED_RESERVATIONS_RELEASED',
      null,
      v_released,
      'COMMITTED_SHORTFALL',
      'Counted on-hand below committed; the listed journeys'' reserved stock was released back to pending and they moved to Waiting for Inventory.',
      null,
      'EMPLOYEE',
      v_emp.id,
      null
    );
  end if;
end;
$$;

grant execute on function public.finalize_inventory_count(uuid, uuid, jsonb) to authenticated;
