-- ============================================================================
-- Migration 163: open trial-action worklist
--
-- One batched read for every screen that lists in-progress returns and
-- exchanges (Batch B): the board's hide rule and Return-in-progress chip,
-- the My Work "Needs you" partition, and the inventory "Returns to
-- receive" list all read this one function instead of per-journey calls.
--
-- Sections:
--   1. list_open_trial_actions - one row per COMMITTED action
-- ============================================================================

-- ============================================================================
-- 1. list_open_trial_actions
--
-- One row per sleep_trial_actions row with status COMMITTED (RETURN and
-- EXCHANGE) on journeys visible to the caller. No role or store filter:
-- the client partitions rows by what the caller can act on. Read only.
--
-- started_by_* is the committer when stamped, else the row creator.
-- is_stalled reuses the list_open_exchange_work rule: committed_at older
-- than companies.exchange_stalled_days AND at least one milestone is
-- still open (receive, replacement delivered, child balance, or an owed
-- refund not yet recorded).
-- ============================================================================

drop function if exists public.list_open_trial_actions();

create function public.list_open_trial_actions()
returns table (
  action_id uuid,
  action text,
  journey_id uuid,
  journey_number text,
  journey_state text,
  customer_name text,
  trial_item_id uuid,
  product_name text,
  store_id uuid,
  store_name text,
  started_by_employee_id uuid,
  started_by_name text,
  committed_at timestamptz,
  days_committed integer,
  original_received_on date,
  replacement_delivered_on date,
  child_journey_id uuid,
  refund_owed_cents integer,
  refund_recorded_at timestamptz,
  is_stalled boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    a.id as action_id,
    a.action,
    a.journey_id,
    sj.journey_number,
    sj.current_state as journey_state,
    btrim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, ''))
      as customer_name,
    a.trial_item_id,
    ti.product_name_snapshot as product_name,
    sj.store_id,
    s.name as store_name,
    coalesce(a.committed_by, a.created_by) as started_by_employee_id,
    e.name as started_by_name,
    a.committed_at,
    floor(extract(epoch from (now() - a.committed_at)) / 86400)::int
      as days_committed,
    a.original_received_on,
    a.replacement_delivered_on,
    a.child_journey_id,
    a.refund_owed_cents,
    a.refund_recorded_at,
    (
      a.committed_at
        < now() - make_interval(days => co.exchange_stalled_days)
      and (
        a.original_received_on is null
        or (a.action = 'EXCHANGE'
              and a.replacement_delivered_on is null)
        or (a.action = 'EXCHANGE'
              and coalesce(cj.price, 0) > 0
              and public.total_paid(cj.id) < cj.price)
        or (coalesce(a.refund_owed_cents, 0) > 0
              and a.refund_recorded_at is null)
      )
    ) as is_stalled
  from public.sleep_trial_actions a
  join public.sleep_journeys sj on sj.id = a.journey_id
  join public.customers c on c.id = sj.customer_id
  join public.stores s on s.id = sj.store_id
  join public.companies co on co.id = s.company_id
  left join public.sleep_trial_items ti on ti.id = a.trial_item_id
  left join public.employees e
    on e.id = coalesce(a.committed_by, a.created_by)
  left join public.sleep_journeys cj on cj.id = a.child_journey_id
  where a.status = 'COMMITTED'
    and a.action in ('RETURN', 'EXCHANGE')
    and public.is_journey_visible(a.journey_id)
  order by a.committed_at;
$$;

revoke execute on function public.list_open_trial_actions()
  from public, anon;
grant execute on function public.list_open_trial_actions()
  to authenticated;
