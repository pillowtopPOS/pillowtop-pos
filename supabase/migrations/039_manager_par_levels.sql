-- PillowTop POS: separate manager toggle for Par Levels management

-- New company-level setting (default off for all, including existing rows).
-- Owner and admin always retain Par Levels access; this gate only applies to managers.
-- RLS on par_levels already restricts access to owner/admin/manager, and is unchanged.

alter table public.companies
  add column if not exists managers_can_manage_par_levels boolean not null default false;
