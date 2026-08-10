"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { createJourney, fetchEmployees, fetchStores, type Employee, type Store } from "@/lib/journeys/queries";
import type { CreateJourneyInput } from "@/lib/journeys/queries";

export default function NewJourneyPage() {
  const router = useRouter();
  const [stores, setStores] = useState<Store[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [step, setStep] = useState<0 | 1 | 2 | 3>(0);

  const [mode, setMode] = useState<"quote" | "purchase" | null>(null);
  const [customer, setCustomer] = useState({
    firstName: "",
    lastName: "",
    phone: "",
    email: "",
  });
  const [product, setProduct] = useState({
    productSummary: "",
    storeId: "",
    assignedEmployeeId: null as string | null,
  });
  const [quote, setQuote] = useState({
    quoteAmount: "",
    quoteNotes: "",
  });
  const [purchase, setPurchase] = useState({
    price: "",
    paymentAmount: "",
    paymentMethod: "",
    followUpDueAt: "",
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
        setProduct((p) => ({
          ...p,
          storeId: activeStore && s.find((st) => st.id === activeStore) ? activeStore : (s[0]?.id ?? ""),
        }));
        setLoading(false);
      });
    });
  }, [router]);

  const canSubmitQuote = useMemo(() => {
    return (
      customer.firstName &&
      customer.lastName &&
      customer.phone &&
      customer.email &&
      product.productSummary &&
      product.storeId
    );
  }, [customer, product]);

  const canSubmitPurchase = useMemo(() => {
    const price = parseFloat(purchase.price);
    const paid = parseFloat(purchase.paymentAmount);
    return (
      canSubmitQuote &&
      price > 0 &&
      paid > 0 &&
      purchase.paymentMethod &&
      (paid >= price || purchase.followUpDueAt)
    );
  }, [canSubmitQuote, purchase]);

  async function handleSubmit() {
    if (!mode) return;
    setSaving(true);
    setError(null);

    const base = {
      customer,
      productSummary: product.productSummary,
      storeId: product.storeId,
      assignedEmployeeId: product.assignedEmployeeId,
    };

    let input: CreateJourneyInput;
    if (mode === "quote") {
      input = {
        ...base,
        mode: "quote",
        quoteAmount: quote.quoteAmount,
        quoteNotes: quote.quoteNotes,
      };
    } else {
      input = {
        ...base,
        mode: "purchase",
        price: purchase.price,
        paymentAmount: purchase.paymentAmount,
        paymentMethod: purchase.paymentMethod,
        followUpDueAt: purchase.followUpDueAt,
      };
    }

    try {
      await createJourney(input);
      router.push("/board");
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

        {step === 0 && (
          <div className="space-y-4">
            <p className="text-sm text-slate-600">What are you creating?</p>
            <div className="grid grid-cols-2 gap-4">
              <button
                onClick={() => {
                  setMode("quote");
                  setStep(1);
                }}
                className="rounded-lg border border-slate-200 p-6 text-left hover:border-brand-500 hover:bg-brand-50"
              >
                <span className="text-base font-semibold text-slate-900">Quote</span>
                <p className="mt-1 text-sm text-slate-500">
                  Customer is considering the purchase
                </p>
              </button>
              <button
                onClick={() => {
                  setMode("purchase");
                  setStep(1);
                }}
                className="rounded-lg border border-slate-200 p-6 text-left hover:border-brand-500 hover:bg-brand-50"
              >
                <span className="text-base font-semibold text-slate-900">Purchase</span>
                <p className="mt-1 text-sm text-slate-500">
                  Customer is ready to buy
                </p>
              </button>
            </div>
          </div>
        )}

        {step === 1 && (
          <div className="space-y-4">
            <h2 className="text-sm font-semibold text-slate-700">Customer</h2>
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium text-slate-700">First name</label>
                <input
                  value={customer.firstName}
                  onChange={(e) => setCustomer((c) => ({ ...c, firstName: e.target.value }))}
                  className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-slate-700">Last name</label>
                <input
                  value={customer.lastName}
                  onChange={(e) => setCustomer((c) => ({ ...c, lastName: e.target.value }))}
                  className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                />
              </div>
            </div>
            <div>
              <label className="block text-sm font-medium text-slate-700">Phone</label>
              <input
                type="tel"
                value={customer.phone}
                onChange={(e) => setCustomer((c) => ({ ...c, phone: e.target.value }))}
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-slate-700">Email</label>
              <input
                type="email"
                value={customer.email}
                onChange={(e) => setCustomer((c) => ({ ...c, email: e.target.value }))}
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
            </div>
            <div className="flex justify-end gap-2">
              <button
                onClick={() => setStep(0)}
                className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Back
              </button>
              <button
                onClick={() => customer.firstName && customer.lastName && customer.phone && customer.email && setStep(2)}
                disabled={!customer.firstName || !customer.lastName || !customer.phone || !customer.email}
                className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
              >
                Continue
              </button>
            </div>
          </div>
        )}

        {step === 2 && (
          <div className="space-y-4">
            <h2 className="text-sm font-semibold text-slate-700">Product</h2>
            <div>
              <label className="block text-sm font-medium text-slate-700">Product summary</label>
              <textarea
                value={product.productSummary}
                onChange={(e) => setProduct((p) => ({ ...p, productSummary: e.target.value }))}
                placeholder="e.g. King, Firm, Sealy Posturepedic"
                rows={3}
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-slate-700">Store</label>
              <select
                value={product.storeId}
                onChange={(e) => setProduct((p) => ({ ...p, storeId: e.target.value }))}
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
              <label className="block text-sm font-medium text-slate-700">Assigned employee</label>
              <select
                value={product.assignedEmployeeId ?? ""}
                onChange={(e) =>
                  setProduct((p) => ({
                    ...p,
                    assignedEmployeeId: e.target.value === "" ? null : e.target.value,
                  }))
                }
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
            <div className="flex justify-end gap-2">
              <button
                onClick={() => setStep(1)}
                className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Back
              </button>
              <button
                onClick={() => product.productSummary && product.storeId && setStep(3)}
                disabled={!product.productSummary || !product.storeId}
                className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
              >
                Continue
              </button>
            </div>
          </div>
        )}

        {step === 3 && mode === "quote" && (
          <div className="space-y-4">
            <h2 className="text-sm font-semibold text-slate-700">Quote</h2>
            <div>
              <label className="block text-sm font-medium text-slate-700">Quote amount</label>
              <input
                type="number"
                min={0}
                step="0.01"
                value={quote.quoteAmount}
                onChange={(e) => setQuote((q) => ({ ...q, quoteAmount: e.target.value }))}
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-slate-700">Notes</label>
              <textarea
                value={quote.quoteNotes}
                onChange={(e) => setQuote((q) => ({ ...q, quoteNotes: e.target.value }))}
                rows={3}
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
            </div>
            <div className="flex justify-end gap-2">
              <button
                onClick={() => setStep(2)}
                className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Back
              </button>
              <button
                onClick={handleSubmit}
                disabled={saving || !canSubmitQuote}
                className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
              >
                {saving ? "Sending…" : "Send Quote"}
              </button>
            </div>
          </div>
        )}

        {step === 3 && mode === "purchase" && (
          <div className="space-y-4">
            <h2 className="text-sm font-semibold text-slate-700">Pricing & Payment</h2>
            <div>
              <label className="block text-sm font-medium text-slate-700">Agreed price</label>
              <input
                type="number"
                min={0}
                step="0.01"
                value={purchase.price}
                onChange={(e) => setPurchase((p) => ({ ...p, price: e.target.value }))}
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
            </div>
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium text-slate-700">Amount paid now</label>
                <input
                  type="number"
                  min={0}
                  step="0.01"
                  value={purchase.paymentAmount}
                  onChange={(e) => setPurchase((p) => ({ ...p, paymentAmount: e.target.value }))}
                  className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-slate-700">Payment method</label>
                <input
                  value={purchase.paymentMethod}
                  onChange={(e) => setPurchase((p) => ({ ...p, paymentMethod: e.target.value }))}
                  placeholder="e.g. Credit card"
                  className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                />
              </div>
            </div>

            {parseFloat(purchase.paymentAmount) > 0 &&
              parseFloat(purchase.paymentAmount) < parseFloat(purchase.price || "0") && (
                <div className="rounded-md bg-amber-50 p-3 text-sm text-amber-700">
                  This is a deposit. The journey will land in <strong>Quoted</strong> with a
                  balance due. Set a follow-up date:
                  <input
                    type="datetime-local"
                    value={purchase.followUpDueAt}
                    onChange={(e) => setPurchase((p) => ({ ...p, followUpDueAt: e.target.value }))}
                    className="mt-2 w-full rounded-md border border-amber-200 bg-white px-3 py-2 text-sm"
                  />
                </div>
              )}

            <div className="flex justify-end gap-2">
              <button
                onClick={() => setStep(2)}
                className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Back
              </button>
              <button
                onClick={handleSubmit}
                disabled={saving || !canSubmitPurchase}
                className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
              >
                {saving ? "Saving…" : "Complete Purchase"}
              </button>
            </div>
          </div>
        )}
      </div>
    </main>
  );
}
