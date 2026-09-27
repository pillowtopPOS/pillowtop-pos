-- 062_revoke_default_write_grants.sql
--
-- Supabase default privileges grant insert/update/delete on new public
-- tables to anon and authenticated. RLS already blocks those writes, so
-- this is defense in depth: strip the default write grants on the
-- interaction/concern tables so the security-definer RPCs are the only
-- write path in principle, not just in practice.
--
-- (Already applied manually in production; committed for the migration log.)
revoke insert, update, delete on
  public.journey_interactions,
  public.sleep_trial_start_corrections,
  public.sleep_concerns,
  public.sleep_concern_issues,
  public.sleep_concern_entries,
  public.sleep_concern_diagnostic_responses,
  public.sleep_trial_exception_requests
from anon, authenticated;
