-- ============================================================================
-- S4a-3: unit-level receive + missing for transfers.
--
-- 1. unit_transitions gains IN_TRANSIT -> MISSING (position_delta 0,
--    mirror_owner 'wrapper'): ship already debited the origin and a missing
--    unit is never credited at the destination, so no position/ledger write.
--    Additive insert only; unit_transitions is never deleted from.
--
-- 2. finalize_transfer gains optional p_unit_receipts jsonb (default null)
--    and now returns jsonb. The old 3-arg signature is dropped and replaced
--    by the 4-arg function with a default — one code path for quantity
--    logic; existing 3-arg calls keep working.
--
-- 3. Permission: verify_transfer_receiver — owner/admin, warehouse-based
--    employees (the old approver set), OR staff whose home store IS the
--    transfer destination. Previously finalize required
--    verify_transfer_approver (owner/admin/warehouse only).
--
-- 4. Receive rules per tracked line with in-flight pick rows:
--      reported received == shipped count -> every shipped unit received,
--        no scanning required.
--      short -> staff MUST name which units are missing (received and/or
--        missing lists, by unit_id or unit_number). Never guessed.
--      A RESERVED (customer-bound) unit is never defaulted to missing.
--      Named units must be a subset of THIS transfer's shipped units;
--      scan count can never exceed shipped.
--    Received units: move_unit -> STOCK (was STOCK) or RESERVED (was
--    RESERVED, keeps its requirement) at the destination with
--    transfer_id in unit_events. Missing units: move_unit -> MISSING with
--    reason + transfer_line_units.missing_* + audit_events row.
--    quantity_received always equals the number of units actually
--    received, so quantity and units agree.
--
-- 5. After receive, arriving STOCK units fill waiting orders via the
--    existing assign_received_units_to_orders; the result returns
--    assignments in the same shape as receive_purchase_order_line plus a
--    missing_units list.
-- ============================================================================

insert into public.unit_transitions
  (from_status, to_status, position_delta, ledger_reason, mirror_owner, two_leg)
values ('IN_TRANSIT', 'MISSING', 0, 'unit_missing', 'wrapper', false)
on conflict (from_status, to_status) do nothing;

