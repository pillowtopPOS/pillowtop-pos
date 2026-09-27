-- ============================================================
-- PillowTop POS: Remove Sleep Trial test journeys
-- Run in the Supabase SQL editor after seed_sleep_trial_test_journeys.sql.
-- ============================================================
--
-- Deletes everything the seed created AND anything recorded on the
-- TEST journeys during manual testing (interactions, sleep concerns
-- and their children, exception requests, trial-start corrections,
-- follow-ups, written sales + adjustments, deposit approvals,
-- reassignments, inventory requirements, events, line items).
-- Scoped strictly to customers named 'TEST' 'Trial %' — no real data
-- can be touched. (There is no payments table; payments live in
-- journey_events, removed below.)

-- Snapshot the target journeys/customers up front so every delete
-- uses the same fixed set even as rows are removed.
create temp table test_journeys on commit drop as
select sj.id
from public.sleep_journeys sj
join public.customers c on c.id = sj.customer_id
where c.first_name = 'TEST' and c.last_name like 'Trial %';

create temp table test_customers on commit drop as
select id from public.customers
where first_name = 'TEST' and last_name like 'Trial %';

create temp table test_concerns on commit drop as
select id from public.sleep_concerns
where journey_id in (select id from test_journeys);

-- Sleep concern children (deepest first)
delete from public.sleep_concern_diagnostic_responses
where sleep_concern_id in (select id from test_concerns);

delete from public.sleep_concern_entries
where sleep_concern_id in (select id from test_concerns);

delete from public.sleep_concern_issues
where sleep_concern_id in (select id from test_concerns);

-- Exception requests reference both the journey and the concern
delete from public.sleep_trial_exception_requests
where journey_id in (select id from test_journeys);

delete from public.sleep_trial_start_corrections
where journey_id in (select id from test_journeys);

delete from public.follow_ups
where journey_id in (select id from test_journeys);

delete from public.sleep_concerns
where journey_id in (select id from test_journeys);

delete from public.journey_interactions
where journey_id in (select id from test_journeys);

-- Written sales + adjustments (created if payments were recorded
-- through the UI during testing)
delete from public.written_sale_adjustments
where order_id in (select id from test_journeys);

delete from public.written_sales
where order_id in (select id from test_journeys);

delete from public.deposit_approval_requests
where entity_type = 'journey'
  and entity_id in (select id from test_journeys);

delete from public.journey_reassignment_events
where journey_id in (select id from test_journeys);

delete from public.journey_inventory_requirements
where journey_id in (select id from test_journeys);

delete from public.journey_line_items
where journey_id in (select id from test_journeys);

delete from public.journey_events
where journey_id in (select id from test_journeys);

-- Journeys, contacts, customers
delete from public.sleep_journeys
where customer_id in (select id from test_customers);

delete from public.customer_contacts
where customer_id in (select id from test_customers);

delete from public.customers
where id in (select id from test_customers);

-- Verification: every count must be 0.
select
  (select count(*) from public.customers
    where first_name = 'TEST' and last_name like 'Trial %') as test_customers,
  (select count(*) from public.sleep_journeys sj
    join public.customers c on c.id = sj.customer_id
    where c.first_name = 'TEST' and c.last_name like 'Trial %') as test_journeys,
  (select count(*) from public.journey_events je
    join public.sleep_journeys sj on sj.id = je.journey_id
    join public.customers c on c.id = sj.customer_id
    where c.first_name = 'TEST' and c.last_name like 'Trial %') as test_events,
  (select count(*) from public.journey_interactions ji
    join public.sleep_journeys sj on sj.id = ji.journey_id
    join public.customers c on c.id = sj.customer_id
    where c.first_name = 'TEST' and c.last_name like 'Trial %') as test_interactions,
  (select count(*) from public.sleep_concerns sc
    join public.sleep_journeys sj on sj.id = sc.journey_id
    join public.customers c on c.id = sj.customer_id
    where c.first_name = 'TEST' and c.last_name like 'Trial %') as test_concerns;
