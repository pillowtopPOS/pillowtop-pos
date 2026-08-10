"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { fetchOpportunities, type Opportunity } from "@/lib/journeys/queries";

export default function OpportunitiesPage() {
  const router = useRouter();
  const [opportunities, setOpportunities] = useState<Opportunity[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!session?.user) {
        router.push("/login");
        return;
      }
      load();
    });
  }, [router]);

  async function load() {
    setLoading(true);
    const data = await fetchOpportunities();
    setOpportunities(data);
    setLoading(false);
  }

  return (
    <main className="min-h-screen bg-slate-50 p-6">
      <header className="mb-4 flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-2xl font-semibold text-slate-900">Opportunities</h1>
        <Link
          href="/board"
          className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
        >
          Back to Board
        </Link>
      </header>

      <p className="mb-4 text-sm text-slate-600">
        Pre-purchase leads. Full pipeline UI is planned for a future phase.
      </p>

      {loading && <p className="text-sm text-slate-500">Loading…</p>}

      {!loading && opportunities.length === 0 && (
        <p className="text-sm text-slate-500">No opportunities found.</p>
      )}

      {!loading && (
        <div className="space-y-2">
          {opportunities.map((o) => (
            <div
              key={o.id}
              className="rounded-lg border border-slate-200 bg-white p-4"
            >
              <div className="flex items-center justify-between">
                <p className="text-sm font-medium text-slate-900">
                  {o.first_name} {o.last_name}
                  <span className="ml-2 rounded-full bg-slate-100 px-2 py-0.5 text-xs font-normal text-slate-600">
                    {o.status}
                  </span>
                </p>
                <p className="text-xs text-slate-500">{o.source ?? "—"}</p>
              </div>
              <div className="mt-1 text-xs text-slate-500">
                {o.phone} · {o.email}
              </div>
              {o.product_summary && (
                <p className="mt-1 text-xs text-slate-600">{o.product_summary}</p>
              )}
              {o.notes && (
                <p className="mt-1 text-xs text-slate-500">{o.notes}</p>
              )}
            </div>
          ))}
        </div>
      )}
    </main>
  );
}
