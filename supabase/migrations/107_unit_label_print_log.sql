-- ============================================================================
-- Unit ID S2: record label prints on the unit history
--
-- unit_events.event_type is plain text (no constraint), so 'label_printed'
-- needs no schema change. This function logs one event per unit after the
-- app prints its label, so the history shows a label was made.
-- ============================================================================

create or replace function public.record_unit_labels_printed(
  p_unit_ids uuid[],
  p_label_kind text
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_actor uuid;
  v_bad uuid;
  v_count integer;
  v_found integer;
begin
  if p_label_kind not in ('stock', 'customer') then
    raise exception 'Label kind must be stock or customer.';
  end if;
  if p_unit_ids is null or cardinality(p_unit_ids) = 0 then
    raise exception 'Give at least one unit to log.';
  end if;
  if cardinality(p_unit_ids) > 500 then
    raise exception 'Cannot log % units at once.', cardinality(p_unit_ids);
  end if;

  select e.id, s.company_id into v_actor, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_actor is null then
    raise exception 'Your employee record was not found or is inactive.';
  end if;

  select u.id into v_bad
  from public.units u
  where u.id = any(p_unit_ids) and u.company_id <> v_company_id
  limit 1;
  if v_bad is not null then
    raise exception 'One of those units is not in your company.';
  end if;

  select count(*) into v_found
  from public.units u
  where u.id = any(p_unit_ids) and u.company_id = v_company_id;
  if v_found <> (select count(distinct x) from unnest(p_unit_ids) x) then
    raise exception 'One of those units was not found.';
  end if;

  insert into public.unit_events (
    unit_id, company_id, event_type, actor_id,
    from_status, to_status, data
  )
  select u.id, v_company_id, 'label_printed', v_actor,
    u.status, u.status,
    jsonb_build_object('label_kind', p_label_kind, 'unit_number', u.unit_number)
  from public.units u
  where u.id = any(p_unit_ids) and u.company_id = v_company_id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

comment on function public.record_unit_labels_printed(uuid[], text) is
  'Logs one label_printed event per unit after the app prints stock or
   customer labels. Company is derived from the caller; units from other
   companies are refused. Does not change unit status.';

grant execute on function public.record_unit_labels_printed(uuid[], text) to authenticated;
revoke execute on function public.record_unit_labels_printed(uuid[], text) from public, anon;
