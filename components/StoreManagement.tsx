"use client";

import Link from "next/link";
import { useEffect, useMemo, useRef, useState } from "react";
import {
  Plus,
  Pencil,
  Power,
  RotateCcw,
  X,
} from "lucide-react";
import Modal from "@/components/Modal";
import TimezonePicker from "@/components/TimezonePicker";
import { createClient } from "@/lib/supabase/client";
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
  store_code: null,
  street_address: "",
  city: "",
  state: "",
  zip_code: "",
  phone: "",
  is_active: true,
  location_type: "STORE",
  transfer_schedule_day: null,
  timezone: null,
};

const SCHEDULE_DAY_OPTIONS = [
  { value: "", label: "No scheduled day" },
  { value: "0", label: "Sunday" },
  { value: "1", label: "Monday" },
  { value: "2", label: "Tuesday" },
  { value: "3", label: "Wednesday" },
  { value: "4", label: "Thursday" },
  { value: "5", label: "Friday" },
  { value: "6", label: "Saturday" },
];

const LOCATION_OPTIONS: { value: Store["location_type"]; label: string }[] = [
  { value: "STORE", label: "Store" },
  { value: "WAREHOUSE", label: "Warehouse" },
];

export default function StoreManagement() {
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [isOpen, setIsOpen] = useState(false);
  const [form, setForm] = useState<Partial<Store>>(emptyStore);
  const initialForm = useRef<Partial<Store>>(emptyStore);
  const [confirm, setConfirm] = useState<{
    store: Store;
    activeJourneys: number;
    reactivate: boolean;
  } | null>(null);
  // stores.timezone arrives with migration 066; until it exists the field
  // stays hidden instead of breaking store saves.
  const [timezoneSupported, setTimezoneSupported] = useState(false);
  const [storeTimezones, setStoreTimezones] = useState<
    Record<string, string | null>
  >({});

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

    fetchStoreTimezones();
  }, []);

  async function fetchStoreTimezones() {
    const supabase = createClient();
    const { data, error } = await (supabase as any)
      .from("stores")
      .select("id, timezone");
    if (error) return;
    setTimezoneSupported(true);
    setStoreTimezones(
      Object.fromEntries(
        ((data ?? []) as { id: string; timezone: string | null }[]).map(
          (r) => [r.id, r.timezone]
        )
      )
    );
  }

  function openNew() {
    initialForm.current = { ...emptyStore };
    setForm({ ...emptyStore });
    setIsOpen(true);
  }

  function openEdit(store: Store) {
    const withTimezone = {
      ...store,
      timezone: storeTimezones[store.id] ?? null,
    };
    initialForm.current = withTimezone;
    setForm(withTimezone);
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
          store_code: form.store_code?.trim().toUpperCase() || null,
          street_address: form.street_address,
          city: form.city,
          state: form.state,
          zip_code: form.zip_code,
          phone: form.phone,
          is_active: form.is_active,
          assigned_warehouse_id: form.assigned_warehouse_id ?? null,
          transfer_schedule_day: form.transfer_schedule_day ?? null,
          // undefined is dropped from the PATCH, so pre-migration saves
          // don't send a column that doesn't exist yet.
          timezone: timezoneSupported ? form.timezone ?? null : undefined,
        });
        if (timezoneSupported) {
          setStoreTimezones((prev) => ({
            ...prev,
            [form.id!]: form.timezone ?? null,
          }));
        }
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
          store_code: form.store_code?.trim().toUpperCase() || null,
          street_address: form.street_address,
          city: form.city,
          state: form.state,
          zip_code: form.zip_code,
          phone: form.phone,
          is_active: form.is_active,
          location_type: form.location_type,
          transfer_schedule_day: form.transfer_schedule_day ?? null,
          timezone: timezoneSupported ? form.timezone ?? null : undefined,
        });
        if (id) {
          if (timezoneSupported) {
            setStoreTimezones((prev) => ({
              ...prev,
              [id]: form.timezone ?? null,
            }));
          }
          const fresh = await fetchStores();
          setStores(fresh);
        }
      }
      closeModal();
    } catch (err) {
      console.error(err);
      const msg = err instanceof Error ? err.message : "Save failed";
      alert(
        msg.includes("idx_stores_company_store_code") || msg.includes("duplicate key")
          ? "That store code is already used by another store in this company."
          : msg
      );
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
                    {s.store_code && (
                      <span className="rounded-full bg-brand-50 px-2 py-0.5 text-xs font-medium text-brand-700">
                        {s.store_code}
                      </span>
                    )}
                    <span className="rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600">
                      {s.location_type.replace("_", " ")}
                    </span>
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
        <Modal
          onClose={closeModal}
          overlayClassName="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
          dirty={
            JSON.stringify(form) !== JSON.stringify(initialForm.current)
          }
          saving={saving}
        >
          <div className="flex max-h-[90vh] w-full max-w-2xl flex-col overflow-hidden rounded-lg bg-white shadow-lg">
            <div className="flex items-center justify-between border-b border-slate-200 px-6 py-4">
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

            <div className="flex-1 space-y-3 overflow-y-auto px-6 py-4">
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

              <div className="grid gap-3 sm:grid-cols-2">
                <div>
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    Store Code
                  </label>
                  <input
                    type="text"
                    value={form.store_code ?? ""}
                    onChange={(e) =>
                      setForm((f) => ({
                        ...f,
                        store_code: e.target.value.toUpperCase(),
                      }))
                    }
                    placeholder="e.g. MS"
                    className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm uppercase focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                  <p className="mt-1 text-xs text-slate-500">
                    Optional. Used in inventory count reference numbers (e.g.
                    MSINV-000001). Auto-derived from the store name if left blank.
                  </p>
                </div>

                <div>
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    Location Type
                  </label>
                  {form.id ? (
                    <p className="py-2 text-sm text-slate-700">
                      {form.location_type?.replace("_", " ")}
                    </p>
                  ) : (
                    <select
                      value={form.location_type ?? "STORE"}
                      onChange={(e) =>
                        setForm((f) => ({
                          ...f,
                          location_type: e.target.value as Store["location_type"],
                        }))
                      }
                      className="w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    >
                      {LOCATION_OPTIONS.map((o) => (
                        <option key={o.value} value={o.value}>
                          {o.label}
                        </option>
                      ))}
                    </select>
                  )}
                </div>
              </div>

              <div className="grid gap-3 sm:grid-cols-2">
                {form.location_type === "STORE" && (
                  <div>
                    <label className="mb-1 block text-sm font-medium text-slate-700">
                      Assigned Warehouse
                    </label>
                    <select
                      value={form.assigned_warehouse_id ?? ""}
                      onChange={(e) =>
                        setForm((f) => ({
                          ...f,
                          assigned_warehouse_id: e.target.value || null,
                        }))
                      }
                      className="w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    >
                      <option value="">None</option>
                      {stores
                        .filter((s) => s.location_type === "WAREHOUSE")
                        .map((s) => (
                          <option key={s.id} value={s.id}>
                            {s.name}
                          </option>
                        ))}
                    </select>
                  </div>
                )}

                <div>
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    Transfer Schedule Day
                  </label>
                  <select
                    value={form.transfer_schedule_day ?? ""}
                    onChange={(e) =>
                      setForm((f) => ({
                        ...f,
                        transfer_schedule_day:
                          e.target.value === "" ? null : Number(e.target.value),
                      }))
                    }
                    className="w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  >
                    {SCHEDULE_DAY_OPTIONS.map((o) => (
                      <option key={o.value} value={o.value}>
                        {o.label}
                      </option>
                    ))}
                  </select>
                  <p className="mt-1 text-xs text-slate-500">
                    Nightly consolidation will pick up this store the day before
                    this scheduled day.
                  </p>
                </div>
              </div>

              {form.location_type === "STORE" && timezoneSupported && (
                <div>
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    Timezone
                  </label>
                  <TimezonePicker
                    value={form.timezone ?? null}
                    allowEmpty
                    emptyLabel="Use company timezone"
                    onChange={(tz) =>
                      setForm((f) => ({ ...f, timezone: tz }))
                    }
                  />
                  <p className="mt-1 text-xs text-slate-500">
                    Business dates for this store (for example sleep trial
                    nights). Leave blank to use the company timezone.
                  </p>
                </div>
              )}

              {form.location_type === "STORE" && (
                <p className="text-xs text-slate-500">
                  Sleep trial policy is set company-wide in Settings →{" "}
                  <Link
                    href="/settings/sleep-trial"
                    className="text-brand-600 hover:underline"
                  >
                    Sleep Trial
                  </Link>
                  .
                </p>
              )}

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

              <div className="grid gap-3 sm:grid-cols-3">
                <div>
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

            <div className="flex justify-end gap-2 border-t border-slate-200 px-6 py-4">
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
        </Modal>
      )}

      {confirm && (
        <Modal
          onClose={() => setConfirm(null)}
          overlayClassName="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
          saving={saving}
        >
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
        </Modal>
      )}
    </main>
  );
}
