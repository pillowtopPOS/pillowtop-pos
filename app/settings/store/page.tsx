import { redirect } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

export default async function StoreSettingsPage() {
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
        <div className="mb-4 flex items-center gap-2 text-sm text-slate-500">
          <Link href="/settings" className="hover:text-slate-700">Settings</Link>
          <span>/</span>
          <span className="text-slate-900">Store Management</span>
        </div>
        <h1 className="text-2xl font-semibold text-slate-900">Store Management</h1>
        <p className="mt-2 text-slate-600">Placeholder — store CRUD coming in a later phase.</p>
      </div>
    </main>
  );
}
