-- PillowTop POS m131: scope the companies UPDATE policy to the caller's
-- own company. The m025 policy checked only current_employee_role(), so
-- an owner/admin of company B could update company A's row (timezone,
-- delivery_cutoff_time, and every other companies column). The SELECT
-- policy is intentionally untouched (tracked on the Go-Live Gate).

drop policy if exists "Companies updatable by owner/admin" on public.companies;

create policy "Companies updatable by owner/admin"
  on public.companies for update
  to authenticated
  using (
    id = public.current_employee_company_id()
    and public.current_employee_role()::text in ('owner', 'admin')
  )
  with check (
    id = public.current_employee_company_id()
    and public.current_employee_role()::text in ('owner', 'admin')
  );
