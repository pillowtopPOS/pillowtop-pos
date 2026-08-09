import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { SLEEP_JOURNEY_STATES } from "@/lib/constants";

export default async function BoardPage() {
  const cookieStore = cookies();
  const supabase = createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  return (
    <main className="min-h-screen p-8">
      <div className="mb-6 flex items-center justify-between">
        <h1 className="text-2xl font-semibold text-slate-900">Sleep Journey Board</h1>
      </div>
      <p className="text-slate-600">
        Supabase connected. The nine columns and cards will be built here next.
      </p>
      <div className="mt-6 grid grid-cols-9 gap-3">
        {SLEEP_JOURNEY_STATES.map((state) => (
          <div
            key={state}
            className="rounded-lg border border-slate-200 bg-white p-3 text-xs font-medium text-slate-700"
          >
            {state}
          </div>
        ))}
      </div>
    </main>
  );
}