-- Receiver check: old approver set (owner/admin or warehouse-based) plus
-- staff homed at the transfer's destination store.
create or replace function public.verify_transfer_receiver(
  p_employee_id uuid,
  p_destination_location_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
begin
  if p_employee_id is null then
    raise exception 'Employee id is required';
  end if;

  select * into v_emp from public.employees where id = p_employee_id;
  if not found then
    raise exception 'Employee not found';
  end if;
  if not v_emp.is_active then
    raise exception 'Employee is not active';
  end if;
  if v_emp.auth_user_id is distinct from auth.uid() then
    raise exception 'Employee does not match the authenticated user';
  end if;

  if v_emp.role::text not in ('owner', 'admin')
     and v_emp.home_store_id is distinct from p_destination_location_id
     and not exists (
       select 1 from public.stores s
       where s.id = v_emp.home_store_id
         and s.location_type = 'WAREHOUSE'
     ) then
    raise exception
      'Only the destination store''s staff, a manager, or warehouse staff can receive a transfer';
  end if;

  return v_emp.id;
end;
$$;

grant execute on function public.verify_transfer_receiver(uuid, uuid) to authenticated;

-- finalize_transfer: 078 body + receiver permission + unit receive/resolve
-- + order assignment + jsonb result. Old 3-arg signature dropped; the
-- 4-arg version defaults p_unit_receipts to null.
drop function if exists public.finalize_transfer(uuid, jsonb, uuid);

create function public.finalize_transfer(
  p_transfer_id uuid,
  p_received jsonb,
  p_employee_id uuid,
  p_unit_receipts jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
  v_t public.transfers%rowtype;
  v_line public.transfer_line_items%rowtype;
  v_recv integer;
  v_pos public.inventory_positions%rowtype;
  v_new_on_hand integer;
  v_release integer;
  v_company uuid;
  -- unit receive state
  v_shipped_ids uuid[];
  v_shipped_count integer;
  v_all_ids uuid[];
  v_open_ids uuid[];
  v_pre_miss_ids uuid[];
  v_open_count integer;
  v_recv_done integer;
  v_recv_new_target integer;
  v_entry jsonb;
  v_recv_ids uuid[];
  v_miss_ids uuid[];
  v_recv_add uuid[];
  v_miss_add uuid[];
  v_all_recv uuid[] := '{}';
  v_all_recv_nums bigint[] := '{}';
  v_missing jsonb := '[]'::jsonb;
  v_assigned_ids uuid[] := '{}';
  v_assigned_all uuid[] := '{}';
  v_assign_failed boolean := false;
  v_assignments jsonb := '[]'::jsonb;
  v_tlu record;
  v_uid uuid;
  v_target text;
  v_journey uuid;
  v_tlu record;
  i integer;
begin
  select s.company_id into v_company
  from public.transfers t
  join public.stores s on s.id = t.destination_location_id
  where t.id = p_transfer_id;
  if v_company is null then raise exception 'Transfer not found'; end if;

  v_actor := public.verify_transfer_receiver(p_employee_id,
    (select destination_location_id from public.transfers
      where id = p_transfer_id));

  select * into v_t
  from public.transfers
  where id = p_transfer_id
  for update;

  if v_t.status <> 'in_transit' then
    raise exception 'Only in_transit transfers can be finalized';
  end if;
  if not (public.is_store_visible(v_t.origin_location_id) or public.is_store_visible(v_t.destination_location_id)) then
    raise exception 'Transfer is not visible to this employee';
  end if;

  for v_line in
    select * from public.transfer_line_items where transfer_id = p_transfer_id for update
  loop
    if p_received is null or not (p_received ? v_line.id::text) then
      v_recv := v_line.quantity_shipped;
    else
      v_recv := (p_received ->> v_line.id::text)::integer;
    end if;

    if v_recv is null or v_recv < 0 or v_recv > v_line.quantity_shipped then
      raise exception 'Invalid received quantity for line %', v_line.id;
    end if;

    perform pg_advisory_xact_lock(
      hashtextextended(v_line.variant_id::text || ':' || v_t.destination_location_id::text || ':Prime', 7137)
    );

    select * into v_pos
    from public.inventory_positions
    where variant_id = v_line.variant_id
      and location_id = v_t.destination_location_id
      and disposition = 'Prime'
      and sublocation_id is null
    for update;

    if not found then
      insert into public.inventory_positions (
        variant_id, location_id, sublocation_id, disposition,
        on_hand_quantity, committed_quantity
      ) values (
        v_line.variant_id, v_t.destination_location_id, null, 'Prime',
        v_recv, 0
      ) returning * into v_pos;
    else
      v_new_on_hand := v_pos.on_hand_quantity + v_recv;
      update public.inventory_positions
        set on_hand_quantity = v_new_on_hand,
            updated_at = now()
      where id = v_pos.id;
    end if;

    insert into public.stock_ledger_entries (
      variant_id, location_id, disposition, quantity_delta,
      reason, reference_type, actor_id
    ) values (
      v_line.variant_id, v_t.destination_location_id, 'Prime', v_recv,
      'transfer_receive', 'transfer_line_item', v_actor::text
    );

    -- Release whatever remains of the approval-time reservation at the
    -- origin: ship already released committed_released_qty.
    v_release := v_line.quantity_requested - v_line.committed_released_qty;
    perform pg_advisory_xact_lock(
      hashtextextended(v_line.variant_id::text || ':' || v_t.origin_location_id::text || ':Prime', 7137)
    );
    update public.inventory_positions
      set committed_quantity = greatest(0, committed_quantity - v_release),
          updated_at = now()
    where variant_id = v_line.variant_id
      and location_id = v_t.origin_location_id
      and disposition = 'Prime'
      and sublocation_id is null;

    update public.transfer_line_items
      set quantity_received = v_recv
    where id = v_line.id;

    -- Stock just arrived at the destination; wake any Journey waiting on it.
    perform public.evaluate_pending_inventory_for_variant(
      v_line.variant_id, v_t.destination_location_id
    );

    -- ---- unit-level receive / missing (picked lines only) -------------
    if public.is_unit_tracked(v_line.variant_id) then
      -- Every pick row left on this line IS a shipped unit: ship deletes
      -- the rows of units that stayed behind. Rows may already be resolved
      -- (received_at / missing_at set by an earlier mark_transfer_unit_missing).
      select array_agg(tlu.unit_id order by tlu.unit_number),
             count(*)
        into v_shipped_ids, v_shipped_count
      from public.transfer_line_units tlu
      where tlu.transfer_line_item_id = v_line.id;

      if v_shipped_ids is not null then
        if v_shipped_count <> v_line.quantity_shipped then
          raise exception
            'Unit/quantity mismatch on line %: % units in flight vs % shipped',
            v_line.id, v_shipped_count, v_line.quantity_shipped;
        end if;

        select coalesce(array_agg(tlu.unit_id), '{}'),
               coalesce(array_agg(tlu.unit_id) filter (
                 where tlu.received_at is null and tlu.missing_at is null), '{}'),
               coalesce(array_agg(tlu.unit_id) filter (
                 where tlu.missing_at is not null), '{}'),
               count(*) filter (where tlu.received_at is not null)
          into v_all_ids, v_open_ids, v_pre_miss_ids, v_recv_done
        from public.transfer_line_units tlu
        where tlu.transfer_line_item_id = v_line.id;

        v_open_count := coalesce(array_length(v_open_ids, 1), 0);
        v_recv_new_target := v_recv - v_recv_done;
        if v_recv_new_target < 0 or v_recv_new_target > v_open_count then
          raise exception
            'Line %: % already resolved, % still open — cannot receive %',
            v_line.id, v_shipped_count - v_open_count, v_open_count, v_recv;
        end if;

        v_entry := null;
        if p_unit_receipts is not null then
          select p into v_entry
          from jsonb_array_elements(p_unit_receipts) p
          where (p ->> 'line_item_id')::uuid = v_line.id
          limit 1;
        end if;

        v_recv_ids := null; v_miss_ids := null;
        if v_entry is not null then
          select coalesce(array_agg(x::uuid), '{}') into v_recv_ids
          from jsonb_array_elements_text(
            coalesce(v_entry -> 'received_unit_ids', '[]'::jsonb)) x;
          select coalesce(array_agg(x::uuid), '{}') into v_miss_ids
          from jsonb_array_elements_text(
            coalesce(v_entry -> 'missing_unit_ids', '[]'::jsonb)) x;
          if coalesce(jsonb_array_length(v_entry -> 'received_unit_numbers'), 0) > 0 then
            select coalesce(array_agg(u.id), '{}') into v_recv_add
            from public.units u
            where u.unit_number = any (
              (select array_agg(n::bigint)
                 from jsonb_array_elements_text(
                   v_entry -> 'received_unit_numbers') n))
              and u.id = any (v_open_ids);
            v_recv_ids := v_recv_ids || v_recv_add;
          end if;
          if coalesce(jsonb_array_length(v_entry -> 'missing_unit_numbers'), 0) > 0 then
            select coalesce(array_agg(u.id), '{}') into v_miss_add
            from public.units u
            where u.unit_number = any (
              (select array_agg(n::bigint)
                 from jsonb_array_elements_text(
                   v_entry -> 'missing_unit_numbers') n))
              and u.id = any (v_open_ids);
            v_miss_ids := v_miss_ids || v_miss_add;
          end if;
        end if;

        -- Normalize over the OPEN set: whichever lists were given, derive
        -- the other side. Nothing is ever guessed; a short count with no
        -- entry is an error, and a RESERVED unit is never defaulted.
        if v_recv_ids is null and v_miss_ids is null then
          if v_recv_new_target <> v_open_count then
            raise exception
              'Line % is short % units — staff must name which units are missing',
              v_line.id, v_open_count - v_recv_new_target;
          end if;
          v_recv_ids := v_open_ids;
          v_miss_ids := '{}';
        else
          v_recv_ids := coalesce(v_recv_ids, '{}');
          v_miss_ids := coalesce(v_miss_ids, '{}');
          if v_recv_ids = '{}' and v_miss_ids <> '{}' then
            select coalesce(array_agg(u), '{}') into v_recv_ids
            from unnest(v_open_ids) u
            where not (u = any (v_miss_ids));
          elsif v_miss_ids = '{}' and v_recv_ids <> '{}' then
            select coalesce(array_agg(u), '{}') into v_miss_ids
            from unnest(v_open_ids) u
            where not (u = any (v_recv_ids));
          end if;
          select coalesce(array_agg(distinct x), '{}') into v_recv_ids
          from unnest(v_recv_ids) x;
          select coalesce(array_agg(distinct x), '{}') into v_miss_ids
          from unnest(v_miss_ids) x;
          if exists (select 1 from unnest(v_recv_ids || v_miss_ids) e
                     group by e having count(*) > 1)
             or exists (select 1 from unnest(v_recv_ids) r
                        where not (r = any (v_open_ids)))
             or exists (select 1 from unnest(v_miss_ids) m
                        where not (m = any (v_open_ids))) then
            raise exception
              'Receive/missing unit lists for line % must be disjoint subsets of the shipped units',
              v_line.id;
          end if;
          if coalesce(array_length(v_recv_ids, 1), 0) <> v_recv_new_target
             or coalesce(array_length(v_miss_ids, 1), 0)
                <> v_open_count - v_recv_new_target then
            raise exception
              'Line %: received + missing units must cover the open units (% received, % missing expected)',
              v_line.id, v_recv_new_target, v_open_count - v_recv_new_target;
          end if;
        end if;

        -- Units already marked missing before finalize join the result.
        for v_tlu in
          select tlu.unit_id, tlu.unit_number, tlu.missing_reason
          from public.transfer_line_units tlu
          where tlu.transfer_line_item_id = v_line.id
            and tlu.missing_at is not null
        loop
          v_missing := v_missing || jsonb_build_object(
            'unit_id', v_tlu.unit_id,
            'unit_number', v_tlu.unit_number,
            'transfer_line_item_id', v_line.id,
            'variant_id', v_line.variant_id,
            'reason', v_tlu.missing_reason);
        end loop;

        -- Move newly received units to the destination.
        for i in 1..coalesce(array_length(v_recv_ids, 1), 0) loop
          v_uid := v_recv_ids[i];
          select case when tlu.picked_status = 'RESERVED'
                      then 'RESERVED' else 'STOCK' end,
                 (select jir.journey_id
                    from public.journey_inventory_requirements jir
                   where jir.id = tlu.picked_requirement_id)
            into v_target, v_journey
          from public.transfer_line_units tlu
          where tlu.unit_id = v_uid
            and tlu.transfer_line_item_id = v_line.id;
          perform public.move_unit(v_uid, v_target, v_t.destination_location_id,
            jsonb_build_object(
              'transfer_id', p_transfer_id,
              'event_type', 'UNIT_RECEIVED',
              'journey_id', v_journey));
          update public.transfer_line_units
            set received_at = now(), received_by = v_actor
          where unit_id = v_uid and transfer_line_item_id = v_line.id;
          v_all_recv := v_all_recv || v_uid;
          v_all_recv_nums := v_all_recv_nums || (
            select unit_number from public.units where id = v_uid);
        end loop;

        -- Move newly missing units to MISSING with an audit trail.
        for i in 1..coalesce(array_length(v_miss_ids, 1), 0) loop
          v_uid := v_miss_ids[i];
          perform public.move_unit(v_uid, 'MISSING', null,
            jsonb_build_object(
              'transfer_id', p_transfer_id,
              'event_type', 'UNIT_MISSING',
              'reason', coalesce(v_entry ->> 'missing_reason',
                                 'not received')));
          update public.transfer_line_units
            set missing_at = now(), missing_by = v_actor,
                missing_reason = coalesce(v_entry ->> 'missing_reason',
                                          'not received')
          where unit_id = v_uid and transfer_line_item_id = v_line.id;
          v_missing := v_missing || jsonb_build_object(
            'unit_id', v_uid,
            'unit_number', (select unit_number from public.units where id = v_uid),
            'transfer_line_item_id', v_line.id,
            'variant_id', v_line.variant_id,
            'reason', coalesce(v_entry ->> 'missing_reason', 'not received'));
          insert into public.audit_events (
            company_id, actor_type, actor_employee_id, entity_type,
            entity_id, event_type, after
          ) values (
            v_company, 'EMPLOYEE', v_actor, 'transfer_line_unit',
            (select id from public.transfer_line_units
              where unit_id = v_uid and transfer_line_item_id = v_line.id),
            'TRANSFER_UNIT_MISSING',
            jsonb_build_object('unit_id', v_uid, 'transfer_id', p_transfer_id,
              'reason', coalesce(v_entry ->> 'missing_reason', 'not received')));
        end loop;

        -- Arriving STOCK units may fill waiting orders at the destination.
        if v_recv_ids <> '{}' then
          begin
            select public.assign_received_units_to_orders(
              v_recv_ids, v_line.variant_id,
              v_t.destination_location_id, v_company)
            into v_assigned_ids;
            v_assigned_all := v_assigned_all
              || coalesce(v_assigned_ids, '{}');
          exception when others then
            v_assign_failed := true;
            insert into public.audit_events (
              company_id, actor_type, entity_type, entity_id,
              event_type, after
            ) values (
              v_company, 'SYSTEM', 'transfer_line_item', v_line.id,
              'UNIT_ORDER_ASSIGN_FAILED',
              jsonb_build_object('error', sqlerrm,
                'variant_id', v_line.variant_id,
                'location_id', v_t.destination_location_id));
          end;
        end if;
      end if;
    end if;
  end loop;

  -- Same assignment result shape as receive_purchase_order_line.
  if v_all_recv <> '{}' or v_assigned_ids <> '{}' then
    select coalesce(jsonb_agg(jsonb_build_object(
        'unit_id', u.id,
        'unit_number', u.unit_number,
        'journey_id', jir.journey_id,
        'journey_number', sj.journey_number,
        'customer_name', nullif(trim(concat_ws(' ', c.first_name, c.last_name)), ''),
        'requirement_id', jir.id
      ) order by u.unit_number), '[]'::jsonb)
    into v_assignments
    from public.units u
    join public.journey_inventory_requirements jir
      on jir.id = u.assigned_requirement_id
    join public.sleep_journeys sj on sj.id = jir.journey_id
    join public.customers c on c.id = sj.customer_id
    where u.id = any(v_all_recv || v_assigned_all);
  end if;

  update public.transfers
    set status = 'finalized',
        finalized_at = now(),
        finalized_by = v_actor
  where id = p_transfer_id;

  return jsonb_build_object(
    'received_unit_ids', v_all_recv,
    'unit_numbers', v_all_recv_nums,
    'assignments', v_assignments,
    'missing_units', v_missing,
    'assign_failed', v_assign_failed);
end;
$$;

grant execute on function public.finalize_transfer(uuid, jsonb, uuid, jsonb) to authenticated;
revoke execute on function public.finalize_transfer(uuid, jsonb, uuid, jsonb)
  from public, anon;

comment on function public.finalize_transfer(uuid, jsonb, uuid, jsonb) is
  'Finalizes an in-transit transfer. Quantity logic is unchanged; for
   unit-tracked lines with pick rows it also receives or marks-missing the
   exact shipped units, assigns arriving stock to waiting orders, and
   returns assignments plus a missing_units list.';

-- mark_transfer_unit_missing: a shipped unit turns out not to have arrived.
-- Same MISSING path as finalize; works any time after ship.
create or replace function public.mark_transfer_unit_missing(
  p_unit_id uuid,
  p_reason text,
  p_employee_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
  v_tlu public.transfer_line_units%rowtype;
  v_t public.transfers%rowtype;
  v_company uuid;
begin
  select tlu.* into v_tlu
  from public.transfer_line_units tlu
  join public.transfer_line_items tli on tli.id = tlu.transfer_line_item_id
  join public.transfers t on t.id = tli.transfer_id
  where tlu.unit_id = p_unit_id
    and tlu.received_at is null
    and tlu.missing_at is null
  for update of tlu;
  if not found then
    raise exception 'Unit % has no unresolved shipment', p_unit_id;
  end if;
  if (select status from public.units where id = p_unit_id) <> 'IN_TRANSIT' then
    raise exception 'Unit % is not in transit', p_unit_id;
  end if;

  select * into v_t from public.transfers
  where id = (select transfer_id from public.transfer_line_items
              where id = v_tlu.transfer_line_item_id);
  select s.company_id into v_company from public.stores s
  where s.id = v_t.destination_location_id;

  v_actor := public.verify_transfer_receiver(p_employee_id,
    v_t.destination_location_id);

  if v_t.status = 'finalized' then
    raise exception 'Transfer is already finalized';
  end if;

  perform public.move_unit(p_unit_id, 'MISSING', null,
    jsonb_build_object(
      'transfer_id', v_t.id,
      'event_type', 'UNIT_MISSING',
      'reason', coalesce(nullif(trim(p_reason), ''), 'reported missing')));

  update public.transfer_line_units
    set missing_at = now(), missing_by = v_actor,
        missing_reason = coalesce(nullif(trim(p_reason), ''), 'reported missing')
  where id = v_tlu.id;

  insert into public.audit_events (
    company_id, actor_type, actor_employee_id, entity_type,
    entity_id, event_type, after
  ) values (
    v_company, 'EMPLOYEE', v_actor, 'transfer_line_unit', v_tlu.id,
    'TRANSFER_UNIT_MISSING',
    jsonb_build_object('unit_id', p_unit_id, 'transfer_id', v_t.id,
      'reason', coalesce(nullif(trim(p_reason), ''), 'reported missing')));

  return jsonb_build_object(
    'unit_id', p_unit_id,
    'unit_number', (select unit_number from public.units where id = p_unit_id),
    'transfer_id', v_t.id,
    'status', 'MISSING');
end;
$$;

grant execute on function public.mark_transfer_unit_missing(uuid, text, uuid) to authenticated;
revoke execute on function public.mark_transfer_unit_missing(uuid, text, uuid)
  from public, anon;
