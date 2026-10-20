-- ============================================================================
-- REFUNDS-B1 (1 of 2): new journey event type 'payment_refunded'
--
-- PostgreSQL requires the enum value to be committed before any function
-- body references it, so it lands alone here. Nothing in this file may use
-- the new value — that is migration 097's job.
-- ============================================================================

alter type public.journey_event_type add value if not exists 'payment_refunded';
