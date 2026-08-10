"use client";

import { useEffect, useMemo, useState } from "react";
import {
  Plus,
  Pencil,
  Power,
  RotateCcw,
  X,
} from "lucide-react";
import {
  fetchCurrentEmployee,
  fetchStores,
  createStore,
  updateStore,
  countActiveJourneysForStore,
  type Store,
  type Employee,
} from "@/lib/journeys/queries";

const emptyStore: Partial<Store> = {
  name: "",
  street_address: "",
  city: "",
  state: "",
  zip_code: "",
  phone: "",
  is_active: true,
};

export default function StoreManagement() {
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [isOpen, setIsOpen] = useState(false);
  const [form, setForm] = useState<Partial<Store>>(emptyStore);
  const [confirm, setConfirm] = useState<{
    store: Store;
    activeJourneys: number;
    reactivate: boolean;
  } | null>(null);

  const isAdmin =
    employee?.role === "owner" || employee?.role === "admin";

  const sortedStores = useMemo(() => {
    return [...stores].sort((a, b) => {
      if (a.is_active === b.is_active) {
        return a.name.localeCompare(b.name);
      }
      return a.is_active ? -1 : 1;
    });
  }, [stores]);

  useEffect(() => {
    Promise.all([fetchCurrentEmployee(), fetchStores()]).then(([emp, s]) => {
      setEmployee(emp);
      setStores(s);
      setLoading(false);
    });
  }, []);

  function openNew() {
    setForm({ ...emptyStore });
    setIsOpen(true);
  }

  function openEdit(store: Store) {
    setForm({ ...store });
    setIsOpen(true);
  }

  function closeModal() {
    setIsOpen(false);
    setForm(emptyStore);
  }

  async function handleSave() {
    if (!form.name?.trim()) return;
    setSaving(true);

    try {
      if (form.id) {
        await updateStore(form.id, {
          name: form.name,
          street_address: form.street_address,
          city: form.city,
          state: form.state,
          zip_code: form.zip_code,
          phone: form.phone,
          is_active: form.is_active,
        });
        setStores((prev) =>
          prev.map((s) =>
            s.id === form.id
              ? ({ ...s, ...form } as Store)
              : s
          )
        );
      } else {
        const companyId = stores[0]?.company_id;
        if (!companyId) return;
        const id = await createStore({
          company_id: companyId,
          name: form.name,
          street_address: form.street_address,
          city: form.city,
          state: form.state,
          zip_code: form.zip_code,
          phone: form.phone,
          is_active: form.is_active,
        });
        if (id) {
          const fresh = await fetchStores();
          setStores(fresh);
        }
      }
      closeModal();
    } catch (err) {
      console.error(err);
      alert(err instanceof Error ? err.message : "Save failed");
    } finally {
      setSaving(false);
    }
  }

  async function promptToggle(store: Store) {
    const activeJourneys = store.is_active
      ? await countActiveJourneysForStore(store.id)
      : 0;
    setConfirm({
      store,
      activeJourneys,
      reactivate: !store.is_active,
    });
  }

  async function handleToggle() {
    if (!confirm) return;
    setSaving(true);
    const { store, reactivate } = confirm;

    try {
      await updateStore(store.id, { is_active: reactivate });
      setStores((prev) =>
        prev.map((s) =>
          s.id === store.id ? { ...s, is_active: reactivate } : s
        )
      );
      setConfirm(null);
    } catch (err) {
      console.error(err);
      alert(err instanceof Error ? err.message : "Toggle failed");
    } finally {
      setSaving(false);
    }
  }

  function formatAddress(s: Store) {
    const parts = [
      s.street_address,
      [s.city, s.state, s.zip_code].filter(Boolean).join(", ") || null,
    ].filter(Boolean);
    return parts.length ? parts.join(" • ") : null;
  }

  if (loading) {
    return (
      <main className="min-h-screen bg-slate-50 p-8">
        <div className="mx-auto max-w-4xl text-center text-slate-500">
          Loading stores…
        </div>
      </main>
    );
  }

  if (!isAdmin) {
    return (
      <main className="min-h-screen bg-slate-50 p-8">
        <div className="mx-auto max-w-4xl text-center text-slate-600">
          You don't have permission to manage stores.
        </div>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-slate-50 p-8">
      <div className="mx-auto max-w-4xl">
        <div className="mb-6 flex items-center justify-between">
          <h1 className="text-2xl font-semibold text-slate-900">
            Store Management
          </h1>
          <button
            onClick={openNew}
            className="flex items-center gap-2 rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700"
          >
            <Plus className="h-4 w-4" />
            Add Store
          </button>
        </div>

        <div className="space-y-3">
          {sortedStores.map((s) => (
            <div
              key={s.id}
              className={`rounded-lg border bg-white p-4 shadow-sm transition ${
                s.is_active
                  ? "border-slate-200"
                  : "border-slate-200 bg-slate-100 opacity-75"
              }`}
            >
              <div className="flex items-start justify-between">
                <div>
                  <div className="flex items-center gap-2">
                    <h2 className="text-lg font-semibold text-slate-900">
                      {s.name}
                    </h2>
                    {!s.is_active && (
                      <span className="rounded-full bg-slate-200 px-2 py-0.5 text-xs font-medium text-slate-600">
                        Inactive
                      </span>
                    )}
                  </div>
                  <p className="mt-1 text-sm text-slate-500">
                    {s.phone ? `${s.phone} • ` : null}
                    {formatAddress(s) ?? "No address on file"}
                  </p>
                </div>
                <div className="flex items-center gap-2">
                  <button
                    onClick={() => openEdit(s)}
                    className="rounded p-2 text-slate-500 hover:bg-slate-100"
                    aria-label="Edit"
                  >
                    <Pencil className="h-4 w-4" />
                  </button>
                  {s.is_active ? (
                    <button
                      onClick={() => promptToggle(s)}
                      className="rounded p-2 text-slate-500 hover:bg-amber-100 hover:text-amber-600"
                      aria-label="Deactivate"
                    >
                      <Power className="h-4 w-4" />
                    </button>
                  ) : (
                    <button
                      onClick={() => promptToggle(s)}
                      className="rounded p-2 text-slate-500 hover:bg-emerald-100 hover:text-emerald-600"
                      aria-label="Reactivate"
                    >
                      <RotateCcw className="h-4 w-4" />
                    </button>
                  )}
                </div>
              </div>
            </div>
          ))}

          {stores.length === 0 && (
            <p className="text-center text-slate-500">
              No stores found.
            </p>
          )}
        </div>
      </div>

      {isOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-md rounded-lg bg-white p-6 shadow-lg">
            <div className="mb-4 flex items-center justify-between">
              <h2 className="text-lg font-semibold text-slate-900">
                {form.id ? "Edit Store" : "Add Store"}
              </h2>
              <button
                onClick={closeModal}
                className="rounded p-1 text-slate-400 hover:bg-slate-100"
              >
                <X className="h-5 w-5" />
              </button>
            </div>

            <div className="space-y-3">
              <div>
                <label className="mb-1 block text-sm font-medium text-slate-700">
                  Store Name <span className="text-red-500">*</span>
                </label>
                <input
                  type="text"
                  value={form.name ?? ""}
                  onChange={(e) =>
                    setForm((f) => ({ ...f, name: e.target.value }))
                  }
                  className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                />
              </div>

              <div>
                <label className="mb-1 block text-sm font-medium text-slate-700">
                  Street Address
                </label>
                <input
                  type="text"
                  value={form.street_address ?? ""}
                  onChange={(e) =>
                    setForm((f) => ({ ...f, street_address: e.target.value }))
                  }
                  className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                />
              </div>

              <div className="grid grid-cols-3 gap-3">
                <div className="col-span-2">
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    City
                  </label>
                  <input
                    type="text"
                    value={form.city ?? ""}
                    onChange={(e) =>
                      setForm((f) => ({ ...f, city: e.target.value }))
                    }
                    className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                </div>
                <div>
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    State
                  </label>
                    <input
                      type="text"
                      value={form.state ?? ""}
                      onChange={(e) =>
                        setForm((f) => ({ ...f, state: e.target.value }))
                      }
                      className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    />
                </div>
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    ZIP
                  </label>
                  <input
                    type="text"
                    value={form.zip_code ?? ""}
                    onChange={(e) =>
                      setForm((f) => ({ ...f, zip_code: e.target.value }))
                    }
                    className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                </div>
                <div>
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    Phone
                  </label>
                  <input
                    type="text"
                    value={form.phone ?? ""}
                    onChange={(e) =>
                      setForm((f) => ({ ...f, phone: e.target.value }))
                    }
                    className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                </div>
              </div>
            </div>

            <div className="mt-6 flex justify-end gap-2">
              <button
                onClick={closeModal}
                className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
              <button
                onClick={handleSave}
                disabled={saving || !form.name?.trim()}
                className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
              >
                {saving ? "Saving…" : form.id ? "Save" : "Add"}
              </button>
            </div>
          </div>
        </div>
      )}

      {confirm && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-md rounded-lg bg-white p-6 shadow-lg">
            <h2 className="mb-2 text-lg font-semibold text-slate-900">
              {confirm.reactivate ? "Reactivate Store" : "Deactivate Store"}
            </h2>
            <p className="text-sm text-slate-600">
              {confirm.reactivate
                ? `Reactivate "${confirm.store.name}"? It will become selectable again.`
                : `Deactivating "${confirm.store.name}" will hide it from store pickers, but historical data will remain visible.`}
            </p>

            {!confirm.reactivate && confirm.activeJourneys > 0 && (
              <div className="mt-3 rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800">
                Warning: this store has {confirm.activeJourneys} active
                journey{confirm.activeJourneys === 1 ? "" : "s"} (non-completed/non-cancelled). Deactivating will not affect those records, but the store will no longer be selectable for new journeys.
              </div>
            )}

            <div className="mt-6 flex justify-end gap-2">
              <button
                onClick={() => setConfirm(null)}
                className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
              <button
                onClick={handleToggle}
                disabled={saving}
                className={`rounded-md px-4 py-2 text-sm font-medium text-white disabled:opacity-50 ${
                  confirm.reactivate
                    ? "bg-emerald-600 hover:bg-emerald-700"
                    : "bg-amber-600 hover:bg-amber-700"
                }`}
              >
                {saving
                  ? "Saving…"
                  : confirm.reactivate
                  ? "Reactivate"
                  : "Deactivate"}
              </button>
            </div>
          </div>
        </div>
      )}
    </main>
  );
}
