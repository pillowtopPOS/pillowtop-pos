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
        </div>
      </div>
    </main>
  );
}
