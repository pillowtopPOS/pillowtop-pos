"use client";

import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, Plus, Trash2, X, GripVertical } from "lucide-react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import Modal from "@/components/Modal";
import { fetchCurrentEmployee, fetchStores, type Employee, type Store } from "@/lib/journeys/queries";
import {
  fetchProductCategories,
  upsertProductCategory,
  deleteProductCategory,
  fetchFinancingTiers,
  saveFinancingTiers,
  fetchAccessoryCategories,
  upsertAccessoryCategory,
  deleteAccessoryCategory,
  fetchAccessoryPins,
  upsertAccessoryPin,
  deleteAccessoryPin,
  fetchAccessoryBundles,
  upsertAccessoryBundle,
  deleteAccessoryBundle,
  fetchBundleComponents,
  saveBundleComponents,
} from "@/lib/financing/queries";
import type {
  ProductCategory,
  FinancingTier,
  AccessoryCategory,
  AccessoryMatchMode,
  AccessoryPin,
  AccessoryBundle,
  AccessoryBundleComponent,
} from "@/lib/financing/types";
import type { Product } from "@/lib/inventory/queries";

type Tab = "tiers" | "categories" | "accessory" | "pins" | "bundles";

export default function FinancingSettings() {
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [tab, setTab] = useState<Tab>("tiers");

  const companyId = useMemo(() => {
    if (!employee?.home_store_id) return null;
    return stores.find((s) => s.id === employee.home_store_id)?.company_id ?? null;
  }, [employee, stores]);

  useEffect(() => {
    fetchCurrentEmployee().then(setEmployee);
    fetchStores().then(setStores);
  }, []);

  if (!companyId) {
    return (
      <main className="min-h-screen bg-slate-50 p-8">
        <p className="text-sm text-slate-500">Loading...</p>
      </main>
    );
  }

  const tabs: { key: Tab; label: string }[] = [
    { key: "tiers", label: "Financing Tiers" },
    { key: "categories", label: "Product Categories" },
    { key: "accessory", label: "Accessory Suggestions" },
    { key: "pins", label: "Pin Management" },
    { key: "bundles", label: "Bundles" },
  ];

  return (
    <main className="min-h-screen bg-slate-50 p-8">
      <div className="mx-auto max-w-4xl">
        <div className="mb-6 flex items-center gap-3">
          <Link href="/settings" className="rounded-md p-1 text-slate-500 hover:bg-slate-100">
            <ArrowLeft className="h-5 w-5" />
          </Link>
          <h1 className="text-2xl font-semibold text-slate-900">Financing &amp; Accessories</h1>
        </div>

        <div className="mb-6 flex flex-wrap gap-2">
          {tabs.map((t) => (
            <button
              key={t.key}
              onClick={() => setTab(t.key)}
              className={`rounded-md px-3 py-1.5 text-sm font-medium ${
                tab === t.key
                  ? "bg-brand-600 text-white"
                  : "border border-slate-300 bg-white text-slate-700 hover:bg-slate-50"
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>

        {tab === "tiers" && <TierBuilder companyId={companyId} />}
        {tab === "categories" && <CategoryManager companyId={companyId} />}
        {tab === "accessory" && <AccessoryCategoryManager companyId={companyId} />}
        {tab === "pins" && <PinManager companyId={companyId} />}
        {tab === "bundles" && <BundleManager companyId={companyId} />}
      </div>
    </main>
  );
}

// ============================================================
// Tier Builder
// ============================================================

const DEFAULT_TERM_LENGTHS = [6, 12, 18, 24, 36, 48, 60, 72];

type DraftTier = {
  key: string;
  upperLimit: string;
  termLengths: number[];
};

function sortDraftTiers(drafts: DraftTier[]) {
  return [...drafts].sort((a, b) => {
    const aLimit = a.upperLimit.trim() === "" ? Number.POSITIVE_INFINITY : Number(a.upperLimit);
    const bLimit = b.upperLimit.trim() === "" ? Number.POSITIVE_INFINITY : Number(b.upperLimit);
    return aLimit - bLimit;
  });
}

function getFullTermSet(drafts: DraftTier[], idx: number): number[] {
  const sorted = sortDraftTiers(drafts);
  const fullSet = new Set<number>();
  for (let i = 0; i <= idx; i++) {
    sorted[i].termLengths.forEach((term) => fullSet.add(term));
  }
  return Array.from(fullSet).sort((a, b) => a - b);
}

function TierBuilder({ companyId }: { companyId: string }) {
  const [drafts, setDrafts] = useState<DraftTier[]>([]);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const sortedDrafts = sortDraftTiers(drafts);
  const termOptions = DEFAULT_TERM_LENGTHS;

  function loadDrafts(tiers: FinancingTier[]) {
    const sorted = [...tiers].sort((a, b) => {
      if (a.max_price === null) return 1;
      if (b.max_price === null) return -1;
      return a.max_price - b.max_price;
    });

    const drafts: DraftTier[] = sorted.map((tier, idx) => {
      const ownTerms = idx === 0
        ? [...tier.term_lengths]
        : tier.term_lengths.filter((term) => !sorted[idx - 1].term_lengths.includes(term));
      return {
        key: tier.id,
        upperLimit: tier.max_price === null ? "" : String(tier.max_price),
        termLengths: ownTerms.sort((a, b) => a - b),
      };
    });

    setDrafts(drafts);
  }

  useEffect(() => {
    fetchFinancingTiers(companyId).then((tiers) => {
      loadDrafts(tiers);
      setLoaded(true);
    });
  }, [companyId]);

  function addTier() {
    setDrafts([
      ...sortedDrafts,
      {
        key: crypto.randomUUID(),
        upperLimit: "",
        termLengths: [],
      },
    ]);
    setError(null);
    setSuccess(false);
  }

  function removeTier(key: string) {
    setDrafts(drafts.filter((draft) => draft.key !== key));
    setError(null);
    setSuccess(false);
  }

  function updateUpperLimit(key: string, upperLimit: string) {
    setDrafts(drafts.map((draft) => (draft.key === key ? { ...draft, upperLimit } : draft)));
    setError(null);
    setSuccess(false);
  }

  function toggleTerm(key: string, term: number) {
    const draftIdx = drafts.findIndex((d) => d.key === key);
    if (draftIdx === -1) return;

    const inheritedTerms = draftIdx === 0 ? [] : getFullTermSet(drafts, draftIdx - 1);
    if (inheritedTerms.includes(term)) return;

    setDrafts(
      drafts.map((draft) => {
        if (draft.key !== key) return draft;
        const termLengths = draft.termLengths.includes(term)
          ? draft.termLengths.filter((length) => length !== term)
          : [...draft.termLengths, term].sort((a, b) => a - b);
        return { ...draft, termLengths };
      })
    );
    setError(null);
    setSuccess(false);
  }

  async function handleSave() {
    setError(null);
    setSuccess(false);

    const orderedDrafts = sortDraftTiers(drafts);
    for (let i = 0; i < orderedDrafts.length - 1; i += 1) {
      const limit = Number(orderedDrafts[i].upperLimit);
      const previousLimit = i === 0 ? 0 : Number(orderedDrafts[i - 1].upperLimit);
      if (orderedDrafts[i].upperLimit.trim() === "" || !Number.isFinite(limit) || limit <= previousLimit) {
        setError("Enter a unique upper limit greater than the tier below it for every tier except the highest tier.");
        return;
      }
    }

    for (let i = 0; i < orderedDrafts.length; i += 1) {
      const fullSet = getFullTermSet(orderedDrafts, i);
      if (fullSet.length === 0) {
        setError("Select at least one term length for every tier.");
        return;
      }
      if (i > 0) {
        const lowerFullSet = getFullTermSet(orderedDrafts, i - 1);
        if (lowerFullSet.some((term) => !fullSet.includes(term))) {
          setError("Each higher tier must include all term lengths from the tier below it.");
          return;
        }
      }
    }

    setSaving(true);
    try {
      const tiers: FinancingTier[] = orderedDrafts.map((draft, i) => ({
        id: "",
        company_id: companyId,
        min_price: i === 0 ? 0 : Number(orderedDrafts[i - 1].upperLimit),
        max_price: i === orderedDrafts.length - 1 ? null : Number(draft.upperLimit),
        term_lengths: getFullTermSet(orderedDrafts, i),
        sort_order: i,
        created_at: "",
      }));

      await saveFinancingTiers(companyId, tiers);
      setSuccess(true);
      loadDrafts(await fetchFinancingTiers(companyId));
    } catch (e: any) {
      const msg = e?.message ?? String(e);
      if (msg.includes("Financing tiers:")) {
        setError(msg.split("Financing tiers:")[1].trim());
      } else {
        setError(msg);
      }
    } finally {
      setSaving(false);
    }
  }

  if (!loaded) return <p className="text-sm text-slate-500">Loading tiers...</p>;

  return (
    <div className="space-y-4">
      <p className="text-sm text-slate-500">
        Build tiers from the lowest price upward. Set where each tier ends and choose its available
        terms; the next tier starts automatically at that same amount.
      </p>

      {sortedDrafts.length === 0 && (
        <p className="text-sm text-slate-400">No tiers configured yet.</p>
      )}

      {sortedDrafts.map((draft, idx) => {
        const isHighestTier = idx === sortedDrafts.length - 1;
        const inheritedTerms = idx === 0 ? [] : getFullTermSet(sortedDrafts, idx - 1);
        const fullTermSet = getFullTermSet(sortedDrafts, idx);
        const startingPrice = idx === 0 ? 0 : Number(sortedDrafts[idx - 1].upperLimit);

        return (
          <div
            key={draft.key}
            className="rounded-lg border border-slate-200 bg-white p-4"
          >
            <div className="flex flex-wrap items-start gap-4">
              <div className="w-48">
                <label className="block text-xs font-medium text-slate-500">
                  {isHighestTier ? "Upper Price Limit" : "Up to ($)"}
                </label>
                {isHighestTier ? (
                  <div className="mt-1 rounded-md border border-slate-200 bg-slate-50 px-3 py-2 text-sm font-medium text-slate-700">
                    No limit (highest tier)
                  </div>
                ) : (
                  <input
                    type="number"
                    min="0.01"
                    step="0.01"
                    value={draft.upperLimit}
                    onChange={(e) => updateUpperLimit(draft.key, e.target.value)}
                    placeholder="e.g. 1500"
                    className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                )}
                <p className="mt-1 text-xs text-slate-400">
                  Starts at ${Number.isFinite(startingPrice) ? startingPrice.toLocaleString() : "—"}
                  {!isHighestTier && "; next tier starts at this amount"}
                </p>
              </div>

              <fieldset className="min-w-0 flex-1">
                <legend className="block text-xs font-medium text-slate-500">Available Terms</legend>
                <div className="mt-2 flex flex-wrap gap-x-4 gap-y-2">
                  {termOptions.map((term) => {
                    const inherited = inheritedTerms.includes(term);
                    return (
                      <label key={term} className="flex items-center gap-2 text-sm text-slate-700">
                        <input
                          type="checkbox"
                          checked={fullTermSet.includes(term)}
                          disabled={inherited}
                          onChange={() => toggleTerm(draft.key, term)}
                          className="h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500 disabled:opacity-60"
                        />
                        {term} months{inherited && <span className="text-xs text-slate-400">(included below)</span>}
                      </label>
                    );
                  })}
                </div>
              </fieldset>

              <button
                onClick={() => removeTier(draft.key)}
                className="rounded-md p-1.5 text-slate-400 hover:bg-red-50 hover:text-red-500"
                title="Remove tier"
              >
                <Trash2 className="h-4 w-4" />
              </button>
            </div>
          </div>
        );
      })}

      <div className="flex items-center gap-3">
        <button
          onClick={addTier}
          className="inline-flex items-center gap-1.5 rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
        >
          <Plus className="h-4 w-4" /> Add Tier
        </button>
        <button
          onClick={handleSave}
          disabled={saving}
          className="inline-flex items-center gap-1.5 rounded-md bg-brand-600 px-4 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
        >
          {saving ? "Saving..." : "Save Tiers"}
        </button>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">
          {error}
        </div>
      )}
      {success && (
        <div className="rounded-md border border-green-200 bg-green-50 px-4 py-3 text-sm text-green-700">
          Tiers saved successfully.
        </div>
      )}
    </div>
  );
}

// ============================================================
// Category Manager (Product Categories)
// ============================================================

function CategoryManager({ companyId }: { companyId: string }) {
  const [categories, setCategories] = useState<ProductCategory[]>([]);
  const [newName, setNewName] = useState("");
  const [editId, setEditId] = useState<string | null>(null);
  const [editName, setEditName] = useState("");
  const [saving, setSaving] = useState(false);
  const [rebindBusy, setRebindBusy] = useState<string | null>(null);
  const [rebindMsg, setRebindMsg] = useState<string | null>(null);

  useEffect(() => {
    loadCategories();
  }, [companyId]);

  async function loadCategories() {
    setCategories(await fetchProductCategories(companyId));
  }

  async function handleAdd() {
    if (!newName.trim()) return;
    setSaving(true);
    try {
      await upsertProductCategory({ company_id: companyId, name: newName.trim() });
      setNewName("");
      await loadCategories();
    } catch (e: any) {
      alert(e.message);
    } finally {
      setSaving(false);
    }
  }

  async function handleUpdate() {
    if (!editId || !editName.trim()) return;
    setSaving(true);
    try {
      await upsertProductCategory({ id: editId, company_id: companyId, name: editName.trim() });
      setEditId(null);
      await loadCategories();
    } catch (e: any) {
      alert(e.message);
    } finally {
      setSaving(false);
    }
  }

  async function handleEligibleChange(cat: ProductCategory, eligible: boolean) {
    try {
      await upsertProductCategory({
        id: cat.id,
        company_id: companyId,
        name: cat.name,
        sleep_trial_eligible: eligible,
      });
      await loadCategories();
    } catch (e: any) {
      alert(e.message);
    }
  }

  async function handleDelete(id: string) {
    if (!confirm("Delete this category? Products using it will become uncategorized.")) return;
    try {
      await deleteProductCategory(id);
      await loadCategories();
    } catch (e: any) {
      alert(e.message);
    }
  }

  async function handleRebind(cat: ProductCategory) {
    setRebindBusy(cat.id);
    setRebindMsg(null);
    try {
      const supabase = createClient();
      const { data, error } = await (supabase as any).rpc("rebind_unbound_sleep_trials", {});
      if (error) throw new Error(error.message);
      setRebindMsg(`Created ${data ?? 0} sleep trial item(s) for past sales.`);
    } catch (e: any) {
      setRebindMsg(`Could not create trials: ${e.message}`);
    } finally {
      setRebindBusy(null);
    }
  }

  return (
    <div className="space-y-4">
      <p className="text-sm text-slate-500">
        Product categories are used to group products for accessory suggestions. Assign categories
        to individual products via the product edit modal on the Inventory page.
      </p>

      <div className="flex items-end gap-2">
        <div className="flex-1">
          <label className="block text-xs font-medium text-slate-500">New Category Name</label>
          <input
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && handleAdd()}
            placeholder="e.g. Pillows, Sheets, Mattress Protectors"
            className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          />
        </div>
        <button
          onClick={handleAdd}
          disabled={saving || !newName.trim()}
          className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
        >
          Add
        </button>
      </div>

      {categories.length === 0 ? (
        <p className="text-sm text-slate-400">No categories yet.</p>
      ) : (
        <ul className="divide-y divide-slate-200 rounded-lg border border-slate-200 bg-white">
          {categories.map((cat) => (
            <li key={cat.id} className="flex items-center justify-between px-4 py-3">
              {editId === cat.id ? (
                <div className="flex flex-1 items-center gap-2">
                  <input
                    value={editName}
                    onChange={(e) => setEditName(e.target.value)}
                    onKeyDown={(e) => e.key === "Enter" && handleUpdate()}
                    className="flex-1 rounded-md border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                  <button onClick={handleUpdate} disabled={saving} className="text-sm font-medium text-brand-600 hover:text-brand-700">Save</button>
                  <button onClick={() => setEditId(null)} className="text-sm text-slate-500 hover:text-slate-700">Cancel</button>
                </div>
              ) : (
                <>
                  <span className="text-sm font-medium text-slate-900">{cat.name}</span>
                  <div className="flex items-center gap-3">
                    <label className="flex items-center gap-1.5 text-xs text-slate-500">
                      <input
                        type="checkbox"
                        checked={cat.sleep_trial_eligible}
                        onChange={(e) => handleEligibleChange(cat, e.target.checked)}
                        className="h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500"
                      />
                      Sleep trial eligible
                    </label>
                    {cat.sleep_trial_eligible && (
                      <button
                        onClick={() => handleRebind(cat)}
                        disabled={rebindBusy === cat.id}
                        className="text-xs text-brand-600 hover:text-brand-700 disabled:opacity-50"
                      >
                        {rebindBusy === cat.id ? "Creating…" : "Create trials for past sales"}
                      </button>
                    )}
                    <button
                      onClick={() => { setEditId(cat.id); setEditName(cat.name); }}
                      className="text-sm text-brand-600 hover:text-brand-700"
                    >
                      Edit
                    </button>
                    <button
                      onClick={() => handleDelete(cat.id)}
                      className="text-sm text-red-500 hover:text-red-700"
                    >
                      Delete
                    </button>
                  </div>
                </>
              )}
            </li>
          ))}
        </ul>
      )}
      {rebindMsg && <p className="text-sm text-slate-500">{rebindMsg}</p>}
    </div>
  );
}

// ============================================================
// Accessory Category Manager
// ============================================================

function AccessoryCategoryManager({ companyId }: { companyId: string }) {
  const [productCats, setProductCats] = useState<ProductCategory[]>([]);
  const [accCats, setAccCats] = useState<AccessoryCategory[]>([]);
  const [saving, setSaving] = useState(false);

  // New form
  const [newCatId, setNewCatId] = useState("");
  const [newMode, setNewMode] = useState<AccessoryMatchMode>("auto_rank");
  const [newQty, setNewQty] = useState("1");

  useEffect(() => {
    load();
  }, [companyId]);

  async function load() {
    const [pc, ac] = await Promise.all([
      fetchProductCategories(companyId),
      fetchAccessoryCategories(companyId),
    ]);
    setProductCats(pc);
    setAccCats(ac);
  }

  async function handleAdd() {
    if (!newCatId) return;
    setSaving(true);
    try {
      await upsertAccessoryCategory({
        company_id: companyId,
        category_id: newCatId,
        match_mode: newMode,
        default_qty: Number(newQty) || 1,
        sort_order: accCats.length,
      });
      setNewCatId("");
      await load();
    } catch (e: any) {
      alert(e.message);
    } finally {
      setSaving(false);
    }
  }

  async function toggleEnabled(ac: AccessoryCategory) {
    await upsertAccessoryCategory({
      ...ac,
      enabled_for_suggestions: !ac.enabled_for_suggestions,
    });
    await load();
  }

  async function updateMode(ac: AccessoryCategory, mode: AccessoryMatchMode) {
    await upsertAccessoryCategory({ ...ac, match_mode: mode });
    await load();
  }

  async function updateQty(ac: AccessoryCategory, qty: number) {
    await upsertAccessoryCategory({ ...ac, default_qty: qty });
    await load();
  }

  async function handleDelete(id: string) {
    if (!confirm("Remove this accessory suggestion category?")) return;
    try {
      await deleteAccessoryCategory(id);
      await load();
    } catch (e: any) {
      alert(e.message);
    }
  }

  return (
    <div className="space-y-4">
      <p className="text-sm text-slate-500">
        Configure which product categories appear as accessory suggestions in the financing
        calculator. Set the match mode and default quantity for each.
      </p>

      <div className="flex flex-wrap items-end gap-2">
        <div>
          <label className="block text-xs font-medium text-slate-500">Product Category</label>
          <select
            value={newCatId}
            onChange={(e) => setNewCatId(e.target.value)}
            className="mt-1 rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          >
            <option value="">Select...</option>
            {productCats.map((c) => (
              <option key={c.id} value={c.id}>{c.name}</option>
            ))}
          </select>
        </div>
        <div>
          <label className="block text-xs font-medium text-slate-500">Match Mode</label>
          <select
            value={newMode}
            onChange={(e) => setNewMode(e.target.value as AccessoryMatchMode)}
            className="mt-1 rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          >
            <option value="auto_rank">Auto Rank</option>
            <option value="manual_pin">Manual Pin</option>
            <option value="show_all">Show All</option>
          </select>
        </div>
        <div className="w-20">
          <label className="block text-xs font-medium text-slate-500">Default Qty</label>
          <input
            type="number"
            min="1"
            value={newQty}
            onChange={(e) => setNewQty(e.target.value)}
            className="mt-1 w-full rounded-md border border-slate-300 px-2 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          />
        </div>
        <button
          onClick={handleAdd}
          disabled={saving || !newCatId}
          className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
        >
          Add
        </button>
      </div>

      {accCats.length === 0 ? (
        <p className="text-sm text-slate-400">No accessory categories configured.</p>
      ) : (
        <div className="space-y-2">
          {accCats.map((ac) => (
            <div key={ac.id} className="flex flex-wrap items-center gap-3 rounded-lg border border-slate-200 bg-white px-4 py-3">
              <span className="min-w-[120px] text-sm font-medium text-slate-900">
                {ac.category_name}
              </span>
              <label className="flex items-center gap-1.5 text-sm text-slate-600">
                <input
                  type="checkbox"
                  checked={ac.enabled_for_suggestions}
                  onChange={() => toggleEnabled(ac)}
                  className="rounded border-slate-300"
                />
                Enabled
              </label>
              <select
                value={ac.match_mode}
                onChange={(e) => updateMode(ac, e.target.value as AccessoryMatchMode)}
                className="rounded-md border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              >
                <option value="auto_rank">Auto Rank</option>
                <option value="manual_pin">Manual Pin</option>
                <option value="show_all">Show All</option>
              </select>
              <div className="flex items-center gap-1">
                <label className="text-xs text-slate-500">Qty:</label>
                <input
                  type="number"
                  min="1"
                  value={ac.default_qty}
                  onChange={(e) => updateQty(ac, Number(e.target.value) || 1)}
                  className="w-16 rounded-md border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                />
              </div>
              <button
                onClick={() => handleDelete(ac.id)}
                className="ml-auto rounded-md p-1 text-slate-400 hover:bg-red-50 hover:text-red-500"
              >
                <Trash2 className="h-4 w-4" />
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// ============================================================
// Pin Manager
// ============================================================

function PinManager({ companyId }: { companyId: string }) {
  const [accCats, setAccCats] = useState<AccessoryCategory[]>([]);
  const [tiers, setTiers] = useState<FinancingTier[]>([]);
  const [pins, setPins] = useState<AccessoryPin[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    load();
  }, [companyId]);

  async function load() {
    const [ac, ft, ap] = await Promise.all([
      fetchAccessoryCategories(companyId),
      fetchFinancingTiers(companyId),
      fetchAccessoryPins(companyId),
    ]);
    // Only show manual_pin categories
    setAccCats(ac.filter((c) => c.match_mode === "manual_pin"));
    setTiers(ft);
    setPins(ap);

    // Load products for pin categories
    const catIds = ac.filter((c) => c.match_mode === "manual_pin").map((c) => c.category_id);
    if (catIds.length > 0) {
      const supabase = createClient();
      const { data } = await (supabase as any)
        .from("products")
        .select("id, item_name, price, category_id, company_id")
        .eq("company_id", companyId)
        .in("category_id", catIds)
        .order("item_name");
      setProducts((data ?? []) as Product[]);
    }
  }

  function getPinProduct(accCatId: string, tierId: string): string {
    const pin = pins.find(
      (p) => p.accessory_category_id === accCatId && p.financing_tier_id === tierId
    );
    return pin?.product_id ?? "";
  }

  async function handlePinChange(accCatId: string, tierId: string, productId: string) {
    setSaving(true);
    try {
      if (!productId) {
        const pin = pins.find(
          (p) => p.accessory_category_id === accCatId && p.financing_tier_id === tierId
        );
        if (pin) await deleteAccessoryPin(pin.id);
      } else {
        await upsertAccessoryPin({
          company_id: companyId,
          accessory_category_id: accCatId,
          financing_tier_id: tierId,
          product_id: productId,
        });
      }
      const fresh = await fetchAccessoryPins(companyId);
      setPins(fresh);
    } catch (e: any) {
      alert(e.message);
    } finally {
      setSaving(false);
    }
  }

  if (accCats.length === 0) {
    return (
      <div className="space-y-2">
        <p className="text-sm text-slate-500">
          Pin management is for accessory categories with &ldquo;Manual Pin&rdquo; match mode.
        </p>
        <p className="text-sm text-slate-400">
          No manual-pin accessory categories configured. Change a category&apos;s match mode to
          &ldquo;Manual Pin&rdquo; in the Accessory Suggestions tab first.
        </p>
      </div>
    );
  }

  if (tiers.length === 0) {
    return (
      <p className="text-sm text-slate-400">
        Configure financing tiers first before setting up pins.
      </p>
    );
  }

  return (
    <div className="space-y-6">
      <p className="text-sm text-slate-500">
        For each manual-pin accessory category, select which product to suggest at each financing
        tier.
      </p>

      {accCats.map((ac) => {
        const catProducts = products.filter((p) => p.category_id === ac.category_id);
        return (
          <div key={ac.id} className="space-y-2">
            <h3 className="text-sm font-semibold text-slate-900">{ac.category_name}</h3>
            <div className="rounded-lg border border-slate-200 bg-white divide-y divide-slate-100">
              {tiers.map((tier, idx) => (
                <div key={tier.id} className="flex items-center gap-3 px-4 py-2.5">
                  <span className="w-40 text-sm text-slate-600">
                    ${tier.min_price} &ndash; {tier.max_price === null ? "∞" : `$${tier.max_price}`}
                  </span>
                  <select
                    value={getPinProduct(ac.id, tier.id)}
                    onChange={(e) => handlePinChange(ac.id, tier.id, e.target.value)}
                    disabled={saving}
                    className="flex-1 rounded-md border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500 disabled:opacity-50"
                  >
                    <option value="">-- none --</option>
                    {catProducts.map((p) => (
                      <option key={p.id} value={p.id}>
                        {p.item_name} {p.price !== null ? `($${p.price})` : ""}
                      </option>
                    ))}
                  </select>
                </div>
              ))}
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ============================================================
// Bundle Manager
// ============================================================

function BundleManager({ companyId }: { companyId: string }) {
  const [bundles, setBundles] = useState<AccessoryBundle[]>([]);
  const [accCats, setAccCats] = useState<AccessoryCategory[]>([]);
  const [newName, setNewName] = useState("");
  const [saving, setSaving] = useState(false);
  const [editBundle, setEditBundle] = useState<string | null>(null);
  const [bundleComps, setBundleComps] = useState<string[]>([]);
  const [initialBundleComps, setInitialBundleComps] = useState<string[]>([]);

  useEffect(() => {
    load();
  }, [companyId]);

  async function load() {
    const [b, ac] = await Promise.all([
      fetchAccessoryBundles(companyId),
      fetchAccessoryCategories(companyId),
    ]);
    setBundles(b);
    setAccCats(ac);
  }

  async function handleAdd() {
    if (!newName.trim()) return;
    setSaving(true);
    try {
      await upsertAccessoryBundle({ company_id: companyId, name: newName.trim() });
      setNewName("");
      await load();
    } catch (e: any) {
      alert(e.message);
    } finally {
      setSaving(false);
    }
  }

  async function handleDelete(id: string) {
    if (!confirm("Delete this bundle?")) return;
    try {
      await deleteAccessoryBundle(id);
      await load();
    } catch (e: any) {
      alert(e.message);
    }
  }

  async function openEdit(bundleId: string) {
    setEditBundle(bundleId);
    const comps = await fetchBundleComponents(bundleId);
    const ids = comps.map((c) => c.accessory_category_id);
    setBundleComps(ids);
    setInitialBundleComps(ids);
  }

  async function saveComps() {
    if (!editBundle) return;
    setSaving(true);
    try {
      await saveBundleComponents(editBundle, bundleComps);
      setEditBundle(null);
    } catch (e: any) {
      alert(e.message);
    } finally {
      setSaving(false);
    }
  }

  function toggleComp(catId: string) {
    setBundleComps((prev) =>
      prev.includes(catId) ? prev.filter((c) => c !== catId) : [...prev, catId]
    );
  }

  return (
    <div className="space-y-4">
      <p className="text-sm text-slate-500">
        Bundles combine multiple accessory categories into a named group shown together in the
        calculator.
      </p>

      <div className="flex items-end gap-2">
        <div className="flex-1">
          <label className="block text-xs font-medium text-slate-500">Bundle Name</label>
          <input
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && handleAdd()}
            placeholder="e.g. Complete Sleep Package"
            className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          />
        </div>
        <button
          onClick={handleAdd}
          disabled={saving || !newName.trim()}
          className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
        >
          Add
        </button>
      </div>

      {bundles.length === 0 ? (
        <p className="text-sm text-slate-400">No bundles created yet.</p>
      ) : (
        <ul className="divide-y divide-slate-200 rounded-lg border border-slate-200 bg-white">
          {bundles.map((b) => (
            <li key={b.id} className="flex items-center justify-between px-4 py-3">
              <span className="text-sm font-medium text-slate-900">{b.name}</span>
              <div className="flex items-center gap-2">
                <button
                  onClick={() => openEdit(b.id)}
                  className="text-sm text-brand-600 hover:text-brand-700"
                >
                  Edit Components
                </button>
                <button
                  onClick={() => handleDelete(b.id)}
                  className="text-sm text-red-500 hover:text-red-700"
                >
                  Delete
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}

      {editBundle && (
        <Modal
          onClose={() => setEditBundle(null)}
          dirty={
            JSON.stringify([...bundleComps].sort()) !==
            JSON.stringify([...initialBundleComps].sort())
          }
          saving={saving}
        >
          <div className="max-h-[90vh] w-full max-w-md overflow-y-auto rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <div className="mb-4 flex items-center justify-between">
              <h2 className="text-lg font-semibold text-slate-900">Bundle Components</h2>
              <button
                onClick={() => setEditBundle(null)}
                className="rounded-md p-1 text-slate-500 hover:bg-slate-100"
              >
                <X className="h-5 w-5" />
              </button>
            </div>
            <p className="mb-3 text-sm text-slate-500">
              Select which accessory categories are included in this bundle.
            </p>
            {accCats.length === 0 ? (
              <p className="text-sm text-slate-400">No accessory categories available.</p>
            ) : (
              <div className="space-y-2">
                {accCats.map((ac) => (
                  <label key={ac.id} className="flex items-center gap-2 text-sm text-slate-700">
                    <input
                      type="checkbox"
                      checked={bundleComps.includes(ac.id)}
                      onChange={() => toggleComp(ac.id)}
                      className="rounded border-slate-300"
                    />
                    {ac.category_name}
                  </label>
                ))}
              </div>
            )}
            <div className="mt-4 flex gap-2">
              <button
                onClick={saveComps}
                disabled={saving}
                className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
              >
                Save
              </button>
              <button
                onClick={() => setEditBundle(null)}
                className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}
