"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { formatDistanceToNow } from "date-fns";
import { createClient } from "@/lib/supabase/client";
import { fetchMyWork, completeFollowUp, FOLLOW_UP_METHOD_LABELS, type MyWorkItem } from "@/lib/journeys/queries";
import { exceptionTypeLabel } from "@/lib/journeys/sleepTrial";

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
    // Keep the sidebar badge equal to exactly what this page renders.
    window.dispatchEvent(
      new CustomEvent<number>("my-work-count", { detail: data.length })
    );
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

  const FOLLOW_UP_LABELS: Record<string, string> = {
    quote: "Quote",
    deposit: "Deposit",
    interaction: "Follow-up",
    sleep_concern: "Sleep Concern",
    inventory_shortage: "Inventory shortage",
  };

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
                        {FOLLOW_UP_LABELS[f.type] ?? f.type}
                      </span>
                      {f.type === "sleep_concern" && f.sleep_concerns?.status && (
                        <span className="ml-2 rounded-full bg-teal-100 px-2 py-0.5 text-xs font-normal text-teal-700">
                          concern: {f.sleep_concerns.status.replace(/_/g, " ")}
                        </span>
                      )}
                    </p>
                    <p className="text-xs text-slate-600">{f.notes}</p>
                    <p className={`text-xs ${overdue ? "text-red-600" : "text-slate-500"}`}>
                      {overdue ? "Overdue" : "Due"} {new Date(f.due_at).toLocaleString()}
                      {f.method ? ` · via ${FOLLOW_UP_METHOD_LABELS[f.method] ?? f.method}` : ""}
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

            if (item.kind === "ready_for_scheduling") {
              const r = item.data;
              return (
                <div
                  key={r.journey_id}
                  className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-emerald-200 bg-emerald-50 p-4"
                >
                  <div>
                    <p className="text-sm font-medium text-slate-900">
                      Ready to schedule:{" "}
                      {r.customer_name ?? "Unknown customer"}
                      <span className="ml-2 rounded-full bg-white px-2 py-0.5 text-xs font-normal text-emerald-700">
                        Stock ready
                      </span>
                    </p>
                    <p className="mt-1 text-xs text-slate-600">
                      Stock arrived{" "}
                      {formatDistanceToNow(new Date(r.ready_after_wait_at), {
                        addSuffix: true,
                      })}
                      {r.store_name ? ` at ${r.store_name}` : ""}
                      {r.item_summary ? ` · ${r.item_summary}` : ""}
                      {r.assigned_employee_name
                        ? ` · assigned to ${r.assigned_employee_name}`
                        : ""}
                    </p>
                  </div>
                  <Link
                    href={`/board?journey=${r.journey_id}`}
                    className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50"
                  >
                    View Journey
                  </Link>
                </div>
              );
            }

            if (item.kind === "approval") {
              const a = item.data;
              return (
                <div
                  key={a.id}
                  className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-indigo-200 bg-indigo-50 p-4"
                >
                  <div>
                    <p className="text-sm font-medium text-slate-900">
                      {a.customer_name ?? "Unknown customer"}
                      <span className="ml-2 rounded-full bg-white px-2 py-0.5 text-xs font-normal text-indigo-700">
                        Approval needed
                      </span>
                    </p>
                    <p className="text-xs text-slate-600">
                      {exceptionTypeLabel(a.exception_type)} exception
                      {a.requester_name
                        ? ` · requested by ${a.requester_name}`
                        : ""}
                    </p>
                    <p className="text-xs text-slate-500">
                      {a.reason_label ?? "No reason"}
                      {a.reason_note ? ` — ${a.reason_note}` : ""}
                    </p>
                  </div>
                  <Link
                    href={`/board?journey=${a.journey_id}`}
                    className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50"
                  >
                    View Journey
                  </Link>
                </div>
              );
            }

            if (
              item.kind === "exchange_progress" ||
              item.kind === "exchange_stalled"
            ) {
              const w = item.data;
              const stalled = item.kind === "exchange_stalled";
              return (
                <div
                  key={w.action_id}
                  className={`flex flex-wrap items-center justify-between gap-3 rounded-lg border p-4 ${
                    stalled
                      ? "border-red-200 bg-red-50"
                      : "border-teal-200 bg-teal-50"
                  }`}
                >
                  <div>
                    <p className="text-sm font-medium text-slate-900">
                      {stalled
                        ? `Exchange stalled ${w.days_committed} day${
                            w.days_committed === 1 ? "" : "s"
                          }: `
                        : "Exchange in progress: "}
                      {w.customer_name ?? "Unknown customer"}
                      <span
                        className={`ml-2 rounded-full bg-white px-2 py-0.5 text-xs font-normal ${
                          stalled ? "text-red-700" : "text-teal-700"
                        }`}
                      >
                        Exchange
                      </span>
                    </p>
                    {w.replacement_product_name && (
                      <p className="mt-0.5 text-xs text-slate-600">
                        Replacement: {w.replacement_product_name}
                      </p>
                    )}
                    <ul className="mt-0.5 space-y-0.5">
                      {w.open_milestones.map((m) => (
                        <li
                          key={m}
                          className={`text-xs ${
                            stalled ? "text-red-700" : "text-slate-500"
                          }`}
                        >
                          {m}
                        </li>
                      ))}
                    </ul>
                  </div>
                  <Link
                    href={`/board?journey=${w.journey_id}`}
                    className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50"
                  >
                    View Journey
                  </Link>
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
