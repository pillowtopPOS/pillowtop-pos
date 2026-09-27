"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { Plus, Trash2 } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import {
  createJourney,
  fetchEmployees,
  fetchStores,
  recordPaymentEvent,
  reconcilePayment,
  type Employee,
  type Store,
  type PaymentOutcome,
} from "@/lib/journeys/queries";
import { requestDepositException } from "@/lib/journeys/deposit";
import type { CreateJourneyInput } from "@/lib/journeys/queries";
import ProductPicker, { type ProductSelection } from "@/components/ProductPicker";
import { fetchProductStock } from "@/lib/inventory/queries";
import { resolveLineItemLocation } from "@/lib/journeys/fulfillment";
import Modal from "@/components/Modal";
import { isStoreConfirmedToday, storeSelectUrl } from "@/lib/journeys/storeConfirm";

const PAYMENT_METHODS = [
  "Credit card",
  "Debit card",
  "Cash",
  "Check",
  "Financing",
  "Other",
  "Simulated card — success",
  "Simulated card — timeout",
  "Simulated card — failure",
];

function paymentOutcomeForMethod(method: string): PaymentOutcome {
  if (method.includes("timeout")) return "UNKNOWN";
  if (method.includes("failure")) return "FAILED";
  return "SUCCEEDED";
}

type LineItem = {
  id: string;
  product_id: string | null;
  item_name: string;
  quantity: number;
  unit_price: number;
  fulfillment_type_override: "delivery" | "pickup" | null;
  pickup_location_id: string | null;
};

