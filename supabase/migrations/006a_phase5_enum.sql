-- PillowTop POS Phase 5, part A: new journey event enum values
-- Run this first, separately, because Postgres does not allow a newly-added enum value
-- to be used in the same transaction in which it was created.

alter type public.journey_event_type add value if not exists 'line_item_added';
alter type public.journey_event_type add value if not exists 'line_item_removed';
alter type public.journey_event_type add value if not exists 'line_item_updated';
alter type public.journey_event_type add value if not exists 'journey_updated_to_sold';
alter type public.journey_event_type add value if not exists 'line_items_changed_balance_due';
