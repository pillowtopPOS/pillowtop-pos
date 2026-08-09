"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { createJourney, type NewJourneyInput } from "@/lib/journeys/actions";
import { fetchEmployees, fetchStores, type Employee, type Store } from "@/lib/journeys/queries";

export default function NewJourneyPage() {
  const router = useRouter();
  const [stores, setStores] = useState<Store[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [form, setForm] = useState<NewJourneyInput>({
    firstName: "",
    lastName: "",
    phone: "",
    email: "",
    productSummary: "",
    storeId: "",
    assignedEmployeeId: null,
  });

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!session?.user) {
        router.push("/login");
        return;
      }

      const activeStore = session.user.user_metadata?.active_store_id;

      Promise.all([fetchStores(), fetchEmployees()]).then(([s, e]) => {
        setStores(s);
        setEmployees(e);
        setForm((f) => ({
          ...f,
          storeId: activeStore && s.find((st) => st.id === activeStore) ? activeStore : (s[0]?.id ?? ""),
        }));
        setLoading(false);
      });
    });
  }, [router]);

  function handleChange(
    e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>
  ) {
    const { name, value } = e.target;
    setForm((f) => ({ ...f, [name]: value === "" ? null : value }));
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSaving(true);
    setError(null);

    try {
      await createJourney(form);
    } catch (e: any) {
      setSaving(false);
      setError(e.message ?? "Failed to create journey");
    }
  }

  if (loading) return <p className="p-8 text-sm text-slate-500">Loading…</p>;

  return (
    <main className="min-h-screen bg-slate-50 p-8">
      <div className="mx-auto max-w-xl rounded-lg border border-slate-200 bg-white p-6 shadow-sm">
        <div className="mb-4 flex items-center justify-between">
          <h1 className="text-xl font-semibold text-slate-900">New Sleep Journey</h1>
          <Link
            href="/board"
            className="text-sm text-slate-500 hover:text-slate-700"
          >
            Back to Board
          </Link>
        </div>

        {error && (
          <p className="mb-4 rounded-md bg-amber-50 p-3 text-sm text-amber-700">
            {error}
          </p>
        )}

        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium text-slate-700">
                First name
              </label>
              <input
                name="firstName"
                required
                value={form.firstName}
                onChange={handleChange}
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-slate-700">
                Last name
              </label>
              <input
                name="lastName"
                required
                value={form.lastName}
                onChange={handleChange}
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
            </div>
          </div>

          <div>
            <label className="block text-sm font-medium text-slate-700">Phone</label>
            <input
              name="phone"
              type="tel"
              required
              value={form.phone}
              onChange={handleChange}
              className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-slate-700">Email</label>
            <input
              name="email"
              type="email"
              required
              value={form.email}
              onChange={handleChange}
              className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-slate-700">
              Product summary
            </label>
            <textarea
              name="productSummary"
              required
              value={form.productSummary}
              onChange={handleChange}
              placeholder="e.g. King, Firm, Sealy Posturepedic"
              className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              rows={3}
            />
          </div>

          <div>
            <label className="block text-sm font-medium text-slate-700">Store</label>
            <select
              name="storeId"
              required
              value={form.storeId}
              onChange={handleChange}
              className="mt-1 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
            >
              {stores.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          </div>

          <div>
            <label className="block text-sm font-medium text-slate-700">
              Assigned employee
            </label>
            <select
              name="assignedEmployeeId"
              value={form.assignedEmployeeId ?? ""}
              onChange={handleChange}
              className="mt-1 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
            >
              <option value="">Unassigned</option>
              {employees.map((e) => (
                <option key={e.id} value={e.id}>
                  {e.name}
                </option>
              ))}
            </select>
          </div>

          <button
            type="submit"
            disabled={saving}
            className="w-full rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
          >
            {saving ? "Creating…" : "Create Journey"}
          </button>
        </form>
      </div>
    </main>
  );
}
