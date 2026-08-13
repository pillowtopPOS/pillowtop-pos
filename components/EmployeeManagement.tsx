"use client";

import { useEffect, useMemo, useState } from "react";
import { Plus, Pencil, Power, RotateCcw, X } from "lucide-react";
import {
  fetchCurrentEmployee,
  fetchEmployees,
  fetchStores,
  createEmployee,
  updateEmployee,
  countActiveJourneysForEmployee,
  type Employee,
  type EmployeeInput,
  type EmployeeRole,
  type Store,
} from "@/lib/journeys/queries";

const ROLES: { value: EmployeeRole; label: string; description: string }[] = [
  {
    value: "owner",
    label: "Owner",
    description: "Full access to every store and all settings.",
  },
  {
    value: "admin",
    label: "Admin",
    description: "Manages stores, employees, and settings.",
  },
  {
    value: "manager",
    label: "Manager",
    description: "Sees every store's journeys, but not settings.",
  },
  {
    value: "employee",
    label: "Employee",
    description: "Works journeys at their assigned store.",
  },
  {
    value: "sales",
    label: "Sales",
    description: "Works journeys at their assigned store.",
  },
];

const emptyForm: EmployeeInput = {
  first_name: "",
  last_name: "",
  role: "employee",
  home_store_id: null,
  birthday: null,
  hire_date: null,
  is_active: true,
};

function roleLabel(role: string) {
  return ROLES.find((r) => r.value === role)?.label ?? role;
}

function formatDate(value: string | null) {
  if (!value) return null;
  const [year, month, day] = value.split("-");
  if (!year || !month || !day) return value;
  return `${month}/${day}/${year}`;
}

