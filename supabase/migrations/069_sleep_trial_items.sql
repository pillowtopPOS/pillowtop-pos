-- 069_sleep_trial_items.sql
--
-- ST-3: Trial items + binding.
--
--   1. sleep_trial_items / sleep_trial_item_bindings tables (Section 26.3),
--      company-scoped, select-only RLS via is_journey_visible.
--   2. resolve_sleep_trial_terms(version, facts) — pure Section 6.2 resolver
--      reused by the evaluator and simulator later.
--   3. journey_line_items: pair_group_id, sold_condition, trial_ineligible_reason.
--   4. Binding triggers: first reach Sold (D2), line added after Sold,
--      line removed / quantity reduced, journey cancelled.
--   5. Trial start: one AFTER UPDATE OF delivered_at trigger covers both
--      delivery_completed and correct_trial_start (Section 23).
--   6. Backfill: RETIRED Version 0 per company + items per Section 7.6.
--   7. Ends with a summary SELECT.
--
-- The UI keeps reading the legacy journey-level trial columns until ST-4;
-- set_journey_delivered_at keeps stamping them alongside the new items.

-- ============================================================================
-- 1. Line-item additions (Section 26.3)
-- ============================================================================

alter table public.journey_line_items
  add column if not exists pair_group_id uuid,
  add column if not exists sold_condition text,
  add column if not exists trial_ineligible_reason text;

comment on column public.journey_line_items.sold_condition is
  'Condition of the unit actually sold (PRIME, FLOOR, CLEARANCE, ...). NULL today: '
  'the sale path does not link a line to a specific inventory position, so no '
  'CONDITION-scoped override can match yet.';
comment on column public.journey_line_items.trial_ineligible_reason is
  'Why this line produced no sleep_trial_item: NOT_CATALOG_ELIGIBLE, '
  'CONDITION_RULE, or TRIAL_DISABLED.';

-- Expose the eligibility flag through the masked product view so the product
-- edit modal can read it (same append-at-end pattern as category_id in 041).
create or replace view public.products_public as
select
  p.id,
  p.company_id,
  p.sku,
  p.item_name,
  p.brand,
  case
    when public.current_employee_role()::text in ('owner', 'admin', 'manager')
    then p.cost
    else null
  end as cost,
  p.price,
  p.sale_price,
  p.search_text,
  p.created_at,
  p.updated_at,
  p.category_id,
  p.sleep_trial_eligible
from public.products p
where public.is_product_visible_by_company(p.company_id);

alter view public.products_public owner to postgres;

-- search_products() returns setof products_public, so it is recreated after
-- the view gains a column (041 pattern).
drop function if exists public.search_products(text);

create or replace function public.search_products(p_query text)
returns setof public.products_public
language sql
stable
security invoker
set search_path = public
as $$
  select *
  from public.products_public p
  where word_similarity(p.search_text, lower(p_query)) > 0.05
  order by word_similarity(p.search_text, lower(p_query)) desc
  limit 20;
$$;

-- ============================================================================
-- 2. Trial item tables (Section 26.3)
-- ============================================================================

