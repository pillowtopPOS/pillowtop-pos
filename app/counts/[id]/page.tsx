"use client";

import { useEffect, useMemo, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import Link from "next/link";
import { Printer, Search } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import {
  fetchCurrentEmployee,
  type Employee,
} from "@/lib/journeys/queries";
import { isStoreConfirmedToday } from "@/lib/journeys/storeConfirm";
import Modal from "@/components/Modal";
import { searchProducts, type Product } from "@/lib/inventory/queries";
import {
  fetchCount,
  fetchCountItems,
  fetchProductsByIds,
  fetchCountReviewItems,
  approveCountStart,
  rejectCountStart,
  submitCountQuantities,
  submitInventoryCount,
  finalizeInventoryCount,
  cancelInventoryCount,
  addInventoryCountItem,
  type InventoryCount,
  type CountItem,
  type CountReviewItem,
} from "@/lib/counts/queries";

const STATUS_CLASS: Record<string, string> = {
  pending_start_approval: "text-amber-700 bg-amber-50",
  in_progress: "text-blue-700 bg-blue-50",
  submitted: "text-purple-700 bg-purple-50",
  approved: "text-emerald-700 bg-emerald-50",
  rejected: "text-slate-600 bg-slate-100",
  cancelled: "text-slate-500 bg-slate-100",
};

const STATUS_LABEL: Record<string, string> = {
  pending_start_approval: "Pending approval",
  in_progress: "In progress",
  submitted: "Submitted",
  approved: "Approved",
  rejected: "Rejected",
  cancelled: "Cancelled",
};

const TERMINAL = ["approved", "rejected", "cancelled"];

export default function CountDetailPage() {
  const params = useParams();
  const router = useRouter();
  const countId = params?.id as string;

  const [employee, setEmployee] = useState<Employee | null>(null);
  const [count, setCount] = useState<InventoryCount | null>(null);
  const [items, setItems] = useState<CountItem[]>([]);
  const [products, setProducts] = useState<Record<string, Product>>({});
  const [employeeNames, setEmployeeNames] = useState<Record<string, string>>({});
  const [activeStoreId, setActiveStoreId] = useState<string | null>(null);
  const [storeConfirmedToday, setStoreConfirmedToday] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [acting, setActing] = useState(false);

  const [entries, setEntries] = useState<Record<string, string>>({});

  const [addQuery, setAddQuery] = useState("");
  const [addOptions, setAddOptions] = useState<Product[]>([]);
  const [addingItem, setAddingItem] = useState(false);

  const [finalizeOpen, setFinalizeOpen] = useState(false);
  const [reviewItems, setReviewItems] = useState<CountReviewItem[]>([]);
  const [finalizeValues, setFinalizeValues] = useState<Record<string, string>>({});
  const [finalizeBaseline, setFinalizeBaseline] = useState<Record<string, string>>({});
  const [finalizeError, setFinalizeError] = useState<string | null>(null);
  const [finalizing, setFinalizing] = useState(false);
  const [hideNoVariance, setHideNoVariance] = useState(false);

  const isAdmin = employee?.role === "owner" || employee?.role === "admin";
  const isManager = employee?.role === "manager";
  const isManagerOfStore =
    isManager && employee?.home_store_id === count?.store_id;
  const canFinalize = isAdmin || isManagerOfStore;
  const isRequester = !!employee && count?.requested_by === employee.id;
  const checkedInAtStore =
    storeConfirmedToday && activeStoreId === count?.store_id;
  const canEnter =
    count?.status === "in_progress" &&
    (isAdmin || isManagerOfStore || isRequester || checkedInAtStore);
  const canCancel =
    !!count &&
    !TERMINAL.includes(count.status) &&
    (isRequester ||
      count.started_by === employee?.id ||
      isAdmin ||
      isManagerOfStore);

  const expectedVisible =
    !!count && count.status !== "pending_start_approval" && count.status !== "in_progress";

  async function load() {
    const [c, its] = await Promise.all([
      fetchCount(countId),
      fetchCountItems(countId),
    ]);
    setCount(c);
    setItems(its);

    const variantIds = its.map((i) => i.variant_id);
    const prods = await fetchProductsByIds(variantIds);
    setProducts(prods);

    // Resolve names for whoever submitted/entered quantities.
    const supabase = createClient();
    const empIds = Array.from(
      new Set(
        its.flatMap((i) =>
          [i.submitted_by, i.entered_by].filter(Boolean) as string[]
        )
      )
    );
    if (empIds.length > 0) {
      const { data } = await supabase
        .from("employees")
        .select("id, name")
        .in("id", empIds);
      const map: Record<string, string> = {};
      for (const e of (data as { id: string; name: string }[]) ?? [])
        map[e.id] = e.name;
      setEmployeeNames(map);
    }

    // Pre-fill entry inputs from existing submissions.
    const initial: Record<string, string> = {};
    for (const i of its) {
      if (i.submitted_quantity !== null)
        initial[i.id] = String(i.submitted_quantity);
    }
    setEntries(initial);
  }

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(async ({ data: { session } }) => {
      if (!session?.user) {
        router.push("/login");
        return;
      }
      setActiveStoreId(session.user.user_metadata?.active_store_id ?? null);
      setStoreConfirmedToday(isStoreConfirmedToday(session.user));
      const e = await fetchCurrentEmployee();
      setEmployee(e);
      await load();
      setLoading(false);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [router, countId]);

  // Debounced product search for adding an out-of-scope item mid-count.
  useEffect(() => {
    const q = addQuery.trim();
    if (!q) {
      setAddOptions([]);
      return;
    }
    const t = setTimeout(() => {
      searchProducts(q).then(setAddOptions);
    }, 200);
    return () => clearTimeout(t);
  }, [addQuery]);

  async function handleAddItem(variantId: string) {
    if (!count) return;
    setAddingItem(true);
    setError(null);
    try {
      const itemId = await addInventoryCountItem(count.id, variantId);
      setAddQuery("");
      setAddOptions([]);
      await load();
      // Route the counter straight to the (new or existing) entry field.
      requestAnimationFrame(() => {
        const row = document.getElementById(`count-item-${itemId}`);
        row?.scrollIntoView({ block: "center" });
        row?.querySelector("input")?.focus();
      });
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to add item");
    } finally {
      setAddingItem(false);
    }
  }

  async function run(action: () => Promise<void>, success: string) {
    setActing(true);
    setError(null);
    setNotice(null);
    try {
      await action();
      setNotice(success);
      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Action failed");
    } finally {
      setActing(false);
    }
  }

  const dirtyEntries = useMemo(
    () =>
      items
        .filter((i) => {
          const v = entries[i.id];
          if (v === undefined || v === "") return false;
          return String(i.submitted_quantity ?? "") !== v;
        })
        .map((i) => ({ item_id: i.id, quantity: Number(entries[i.id]) })),
    [items, entries]
  );

  const entriesValid = dirtyEntries.every(
    (e) => Number.isInteger(e.quantity) && e.quantity >= 0
  );

  async function openFinalize() {
    setFinalizeError(null);
    setFinalizing(true);
    try {
      const review = await fetchCountReviewItems(countId);
      setReviewItems(review);
      // Items whose submitted count already matches expected pre-fill with
      // that value; variances and unsubmitted (e.g. paper-only) items start
      // blank and require manual entry.
      const values: Record<string, string> = {};
      for (const r of review) {
        if (
          r.submitted_quantity !== null &&
          r.submitted_quantity === r.expected_quantity
        ) {
          values[r.item_id] = String(r.submitted_quantity);
        }
      }
      setFinalizeValues(values);
      setFinalizeBaseline(values);
      setHideNoVariance(false);
      setFinalizeOpen(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load review");
    } finally {
      setFinalizing(false);
    }
  }

  const finalizeComplete =
    reviewItems.length > 0 &&
    reviewItems.every((r) => {
      const v = finalizeValues[r.item_id];
      return v !== undefined && v !== "" && Number.isInteger(Number(v)) && Number(v) >= 0;
    });

  async function handleFinalize() {
    const counts: Record<string, number> = {};
    for (const r of reviewItems) counts[r.item_id] = Number(finalizeValues[r.item_id]);
    setFinalizing(true);
    setFinalizeError(null);
    try {
      await finalizeInventoryCount(countId, counts);
      setFinalizeOpen(false);
      setNotice("Count approved — inventory updated.");
      await load();
    } catch (err) {
      setFinalizeError(err instanceof Error ? err.message : "Finalize failed");
    } finally {
      setFinalizing(false);
    }
  }

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <p className="text-sm text-slate-500">Loading…</p>
      </div>
    );
  }

  if (!count) {
    return (
      <div className="mx-auto max-w-4xl p-6">
        <p className="text-sm text-slate-500">Count not found.</p>
        <Link href="/counts" className="text-sm text-brand-600 hover:text-brand-700">
          Back to counts
        </Link>
      </div>
    );
  }

  const sortedItems = [...items].sort((a, b) =>
    (products[a.variant_id]?.item_name ?? "").localeCompare(
      products[b.variant_id]?.item_name ?? ""
    )
  );

  const varianceTotal =
    count.status === "approved"
      ? items.reduce(
          (sum, i) =>
            sum + ((i.counted_quantity ?? 0) - (i.expected_quantity ?? 0)),
          0
        )
      : null;

  return (
    <div className="mx-auto max-w-5xl p-6">
      <div className="mb-6 flex items-start justify-between">
        <div>
          <div className="flex items-center gap-3">
            {count.reference_code && (
              <span className="rounded-md bg-brand-50 px-2.5 py-1 text-sm font-semibold text-brand-700">
                {count.reference_code}
              </span>
            )}
            <h1 className="text-2xl font-semibold text-slate-900">
              {count.count_type === "full" ? "Full count" : "Cycle count"} —{" "}
              {count.store?.name ?? "Store"}
            </h1>
            <span
              className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_CLASS[count.status]}`}
            >
              {STATUS_LABEL[count.status]}
            </span>
          </div>
          <p className="mt-1 text-sm text-slate-500">
            Requested by {count.requester?.name ?? "—"} ·{" "}
            {new Date(count.created_at).toLocaleString()}
            {count.starter && ` · Started by ${count.starter.name}`}
            {count.approver &&
              ` · Approved by ${count.approver.name} ${new Date(count.approved_at!).toLocaleString()}`}
          </p>
        </div>
        <div className="flex items-center gap-2">
          {items.length > 0 && (
            <Link
              href={`/counts/${count.id}/print`}
              target="_blank"
              className="inline-flex items-center gap-2 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
            >
              <Printer className="h-4 w-4" /> Count sheet
            </Link>
          )}
          <Link
            href="/counts"
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            All counts
          </Link>
        </div>
      </div>

      {error && (
        <p className="mb-4 rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>
      )}
      {notice && (
        <p className="mb-4 rounded-md bg-emerald-50 px-3 py-2 text-sm text-emerald-700">
          {notice}
        </p>
      )}

      {count.status === "pending_start_approval" && (
        <div className="mb-4 rounded-md border border-amber-200 bg-amber-50 px-4 py-3">
          <p className="text-sm text-amber-800">
            This count is waiting for an owner or admin to approve it before
            counting can begin.
          </p>
          <div className="mt-3 flex gap-2">
            {isAdmin && (
              <>
                <button
                  type="button"
                  disabled={acting}
                  onClick={() =>
                    run(() => approveCountStart(count.id), "Count approved — counting can begin.")
                  }
                  className="rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                >
                  Approve &amp; start
                </button>
                <button
                  type="button"
                  disabled={acting}
                  onClick={() =>
                    run(() => rejectCountStart(count.id), "Count request rejected.")
                  }
                  className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
                >
                  Reject
                </button>
              </>
            )}
          </div>
        </div>
      )}

      {count.status === "in_progress" && (
        <div className="mb-4 rounded-md border border-blue-200 bg-blue-50 px-4 py-3 text-sm text-blue-800">
          Counting is in progress. Expected quantities are hidden until the
          count is submitted or finalized — count what&apos;s physically there.
        </div>
      )}

      {count.status === "in_progress" && canEnter && (
        <div className="relative mb-4">
          <Search className="absolute left-3 top-2.5 h-4 w-4 text-slate-400" />
          <input
            value={addQuery}
            onChange={(e) => setAddQuery(e.target.value)}
            placeholder="Product not on this list? Search to add it to the count…"
            disabled={addingItem}
            className="w-full rounded-md border border-slate-300 bg-white py-2 pl-9 pr-3 text-sm"
          />
          {addOptions.length > 0 && (
            <div className="absolute z-10 mt-1 max-h-56 w-full overflow-y-auto rounded-md border border-slate-200 bg-white shadow-lg">
              {addOptions.map((p) => {
                const onList = items.some((i) => i.variant_id === p.id);
                return (
                  <button
                    key={p.id}
                    type="button"
                    disabled={addingItem}
                    onClick={() => handleAddItem(p.id)}
                    className="flex w-full items-center justify-between px-3 py-2 text-left text-sm hover:bg-slate-50"
                  >
                    <span>{p.item_name}</span>
                    <span className="text-xs text-slate-400">
                      {p.sku}
                      {onList && " · already on list"}
                    </span>
                  </button>
                );
              })}
            </div>
          )}
        </div>
      )}

      {count.status === "rejected" && (
        <div className="mb-4 rounded-md border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-600">
          This count request was rejected.
        </div>
      )}
      {count.status === "cancelled" && (
        <div className="mb-4 rounded-md border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-600">
          This count was cancelled.
        </div>
      )}

      <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
        <table className="min-w-full divide-y divide-slate-200">
          <thead className="bg-slate-50">
            <tr>
              <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wide text-slate-500">Product</th>
              <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wide text-slate-500">SKU</th>
              {expectedVisible && (
                <th className="px-4 py-3 text-right text-xs font-medium uppercase tracking-wide text-slate-500">Expected</th>
              )}
              <th className="px-4 py-3 text-right text-xs font-medium uppercase tracking-wide text-slate-500">
                {count.status === "in_progress" ? "Counted" : "Submitted"}
              </th>
              <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wide text-slate-500">Counted by</th>
              {count.status === "approved" && (
                <>
                  <th className="px-4 py-3 text-right text-xs font-medium uppercase tracking-wide text-slate-500">Final</th>
                  <th className="px-4 py-3 text-right text-xs font-medium uppercase tracking-wide text-slate-500">Variance</th>
                </>
              )}
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {sortedItems.length === 0 && (
              <tr>
                <td colSpan={7} className="px-4 py-8 text-center text-sm text-slate-500">
                  No items in this count.
                </td>
              </tr>
            )}
            {sortedItems.map((item) => {
              const p = products[item.variant_id];
              const variance =
                item.counted_quantity !== null && item.expected_quantity !== null
                  ? item.counted_quantity - item.expected_quantity
                  : null;
              return (
                <tr key={item.id} id={`count-item-${item.id}`}>
                  <td className="px-4 py-2.5 text-sm font-medium text-slate-900">
                    {p?.item_name ?? item.variant_id}
                    {p?.brand && (
                      <span className="ml-2 text-xs text-slate-400">{p.brand}</span>
                    )}
                  </td>
                  <td className="px-4 py-2.5 text-sm text-slate-500">{p?.sku ?? "—"}</td>
                  {expectedVisible && (
                    <td className="px-4 py-2.5 text-right text-sm text-slate-600">
                      {item.expected_quantity}
                    </td>
                  )}
                  <td className="px-4 py-2.5 text-right">
                    {count.status === "in_progress" && canEnter ? (
                      <input
                        type="number"
                        min={0}
                        value={entries[item.id] ?? ""}
                        onChange={(e) =>
                          setEntries((prev) => ({
                            ...prev,
                            [item.id]: e.target.value,
                          }))
                        }
                        className="w-24 rounded-md border border-slate-300 px-2 py-1 text-right text-sm"
                        placeholder="—"
                      />
                    ) : (
                      <span className="text-sm text-slate-700">
                        {item.submitted_quantity ?? "—"}
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-2.5 text-sm text-slate-500">
                    {item.submitted_by
                      ? (employeeNames[item.submitted_by] ?? "—")
                      : "—"}
                  </td>
                  {count.status === "approved" && (
                    <>
                      <td className="px-4 py-2.5 text-right text-sm font-medium text-slate-900">
                        {item.counted_quantity ?? "—"}
                      </td>
                      <td
                        className={`px-4 py-2.5 text-right text-sm font-medium ${
                          variance === null || variance === 0
                            ? "text-slate-500"
                            : variance > 0
                              ? "text-emerald-700"
                              : "text-red-700"
                        }`}
                      >
                        {variance === null
                          ? "—"
                          : variance > 0
                            ? `+${variance}`
                            : variance}
                      </td>
                    </>
                  )}
                </tr>
              );
            })}
          </tbody>
          {count.status === "approved" && varianceTotal !== null && (
            <tfoot className="border-t border-slate-200 bg-slate-50">
              <tr>
                <td colSpan={expectedVisible ? 6 : 5} className="px-4 py-2.5 text-right text-sm font-medium text-slate-700">
                  Total variance
                </td>
                <td
                  className={`px-4 py-2.5 text-right text-sm font-semibold ${
                    varianceTotal === 0
                      ? "text-slate-600"
                      : varianceTotal > 0
                        ? "text-emerald-700"
                        : "text-red-700"
                  }`}
                >
                  {varianceTotal > 0 ? `+${varianceTotal}` : varianceTotal}
                </td>
              </tr>
            </tfoot>
          )}
        </table>
      </div>

      {(count.status === "in_progress" || count.status === "submitted") && (
        <div className="mt-4 flex items-center justify-between">
          <div className="flex items-center gap-2">
            {count.status === "in_progress" && canEnter && (
              <>
                <button
                  type="button"
                  disabled={acting || dirtyEntries.length === 0 || !entriesValid}
                  onClick={() =>
                    run(
                      () => submitCountQuantities(count.id, dirtyEntries),
                      "Entries saved."
                    )
                  }
                  className="rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                >
                  Save entries{dirtyEntries.length > 0 ? ` (${dirtyEntries.length})` : ""}
                </button>
                <button
                  type="button"
                  disabled={acting}
                  onClick={() =>
                    run(
                      () => submitInventoryCount(count.id),
                      "Count submitted for review."
                    )
                  }
                  className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
                >
                  Submit for review
                </button>
              </>
            )}
            {count.status === "submitted" && canFinalize && (
              <button
                type="button"
                disabled={finalizing}
                onClick={openFinalize}
                className="rounded-md bg-emerald-600 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
              >
                {finalizing ? "Loading…" : "Finalize & approve"}
              </button>
            )}
          </div>
          {canCancel && (
            <button
              type="button"
              disabled={acting}
              onClick={() => {
                if (window.confirm("Cancel this count?")) {
                  run(() => cancelInventoryCount(count.id), "Count cancelled.");
                }
              }}
              className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-red-600 hover:bg-red-50 disabled:opacity-50"
            >
              Cancel count
            </button>
          )}
        </div>
      )}

      {count.status === "pending_start_approval" && canCancel && (
        <div className="mt-4 flex justify-end">
          <button
            type="button"
            disabled={acting}
            onClick={() => {
              if (window.confirm("Cancel this count request?")) {
                run(() => cancelInventoryCount(count.id), "Count cancelled.");
              }
            }}
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-red-600 hover:bg-red-50 disabled:opacity-50"
          >
            Cancel request
          </button>
        </div>
      )}

      {finalizeOpen && (
        <Modal
          onClose={() => setFinalizeOpen(false)}
          overlayClassName="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
          dirty={
            JSON.stringify(finalizeValues) !== JSON.stringify(finalizeBaseline)
          }
          saving={finalizing}
        >
          <div className="max-h-[90vh] w-full max-w-3xl overflow-y-auto rounded-lg bg-white p-6 shadow-xl">
            <h2 className="text-lg font-semibold text-slate-900">
              Finalize &amp; approve count
            </h2>
            <p className="mt-1 text-sm text-slate-500">
              Enter the authoritative counted quantity for every item. Expected
              and submitted values are shown for reference. Confirming sets each
              product&apos;s on-hand inventory to the final count.
            </p>

            <label className="mt-3 flex items-center gap-2 text-sm text-slate-700">
              <input
                type="checkbox"
                checked={hideNoVariance}
                onChange={(e) => setHideNoVariance(e.target.checked)}
              />
              Hide items with no variance
            </label>

            <div className="mt-4 overflow-hidden rounded-lg border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200">
                <thead className="bg-slate-50">
                  <tr>
                    <th className="px-4 py-2.5 text-left text-xs font-medium uppercase tracking-wide text-slate-500">Product</th>
                    <th className="px-4 py-2.5 text-right text-xs font-medium uppercase tracking-wide text-slate-500">Expected</th>
                    <th className="px-4 py-2.5 text-right text-xs font-medium uppercase tracking-wide text-slate-500">Submitted</th>
                    <th className="px-4 py-2.5 text-right text-xs font-medium uppercase tracking-wide text-slate-500">Final count</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {reviewItems
                    .filter((r) => {
                      // Display-only filter — hidden rows keep their value and
                      // are still submitted on approve.
                      if (!hideNoVariance) return true;
                      const v = finalizeValues[r.item_id];
                      return !(
                        v !== undefined &&
                        v !== "" &&
                        Number(v) === r.expected_quantity
                      );
                    })
                    .map((r) => (
                    <tr key={r.item_id}>
                      <td className="px-4 py-2 text-sm font-medium text-slate-900">
                        {r.item_name}
                        {r.sku && (
                          <span className="ml-2 text-xs text-slate-400">{r.sku}</span>
                        )}
                      </td>
                      <td className="px-4 py-2 text-right text-sm text-slate-600">
                        {r.expected_quantity}
                      </td>
                      <td className="px-4 py-2 text-right text-sm text-slate-600">
                        {r.submitted_quantity ?? "—"}
                        {r.submitted_by_name && (
                          <span className="ml-1 text-xs text-slate-400">
                            ({r.submitted_by_name})
                          </span>
                        )}
                      </td>
                      <td className="px-4 py-2 text-right">
                        <input
                          type="number"
                          min={0}
                          value={finalizeValues[r.item_id] ?? ""}
                          onChange={(e) =>
                            setFinalizeValues((prev) => ({
                              ...prev,
                              [r.item_id]: e.target.value,
                            }))
                          }
                          className="w-24 rounded-md border border-slate-300 px-2 py-1 text-right text-sm"
                        />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {finalizeError && (
              <p className="mt-3 rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">
                {finalizeError}
              </p>
            )}

            <div className="mt-4 flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setFinalizeOpen(false)}
                className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Back
              </button>
              <button
                type="button"
                disabled={finalizing || !finalizeComplete}
                onClick={handleFinalize}
                className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
              >
                {finalizing ? "Approving…" : "Approve count"}
              </button>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}
