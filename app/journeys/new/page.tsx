"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { Plus, Trash2 } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { createJourney, fetchEmployees, fetchStores, type Employee, type Store } from "@/lib/journeys/queries";
import type { CreateJourneyInput } from "@/lib/journeys/queries";
import ProductPicker, { type ProductSelection } from "@/components/ProductPicker";

const PAYMENT_METHODS = ["Credit card", "Debit card", "Cash", "Check", "Financing", "Other"];

type LineItem = {
  id: string;
  product_id: string | null;
  item_name: string;
  quantity: number;
  unit_price: number;
};

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
  const [storeId, setStoreId] = useState("");
  const [assignedEmployeeId, setAssignedEmployeeId] = useState<string | null>(null);
  const [lineItems, setLineItems] = useState<LineItem[]>([]);
  const [quoteNotes, setQuoteNotes] = useState("");
  const [purchase, setPurchase] = useState({
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

      Promise.all([fetchStores(true), fetchEmployees()]).then(([s, e]) => {
        setStores(s);
        setEmployees(e);
        setStoreId(activeStore && s.find((st) => st.id === activeStore) ? activeStore : (s[0]?.id ?? ""));
        setLoading(false);
      });
    });
  }, [router]);

  const total = useMemo(
    () => lineItems.reduce((sum, item) => sum + item.quantity * item.unit_price, 0),
    [lineItems]
  );

  const canSubmitQuote = useMemo(() => {
    return (
      customer.firstName &&
      customer.lastName &&
      customer.phone &&
      customer.email &&
      lineItems.length > 0 &&
      storeId
    );
  }, [customer, lineItems, storeId]);

  const canSubmitPurchase = useMemo(() => {
    const paid = parseFloat(purchase.paymentAmount);
    return (
      canSubmitQuote &&
      total > 0 &&
      paid > 0 &&
      purchase.paymentMethod &&
      (paid >= total || purchase.followUpDueAt)
    );
  }, [canSubmitQuote, total, purchase]);

  function addLineItem(selection: ProductSelection) {
    const unitPrice = selection.salePrice ?? selection.price ?? 0;
    setLineItems((prev) => [
      ...prev,
      {
        id: crypto.randomUUID(),
        product_id: selection.productId,
        item_name: selection.productSummary,
        quantity: 1,
        unit_price: unitPrice,
      },
    ]);
  }

  function updateLineItem(id: string, updates: Partial<LineItem>) {
    setLineItems((prev) =>
      prev.map((item) =>
        item.id === id ? { ...item, ...updates } : item
      )
    );
  }

  function removeLineItem(id: string) {
    setLineItems((prev) => prev.filter((item) => item.id !== id));
  }

  async function handleSubmit() {
    if (!mode) return;
    setSaving(true);
    setError(null);

    const baseInput = {
      customer,
      lineItems: lineItems.map((item) => ({
        productId: item.product_id,
        itemName: item.item_name,
        quantity: item.quantity,
        unitPrice: item.unit_price,
      })),
      storeId,
      assignedEmployeeId,
    };

    let input: CreateJourneyInput;
    if (mode === "quote") {
      input = { ...baseInput, mode: "quote", quoteNotes };
    } else {
      input = {
        ...baseInput,
        mode: "purchase",
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

  const paid = parseFloat(purchase.paymentAmount) || 0;
  const balance = total - paid;

  return (
    <main className="min-h-screen bg-slate-50 p-8">
      <div className="mx-auto max-w-2xl rounded-lg border border-slate-200 bg-white p-6 shadow-sm">
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
            <h2 className="text-sm font-semibold text-slate-700">Line Items</h2>

            <ProductPicker
              storeId={storeId}
              onSelect={addLineItem}
            />

            {lineItems.length > 0 && (
              <div className="space-y-2">
                {lineItems.map((item) => (
                  <div
                    key={item.id}
                    className="grid grid-cols-12 items-center gap-2 rounded-md border border-slate-200 bg-slate-50 p-2 text-sm"
                  >
                    <div className="col-span-5 truncate text-slate-900">
                      {item.item_name}
                    </div>
                    <div className="col-span-2">
                      <input
                        type="number"
                        min={1}
                        value={item.quantity}
                        onChange={(e) =>
                          updateLineItem(item.id, { quantity: Math.max(1, parseInt(e.target.value) || 1) })
                        }
                        className="w-full rounded-md border border-slate-300 px-2 py-1 text-sm text-center focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                      />
                    </div>
                    <div className="col-span-3">
                      <input
                        type="number"
                        min={0}
                        step="0.01"
                        value={item.unit_price.toFixed(2)}
                        onChange={(e) =>
                          updateLineItem(item.id, { unit_price: parseFloat(e.target.value) || 0 })
                        }
                        className="w-full rounded-md border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                      />
                    </div>
                    <div className="col-span-1 text-right text-slate-600">
                      ${(item.quantity * item.unit_price).toFixed(2)}
                    </div>
                    <div className="col-span-1 flex justify-end">
                      <button
                        onClick={() => removeLineItem(item.id)}
                        className="rounded p-1 text-slate-400 hover:bg-red-100 hover:text-red-600"
                        aria-label="Remove"
                      >
                        <Trash2 className="h-4 w-4" />
                      </button>
                    </div>
                  </div>
                ))}
                <div className="flex justify-end border-t border-slate-200 pt-2 text-sm font-semibold text-slate-900">
                  Total: ${total.toFixed(2)}
                </div>
              </div>
            )}

            {lineItems.length === 0 && (
              <p className="text-sm text-slate-500">Add at least one product to continue.</p>
            )}

            <div>
              <label className="block text-sm font-medium text-slate-700">Store</label>
              <select
                value={storeId}
                onChange={(e) => setStoreId(e.target.value)}
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
                value={assignedEmployeeId ?? ""}
                onChange={(e) => setAssignedEmployeeId(e.target.value === "" ? null : e.target.value)}
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
                onClick={() => lineItems.length > 0 && setStep(3)}
                disabled={lineItems.length === 0}
                className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
              >
                Continue
              </button>
            </div>
          </div>
        )}

        {step === 3 && mode === "quote" && (
          <div className="space-y-4">
            <h2 className="text-sm font-semibold text-slate-700">Quote Summary</h2>

            <div className="rounded-md border border-slate-200 bg-slate-50 p-3 text-sm">
              <p className="font-medium text-slate-900">Total: ${total.toFixed(2)}</p>
              <p className="text-slate-500">{lineItems.length} item(s)</p>
            </div>

            <div>
              <label className="block text-sm font-medium text-slate-700">Notes</label>
              <textarea
                value={quoteNotes}
                onChange={(e) => setQuoteNotes(e.target.value)}
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

            <div className="rounded-md border border-slate-200 bg-slate-50 p-3 text-sm">
              <p className="font-medium text-slate-900">Agreed total: ${total.toFixed(2)}</p>
              <p className="text-slate-500">{lineItems.length} item(s)</p>
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
                <select
                  value={purchase.paymentMethod}
                  onChange={(e) => setPurchase((p) => ({ ...p, paymentMethod: e.target.value }))}
                  className="mt-1 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                >
                  <option value="">Select…</option>
                  {PAYMENT_METHODS.map((m) => (
                    <option key={m} value={m}>
                      {m}
                    </option>
                  ))}
                </select>
              </div>
            </div>

            {paid > 0 && paid < total && (
              <div className="rounded-md bg-amber-50 p-3 text-sm text-amber-700">
                Balance due: <strong>${balance.toFixed(2)}</strong>. This is a deposit — the journey will land in Quoted. Set a follow-up date:
                <input
                  type="datetime-local"
                  value={purchase.followUpDueAt}
                  onChange={(e) => setPurchase((p) => ({ ...p, followUpDueAt: e.target.value }))}
                  className="mt-2 w-full rounded-md border border-amber-200 bg-white px-3 py-2 text-sm"
                />
              </div>
            )}

            {paid > 0 && paid >= total && (
              <div className="rounded-md bg-green-50 p-3 text-sm text-green-700">
                Paid in full. The journey will land in Sold.
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
                {saving ? "Saving…" : "Create Purchase"}
              </button>
            </div>
          </div>
        )}
      </div>
    </main>
  );
}
