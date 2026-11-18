-- 154_journey_fulfillment_recorded_event.sql
-- Adds the journey_fulfillment_recorded event type used by slice 2 per-item
-- fulfillment. This is its own migration because a new enum value cannot be
-- used inside the same transaction that adds it, so it must be installed
-- before 155 and 156, which reference the value in the insert policy, the
-- delivery-event guard, and the record_journey_fulfillment RPC.

alter type public.journey_event_type add value if not exists 'journey_fulfillment_recorded';
