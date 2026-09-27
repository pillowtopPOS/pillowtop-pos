import { redirect } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

export default async function SettingsPage() {
  const supabase = createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    redirect("/login");
  }

  const { data: employee } = await supabase
    .from("employees")
    .select("role")
    .eq("auth_user_id", user.id)
    .maybeSingle();

  if (employee?.role !== "owner" && employee?.role !== "admin") {
    redirect("/board");
  }

  return (
    <main className="min-h-screen bg-slate-50 p-8">
      <div className="mx-auto max-w-2xl">
        <h1 className="mb-6 text-2xl font-semibold text-slate-900">Settings</h1>

        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <Link
            href="/settings/store"
            className="rounded-lg border border-slate-200 bg-white p-6 shadow-sm transition hover:border-brand-500 hover:bg-brand-50"
          >
            <h2 className="text-lg font-semibold text-slate-900">Store Management</h2>
            <p className="mt-2 text-sm text-slate-500">
              Manage stores, locations, and store-level defaults.
            </p>
          </Link>

          <Link
            href="/settings/employees"
            className="rounded-lg border border-slate-200 bg-white p-6 shadow-sm transition hover:border-brand-500 hover:bg-brand-50"
          >
            <h2 className="text-lg font-semibold text-slate-900">Employee Management</h2>
            <p className="mt-2 text-sm text-slate-500">
              Manage employees, roles, and permissions.
            </p>
          </Link>

          <Link
            href="/settings/deposit-policy"
            className="rounded-lg border border-slate-200 bg-white p-6 shadow-sm transition hover:border-brand-500 hover:bg-brand-50"
          >
            <h2 className="text-lg font-semibold text-slate-900">Deposit Policy</h2>
            <p className="mt-2 text-sm text-slate-500">
              Configure required deposits by company.
            </p>
          </Link>

          <Link
            href="/settings/deposit-approvals"
            className="rounded-lg border border-slate-200 bg-white p-6 shadow-sm transition hover:border-brand-500 hover:bg-brand-50"
          >
            <h2 className="text-lg font-semibold text-slate-900">Deposit Approvals</h2>
            <p className="mt-2 text-sm text-slate-500">
              Review and approve below-floor payment requests.
            </p>
          </Link>

          <Link
            href="/settings/company"
            className="rounded-lg border border-slate-200 bg-white p-6 shadow-sm transition hover:border-brand-500 hover:bg-brand-50"
          >
            <h2 className="text-lg font-semibold text-slate-900">Company Settings</h2>
            <p className="mt-2 text-sm text-slate-500">
              Configure company-wide inventory and manager permissions.
            </p>
          </Link>

          <Link
            href="/settings/sleep-trial"
            className="rounded-lg border border-slate-200 bg-white p-6 shadow-sm transition hover:border-brand-500 hover:bg-brand-50"
          >
            <h2 className="text-lg font-semibold text-slate-900">Sleep Trial</h2>
            <p className="mt-2 text-sm text-slate-500">
              Sleep trial policy, approvals, and exceptions.
            </p>
          </Link>

          <Link
            href="/settings/financing"
            className="rounded-lg border border-slate-200 bg-white p-6 shadow-sm transition hover:border-brand-500 hover:bg-brand-50"
          >
            <h2 className="text-lg font-semibold text-slate-900">Financing &amp; Accessories</h2>
            <p className="mt-2 text-sm text-slate-500">
              Configure financing tiers, accessory suggestions, and bundles.
            </p>
          </Link>
        </div>
      </div>
    </main>
  );
}
