-- Phase 6a follow-up: add event_type tracking to the reconciliation log
-- When 014 first ran, payment_reconciliation_events already existed, so
-- the previous_event_type/new_event_type columns were never added by CREATE TABLE IF NOT EXISTS.

alter table public.payment_reconciliation_events
  add column if not exists previous_event_type public.journey_event_type,
  add column if not exists new_event_type public.journey_event_type;
