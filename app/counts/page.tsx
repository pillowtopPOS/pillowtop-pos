"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { Plus, Search, X, ClipboardList } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import {
  fetchCurrentEmployee,
  fetchStores,
  type Employee,
  type Store,
} from "@/lib/journeys/queries";
import { isStoreConfirmedToday } from "@/lib/journeys/storeConfirm";
import { searchProducts, type Product } from "@/lib/inventory/queries";
import { fetchProductCategories } from "@/lib/financing/queries";
import Modal from "@/components/Modal";
import type { ProductCategory } from "@/lib/financing/types";
import {
  fetchCounts,
  createInventoryCount,
  suggestCountItems,
  type InventoryCount,
  type CountType,
  type CycleSuggestion,
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

const ACTIVE_STATUSES = ["pending_start_approval", "in_progress", "submitted"];

export default function CountsPage() {
  const router = useRouter();
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [counts, setCounts] = useState<InventoryCount[]>([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState("");
  const [activeStoreId, setActiveStoreId] = useState<string | null>(null);
  const [storeConfirmedToday, setStoreConfirmedToday] = useState(false);

  const [createOpen, setCreateOpen] = useState(false);
  const [formStoreId, setFormStoreId] = useState("");
  const [formType, setFormType] = useState<CountType>("full");
  const [productQuery, setProductQuery] = useState("");
  const [productOptions, setProductOptions] = useState<Product[]>([]);
  const [selected, setSelected] = useState<
    { variant_id: string; item_name: string; sku: string | null }[]
  >([]);
  const [categories, setCategories] = useState<ProductCategory[]>([]);
  const [allProducts, setAllProducts] = useState<Product[]>([]);
  const [suggestions, setSuggestions] = useState<CycleSuggestion[] | null>(null);
  const [suggestionProducts, setSuggestionProducts] = useState<
    Record<string, Product>
  >({});
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);

  const isAdmin = employee?.role === "owner" || employee?.role === "admin";

  // Owner/admin may count any store. Managers start counts directly at their
  // home store or wherever they're checked in today. Everyone else creates a
  // request for the store they're checked into today (same daily check-in as
  // count entry/Confirm Receipt).
  const storeOptions = useMemo(() => {
    const active = stores.filter((s) => s.is_active);
    if (isAdmin) return active;
    if (employee?.role === "manager") {
      return active.filter(
        (s) =>
          s.id === employee.home_store_id ||
          (storeConfirmedToday && s.id === activeStoreId)
      );
    }
    if (!storeConfirmedToday || !activeStoreId) return [];
    return active.filter((s) => s.id === activeStoreId);
  }, [stores, isAdmin, employee, activeStoreId, storeConfirmedToday]);

  const storeHasActiveCount = useMemo(
    () =>
      formStoreId
        ? counts.some(
            (c) => c.store_id === formStoreId && ACTIVE_STATUSES.includes(c.status)
          )
        : false,
    [counts, formStoreId]
  );

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(async ({ data: { session } }) => {
      if (!session?.user) {
        router.push("/login");
        return;
      }
      setActiveStoreId(session.user.user_metadata?.active_store_id ?? null);
      setStoreConfirmedToday(isStoreConfirmedToday(session.user));
      const [e, s, c] = await Promise.all([
        fetchCurrentEmployee(),
        fetchStores(),
        fetchCounts(),
      ]);
      setEmployee(e);
      setStores(s);
      setCounts(c);
      setLoading(false);
    });
  }, [router]);

  // Product search for the cycle picker.
  useEffect(() => {
    const q = productQuery.trim();
    if (!q) {
      setProductOptions([]);
      return;
    }
    const t = setTimeout(() => {
      searchProducts(q).then(setProductOptions);
    }, 200);
    return () => clearTimeout(t);
  }, [productQuery]);

  // Load categories + full product list when a cycle count is being scoped.
  useEffect(() => {
    if (!createOpen || formType !== "cycle" || !formStoreId) return;
    const store = stores.find((s) => s.id === formStoreId);
    if (!store) return;
    fetchProductCategories(store.company_id).then(setCategories);
    const supabase = createClient();
    supabase
      .from("products_public")
      .select("*")
      .order("item_name")
      .then(({ data }) => setAllProducts((data as unknown as Product[]) ?? []));
  }, [createOpen, formType, formStoreId, stores]);

  function openCreate() {
    setFormStoreId(storeOptions[0]?.id ?? "");
    setFormType("full");
    setSelected([]);
    setProductQuery("");
    setSuggestions(null);
    setCreateError(null);
    setCreateOpen(true);
  }

  function addProduct(p: Product) {
    if (selected.some((s) => s.variant_id === p.id)) return;
    setSelected((prev) => [
      ...prev,
      { variant_id: p.id, item_name: p.item_name, sku: p.sku ?? null },
    ]);
    setProductQuery("");
    setProductOptions([]);
  }

  function addCategory(categoryId: string) {
    const inCategory = allProducts.filter((p) => p.category_id === categoryId);
    setSelected((prev) => {
      const have = new Set(prev.map((s) => s.variant_id));
      return [
        ...prev,
        ...inCategory
          .filter((p) => !have.has(p.id))
          .map((p) => ({
            variant_id: p.id,
            item_name: p.item_name,
            sku: p.sku ?? null,
          })),
      ];
    });
  }

  async function loadSuggestions() {
    if (!formStoreId) return;
    setCreateError(null);
    let list: CycleSuggestion[];
    try {
      list = await suggestCountItems(formStoreId, 25);
    } catch (err) {
      setCreateError(
        err instanceof Error ? err.message : "Failed to load suggestions"
      );
      return;
    }
    setSuggestions(list);
    const missing = list
      .map((s) => s.variant_id)
      .filter((id) => !allProducts.some((p) => p.id === id));
    if (missing.length > 0) {
      const supabase = createClient();
      const { data } = await supabase
        .from("products_public")
        .select("*")
        .in("id", missing);
      const map: Record<string, Product> = {};
      for (const p of (data as unknown as Product[]) ?? []) map[p.id] = p;
      setSuggestionProducts(map);
    }
  }

  function suggestionProduct(id: string): Product | undefined {
    return (
      allProducts.find((p) => p.id === id) ?? suggestionProducts[id]
    );
  }

  async function handleCreate() {
    if (!formStoreId) {
      setCreateError("Choose a store to count.");
      return;
    }
    if (formType === "cycle" && selected.length === 0) {
      setCreateError("Pick at least one product for a cycle count.");
      return;
    }
    setCreating(true);
    setCreateError(null);
    try {
      const id = await createInventoryCount(
        formStoreId,
        formType,
        formType === "cycle" ? selected.map((s) => s.variant_id) : undefined
      );
      router.push(`/counts/${id}`);
    } catch (err) {
      setCreateError(err instanceof Error ? err.message : "Failed to create count");
      setCreating(false);
    }
  }

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <p className="text-sm text-slate-500">Loading…</p>
      </div>
    );
  }

  const filtered = statusFilter
    ? counts.filter((c) => c.status === statusFilter)
    : counts;

  return (
    <div className="mx-auto max-w-6xl p-6">
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold text-slate-900">
            Inventory Counts
          </h1>
          <p className="mt-1 text-sm text-slate-500">
            Blind physical counts — full or cycle — reconciled against the system.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={openCreate}
            className="inline-flex items-center gap-2 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700"
          >
            <Plus className="h-4 w-4" /> New Count
          </button>
          <Link
            href="/inventory"
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            Back to Inventory
          </Link>
        </div>
      </div>

      <div className="mb-4 flex items-center gap-2">
        <select
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value)}
          className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm"
        >
          <option value="">All statuses</option>
          {Object.entries(STATUS_LABEL).map(([v, l]) => (
            <option key={v} value={v}>
              {l}
            </option>
          ))}
        </select>
      </div>

      <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
        <table className="min-w-full divide-y divide-slate-200">
          <thead className="bg-slate-50">
            <tr>
              <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wide text-slate-500">Ref</th>
              <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wide text-slate-500">Store</th>
              <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wide text-slate-500">Type</th>
              <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wide text-slate-500">Status</th>
              <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wide text-slate-500">Requested by</th>
              <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wide text-slate-500">Created</th>
              <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wide text-slate-500">Approved by</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {filtered.length === 0 && (
              <tr>
                <td colSpan={7} className="px-4 py-8 text-center text-sm text-slate-500">
                  No counts yet.
                </td>
              </tr>
            )}
            {filtered.map((c) => (
              <tr
                key={c.id}
                onClick={() => router.push(`/counts/${c.id}`)}
                className="cursor-pointer hover:bg-slate-50"
              >
                <td className="px-4 py-3 text-sm font-medium text-brand-700">
                  {c.reference_code ?? "—"}
                </td>
                <td className="px-4 py-3 text-sm font-medium text-slate-900">
                  {c.store?.name ?? "—"}
                </td>
                <td className="px-4 py-3 text-sm text-slate-600 capitalize">
                  {c.count_type}
                </td>
                <td className="px-4 py-3">
                  <span
                    className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_CLASS[c.status] ?? "bg-slate-100 text-slate-600"}`}
                  >
                    {STATUS_LABEL[c.status] ?? c.status}
                  </span>
                </td>
                <td className="px-4 py-3 text-sm text-slate-600">
                  {c.requester?.name ?? "—"}
                </td>
                <td className="px-4 py-3 text-sm text-slate-600">
                  {new Date(c.created_at).toLocaleDateString()}
                </td>
                <td className="px-4 py-3 text-sm text-slate-600">
                  {c.approver?.name ?? "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {createOpen && (
        <Modal
          onClose={() => setCreateOpen(false)}
          overlayClassName="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
          dirty={
            formType !== "full" ||
            selected.length > 0 ||
            productQuery.trim() !== "" ||
            formStoreId !== (storeOptions[0]?.id ?? "")
          }
          saving={creating}
        >
          <div className="max-h-[90vh] w-full max-w-2xl overflow-y-auto rounded-lg bg-white p-6 shadow-xl">
            <div className="mb-4 flex items-center justify-between">
              <h2 className="text-lg font-semibold text-slate-900">
                New Inventory Count
              </h2>
              <button
                type="button"
                onClick={() => setCreateOpen(false)}
                className="rounded p-1 text-slate-500 hover:bg-slate-100"
              >
                <X className="h-5 w-5" />
              </button>
            </div>

            <div className="space-y-4">
              <div>
                <label className="mb-1 block text-sm font-medium text-slate-700">
                  Store
                </label>
                <select
                  value={formStoreId}
                  onChange={(e) => setFormStoreId(e.target.value)}
                  className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                >
                  {storeOptions.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.name}
                    </option>
                  ))}
                </select>
                {storeOptions.length === 0 && (
                  <p className="mt-1 text-xs text-amber-700">
                    Check in at a store first — count requests are made for the
                    store you&apos;re working at today.
                  </p>
                )}
                {storeHasActiveCount && (
                  <p className="mt-1 text-xs text-amber-700">
                    This store already has an active count — finish or cancel it
                    before starting another.
                  </p>
                )}
              </div>

              <div>
                <label className="mb-1 block text-sm font-medium text-slate-700">
                  Count type
                </label>
                <div className="flex gap-4">
                  <label className="flex items-center gap-2 text-sm text-slate-700">
                    <input
                      type="radio"
                      checked={formType === "full"}
                      onChange={() => setFormType("full")}
                    />
                    Full — everything with a footprint at this store
                  </label>
                  <label className="flex items-center gap-2 text-sm text-slate-700">
                    <input
                      type="radio"
                      checked={formType === "cycle"}
                      onChange={() => setFormType("cycle")}
                    />
                    Cycle — selected products
                  </label>
                </div>
              </div>

              {formType === "cycle" && (
                <div className="space-y-3 rounded-md border border-slate-200 p-3">
                  <div className="relative">
                    <Search className="absolute left-3 top-2.5 h-4 w-4 text-slate-400" />
                    <input
                      value={productQuery}
                      onChange={(e) => setProductQuery(e.target.value)}
                      placeholder="Search products to add…"
                      className="w-full rounded-md border border-slate-300 py-2 pl-9 pr-3 text-sm"
                    />
                    {productOptions.length > 0 && (
                      <div className="absolute z-10 mt-1 max-h-56 w-full overflow-y-auto rounded-md border border-slate-200 bg-white shadow-lg">
                        {productOptions.map((p) => (
                          <button
                            key={p.id}
                            type="button"
                            onClick={() => addProduct(p)}
                            className="flex w-full items-center justify-between px-3 py-2 text-left text-sm hover:bg-slate-50"
                          >
                            <span>{p.item_name}</span>
                            <span className="text-xs text-slate-400">{p.sku}</span>
                          </button>
                        ))}
                      </div>
                    )}
                  </div>

                  <div className="flex items-center gap-2">
                    <select
                      defaultValue=""
                      onChange={(e) => {
                        if (e.target.value) addCategory(e.target.value);
                        e.target.value = "";
                      }}
                      className="rounded-md border border-slate-300 px-3 py-2 text-sm"
                    >
                      <option value="">Add a whole category…</option>
                      {categories.map((c) => (
                        <option key={c.id} value={c.id}>
                          {c.name}
                        </option>
                      ))}
                    </select>
                    <button
                      type="button"
                      onClick={loadSuggestions}
                      className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                    >
                      Suggest items
                    </button>
                  </div>

                  {suggestions && (
                    <div className="rounded-md bg-slate-50 p-2">
                      <p className="mb-1 px-1 text-xs font-medium uppercase text-slate-500">
                        Least recently counted
                      </p>
                      <div className="max-h-40 space-y-1 overflow-y-auto">
                        {suggestions.length === 0 && (
                          <p className="px-1 text-sm text-slate-500">
                            No suggestions.
                          </p>
                        )}
                        {suggestions.map((s) => {
                          const p = suggestionProduct(s.variant_id);
                          const already = selected.some(
                            (x) => x.variant_id === s.variant_id
                          );
                          return (
                            <div
                              key={s.variant_id}
                              className="flex items-center justify-between rounded px-1 py-1 text-sm"
                            >
                              <span className="text-slate-700">
                                {p?.item_name ?? s.variant_id}
                                <span className="ml-2 text-xs text-slate-400">
                                  {s.last_counted_at
                                    ? `last counted ${new Date(s.last_counted_at).toLocaleDateString()}`
                                    : "never counted"}
                                </span>
                              </span>
                              <button
                                type="button"
                                disabled={already}
                                onClick={() =>
                                  p
                                    ? addProduct(p)
                                    : setSelected((prev) => [
                                        ...prev,
                                        {
                                          variant_id: s.variant_id,
                                          item_name: s.variant_id,
                                          sku: null,
                                        },
                                      ])
                                }
                                className="text-xs font-medium text-brand-600 hover:text-brand-700 disabled:text-slate-300"
                              >
                                {already ? "Added" : "Add"}
                              </button>
                            </div>
                          );
                        })}
                      </div>
                    </div>
                  )}

                  {selected.length > 0 && (
                    <div>
                      <p className="mb-1 text-xs font-medium uppercase text-slate-500">
                        Selected ({selected.length})
                      </p>
                      <div className="max-h-40 space-y-1 overflow-y-auto">
                        {selected.map((s) => (
                          <div
                            key={s.variant_id}
                            className="flex items-center justify-between rounded bg-slate-50 px-2 py-1 text-sm"
                          >
                            <span className="text-slate-700">
                              {s.item_name}
                              {s.sku && (
                                <span className="ml-2 text-xs text-slate-400">
                                  {s.sku}
                                </span>
                              )}
                            </span>
                            <button
                              type="button"
                              onClick={() =>
                                setSelected((prev) =>
                                  prev.filter(
                                    (x) => x.variant_id !== s.variant_id
                                  )
                                )
                              }
                              className="text-slate-400 hover:text-slate-600"
                            >
                              <X className="h-4 w-4" />
                            </button>
                          </div>
                        ))}
                      </div>
                    </div>
                  )}
                </div>
              )}

              {!isAdmin && employee?.role !== "manager" && (
                <p className="rounded-md bg-amber-50 px-3 py-2 text-xs text-amber-800">
                  This will create a count request — an owner or admin must
                  approve it before counting can begin.
                </p>
              )}

              {createError && (
                <p className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">
                  {createError}
                </p>
              )}

              <div className="flex justify-end gap-2">
                <button
                  type="button"
                  onClick={() => setCreateOpen(false)}
                  className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                >
                  Cancel
                </button>
                <button
                  type="button"
                  disabled={creating || storeHasActiveCount || !formStoreId}
                  onClick={handleCreate}
                  className="inline-flex items-center gap-2 rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                >
                  <ClipboardList className="h-4 w-4" />
                  {creating
                    ? "Creating…"
                    : isAdmin || employee?.role === "manager"
                      ? "Start count"
                      : "Request count"}
                </button>
              </div>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}