export default function EmployeeManagement() {
  const [currentEmployee, setCurrentEmployee] = useState<Employee | null>(null);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [stores, setStores] = useState<Store[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [isOpen, setIsOpen] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [form, setForm] = useState<EmployeeInput>(emptyForm);
  const [error, setError] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<{
    employee: Employee;
    activeJourneys: number;
    reactivate: boolean;
  } | null>(null);

  const isAdmin =
    currentEmployee?.role === "owner" || currentEmployee?.role === "admin";

  const storeNames = useMemo(() => {
    const map = new Map<string, string>();
    stores.forEach((s) => map.set(s.id, s.name));
    return map;
  }, [stores]);

  const sortedEmployees = useMemo(() => {
    return [...employees].sort((a, b) => {
      if (a.is_active === b.is_active) return a.name.localeCompare(b.name);
      return a.is_active ? -1 : 1;
    });
  }, [employees]);

  useEffect(() => {
    Promise.all([
      fetchCurrentEmployee(),
      fetchEmployees(),
      fetchStores(true),
    ]).then(([me, emps, s]) => {
      setCurrentEmployee(me);
      setEmployees(emps);
      setStores(s);
      setLoading(false);
    });
  }, []);

  function openNew() {
    setEditingId(null);
    setError(null);
    setForm({
      ...emptyForm,
      home_store_id: currentEmployee?.home_store_id ?? stores[0]?.id ?? null,
    });
    setIsOpen(true);
  }

  function openEdit(employee: Employee) {
    setEditingId(employee.id);
    setError(null);
    setForm({
      first_name: employee.first_name,
      last_name: employee.last_name,
      role: employee.role as EmployeeRole,
      home_store_id: employee.home_store_id,
      birthday: employee.birthday,
      hire_date: employee.hire_date,
      is_active: employee.is_active,
    });
    setIsOpen(true);
  }

  function closeModal() {
    setIsOpen(false);
    setEditingId(null);
    setForm(emptyForm);
    setError(null);
  }

  async function reload() {
    setEmployees(await fetchEmployees());
  }

  async function handleSave() {
    if (!form.first_name.trim() || !form.last_name?.trim() || !form.home_store_id)
      return;
    setSaving(true);
    setError(null);

    const payload: EmployeeInput = {
      ...form,
      first_name: form.first_name.trim(),
      last_name: form.last_name?.trim() || null,
      birthday: form.birthday || null,
      hire_date: form.hire_date || null,
    };

    try {
      if (editingId) {
        await updateEmployee(editingId, payload);
      } else {
        await createEmployee(payload);
      }
      await reload();
      closeModal();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Save failed");
    } finally {
      setSaving(false);
    }
  }

  async function promptToggle(employee: Employee) {
    const activeJourneys = employee.is_active
      ? await countActiveJourneysForEmployee(employee.id)
      : 0;
    setConfirm({
      employee,
      activeJourneys,
      reactivate: !employee.is_active,
    });
  }

  async function handleToggle() {
    if (!confirm) return;
    setSaving(true);
    const { employee, reactivate } = confirm;

    try {
      await updateEmployee(employee.id, { is_active: reactivate });
      setEmployees((prev) =>
        prev.map((e) =>
          e.id === employee.id ? { ...e, is_active: reactivate } : e
        )
      );
      setConfirm(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Update failed");
    } finally {
      setSaving(false);
    }
  }

  if (loading) {
    return (
      <main className="min-h-screen bg-slate-50 p-8">
        <div className="mx-auto max-w-4xl text-center text-slate-500">
          Loading employees…
        </div>
      </main>
    );
  }

  if (!isAdmin) {
    return (
      <main className="min-h-screen bg-slate-50 p-8">
        <div className="mx-auto max-w-4xl text-center text-slate-600">
          You don&apos;t have permission to manage employees.
        </div>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-slate-50 p-8">
      <div className="mx-auto max-w-4xl">
        <div className="mb-6 flex items-center justify-between">
          <h1 className="text-2xl font-semibold text-slate-900">
            Employee Management
          </h1>
          <button
            onClick={openNew}
            className="flex items-center gap-2 rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700"
          >
            <Plus className="h-4 w-4" />
            Add Employee
          </button>
        </div>

        {error && !isOpen && (
          <div className="mb-4 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-700">
            {error}
          </div>
        )}

        <div className="space-y-3">
          {sortedEmployees.map((e) => {
            const isSelf = e.id === currentEmployee?.id;
            return (
              <div
                key={e.id}
                className={`rounded-lg border bg-white p-4 shadow-sm transition ${
                  e.is_active
                    ? "border-slate-200"
                    : "border-slate-200 bg-slate-100 opacity-75"
                }`}
              >
                <div className="flex items-start justify-between">
                  <div>
                    <div className="flex items-center gap-2">
                      <h2 className="text-lg font-semibold text-slate-900">
                        {e.name}
                      </h2>
                      <span className="rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600">
                        {roleLabel(e.role)}
                      </span>
                      {!e.is_active && (
                        <span className="rounded-full bg-slate-200 px-2 py-0.5 text-xs font-medium text-slate-600">
                          Inactive
                        </span>
                      )}
                      {!e.auth_user_id && (
                        <span className="rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700">
                          No login
                        </span>
                      )}
                    </div>
                    <p className="mt-1 text-sm text-slate-500">
                      {(e.home_store_id && storeNames.get(e.home_store_id)) ??
                        "No home store"}
                      {e.hire_date
                        ? ` • Hired ${formatDate(e.hire_date)}`
                        : null}
                      {e.birthday ? ` • Birthday ${formatDate(e.birthday)}` : null}
                    </p>
                  </div>
                  <div className="flex items-center gap-2">
                    <button
                      onClick={() => openEdit(e)}
                      className="rounded p-2 text-slate-500 hover:bg-slate-100"
                      aria-label="Edit"
                    >
                      <Pencil className="h-4 w-4" />
                    </button>
                    {e.is_active ? (
                      <button
                        onClick={() => promptToggle(e)}
                        disabled={isSelf}
                        title={
                          isSelf ? "You can't deactivate yourself" : "Deactivate"
                        }
                        className="rounded p-2 text-slate-500 hover:bg-amber-100 hover:text-amber-600 disabled:cursor-not-allowed disabled:opacity-40 disabled:hover:bg-transparent"
                        aria-label="Deactivate"
                      >
                        <Power className="h-4 w-4" />
                      </button>
                    ) : (
                      <button
                        onClick={() => promptToggle(e)}
                        className="rounded p-2 text-slate-500 hover:bg-emerald-100 hover:text-emerald-600"
                        aria-label="Reactivate"
                      >
                        <RotateCcw className="h-4 w-4" />
                      </button>
                    )}
                  </div>
                </div>
              </div>
            );
          })}

          {employees.length === 0 && (
            <p className="text-center text-slate-500">No employees found.</p>
          )}
        </div>
      </div>

      {isOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-md rounded-lg bg-white p-6 shadow-lg">
            <div className="mb-4 flex items-center justify-between">
              <h2 className="text-lg font-semibold text-slate-900">
                {editingId ? "Edit Employee" : "Add Employee"}
              </h2>
              <button
                onClick={closeModal}
                className="rounded p-1 text-slate-400 hover:bg-slate-100"
              >
                <X className="h-5 w-5" />
              </button>
            </div>

            <div className="space-y-3">
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    First Name <span className="text-red-500">*</span>
                  </label>
                  <input
                    type="text"
                    value={form.first_name}
                    onChange={(e) =>
                      setForm((f) => ({ ...f, first_name: e.target.value }))
                    }
                    className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                </div>
                <div>
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    Last Name <span className="text-red-500">*</span>
                  </label>
                  <input
                    type="text"
                    value={form.last_name ?? ""}
                    onChange={(e) =>
                      setForm((f) => ({ ...f, last_name: e.target.value }))
                    }
                    className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                </div>
              </div>

              <div>
                <label className="mb-1 block text-sm font-medium text-slate-700">
                  Role <span className="text-red-500">*</span>
                </label>
                <select
                  value={form.role}
                  disabled={editingId === currentEmployee?.id}
                  onChange={(e) =>
                    setForm((f) => ({
                      ...f,
                      role: e.target.value as EmployeeRole,
                    }))
                  }
                  className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500 disabled:bg-slate-100 disabled:text-slate-500"
                >
                  {ROLES.map((r) => (
                    <option key={r.value} value={r.value}>
                      {r.label}
                    </option>
                  ))}
                </select>
                <p className="mt-1 text-xs text-slate-500">
                  {editingId === currentEmployee?.id
                    ? "You can't change your own role."
                    : ROLES.find((r) => r.value === form.role)?.description}
                </p>
              </div>

              <div>
                <label className="mb-1 block text-sm font-medium text-slate-700">
                  Home Store <span className="text-red-500">*</span>
                </label>
                <select
                  value={form.home_store_id ?? ""}
                  onChange={(e) =>
                    setForm((f) => ({
                      ...f,
                      home_store_id: e.target.value || null,
                    }))
                  }
                  className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                >
                  <option value="">Select a store…</option>
                  {stores.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.name}
                    </option>
                  ))}
                </select>
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    Hire Date
                  </label>
                  <input
                    type="date"
                    value={form.hire_date ?? ""}
                    onChange={(e) =>
                      setForm((f) => ({ ...f, hire_date: e.target.value }))
                    }
                    className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                </div>
                <div>
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    Birthday
                  </label>
                  <input
                    type="date"
                    value={form.birthday ?? ""}
                    onChange={(e) =>
                      setForm((f) => ({ ...f, birthday: e.target.value }))
                    }
                    className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                </div>
              </div>
            </div>

            {error && (
              <div className="mt-4 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-700">
                {error}
              </div>
            )}

            <div className="mt-6 flex justify-end gap-2">
              <button
                onClick={closeModal}
                className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
              <button
                onClick={handleSave}
                disabled={
                  saving ||
                  !form.first_name.trim() ||
                  !form.last_name?.trim() ||
                  !form.home_store_id
                }
                className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
              >
                {saving ? "Saving…" : editingId ? "Save" : "Add"}
              </button>
            </div>
          </div>
        </div>
      )}

      {confirm && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="w-full max-w-md rounded-lg bg-white p-6 shadow-lg">
            <h2 className="mb-2 text-lg font-semibold text-slate-900">
              {confirm.reactivate ? "Reactivate Employee" : "Deactivate Employee"}
            </h2>
            <p className="text-sm text-slate-600">
              {confirm.reactivate
                ? `Reactivate "${confirm.employee.name}"? They will be assignable again.`
                : `Deactivating "${confirm.employee.name}" hides them from assignment pickers, but their historical journeys stay intact.`}
            </p>

            {!confirm.reactivate && confirm.activeJourneys > 0 && (
              <div className="mt-3 rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800">
                Warning: this employee is assigned to {confirm.activeJourneys}{" "}
                active journey{confirm.activeJourneys === 1 ? "" : "s"}. Those
                journeys keep their assignment and should be reassigned.
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