export default function NewJourneyPage() {
  const router = useRouter();
  const [stores, setStores] = useState<Store[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [created, setCreated] = useState<{
    journeyId: string;
    paymentEventId: string;
    outcome: PaymentOutcome;
  } | null>(null);
  const [pendingOverpayment, setPendingOverpayment] = useState<{
    paid: number;
    total: number;
  } | null>(null);
  const [pendingDepositException, setPendingDepositException] = useState<{
    journeyId: string;
    amount: number;
    method: string;
    requestId?: string;
    reason?: string;
    error?: string;
  } | null>(null);
  const [step, setStep] = useState<0 | 1 | 2 | 3>(0);

  const [mode, setMode] = useState<"quote" | "purchase" | null>(null);
  const [customer, setCustomer] = useState({
    firstName: "",
    lastName: "",
    phone: "",
    email: "",
    streetAddress: "",
    streetAddressLine2: "",
    city: "",
    state: "",
    zipCode: "",
  });
  const [storeId, setStoreId] = useState("");
  const [fulfillmentType, setFulfillmentType] = useState<"delivery" | "pickup">("delivery");
  const [assignedEmployeeId, setAssignedEmployeeId] = useState<string | null>(null);
  const [lineItems, setLineItems] = useState<LineItem[]>([]);
  const [availability, setAvailability] = useState<Record<string, number>>({});
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

      Promise.all([fetchStores(true), fetchEmployees(true)]).then(([s, e]) => {
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

  const inventoryStoreId = useMemo(
    () =>
      resolveLineItemLocation(
        {},
        { store_id: storeId, fulfillment_type: fulfillmentType },
        stores
      ),
    [stores, storeId, fulfillmentType]
  );

  async function refreshAvailability(item: LineItem) {
    if (!item.product_id) return;
    const productId = item.product_id;
    const locationId = resolveLineItemLocation(
      item,
      { store_id: storeId, fulfillment_type: fulfillmentType },
      stores
    );
    if (!locationId) return;
    const map = await fetchProductStock([productId], locationId);
    setAvailability((prev) => ({ ...prev, [item.id]: map[productId]?.ats ?? 0 }));
  }

  const hasDeliveryAddress = customer.streetAddress.trim() !== "";

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
    const item: LineItem = {
      id: crypto.randomUUID(),
      product_id: selection.productId,
      item_name: selection.productSummary,
      quantity: 1,
      unit_price: unitPrice,
      fulfillment_type_override: null,
      pickup_location_id: null,
    };
    setLineItems((prev) => [...prev, item]);
    void refreshAvailability(item);
  }

  function updateLineItem(id: string, updates: Partial<LineItem>) {
    setLineItems((prev) => {
      const next = prev.map((item) =>
        item.id === id ? { ...item, ...updates } : item
      );
      const changed = next.find((item) => item.id === id);
      if (changed) void refreshAvailability(changed);
      return next;
    });
  }

  function removeLineItem(id: string) {
    setLineItems((prev) => prev.filter((item) => item.id !== id));
  }

  async function performSubmit() {
    setSaving(true);
    setError(null);

    const supabase = createClient();
    const { data: { session } } = await supabase.auth.getSession();
    if (!session?.user || !isStoreConfirmedToday(session.user)) {
      setSaving(false);
      router.push(storeSelectUrl("/journeys/new"));
      return;
    }

    const baseInput = {
      customer,
      lineItems: lineItems.map((item) => ({
        productId: item.product_id,
        itemName: item.item_name,
        quantity: item.quantity,
        unitPrice: item.unit_price,
        fulfillmentTypeOverride: item.fulfillment_type_override,
        pickupLocationId: item.pickup_location_id,
      })),
      storeId,
      fulfillmentType,
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

    let journeyId: string | undefined;

    try {
      journeyId = await createJourney(input);

      if (mode === "quote") {
        router.push("/board");
        return;
      }

      const paid = parseFloat(purchase.paymentAmount) || 0;
      const idempotencyKey = crypto.randomUUID();
      const outcome = paymentOutcomeForMethod(purchase.paymentMethod);

      const paymentEventId = await recordPaymentEvent({
        journeyId,
        amount: paid,
        paymentMethod: purchase.paymentMethod,
        idempotencyKey,
        outcome,
        followUpDueAt: purchase.followUpDueAt,
      });

      if (outcome === "SUCCEEDED") {
        router.push("/board");
        return;
      }

      setCreated({
        journeyId,
        paymentEventId,
        outcome,
      });
    } catch (e: any) {
      const msg = e.message ?? "";
      if (
        journeyId &&
        (msg.includes("below the required deposit") ||
          msg.includes("below the approved minimum"))
      ) {
        setPendingDepositException({
          journeyId,
          amount: paid,
          method: purchase.paymentMethod,
        });
        setSaving(false);
        return;
      }
      setSaving(false);
      setError(msg || "Failed to create journey");
    }
  }

  async function handleSubmit() {
    if (!mode || saving) return;

    if (mode === "purchase") {
      const paid = parseFloat(purchase.paymentAmount) || 0;
      if (paid > total) {
        setPendingOverpayment({ paid, total });
        return;
      }
    }

    await performSubmit();
  }

  function confirmOverpayment() {
    setPendingOverpayment(null);
    performSubmit();
  }

  function cancelOverpayment() {
    setPendingOverpayment(null);
  }

  async function submitDepositException() {
    if (!pendingDepositException || !pendingDepositException.reason?.trim()) return;
    setSaving(true);
    try {
      const requestId = await requestDepositException(
        pendingDepositException.journeyId,
        pendingDepositException.amount,
        pendingDepositException.reason.trim()
      );
      setPendingDepositException((prev) =>
        prev ? { ...prev, requestId } : null
      );
    } catch (e: any) {
      setPendingDepositException((prev) =>
        prev ? { ...prev, error: e.message ?? "Request failed" } : null
      );
    } finally {
      setSaving(false);
    }
  }

  async function recordPaymentWithException() {
    if (!pendingDepositException?.requestId) return;
    setSaving(true);
    try {
      const idempotencyKey = crypto.randomUUID();
      const outcome = paymentOutcomeForMethod(pendingDepositException.method);
      const paymentEventId = await recordPaymentEvent({
        journeyId: pendingDepositException.journeyId,
        amount: pendingDepositException.amount,
        paymentMethod: pendingDepositException.method,
        idempotencyKey,
        outcome,
        followUpDueAt: purchase.followUpDueAt,
        depositApprovalId: pendingDepositException.requestId,
      });

      setPendingDepositException(null);

      if (outcome === "SUCCEEDED") {
        router.push("/board");
        return;
      }

      setCreated({
        journeyId: pendingDepositException.journeyId,
        paymentEventId,
        outcome,
      });
    } catch (e: any) {
      setPendingDepositException((prev) =>
        prev ? { ...prev, error: e.message ?? "Payment failed" } : null
      );
    } finally {
      setSaving(false);
    }
  }

  function closeDepositException() {
    setPendingDepositException(null);
  }

  async function handleReconcile(newOutcome: PaymentOutcome) {
    if (!created) return;
    setSaving(true);
    setError(null);
    try {
      await reconcilePayment(created.paymentEventId, newOutcome);
      if (newOutcome === "SUCCEEDED") {
        router.push("/board");
      } else {
        setCreated({ ...created, outcome: newOutcome });
        setSaving(false);
      }
    } catch (e: any) {
      setSaving(false);
      setError(e.message ?? "Reconciliation failed");
    }
  }

  if (loading) return <p className="p-8 text-sm text-slate-500">Loading…</p>;

  if (created) {
    return (
      <main className="min-h-screen bg-slate-50 p-8">
        <div className="mx-auto max-w-2xl rounded-lg border border-slate-200 bg-white p-6 shadow-sm">
          <h1 className="text-xl font-semibold text-slate-900">Payment outcome</h1>

          {error && (
            <p className="mt-4 rounded-md bg-amber-50 p-3 text-sm text-amber-700">
              {error}
            </p>
          )}

          {created.outcome === "UNKNOWN" && (
            <div className="mt-4 space-y-4">
              <p className="rounded-md bg-amber-50 p-3 text-sm text-amber-700">
                Confirming payment — please wait. This payment is unresolved, so
                no new payment can be submitted for this order until it is
                reconciled.
              </p>
              <div className="flex gap-2">
                <button
                  onClick={() => handleReconcile("SUCCEEDED")}
                  disabled={saving}
                  className="rounded-md bg-green-600 px-4 py-2 text-sm font-medium text-white hover:bg-green-700 disabled:opacity-50"
                >
                  {saving ? "Reconciling…" : "Mark payment succeeded"}
                </button>
                <button
                  onClick={() => handleReconcile("FAILED")}
                  disabled={saving}
                  className="rounded-md bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
                >
                  Mark payment failed
                </button>
              </div>
            </div>
          )}

          {created.outcome === "FAILED" && (
            <div className="mt-4 space-y-4">
              <p className="rounded-md bg-red-50 p-3 text-sm text-red-700">
                The payment was recorded as failed. No money was collected.
              </p>
              <button
                onClick={() => handleReconcile("SUCCEEDED")}
                disabled={saving}
                className="rounded-md bg-green-600 px-4 py-2 text-sm font-medium text-white hover:bg-green-700 disabled:opacity-50"
              >
                {saving ? "Reconciling…" : "Reconcile to succeeded"}
              </button>
            </div>
          )}

          <div className="mt-6">
            <Link
              href="/board"
              className="text-sm text-slate-500 hover:text-slate-700"
            >
              Back to Board
            </Link>
          </div>
        </div>
      </main>
    );
  }

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
            <div>
              <label className="block text-sm font-medium text-slate-700">Street address</label>
              <input
                value={customer.streetAddress}
                onChange={(e) => setCustomer((c) => ({ ...c, streetAddress: e.target.value }))}
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-slate-700">Address Line 2</label>
              <input
                value={customer.streetAddressLine2}
                onChange={(e) => setCustomer((c) => ({ ...c, streetAddressLine2: e.target.value }))}
                placeholder="Apartment, suite, etc. (optional)"
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
              />
            </div>
            <div className="grid grid-cols-3 gap-3">
              <input placeholder="City" value={customer.city} onChange={(e) => setCustomer((c) => ({ ...c, city: e.target.value }))} className="rounded-md border border-slate-300 px-3 py-2 text-sm" />
              <input placeholder="State" value={customer.state} onChange={(e) => setCustomer((c) => ({ ...c, state: e.target.value }))} className="rounded-md border border-slate-300 px-3 py-2 text-sm" />
              <input placeholder="ZIP" value={customer.zipCode} onChange={(e) => setCustomer((c) => ({ ...c, zipCode: e.target.value }))} className="rounded-md border border-slate-300 px-3 py-2 text-sm" />
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
              storeId={inventoryStoreId}
              onSelect={addLineItem}
            />

            {lineItems.length > 0 && (
              <div className="space-y-2">
                {lineItems.map((item) => (
                  <div
                    key={item.id}
                    className="grid grid-cols-12 items-center gap-2 rounded-md border border-slate-200 bg-slate-50 p-2 text-sm"
                  >
                    <div className="col-span-5 min-w-0 text-slate-900">
                      <div className="truncate">{item.item_name}</div>
                      <select
                        value={item.fulfillment_type_override ?? "inherit"}
                        onChange={(e) =>
                          updateLineItem(item.id, {
                            fulfillment_type_override:
                              e.target.value === "inherit"
                                ? null
                                : (e.target.value as "delivery" | "pickup"),
                            pickup_location_id:
                              e.target.value === "pickup"
                                ? item.pickup_location_id ?? storeId
                                : null,
                          })
                        }
                        className="mt-1 w-full rounded border border-slate-300 bg-white px-1 py-1 text-xs"
                      >
                        <option value="inherit">Inherit Journey ({fulfillmentType})</option>
                        <option value="delivery" disabled={!hasDeliveryAddress}>Delivery</option>
                        <option value="pickup">Pickup</option>
                      </select>
                      {(item.fulfillment_type_override ?? fulfillmentType) === "pickup" && (
                        <select
                          value={item.pickup_location_id ?? storeId}
                          onChange={(e) =>
                            updateLineItem(item.id, { pickup_location_id: e.target.value })
                          }
                          className="mt-1 w-full rounded border border-slate-300 bg-white px-1 py-1 text-xs"
                        >
                          {stores
                            .filter((s) => s.location_type !== "WAREHOUSE_QUARANTINE")
                            .map((s) => (
                              <option key={s.id} value={s.id}>{s.name}</option>
                            ))}
                        </select>
                      )}
                      {item.product_id && (
                        <div className="mt-1 text-xs text-slate-500">
                          Availability: {availability[item.id] ?? "Loading…"}
                        </div>
                      )}
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
              <label className="block text-sm font-medium text-slate-700">Fulfillment</label>
              <select
                value={fulfillmentType}
                onChange={(e) =>
                  setFulfillmentType(e.target.value as "delivery" | "pickup")
                }
                className="mt-1 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              >
                <option value="delivery" disabled={!hasDeliveryAddress}>Delivery</option>
                <option value="pickup">Pickup</option>
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
                onClick={() => lineItems.length > 0 && (fulfillmentType === "pickup" || hasDeliveryAddress) && setStep(3)}
                disabled={lineItems.length === 0 || (fulfillmentType === "delivery" && !hasDeliveryAddress)}
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

      {pendingOverpayment && (
        <Modal onClose={cancelOverpayment} saving={saving}>
          <div className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-2 text-lg font-semibold text-slate-900">
              Overpayment confirmation
            </h2>
            <p className="mb-4 text-sm text-slate-600">
              This payment is{" "}
              <strong>${(pendingOverpayment.paid - pendingOverpayment.total).toFixed(2)}</strong>{" "}
              more than the{" "}
              <strong>${pendingOverpayment.total.toFixed(2)}</strong> owed. The customer will
              have a{" "}
              <strong>${(pendingOverpayment.paid - pendingOverpayment.total).toFixed(2)}</strong>{" "}
              credit on their account. Continue?
            </p>
            <div className="flex gap-2">
              <button
                onClick={confirmOverpayment}
                className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700"
              >
                Record payment
              </button>
              <button
                onClick={cancelOverpayment}
                className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
            </div>
          </div>
        </Modal>
      )}

      {pendingDepositException && (
        <Modal
          onClose={closeDepositException}
          dirty={!!pendingDepositException.reason?.trim() && !pendingDepositException.requestId}
          saving={saving}
        >
          <div className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-2 text-lg font-semibold text-slate-900">
              Deposit exception
            </h2>
            <p className="mb-4 text-sm text-slate-600">
              The proposed payment of{" "}
              <strong>${pendingDepositException.amount.toFixed(2)}</strong> is below the
              required deposit for this order.
            </p>

            {pendingDepositException.error && (
              <p className="mb-4 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-700">
                {pendingDepositException.error}
              </p>
            )}

            {!pendingDepositException.requestId ? (
              <div className="space-y-3">
                <div>
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    Reason for exception
                  </label>
                  <textarea
                    value={pendingDepositException.reason ?? ""}
                    onChange={(e) =>
                      setPendingDepositException((prev) =>
                        prev ? { ...prev, reason: e.target.value } : null
                      )
                    }
                    className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    rows={3}
                    placeholder="Explain why this below-floor payment should be accepted"
                  />
                </div>
                <div className="flex gap-2">
                  <button
                    onClick={submitDepositException}
                    disabled={!pendingDepositException.reason?.trim()}
                    className="flex-1 rounded-md bg-amber-600 px-3 py-2 text-sm font-medium text-white hover:bg-amber-700 disabled:opacity-50"
                  >
                    Request approval
                  </button>
                  <button
                    onClick={closeDepositException}
                    className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                  >
                    Cancel
                  </button>
                </div>
              </div>
            ) : (
              <div className="space-y-3">
                <p className="rounded-md bg-slate-50 p-3 text-sm text-slate-700">
                  Exception request submitted. An owner, admin, or manager must approve it in
                  Settings &gt; Deposit Approvals before the payment can be recorded.
                </p>
                <button
                    onClick={recordPaymentWithException}
                    className="w-full rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700"
                  >
                    Try recording payment now
                  </button>
                  <button
                    onClick={closeDepositException}
                    className="w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                  >
                    Close
                  </button>
              </div>
            )}
          </div>
        </Modal>
      )}
    </main>
  );
}
