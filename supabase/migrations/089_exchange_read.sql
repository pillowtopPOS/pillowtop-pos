-- ============================================================================
-- Migration 089 — Exchange Builder EB-3a: read RPCs
--
-- sleep_trial_actions is not client-selectable by design (087 grants). The
-- Exchange Builder UI needs two read paths, both security definer and
-- visibility-checked exactly like quote_sleep_trial_action
-- (is_journey_visible, which walks store -> company):
--
--   1. get_exchange_action(p_action_id)
--        One action row with the fields the builder panel renders,
--        including the replacement product name and the starter's name.
--
--   2. get_journey_exchange_actions(p_journey_id)
--        The open (DRAFT) or COMMITTED action for each trial item on the
--        journey — used to show "who started it", continue-or-discard, and
--        the original journey's "Exchange in progress" link — plus, when the
--        journey itself is an exchange child, the parent link (parent
--        journey, customer, original mattress, action, status).
--
-- Read-only: no writes, no new tables, no client-supplied company_id.
-- ============================================================================

create or replace function public.get_exchange_action(
  p_action_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_repl_name text;
  v_creator_name text;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id;
  if not found then
    raise exception 'Exchange action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select p.item_name into v_repl_name
  from public.products p
  where p.id = v_action.replacement_product_id;

  select e.name into v_creator_name
  from public.employees e
  where e.id = v_action.created_by;

  return jsonb_build_object(
    'action_id', v_action.id,
    'status', v_action.status,
    'action', v_action.action,
    'trial_item_id', v_action.trial_item_id,
    'journey_id', v_action.journey_id,
    'child_journey_id', v_action.child_journey_id,
    'replacement_product_id', v_action.replacement_product_id,
    'replacement_product_name', v_repl_name,
    'replacement_price_cents', v_action.replacement_price_cents,
    'original_credit_cents', v_action.original_credit_cents,
    'exchange_fee_cents', v_action.exchange_fee_cents,
    'other_fees_cents', v_action.other_fees_cents,
    'tax_cents', v_action.tax_cents,
    'net_cents', v_action.net_cents,
    'refund_owed_cents', v_action.refund_owed_cents,
    'fulfillment_method', v_action.fulfillment_method,
    'created_by', v_action.created_by,
    'created_by_name', v_creator_name,
    'created_at', v_action.created_at,
    'committed_at', v_action.committed_at);
end;
$$;

revoke execute on function public.get_exchange_action(uuid) from public, anon;
grant execute on function public.get_exchange_action(uuid) to authenticated;

-- ----------------------------------------------------------------------------

create or replace function public.get_journey_exchange_actions(
  p_journey_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_journey public.sleep_journeys%rowtype;
  v_actions jsonb;
  v_parent jsonb;
begin
  select * into v_journey
  from public.sleep_journeys
  where id = p_journey_id;
  if not found then
    raise exception 'Journey not found';
  end if;
  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  -- One entry per open (DRAFT) or COMMITTED action on this journey.
  -- CANCELLED/COMPLETED rows are history, not UI state.
  select coalesce(
    jsonb_agg(row_obj order by row_obj ->> 'created_at'),
    '[]'::jsonb)
  into v_actions
  from (
    select jsonb_build_object(
      'action_id', a.id,
      'status', a.status,
      'action', a.action,
      'trial_item_id', a.trial_item_id,
      'journey_id', a.journey_id,
      'child_journey_id', a.child_journey_id,
      'replacement_product_id', a.replacement_product_id,
      'replacement_product_name', p.item_name,
      'created_by', a.created_by,
      'created_by_name', e.name,
      'created_at', a.created_at,
      'committed_at', a.committed_at) as row_obj
    from public.sleep_trial_actions a
    left join public.products p on p.id = a.replacement_product_id
    left join public.employees e on e.id = a.created_by
    where a.journey_id = p_journey_id
      and a.status in ('DRAFT', 'COMMITTED')
  ) s;

  -- When this journey is itself an exchange child, describe the link back:
  -- the original journey, its customer, and the mattress being exchanged.
  v_parent := null;
  if v_journey.parent_journey_id is not null then
    select jsonb_build_object(
      'parent_journey_id', pj.id,
      'parent_customer_name',
        nullif(btrim(
          coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')),
          ''),
      'original_mattress_name', ti.product_name_snapshot,
      'action_id', pa.id,
      'action_status', pa.status)
    into v_parent
    from public.sleep_journeys pj
    left join public.customers c on c.id = pj.customer_id
    left join public.sleep_trial_actions pa
      on pa.id = v_journey.exchange_action_id
    left join public.sleep_trial_items ti on ti.id = pa.trial_item_id
    where pj.id = v_journey.parent_journey_id;
  end if;

  return jsonb_build_object(
    'actions', v_actions,
    'parent', v_parent);
end;
$$;

revoke execute on function public.get_journey_exchange_actions(uuid)
  from public, anon;
grant execute on function public.get_journey_exchange_actions(uuid)
  to authenticated;