create table if not exists public.sleep_trial_items (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  line_item_id uuid references public.journey_line_items (id) on delete set null,
  unit_index integer not null default 1,
  customer_id uuid references public.customers (id) on delete set null,
  -- Product facts snapshot used at binding (Section 7.2)
  product_id uuid references public.products (id) on delete set null,
  product_name_snapshot text,
  brand_snapshot text,
  category_id_snapshot uuid,
  category_name_snapshot text,
  condition_snapshot text,
  size_snapshot text,
  comfort_snapshot text,
  pair_group_id uuid,
  -- Immutable binding (Section 7.2)
  policy_version_id uuid references public.policy_versions (id) on delete set null,
  resolved_terms jsonb,
  term_sources jsonb,
  terms_hash text,
  bound_at timestamptz,
  bound_reason text check (bound_reason in (
    'SALE','ITEM_ADDED','BACKFILL','REPLACEMENT','CORRECTION')),
  -- Lifecycle (Section 8.2)
  status text not null default 'PENDING_FULFILLMENT' check (status in (
    'PENDING_FULFILLMENT','ACTIVE','EXCHANGE_IN_PROGRESS',
    'RETURN_IN_PROGRESS','CLOSED','VOIDED')),
  close_reason text check (close_reason in (
    'EXCHANGED','RETURNED','COMPLETED','WARRANTY',
    'NO_REPLACEMENT_TRIAL','VOIDED')),
  closed_at timestamptz,
  started_on date,
  start_source text check (start_source in (
    'DELIVERY','PICKUP','BACKFILL','CORRECTION')),
  fee_basis_cents integer,
  fee_basis_source text,
  -- Replacement chain (Section 8.2)
  lineage_root_id uuid references public.sleep_trial_items (id) on delete set null,
  predecessor_item_id uuid references public.sleep_trial_items (id) on delete set null,
  exchange_sequence integer not null default 0,
  replacement_remaining_nights integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.sleep_trial_items is
  'One sleep trial per trial-eligible mattress unit (D3). Binding fields are '
  'immutable after insert; corrections write a new binding row.';

create index if not exists idx_sleep_trial_items_journey
  on public.sleep_trial_items (journey_id);
create index if not exists idx_sleep_trial_items_company_status
  on public.sleep_trial_items (company_id, status);
create index if not exists idx_sleep_trial_items_lineage
  on public.sleep_trial_items (lineage_root_id);
create index if not exists idx_sleep_trial_items_line
  on public.sleep_trial_items (line_item_id);

-- One live item per (line, unit). CLOSED/VOIDED rows leave the slot free.
create unique index if not exists sleep_trial_items_one_live_unit
  on public.sleep_trial_items (line_item_id, unit_index)
  where line_item_id is not null and status not in ('CLOSED','VOIDED');

-- Binding history for corrections (Sections 7.4, 26.3)
create table if not exists public.sleep_trial_item_bindings (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.sleep_trial_items (id) on delete cascade,
  company_id uuid not null references public.companies (id) on delete cascade,
  policy_version_id uuid references public.policy_versions (id) on delete set null,
  resolved_terms jsonb,
  term_sources jsonb,
  terms_hash text,
  reason text,
  actor_employee_id uuid references public.employees (id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_sleep_trial_item_bindings_item
  on public.sleep_trial_item_bindings (item_id);

alter table public.sleep_trial_items enable row level security;
alter table public.sleep_trial_item_bindings enable row level security;

drop policy if exists "Sleep trial items viewable by authenticated users" on public.sleep_trial_items;
create policy "Sleep trial items viewable by authenticated users"
  on public.sleep_trial_items for select
  to authenticated
  using (public.is_journey_visible(journey_id));

drop policy if exists "Sleep trial item bindings viewable by authenticated users" on public.sleep_trial_item_bindings;
create policy "Sleep trial item bindings viewable by authenticated users"
  on public.sleep_trial_item_bindings for select
  to authenticated
  using (
    exists (
      select 1 from public.sleep_trial_items i
      where i.id = item_id and public.is_journey_visible(i.journey_id)));

-- No INSERT/UPDATE/DELETE policies: items and bindings are written only by
-- security-definer functions below (062/065 pattern — no direct client writes).

-- Item-level FKs for concern/correction rows (columns only; wiring later)
alter table public.sleep_concerns
  add column if not exists trial_item_id uuid references public.sleep_trial_items (id) on delete set null;
alter table public.sleep_trial_start_corrections
  add column if not exists trial_item_id uuid references public.sleep_trial_items (id) on delete set null;

create index if not exists idx_sleep_concerns_trial_item on public.sleep_concerns (trial_item_id);
create index if not exists idx_trial_start_corrections_trial_item on public.sleep_trial_start_corrections (trial_item_id);

-- ============================================================================
-- 3. Helpers
-- ============================================================================

-- sha256 for terms_hash. pgcrypto's digest may live in `extensions` or
-- `public` depending on when the project was created; detect it here so the
-- security-definer callers (search_path = public) always resolve it.
do $$
declare
  v_ns name;
begin
  select n.nspname into v_ns
  from pg_extension e
  join pg_namespace n on n.oid = e.extnamespace
  where e.extname = 'pgcrypto';
  v_ns := coalesce(v_ns, 'pg_catalog');
  execute format(
    'create or replace function public.stv_sha256(p_text text) returns text
       language sql immutable set search_path = public
       as $f$ select encode(%I.digest($1, ''sha256''), ''hex'') $f$',
    v_ns);
end;
$$;

revoke execute on function public.stv_sha256(text) from public, anon, authenticated;

-- term_sources initialized to COMPANY for every leaf field (Section 6.2).
create or replace function public.stv_company_term_sources(p_terms jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_sources jsonb := '{}'::jsonb;
  v_section text;
  v_field text;
begin
  if p_terms is null or jsonb_typeof(p_terms) <> 'object' then
    return v_sources;
  end if;
  for v_section in select key from jsonb_object_keys(p_terms) as k(key) loop
    if jsonb_typeof(p_terms -> v_section) = 'object' then
      for v_field in select key from jsonb_object_keys(p_terms -> v_section) as k2(key) loop
        v_sources := v_sources || jsonb_build_object(v_section || '.' || v_field, 'COMPANY');
      end loop;
    else
      v_sources := v_sources || jsonb_build_object(v_section, 'COMPANY');
    end if;
  end loop;
  return v_sources;
end;
$$;

revoke execute on function public.stv_company_term_sources(jsonb) from public, anon, authenticated;

-- ============================================================================
-- 4. resolve_sleep_trial_terms (Section 6.2)
--    Pure: reads only the policy_versions row passed in. Returns
--    { resolved_terms, term_sources }.
--    Facts jsonb: { product_id, category_id, brand, condition }.
-- ============================================================================

create or replace function public.resolve_sleep_trial_terms(
  p_policy_version_id uuid,
  p_facts jsonb
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_def jsonb;
  v_terms jsonb;
  v_sources jsonb;
  v_override jsonb;
  v_scope_type text;
  v_scope_value text;
  v_field text;
  v_fpath text[];
  v_category text := nullif(btrim(coalesce(p_facts ->> 'category_id', '')), '');
  v_brand text := lower(btrim(coalesce(p_facts ->> 'brand', '')));
  v_product text := nullif(btrim(coalesce(p_facts ->> 'product_id', '')), '');
  v_condition text := upper(btrim(coalesce(p_facts ->> 'condition', '')));
  v_match boolean;
begin
  select definition into v_def
  from public.policy_versions
  where id = p_policy_version_id;
  if v_def is null then
    raise exception 'resolve_sleep_trial_terms: policy version % not found', p_policy_version_id;
  end if;

  v_terms := coalesce(v_def -> 'base', '{}'::jsonb);
  v_sources := public.stv_company_term_sources(v_terms);

  -- Apply matching overrides least-specific first so the most specific
  -- (CONDITION) wins per field (CATEGORY < BRAND < PRODUCT < CONDITION).
  -- v_override is the jsonb element itself — a scalar FOR target receives the
  -- single selected column, so field access goes through -> / ->>.
  for v_override in
    select o.value
    from (
      select t.value,
        case t.value -> 'scope' ->> 'type'
          when 'CATEGORY' then 1
          when 'BRAND' then 2
          when 'PRODUCT' then 3
          when 'CONDITION' then 4
          else 9
        end as rank
      from jsonb_array_elements(coalesce(v_def -> 'overrides', '[]'::jsonb)) as t(value)
      where jsonb_typeof(t.value) = 'object'
    ) o
    order by o.rank asc
  loop
    v_scope_type := v_override -> 'scope' ->> 'type';
    v_scope_value := v_override -> 'scope' ->> 'value';
    v_match := case v_scope_type
      when 'CATEGORY' then v_category is not null and v_category = v_scope_value
      when 'BRAND' then v_brand <> '' and v_scope_value is not null
                    and v_brand = lower(btrim(v_scope_value))
      when 'PRODUCT' then v_product is not null and v_product = v_scope_value
      when 'CONDITION' then v_condition <> '' and v_scope_value is not null
                      and v_condition = upper(btrim(v_scope_value))
      else false
    end;
    if not v_match then
      continue;
    end if;

    for v_field in
      select key from jsonb_object_keys(coalesce(v_override -> 'set', '{}'::jsonb)) as s(key)
    loop
      v_fpath := string_to_array(v_field, '.');
      v_terms := jsonb_set(v_terms, v_fpath, v_override -> 'set' -> v_field, true);
      v_sources := v_sources || jsonb_build_object(v_field, jsonb_build_object(
        'override_id', v_override ->> 'id',
        'scope', v_scope_type,
        'label', coalesce(v_override ->> 'label', v_scope_type || ': ' || v_scope_value)));
    end loop;
  end loop;

  return jsonb_build_object(
    'resolved_terms', v_terms,
    'term_sources', v_sources);
end;
$$;

revoke execute on function public.resolve_sleep_trial_terms(uuid, jsonb)
  from public, anon, authenticated;

-- ============================================================================
-- 5. Binding + void helpers (security definer; called only from triggers)
-- ============================================================================

-- Bind trial items for a journey's eligible line items. Idempotent per unit:
-- units already covered by a live item are skipped. Returns items created.
create or replace function public.stv_bind_trial_items(
  p_journey_id uuid,
  p_reason text,
  p_line_item_id uuid default null,    -- null = all lines on the journey
  p_policy_version_id uuid default null -- null = company's current PUBLISHED version
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_journey public.sleep_journeys%rowtype;
  v_company_id uuid;
  v_version_id uuid;
  v_actor uuid;
  v_line record;
  v_eligible boolean;
  v_facts jsonb;
  v_resolved jsonb;
  v_terms jsonb;
  v_sources jsonb;
  v_enabled boolean;
  v_src jsonb;
  v_i int;
  v_item_id uuid;
  v_hash text;
  v_count int := 0;
begin
  select * into v_journey from public.sleep_journeys where id = p_journey_id;
  if not found or v_journey.cancelled_at is not null then
    return 0;
  end if;

  -- sleep_journeys has no company_id; the journey's store carries it.
  select s.company_id into v_company_id
  from public.stores s
  where s.id = v_journey.store_id;
  if v_company_id is null then
    return 0;
  end if;

  if p_policy_version_id is not null then
    v_version_id := p_policy_version_id;
  else
    select p.current_version_id into v_version_id
    from public.policies p
    where p.company_id = v_company_id
      and p.policy_type = 'SLEEP_TRIAL';
  end if;
  if v_version_id is null then
    return 0; -- no published policy yet → nothing to bind
  end if;

  select e.id into v_actor
  from public.employees e
  where e.auth_user_id = auth.uid();

  for v_line in
    select jli.*,
           p.item_name as product_name,
           p.brand,
           p.category_id,
           p.sleep_trial_eligible as prod_eligible,
           pc.name as category_name,
           pc.sleep_trial_eligible as cat_eligible
    from public.journey_line_items jli
    left join public.products p on p.id = jli.product_id
    left join public.product_categories pc on pc.id = p.category_id
    where jli.journey_id = p_journey_id
      and (p_line_item_id is null or jli.id = p_line_item_id)
  loop
    -- L4: product override wins, else the category flag.
    v_eligible := coalesce(v_line.prod_eligible, v_line.cat_eligible, false);

    if not v_eligible then
      update public.journey_line_items
      set trial_ineligible_reason = 'NOT_CATALOG_ELIGIBLE', updated_at = now()
      where id = v_line.id
        and trial_ineligible_reason is distinct from 'NOT_CATALOG_ELIGIBLE';
      continue;
    end if;

    v_facts := jsonb_build_object(
      'product_id', v_line.product_id,
      'category_id', v_line.category_id,
      'brand', v_line.brand,
      'condition', v_line.sold_condition);
    v_resolved := public.resolve_sleep_trial_terms(v_version_id, v_facts);
    v_terms := v_resolved -> 'resolved_terms';
    v_sources := v_resolved -> 'term_sources';
    v_hash := public.stv_sha256(v_terms::text);

    v_enabled := coalesce((v_terms #>> '{trial,enabled}')::boolean, true);

    if not v_enabled then
      -- Catalog-eligible but a rule disables the trial (Section 9.1 step 4).
      v_src := v_sources -> 'trial.enabled';
      update public.journey_line_items
      set trial_ineligible_reason = case
            when jsonb_typeof(v_src) = 'object' and v_src ->> 'scope' = 'CONDITION'
              then 'CONDITION_RULE'
            else 'TRIAL_DISABLED' end,
          updated_at = now()
      where id = v_line.id;
      continue;
    end if;

    update public.journey_line_items
    set trial_ineligible_reason = null, updated_at = now()
    where id = v_line.id and trial_ineligible_reason is not null;

    for v_i in 1 .. greatest(coalesce(v_line.quantity, 0), 0) loop
      if exists (
        select 1 from public.sleep_trial_items st
        where st.line_item_id = v_line.id
          and st.unit_index = v_i
          and st.status not in ('CLOSED','VOIDED')) then
        continue;
      end if;

      insert into public.sleep_trial_items (
        company_id, journey_id, line_item_id, unit_index, customer_id,
        product_id, product_name_snapshot, brand_snapshot,
        category_id_snapshot, category_name_snapshot, condition_snapshot,
        pair_group_id,
        policy_version_id, resolved_terms, term_sources, terms_hash,
        bound_at, bound_reason, status, lineage_root_id
      ) values (
        v_company_id, v_journey.id, v_line.id, v_i, v_journey.customer_id,
        v_line.product_id, coalesce(v_line.product_name, v_line.item_name), v_line.brand,
        v_line.category_id, v_line.category_name, v_line.sold_condition,
        v_line.pair_group_id,
        v_version_id, v_terms, v_sources, v_hash,
        now(), p_reason, 'PENDING_FULFILLMENT', null
      ) returning id into v_item_id;

      update public.sleep_trial_items
      set lineage_root_id = v_item_id
      where id = v_item_id;

      insert into public.sleep_trial_item_bindings (
        item_id, company_id, policy_version_id, resolved_terms,
        term_sources, terms_hash, reason, actor_employee_id
      ) values (
        v_item_id, v_company_id, v_version_id, v_terms,
        v_sources, v_hash, p_reason, v_actor
      );

      perform public.log_audit_event(
        v_company_id,
        'sleep_trial_item', v_item_id, 'SLEEP_TRIAL_ITEM_BOUND',
        null,
        jsonb_build_object(
          'policy_version_id', v_version_id,
          'bound_reason', p_reason,
          'line_item_id', v_line.id,
          'unit_index', v_i),
        null, null, v_journey.id, 'EMPLOYEE', v_actor);

      v_count := v_count + 1;
    end loop;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.stv_bind_trial_items(uuid, text, uuid, uuid)
  from public, anon, authenticated;

-- Void items. p_min_unit filters unit_index >= N (quantity-reduced case);
-- p_line_item_id limits to one line; null = whole journey. p_pending_only
-- limits to not-yet-delivered items (line edits only void unfulfilled units;
-- a journey cancel voids everything non-closed).
create or replace function public.stv_void_trial_items(
  p_journey_id uuid,
  p_line_item_id uuid default null,
  p_min_unit integer default null,
  p_pending_only boolean default false
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item record;
  v_actor uuid;
  v_count int := 0;
begin
  select e.id into v_actor
  from public.employees e
  where e.auth_user_id = auth.uid();

  for v_item in
    select * from public.sleep_trial_items
    where journey_id = p_journey_id
      and status not in ('CLOSED','VOIDED')
      and (not p_pending_only or status = 'PENDING_FULFILLMENT')
      and (p_line_item_id is null or line_item_id = p_line_item_id)
      and (p_min_unit is null or unit_index >= p_min_unit)
  loop
    update public.sleep_trial_items
    set status = 'VOIDED',
        close_reason = 'VOIDED',
        closed_at = now(),
        updated_at = now()
    where id = v_item.id;

    perform public.log_audit_event(
      v_item.company_id,
      'sleep_trial_item', v_item.id, 'SLEEP_TRIAL_ITEM_VOIDED',
      jsonb_build_object(
        'status', v_item.status,
        'line_item_id', v_item.line_item_id,
        'unit_index', v_item.unit_index),
      jsonb_build_object('status', 'VOIDED'),
      null, null, v_item.journey_id, 'EMPLOYEE', v_actor);

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.stv_void_trial_items(uuid, uuid, integer, boolean)
  from public, anon, authenticated;

-- Failure audit used by the trigger exception guards below. Its own handler
-- swallows errors so auditing can never block the operation either.
create or replace function public.stv_audit_trial_failure(
  p_company_id uuid,
  p_journey_id uuid,
  p_event_type text,
  p_error text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.log_audit_event(
    p_company_id,
    'sleep_journey', p_journey_id, p_event_type,
    null,
    jsonb_build_object('error', p_error),
    null, p_error, p_journey_id, 'SYSTEM', null);
exception when others then
  null;
end;
$$;

revoke execute on function public.stv_audit_trial_failure(uuid, uuid, text, text)
  from public, anon, authenticated;

-- ============================================================================
-- 6. Triggers
-- ============================================================================

-- (a) Journey first reaches Sold → bind every eligible line (D2).
--     derive_journey_state writes current_state; this catches every path that
--     establishes a written sale (payment complete, fulfillment event, RPCs).
create or replace function public.stv_on_journey_sold()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- First entry into the at-or-past-Sold set. Normally this is the Sold
  -- transition itself (D2), but event_to_state can move a journey directly
  -- to a later state (e.g. inventory_required → Waiting for Inventory);
  -- binding on set entry covers that path too.
  if new.current_state in (
       'Sold','Waiting for Inventory','Ready to Schedule',
       'Scheduled','Sleep Trial','Completed')
     and (old.current_state is null
          or old.current_state not in (
            'Sold','Waiting for Inventory','Ready to Schedule',
            'Scheduled','Sleep Trial','Completed'))
     and new.cancelled_at is null then
    -- A trial problem must never block a sale.
    begin
      perform public.stv_bind_trial_items(new.id, 'SALE');
    exception when others then
      perform public.stv_audit_trial_failure(
        (select s.company_id from public.stores s where s.id = new.store_id),
        new.id, 'SLEEP_TRIAL_BIND_FAILED', sqlerrm);
    end;
  end if;
  return new;
end;
$$;

revoke execute on function public.stv_on_journey_sold() from public, anon, authenticated;

drop trigger if exists trg_stv_journey_sold on public.sleep_journeys;
create trigger trg_stv_journey_sold
  after update of current_state on public.sleep_journeys
  for each row execute function public.stv_on_journey_sold();

-- (b) Line added to a journey already at/past Sold → bind just that line.
create or replace function public.stv_on_line_item_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1 from public.sleep_journeys sj
    where sj.id = new.journey_id
      and sj.cancelled_at is null
      and sj.current_state in (
        'Sold','Waiting for Inventory','Ready to Schedule',
        'Scheduled','Sleep Trial','Completed')) then
    begin
      perform public.stv_bind_trial_items(new.journey_id, 'ITEM_ADDED', new.id);
    exception when others then
      perform public.stv_audit_trial_failure(
        (select st.company_id
         from public.sleep_journeys sj
         join public.stores st on st.id = sj.store_id
         where sj.id = new.journey_id),
        new.journey_id, 'SLEEP_TRIAL_BIND_FAILED', sqlerrm);
    end;
  end if;
  return new;
end;
$$;

revoke execute on function public.stv_on_line_item_insert() from public, anon, authenticated;

drop trigger if exists trg_stv_line_item_insert on public.journey_line_items;
create trigger trg_stv_line_item_insert
  after insert on public.journey_line_items
  for each row execute function public.stv_on_line_item_insert();

-- (c) Quantity changed: reduced → extra units voided; increased on an
--     at/past-Sold journey → new units bound as ITEM_ADDED.
create or replace function public.stv_on_line_item_qty()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    if new.quantity < old.quantity then
      perform public.stv_void_trial_items(new.journey_id, new.id, new.quantity + 1, true);
    elsif new.quantity > old.quantity
          and exists (
            select 1 from public.sleep_journeys sj
            where sj.id = new.journey_id
              and sj.cancelled_at is null
              and sj.current_state in (
                'Sold','Waiting for Inventory','Ready to Schedule',
                'Scheduled','Sleep Trial','Completed')) then
      perform public.stv_bind_trial_items(new.journey_id, 'ITEM_ADDED', new.id);
    end if;
  exception when others then
    perform public.stv_audit_trial_failure(
      (select st.company_id
       from public.sleep_journeys sj
       join public.stores st on st.id = sj.store_id
       where sj.id = new.journey_id),
      new.journey_id, 'SLEEP_TRIAL_BIND_FAILED', sqlerrm);
  end;
  return new;
end;
$$;

revoke execute on function public.stv_on_line_item_qty() from public, anon, authenticated;

drop trigger if exists trg_stv_line_item_qty on public.journey_line_items;
create trigger trg_stv_line_item_qty
  after update of quantity on public.journey_line_items
  for each row execute function public.stv_on_line_item_qty();

-- (d) Line removed → its unfulfilled items are voided (removals happen
--     before fulfillment). BEFORE delete so the row is still findable via
--     line_item_id (the FK set-null action runs after).
create or replace function public.stv_on_line_item_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public.stv_void_trial_items(old.journey_id, old.id, null, true);
  exception when others then
    perform public.stv_audit_trial_failure(
      (select st.company_id
       from public.sleep_journeys sj
       join public.stores st on st.id = sj.store_id
       where sj.id = old.journey_id),
      old.journey_id, 'SLEEP_TRIAL_BIND_FAILED', sqlerrm);
  end;
  return old;
end;
$$;

revoke execute on function public.stv_on_line_item_delete() from public, anon, authenticated;

drop trigger if exists trg_stv_line_item_delete on public.journey_line_items;
create trigger trg_stv_line_item_delete
  before delete on public.journey_line_items
  for each row execute function public.stv_on_line_item_delete();

-- (e) Journey cancelled → every non-closed item voided.
create or replace function public.stv_on_journey_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.cancelled_at is not null and old.cancelled_at is null then
    begin
      perform public.stv_void_trial_items(new.id);
    exception when others then
      perform public.stv_audit_trial_failure(
        (select s.company_id from public.stores s where s.id = new.store_id),
        new.id, 'SLEEP_TRIAL_BIND_FAILED', sqlerrm);
    end;
  end if;
  return new;
end;
$$;

revoke execute on function public.stv_on_journey_cancel() from public, anon, authenticated;

drop trigger if exists trg_stv_journey_cancel on public.sleep_journeys;
create trigger trg_stv_journey_cancel
  after update of cancelled_at on public.sleep_journeys
  for each row execute function public.stv_on_journey_cancel();

-- (f) delivered_at set or corrected → start / correct trial items (Section
--     11.1, 23). One mechanism covers delivery_completed and
--     correct_trial_start because both write sleep_journeys.delivered_at.
create or replace function public.stv_on_journey_delivered()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item record;
  v_actor uuid;
  v_count_starts text;
  v_new_start date;
  v_fee_cents int;
  v_start_source text;
begin
  if new.delivered_at is null
     or new.delivered_at is not distinct from old.delivered_at then
    return new;
  end if;

  -- A trial problem must never block a delivery record.
  begin
  select e.id into v_actor
  from public.employees e
  where e.auth_user_id = auth.uid();

  for v_item in
    select sti.*, jli.unit_price, jli.fulfillment_type_override
    from public.sleep_trial_items sti
    left join public.journey_line_items jli on jli.id = sti.line_item_id
    where sti.journey_id = new.id
      and sti.status in ('PENDING_FULFILLMENT','ACTIVE')
  loop
    v_count_starts := v_item.resolved_terms #>> '{trial,count_starts}';
    v_new_start := case
      when v_count_starts = 'FULFILLMENT_DATE' then new.delivered_at
      else new.delivered_at + 1 end;

    if v_item.status = 'PENDING_FULFILLMENT' then
      -- Section 13.2: until the pricing engine exists, the fee basis is the
      -- line's unit_price.
      v_fee_cents := case when v_item.unit_price is not null
                          then round(v_item.unit_price * 100)::int end;
      v_start_source := case
        when coalesce(v_item.fulfillment_type_override, new.fulfillment_type) = 'pickup'
          then 'PICKUP' else 'DELIVERY' end;

      update public.sleep_trial_items
      set status = 'ACTIVE',
          started_on = v_new_start,
          start_source = v_start_source,
          fee_basis_cents = coalesce(fee_basis_cents, v_fee_cents),
          fee_basis_source = coalesce(fee_basis_source,
            case when v_fee_cents is not null then 'UNIT_PRICE' end),
          updated_at = now()
      where id = v_item.id;

      perform public.log_audit_event(
        v_item.company_id,
        'sleep_trial_item', v_item.id, 'SLEEP_TRIAL_STARTED',
        jsonb_build_object('status', 'PENDING_FULFILLMENT'),
        jsonb_build_object('status', 'ACTIVE', 'started_on', v_new_start,
                           'start_source', v_start_source,
                           'fee_basis_cents', v_fee_cents),
        null, null, v_item.journey_id, 'EMPLOYEE', v_actor);

    elsif v_item.status = 'ACTIVE'
          and v_item.started_on is distinct from v_new_start then
      update public.sleep_trial_items
      set started_on = v_new_start,
          start_source = 'CORRECTION',
          updated_at = now()
      where id = v_item.id;

      perform public.log_audit_event(
        v_item.company_id,
        'sleep_trial_item', v_item.id, 'SLEEP_TRIAL_START_CORRECTED',
        jsonb_build_object('started_on', v_item.started_on),
        jsonb_build_object('started_on', v_new_start),
        null, null, v_item.journey_id, 'EMPLOYEE', v_actor);
    end if;
  end loop;

  exception when others then
    perform public.stv_audit_trial_failure(
      (select s.company_id from public.stores s where s.id = new.store_id),
      new.id, 'SLEEP_TRIAL_START_FAILED', sqlerrm);
  end;

  return new;
end;
$$;

revoke execute on function public.stv_on_journey_delivered() from public, anon, authenticated;

drop trigger if exists trg_stv_journey_delivered on public.sleep_journeys;
create trigger trg_stv_journey_delivered
  after update of delivered_at on public.sleep_journeys
  for each row execute function public.stv_on_journey_delivered();

-- ============================================================================
-- 6b. Manual rebind command
-- ============================================================================

-- Binds eligible line units that have no live trial item, bound_reason
-- CORRECTION (Section 7.2). Covers journeys sold before catalog eligibility
-- was configured and any journey whose binding raised SLEEP_TRIAL_BIND_FAILED.
-- One journey, or every at/past-Sold journey in the caller's company when
-- p_journey_id is null. Returns items created; per-item binding audits are
-- written by stv_bind_trial_items.
create or replace function public.rebind_unbound_sleep_trials(
  p_journey_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid;
  v_j record;
  v_created int;
  v_count int := 0;
begin
  if not public.has_permission('sleep_trial.manage_policy') then
    raise exception 'rebind_unbound_sleep_trials: sleep_trial.manage_policy permission required';
  end if;

  select s.company_id into v_company
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid();

  for v_j in
    select sj.id
    from public.sleep_journeys sj
    join public.stores st on st.id = sj.store_id
    where sj.cancelled_at is null
      and sj.current_state in (
        'Sold','Waiting for Inventory','Ready to Schedule',
        'Scheduled','Sleep Trial','Completed')
      and (p_journey_id is null or sj.id = p_journey_id)
      and (v_company is null or st.company_id = v_company)
  loop
    v_created := public.stv_bind_trial_items(v_j.id, 'CORRECTION');
    v_count := v_count + coalesce(v_created, 0);
  end loop;

  return v_count;
end;
$$;

grant execute on function public.rebind_unbound_sleep_trials(uuid) to authenticated;

-- ============================================================================
-- 7. Backfill (Section 7.6)
-- ============================================================================

-- 7a. RETIRED Version 0 "Legacy" per company with a Sleep Trial policy.
--     count_starts = FULFILLMENT_DATE (legacy trials count from the delivery
--     date); every other value comes from Version 1.
insert into public.policy_versions (
  policy_id, company_id, version_number, status, definition,
  definition_schema_version, summary_text,
  effective_from, effective_until, published_at
)
select
  p.id,
  p.company_id,
  0,
  'RETIRED',
  jsonb_set(v1.definition, '{base,trial,count_starts}', '"FULFILLMENT_DATE"'::jsonb),
  v1.definition_schema_version,
  'Version 0 (Legacy): terms reconstructed from per-journey trial snapshots recorded before the policy engine.',
  '2000-01-01'::timestamptz,
  v1.effective_from,
  '2000-01-01'::timestamptz
from public.policies p
join public.policy_versions v1 on v1.id = p.current_version_id
where p.policy_type = 'SLEEP_TRIAL'
  and not exists (
    select 1 from public.policy_versions v0
    where v0.policy_id = p.id and v0.version_number = 0);

-- 7b. Trial items for every catalog-eligible line on non-cancelled journeys
--     at/past Sold, bound to Version 0 with resolved_terms taken from the
--     journey's own snapshot columns.
with eligible_lines as (
  select
    sj.id as journey_id,
    st.company_id,
    sj.customer_id,
    sj.current_state,
    sj.delivered_at,
    sj.updated_at as journey_updated_at,
    sj.trial_length_nights,
    sj.minimum_adjustment_nights,
    jli.id as line_item_id,
    jli.item_name as line_item_name,
    jli.product_id,
    jli.quantity,
    jli.unit_price,
    jli.pair_group_id,
    jli.sold_condition,
    p.item_name as product_name,
    p.brand,
    p.category_id,
    pc.name as category_name,
    v0.id as version0_id,
    v0.definition -> 'base' as base_terms
  from public.sleep_journeys sj
  join public.stores st on st.id = sj.store_id
  join public.journey_line_items jli on jli.journey_id = sj.id
  left join public.products p on p.id = jli.product_id
  left join public.product_categories pc on pc.id = p.category_id
  join public.policies pol
    on pol.company_id = st.company_id and pol.policy_type = 'SLEEP_TRIAL'
  join public.policy_versions v0
    on v0.policy_id = pol.id and v0.version_number = 0
  where sj.cancelled_at is null
    and sj.current_state in (
      'Sold','Waiting for Inventory','Ready to Schedule',
      'Scheduled','Sleep Trial','Completed')
    and coalesce(p.sleep_trial_eligible, pc.sleep_trial_eligible, false)
), resolved as (
  select
    el.*,
    -- Journey snapshot values win over the V0 base when present.
    jsonb_set(
      jsonb_set(el.base_terms,
        '{trial,length_nights}',
        coalesce(to_jsonb(el.trial_length_nights),
                 el.base_terms #> '{trial,length_nights}'), true),
      '{trial,minimum_nights}',
        coalesce(to_jsonb(el.minimum_adjustment_nights),
                 el.base_terms #> '{trial,minimum_nights}'), true) as resolved_terms
  from eligible_lines el
)
insert into public.sleep_trial_items (
  company_id, journey_id, line_item_id, unit_index, customer_id,
  product_id, product_name_snapshot, brand_snapshot,
  category_id_snapshot, category_name_snapshot, condition_snapshot,
  pair_group_id,
  policy_version_id, resolved_terms, term_sources, terms_hash,
  bound_at, bound_reason, status, close_reason, closed_at,
  started_on, start_source, fee_basis_cents, fee_basis_source,
  exchange_sequence
)
select
  r.company_id,
  r.journey_id,
  r.line_item_id,
  u.unit_index,
  r.customer_id,
  r.product_id,
  coalesce(r.product_name, r.line_item_name),
  r.brand,
  r.category_id,
  r.category_name,
  r.sold_condition,
  r.pair_group_id,
  r.version0_id,
  r.resolved_terms,
  public.stv_company_term_sources(r.resolved_terms),
  public.stv_sha256(r.resolved_terms::text),
  now(),
  'BACKFILL',
  case
    when r.current_state = 'Completed' then 'CLOSED'
    when r.delivered_at is not null then 'ACTIVE'
    else 'PENDING_FULFILLMENT' end,
  case when r.current_state = 'Completed' then 'COMPLETED' end,
  case when r.current_state = 'Completed' then r.journey_updated_at end,
  r.delivered_at,  -- legacy trials count from the delivery date itself
  case when r.delivered_at is not null then 'BACKFILL' end,
  case when r.delivered_at is not null
        then round(r.unit_price * 100)::int end,
  case when r.delivered_at is not null then 'BACKFILL' end,
  0
from resolved r
cross join lateral generate_series(1, greatest(r.quantity, 0)) as u(unit_index)
where not exists (
  select 1 from public.sleep_trial_items st
  where st.line_item_id = r.line_item_id and st.unit_index = u.unit_index);

-- 7c. Journeys with NO eligible line items but delivered or in Sleep Trial
--     (older data + TEST journeys have no line items): one legacy item,
--     product facts from the journey-level product fields.
with legacy_journeys as (
  select
    sj.id as journey_id,
    st.company_id,
    sj.customer_id,
    sj.current_state,
    sj.delivered_at,
    sj.updated_at as journey_updated_at,
    sj.trial_length_nights,
    sj.minimum_adjustment_nights,
    sj.product_id,
    sj.product_summary,
    p.item_name as product_name,
    p.brand,
    p.category_id,
    pc.name as category_name,
    v0.id as version0_id,
    v0.definition -> 'base' as base_terms
  from public.sleep_journeys sj
  join public.stores st on st.id = sj.store_id
  left join public.products p on p.id = sj.product_id
  left join public.product_categories pc on pc.id = p.category_id
  join public.policies pol
    on pol.company_id = st.company_id and pol.policy_type = 'SLEEP_TRIAL'
  join public.policy_versions v0
    on v0.policy_id = pol.id and v0.version_number = 0
  where sj.cancelled_at is null
    and sj.current_state in (
      'Sold','Waiting for Inventory','Ready to Schedule',
      'Scheduled','Sleep Trial','Completed')
    and (sj.delivered_at is not null or sj.current_state = 'Sleep Trial')
    and not exists (
      select 1
      from public.journey_line_items jli
      left join public.products p2 on p2.id = jli.product_id
      left join public.product_categories pc2 on pc2.id = p2.category_id
      where jli.journey_id = sj.id
        and coalesce(p2.sleep_trial_eligible, pc2.sleep_trial_eligible, false))
    and not exists (
      select 1 from public.sleep_trial_items i
      where i.journey_id = sj.id)
)
insert into public.sleep_trial_items (
  company_id, journey_id, line_item_id, unit_index, customer_id,
  product_id, product_name_snapshot, brand_snapshot,
  category_id_snapshot, category_name_snapshot, condition_snapshot,
  policy_version_id, resolved_terms, term_sources, terms_hash,
  bound_at, bound_reason, status, close_reason, closed_at,
  started_on, start_source, exchange_sequence
)
select
  lj.company_id,
  lj.journey_id,
  null,
  1,
  lj.customer_id,
  lj.product_id,
  coalesce(lj.product_name, lj.product_summary),
  lj.brand,
  lj.category_id,
  lj.category_name,
  null,
  lj.version0_id,
  jsonb_set(
    jsonb_set(lj.base_terms,
      '{trial,length_nights}',
      coalesce(to_jsonb(lj.trial_length_nights),
               lj.base_terms #> '{trial,length_nights}'), true),
    '{trial,minimum_nights}',
      coalesce(to_jsonb(lj.minimum_adjustment_nights),
               lj.base_terms #> '{trial,minimum_nights}'), true),
  '{}'::jsonb,
  null,
  now(),
  'BACKFILL',
  case
    when lj.current_state = 'Completed' then 'CLOSED'
    when lj.delivered_at is not null then 'ACTIVE'
    else 'PENDING_FULFILLMENT' end,
  case when lj.current_state = 'Completed' then 'COMPLETED' end,
  case when lj.current_state = 'Completed' then lj.journey_updated_at end,
  lj.delivered_at,
  case when lj.delivered_at is not null then 'BACKFILL' end,
  0
from legacy_journeys lj;

-- Fill the pieces the two big INSERTs left unset.
update public.sleep_trial_items
set lineage_root_id = id
where bound_reason = 'BACKFILL' and lineage_root_id is null;

update public.sleep_trial_items
set term_sources = public.stv_company_term_sources(resolved_terms),
    terms_hash = public.stv_sha256(resolved_terms::text)
where bound_reason = 'BACKFILL' and terms_hash is null;

-- Binding-history rows for everything created above.
insert into public.sleep_trial_item_bindings (
  item_id, company_id, policy_version_id, resolved_terms,
  term_sources, terms_hash, reason, actor_employee_id
)
select i.id, i.company_id, i.policy_version_id, i.resolved_terms,
       i.term_sources, i.terms_hash, 'BACKFILL', null
from public.sleep_trial_items i
where i.bound_reason = 'BACKFILL'
  and not exists (
    select 1 from public.sleep_trial_item_bindings b where b.item_id = i.id);

-- Point concerns / start corrections at the item when the journey has
-- exactly one.
update public.sleep_concerns sc
set trial_item_id = t.item_id
from (
  select journey_id, (array_agg(id))[1] as item_id
  from public.sleep_trial_items
  group by journey_id
  having count(*) = 1
) t
where sc.journey_id = t.journey_id
  and sc.trial_item_id is null;

update public.sleep_trial_start_corrections sc
set trial_item_id = t.item_id
from (
  select journey_id, (array_agg(id))[1] as item_id
  from public.sleep_trial_items
  group by journey_id
  having count(*) = 1
) t
where sc.journey_id = t.journey_id
  and sc.trial_item_id is null;

-- One summary audit row per company for the backfill (per-item audit is
-- skipped for backfill rows by design).
do $$
declare
  v_co record;
  v_counts jsonb;
begin
  for v_co in
    select p.company_id, p.id as policy_id
    from public.policies p
    where p.policy_type = 'SLEEP_TRIAL'
  loop
    select jsonb_object_agg(coalesce(status, 'NULL'), cnt) into v_counts
    from (
      select status, count(*) as cnt
      from public.sleep_trial_items
      where company_id = v_co.company_id and bound_reason = 'BACKFILL'
      group by status
    ) s;
    perform public.log_audit_event(
      v_co.company_id,
      'policy', v_co.policy_id, 'SLEEP_TRIAL_BACKFILL',
      null,
      jsonb_build_object('items_by_status', coalesce(v_counts, '{}'::jsonb)),
      null,
      'Backfilled sleep_trial_items for journeys at/past Sold (Version 0 Legacy).',
      null, 'SYSTEM', null);
  end loop;
end;
$$;

-- ============================================================================
-- 8. Summary
-- ============================================================================

select
  'items_by_status_and_reason' as section,
  coalesce(status, 'NULL') as status,
  coalesce(bound_reason, 'NULL') as bound_reason,
  count(*) as n
from public.sleep_trial_items
group by status, bound_reason
union all
select
  'legacy_items_without_line', null, null, count(*)
from public.sleep_trial_items
where bound_reason = 'BACKFILL' and line_item_id is null
union all
select
  'sold_journeys_zero_items', null, null, count(*)
from public.sleep_journeys sj
where sj.cancelled_at is null
  and sj.current_state in (
    'Sold','Waiting for Inventory','Ready to Schedule',
    'Scheduled','Sleep Trial','Completed')
  and not exists (
    select 1 from public.sleep_trial_items i where i.journey_id = sj.id)
order by section, status, bound_reason;
