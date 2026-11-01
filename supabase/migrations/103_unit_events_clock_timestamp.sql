-- 103: unit_events.created_at uses clock_timestamp(), not now().
-- now() is the transaction start time, so several moves inside one
-- transaction got identical timestamps and the history order was
-- ambiguous. clock_timestamp() is the actual wall-clock time at each
-- insert, so events order correctly within a transaction.
-- Existing rows are unchanged; this only affects new inserts.

alter table public.unit_events
  alter column created_at set default clock_timestamp();

-- Confirm the default installed:
select column_default
from information_schema.columns
where table_schema = 'public'
  and table_name = 'unit_events'
  and column_name = 'created_at';
