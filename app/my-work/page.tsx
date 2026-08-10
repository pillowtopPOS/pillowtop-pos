"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { fetchMyWork, completeFollowUp, type MyWorkItem } from "@/lib/journeys/queries";

export default function MyWorkPage() {
  const router = useRouter();
  const [items, setItems] = useState<MyWorkItem[]>([]);
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
    const data = await fetchMyWork();
    setItems(data);
    setLoading(false);
  }

  async function handleComplete(id: string) {
    try {
      await completeFollowUp(id);
      load();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to complete follow-up");
    }
  }

  function isOverdue(dueAt: string) {
    return new Date(dueAt) < new Date();
  }

  return (
    <main className="min-h-screen bg-slate-50 p-6">
      <header className="mb-4 flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-2xl font-semibold text-slate-900">My Work</h1>
        <Link
          href="/board"
          className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
        >
          Back to Board
        </Link>
      </header>

      {loading && <p className="text-sm text-slate-500">Loading…</p>}

      {!loading && items.length === 0 && (
        <p className="text-sm text-slate-500">Nothing needs attention right now.</p>
      )}

      {!loading && (
        <div className="space-y-2">
          {items.map((item) => {
            if (item.kind === "follow_up") {
              const f = item.data;
              const customer = f.journey?.customer;
              const overdue = isOverdue(f.due_at);
              return (
                <div
                  key={f.id}
                  className={`flex flex-wrap items-center justify-between gap-3 rounded-lg border p-4 ${
                    overdue
                      ? "border-red-200 bg-red-50"
                      : "border-amber-200 bg-amber-50"
                  }`}
                >
                  <div>
                    <p className="text-sm font-medium text-slate-900">
                      {customer
                        ? `${customer.first_name} ${customer.last_name}`
                        : "Unknown"}
                      <span className="ml-2 rounded-full bg-white px-2 py-0.5 text-xs font-normal text-slate-600">
                        {f.type}
                      </span>
                    </p>
                    <p className="text-xs text-slate-600">{f.notes}</p>
                    <p className={`text-xs ${overdue ? "text-red-600" : "text-slate-500"}`}>
                      {overdue ? "Overdue" : "Due"} {new Date(f.due_at).toLocaleString()}
                    </p>
                  </div>
                  <div className="flex items-center gap-2">
                    <Link
                      href={`/board?journey=${f.journey_id}`}
                      className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50"
                    >
                      View Journey
                    </Link>
                    <button
                      onClick={() => handleComplete(f.id)}
                      className="rounded-md bg-brand-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-700"
                    >
                      Mark Done
                    </button>
                  </div>
                </div>
              );
            }

            const o = item.data;
            return (
              <div
                key={o.id}
                className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-slate-200 bg-white p-4"
              >
                <div>
                  <p className="text-sm font-medium text-slate-900">
                    {o.first_name} {o.last_name}
                    <span className="ml-2 rounded-full bg-slate-100 px-2 py-0.5 text-xs font-normal text-slate-600">
                      {o.status}
                    </span>
                  </p>
                  <p className="text-xs text-slate-500">{o.product_summary ?? "—"}</p>
                </div>
                <div className="text-right text-xs text-slate-500">
                  {o.phone}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </main>
  );
}
