"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { formatDistanceToNow } from "date-fns";
import { createClient } from "@/lib/supabase/client";
import { fetchMyWork, completeFollowUp, FOLLOW_UP_METHOD_LABELS, type MyWorkItem } from "@/lib/journeys/queries";
import { exceptionTypeLabel } from "@/lib/journeys/sleepTrial";
import { READY_SCHEDULING_STALE_DAYS } from "@/lib/constants";

export default function MyWorkPage() {
  const router = useRouter();
  const [items, setItems] = useState<MyWorkItem[]>([]);
  const [showAllStores, setShowAllStores] = useState(false);

  const [pageError, setPageError] = useState<string | null>(null);
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

  async function load(allStores = showAllStores) {
    setLoading(true);
    const data = await fetchMyWork({ allStores });
    setItems(data);
    setLoading(false);
    // Keep the sidebar badge equal to exactly what this page renders.
    window.dispatchEvent(
      new CustomEvent<number>("my-work-count", { detail: data.length })
    );
  }

  async function handleComplete(id: string) {
    try {
      setPageError(null);
      await completeFollowUp(id);
      load();
    } catch (e: any) {
      setPageError(e.message ?? "Failed to complete follow-up");
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


  type WorkSection = "ready" | "follow_ups" | "approvals" | "exchanges" | "opportunities";
  const SECTION_DEFS: { key: WorkSection; title: string }[] = [
    { key: "ready", title: "Ready to schedule" },
    { key: "follow_ups", title: "Follow-ups" },
    { key: "approvals", title: "Approvals" },
    { key: "exchanges", title: "Exchanges" },
    { key: "opportunities", title: "Opportunities" },
  ];
  const ACTION_CLS = "font-semibold underline";

  function sectionOf(item: MyWorkItem): WorkSection {
    switch (item.kind) {
      case "ready_for_scheduling": return "ready";
      case "follow_up": return "follow_ups";
      case "approval": return "approvals";
      case "exchange_progress":
      case "exchange_stalled": return "exchanges";
      default: return "opportunities";
    }
  }

  function renderItem(item: MyWorkItem) {

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
                      <span className={ACTION_CLS}>
                        {FOLLOW_UP_LABELS[f.type] ?? f.type}:
                      </span>{" "}
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
                      <span className={ACTION_CLS}>Ready to schedule:</span>{" "}
                      {r.customer_name ?? "Unknown customer"}
                      {r.journey_number && (
                        <span className="ml-2 rounded-full bg-white px-2 py-0.5 text-xs font-normal text-slate-600">
                          {r.journey_number}
                        </span>
                      )}
                      {r.ready_after_wait_at && (
                        <span className="ml-2 rounded-full bg-white px-2 py-0.5 text-xs font-normal text-emerald-700">
                          Stock ready
                        </span>
                      )}
                      {(() => {
                        if (!r.ready_at) return null;
                        const days = Math.floor(
                          (Date.now() - new Date(r.ready_at).getTime()) /
                            86400000
                        );
                        if (days < READY_SCHEDULING_STALE_DAYS) return null;
                        return (
                          <span className="ml-2 rounded-full bg-amber-100 px-2 py-0.5 text-xs font-normal text-amber-800">
                            Waiting {days} day{days === 1 ? "" : "s"}
                          </span>
                        );
                      })()}
                    </p>
                    <p className="mt-1 text-xs text-slate-600">
                      {r.ready_at
                        ? `Ready ${formatDistanceToNow(new Date(r.ready_at), {
                            addSuffix: true,
                          })}`
                        : "Ready"}
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
                      <span className={ACTION_CLS}>Approval:</span>{" "}
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
                      <span className={ACTION_CLS}>
                        {stalled
                          ? `Exchange stalled ${w.days_committed} day${
                              w.days_committed === 1 ? "" : "s"
                            }:`
                          : "Exchange in progress:"}
                      </span>{" "}
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
                    <span className={ACTION_CLS}>Opportunity:</span>{" "}
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

    return null;
  }

  return (
    <main className="min-h-screen bg-slate-50 p-6">
      {pageError && (
        <p key="page-error" role="alert" className="mb-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">{pageError}</p>
      )}
      <header className="mb-4 flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-2xl font-semibold text-slate-900">My Work</h1>
        <div className="flex items-center gap-4">
          <label className="flex items-center gap-2 text-sm text-slate-600">
            <input
              type="checkbox"
              checked={showAllStores}
              onChange={(e) => {
                setShowAllStores(e.target.checked);
                load(e.target.checked);
              }}
              className="h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500"
            />
            Show all stores
          </label>
          <Link
            href="/board"
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            Back to Board
          </Link>
        </div>
      </header>

      {loading && <p className="text-sm text-slate-500">Loading…</p>}

      {!loading && items.length === 0 && (
        <p className="text-sm text-slate-500">Nothing needs attention right now.</p>
      )}

      {!loading && (
        <div className="space-y-6">
          {SECTION_DEFS.map((def) => {
            const sectionItems = items.filter((i) => sectionOf(i) === def.key);
            if (sectionItems.length === 0) return null;
            return (
              <section key={def.key}>
                <h2 className="mb-2 text-sm font-semibold text-slate-700">
                  {def.title} ({sectionItems.length})
                </h2>
                <div className="space-y-2">
                  {sectionItems.map((item) => renderItem(item))}
                </div>
              </section>
            );
          })}
        </div>
      )}
    </main>
  );
}
