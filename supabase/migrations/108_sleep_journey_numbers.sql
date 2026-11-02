-- ============================================================================
-- SJ-1 Stage 1: permanent human-readable journey numbers
--
-- Every sleep journey gets SJ-{StoreCode}{5-digit counter}, for example
-- SJ-MS00001, counted per store using the document_counters mechanism from
-- migration 051. Filled by a BEFORE INSERT trigger when the caller leaves it
-- null, so every insert path (RPCs, seeds, future code) gets one for free.
-- The number never changes afterwards: a journey that moves stores keeps
-- the number it was born with.
--
-- sleep_journeys has no company_id (company derives via store_id -> stores),
-- so the uniqueness scope is (store_id, journey_number). Store codes are
-- unique within a company, which makes this identical to unique-per-company
-- in practice; two companies may both have a store coded MS and that is fine.
-- ============================================================================

-- document_counters.doc_type only allowed count/transfer/PO rows; journeys
-- need their own doc_type. The check constraint is the default name.
alter table public.document_counters
  drop constraint if exists document_counters_doc_type_check;
alter table public.document_counters
  add constraint document_counters_doc_type_check
  check (doc_type in ('inventory_count', 'transfer', 'purchase_order', 'sleep_journey'));

alter table public.sleep_journeys
  add column if not exists journey_number text;

-- BEFORE INSERT: fill journey_number when null. The counter upsert inside
-- next_document_number is atomic; rolled-back inserts simply burn a number,
-- which is acceptable (numbers are never reused).
create or replace function public.assign_journey_number()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_company uuid;
  v_n integer;
begin
  if tg_op = 'UPDATE' then
    if old.journey_number is not null
       and new.journey_number is distinct from old.journey_number then
      raise exception 'A journey number cannot be changed.';
    end if;
    return new;
  end if;

  -- Always assign: a caller-supplied number is ignored, the counter owns it.
  v_code := upper(public.ensure_store_code(new.store_id));
  select s.company_id into v_company
  from public.stores s where s.id = new.store_id;
  v_n := public.next_document_number(v_company, new.store_id, 'sleep_journey');
  new.journey_number := 'SJ-' || v_code || lpad(v_n::text, 5, '0');
  return new;
end;
$$;

revoke execute on function public.assign_journey_number() from public, anon;

drop trigger if exists trg_sleep_journeys_number on public.sleep_journeys;
create trigger trg_sleep_journeys_number
before insert on public.sleep_journeys
for each row execute function public.assign_journey_number();

drop trigger if exists trg_sleep_journeys_number_immutable on public.sleep_journeys;
create trigger trg_sleep_journeys_number_immutable
before update on public.sleep_journeys
for each row execute function public.assign_journey_number();

-- Backfill: per store, oldest first, using the same counter so new numbers
-- continue after the last backfilled one. The UPDATE trigger permits this
-- because old.journey_number is null.
do $$
declare
  r record;
  v_co uuid;
  v_code text;
  v_n integer;
begin
  for r in
    select sj.id, sj.store_id
    from public.sleep_journeys sj
    where sj.journey_number is null
    order by sj.store_id, sj.created_at, sj.id
  loop
    v_code := upper(public.ensure_store_code(r.store_id));
    select s.company_id into v_co
    from public.stores s where s.id = r.store_id;
    v_n := public.next_document_number(v_co, r.store_id, 'sleep_journey');
    update public.sleep_journeys
    set journey_number = 'SJ-' || v_code || lpad(v_n::text, 5, '0')
    where id = r.id;
  end loop;
end $$;

alter table public.sleep_journeys
  alter column journey_number set not null;

create unique index if not exists idx_sleep_journeys_store_number
  on public.sleep_journeys (store_id, journey_number);

-- normalize_journey_number: accepts "SJ-MS00001", "sjms00001", "MS00001",
-- "SJ MS 00001" and returns the canonical "SJ-MS00001". Digits-only input is
-- ambiguous across stores, so it returns null. Pure text work, no tables.
create or replace function public.normalize_journey_number(p_input text)
returns text
language plpgsql
immutable
as $$
declare
  v text;
begin
  if p_input is null then
    return null;
  end if;
  v := upper(regexp_replace(p_input, '[^A-Za-z0-9]', '', 'g'));
  v := regexp_replace(v, '^SJ', '');
  if v !~ '^[A-Z]+[0-9]+$' then
    return null;
  end if;
  return 'SJ-' || v;
end;
$$;

grant execute on function public.normalize_journey_number(text) to authenticated;
revoke execute on function public.normalize_journey_number(text) from public, anon;

-- Install confirmation
select
  (select count(*) from public.sleep_journeys where journey_number is null) as missing,
  (select count(*) from public.sleep_journeys where journey_number is not null) as numbered,
  public.normalize_journey_number('sj ms 00042') as normalize_sample,
  public.normalize_journey_number('00042') as normalize_digits_only;
