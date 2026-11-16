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
import { fetchProductAvailabilityByLocation, type LocationAvailability } from "@/lib/inventory/queries";
import { fetchInTransitArrivals } from "@/lib/transfers/queries";
import { resolveLineItemLocation } from "@/lib/journeys/fulfillment";
import Modal from "@/components/Modal";
import { isStoreConfirmedToday, storeSelectUrl } from "@/lib/journeys/storeConfirm";
import {
  defaultAssigneeId,
  parseAssigneeChoice,
} from "@/lib/journeys/assignee";
import { formatPhone, formatPhoneAsYouType } from "@/lib/format/phone";
import { REFERRAL_SOURCES } from "@/lib/customers/referralSources";
import {
  fetchMatchingCustomers,
  customerDisplayName,
  type CustomerMatch,
} from "@/lib/customers/lookup";
import {
  getCustomer,
  addCustomerAddress,
  setJourneyShipTo,
  type CustomerAddress,
} from "@/lib/customers/api";
import { formatShipToLine } from "@/lib/customers/shipTo";

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
    isCompany: false,
    companyName: "",
    firstName: "",
    lastName: "",
    phone: "",
    phone2: "",
    email: "",
    referralSource: "",
    streetAddress: "",
    streetAddressLine2: "",
    city: "",
    state: "",
    zipCode: "",
  });
  // Repeat-customer lookup (m142): candidates from find_matching_customers,
  // ids the rep dismissed, and the customer chosen via "Use this customer".
  const [customerMatches, setCustomerMatches] = useState<CustomerMatch[]>([]);
  const [dismissedMatchIds, setDismissedMatchIds] = useState<Set<string>>(new Set());
  const [selectedCustomer, setSelectedCustomer] = useState<CustomerMatch | null>(null);
  const [storeId, setStoreId] = useState("");
  const [fulfillmentType, setFulfillmentType] = useState<"delivery" | "pickup">("delivery");
  const [assignedEmployeeId, setAssignedEmployeeId] = useState<string | null>(null);
  const [lineItems, setLineItems] = useState<LineItem[]>([]);
  const [locationStock, setLocationStock] = useState<Record<string, LocationAvailability[]>>({});
  const [inTransitArrivals, setInTransitArrivals] = useState<Record<string, Record<string, number>>>({});
  const [stockLoaded, setStockLoaded] = useState(false);
  const [otherStoresItemId, setOtherStoresItemId] = useState<string | null>(null);
  const [otherStoresQuery, setOtherStoresQuery] = useState("");
  const [quoteNotes, setQuoteNotes] = useState("");
  const [purchase, setPurchase] = useState({
    paymentAmount: "",
    paymentMethod: "",
    followUpDueAt: "",
  });
  // Optional contact person for a company customer; saved to
  // customer_contacts after the order exists.
  const [contactPerson, setContactPerson] = useState({
    name: "",
    phone: "",
    role: "",
  });
  // Ship-to for an existing customer (m145): primary, a saved address,
  // or a new one saved after the order exists.
  const [shipToChoice, setShipToChoice] = useState<"primary" | "saved" | "new">("primary");
  const [shipToAddressId, setShipToAddressId] = useState<string | null>(null);
  const [shipToNew, setShipToNew] = useState({
    label: "",
    street: "",
    line2: "",
    city: "",
    state: "",
    zip: "",
  });
  const [savedAddresses, setSavedAddresses] = useState<CustomerAddress[]>([]);
  const [shipToSubmitError, setShipToSubmitError] = useState<string | null>(null);

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
        // Default the salesperson to the signed-in employee; the
        // select still allows any employee or a deliberate Unassigned.
        const me = e.find((emp) => emp.auth_user_id === session.user.id);
        setAssignedEmployeeId(defaultAssigneeId(me ?? null));
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

  // All-locations availability + in-transit arrivals, batched once per
  // distinct product set (not per line item or keystroke).
  const productKey = useMemo(
    () =>
      Array.from(
        new Set(
          lineItems
            .map((i) => i.product_id)
            .filter((x): x is string => !!x)
        )
      )
        .sort()
        .join(","),
    [lineItems]
  );

  useEffect(() => {
    if (loading) return;
    if (!productKey) {
      setLocationStock({});
      setInTransitArrivals({});
      setStockLoaded(true);
      return;
    }
    setStockLoaded(false);
    const ids = productKey.split(",");
    let cancelled = false;
    Promise.all([
      fetchProductAvailabilityByLocation(ids),
      fetchInTransitArrivals(ids),
    ]).then(([stock, arrivals]) => {
      if (cancelled) return;
      setLocationStock(stock);
      setInTransitArrivals(arrivals);
      setStockLoaded(true);
    });
    return () => {
      cancelled = true;
    };
  }, [loading, productKey]);

  const hasDeliveryAddress = customer.streetAddress.trim() !== "";
  // An existing customer who already has a primary address gets it shown
  // read-only here; the Ship to block is the only way to ship elsewhere.
  // With no primary on file the inputs stay editable and are saved as the
  // primary at submit, and there is nothing to choose between yet.
  const existingHasPrimary =
    !!selectedCustomer &&
    (selectedCustomer.street_address ?? "").trim() !== "";

  // Repeat-customer lookup: fires 400ms after the rep stops typing when
  // the phone is a full 10 digits, the email has an @, or both names are
  // 2+ characters. Warn-only: it never gates Continue. Skipped while an
  // existing customer is selected (the panel is collapsed then anyway).
  const lookupPhoneDigits = customer.phone.replace(/\D/g, "");
  const lookupPhoneValid =
    lookupPhoneDigits.length === 10 ||
    (lookupPhoneDigits.length === 11 && lookupPhoneDigits.startsWith("1"));
  const lookupEmailValid = customer.email.includes("@");
  const lookupNameValid = customer.isCompany
    ? customer.companyName.trim().length >= 2
    : customer.firstName.trim().length >= 2 &&
      customer.lastName.trim().length >= 2;
  const lookupActive =
    !selectedCustomer &&
    (lookupPhoneValid || lookupEmailValid || lookupNameValid);

  useEffect(() => {
    if (!lookupActive) {
      setCustomerMatches([]);
      return;
    }
    let cancelled = false;
    const handle = setTimeout(() => {
      fetchMatchingCustomers({
        first: customer.isCompany ? customer.companyName : customer.firstName,
        last: customer.isCompany ? null : customer.lastName,
        phone: customer.phone,
        email: customer.email,
      }).then((rows) => {
        if (!cancelled) setCustomerMatches(rows);
      });
    }, 400);
    return () => {
      cancelled = true;
      clearTimeout(handle);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [
    lookupActive,
    customer.isCompany,
    customer.companyName,
    customer.firstName,
    customer.lastName,
    customer.phone,
    customer.email,
  ]);

  const visibleMatches = customerMatches.filter(
    (m) => !dismissedMatchIds.has(m.id)
  );

  function useCustomerMatch(match: CustomerMatch) {
    setCustomer({
      isCompany: match.is_company === true,
      companyName: match.is_company
        ? (match.company_name ?? match.first_name ?? "")
        : "",
      firstName: match.first_name ?? "",
      lastName: match.last_name ?? "",
      phone: formatPhone(match.phone),
      phone2: formatPhone(match.phone2),
      email: match.email ?? "",
      referralSource: match.referral_source ?? "",
      streetAddress: match.street_address ?? "",
      streetAddressLine2: match.street_address_line_2 ?? "",
      city: match.city ?? "",
      state: match.state ?? "",
      zipCode: match.zip_code ?? "",
    });
    setSelectedCustomer(match);
    setShipToChoice("primary");
    setShipToAddressId(null);
    setShipToNew({ label: "", street: "", line2: "", city: "", state: "", zip: "" });
    setSavedAddresses([]);
    getCustomer(match.id)
      .then((d) => setSavedAddresses(d.addresses ?? []))
      .catch(() => setSavedAddresses([]));
  }

  function clearSelectedCustomer() {
    setSelectedCustomer(null);
    setShipToChoice("primary");
    setShipToAddressId(null);
    setSavedAddresses([]);
  }

  // With an existing customer selected, address edits write back to that
  // customer's row (and therefore their earlier orders) at submit time.
  const selectedAddressDirty = (() => {
    if (!selectedCustomer) return false;
    const norm = (v: string | null | undefined) => (v ?? "").trim();
    return (
      norm(customer.streetAddress) !== norm(selectedCustomer.street_address) ||
      norm(customer.streetAddressLine2) !== norm(selectedCustomer.street_address_line_2) ||
      norm(customer.city) !== norm(selectedCustomer.city) ||
      norm(customer.state) !== norm(selectedCustomer.state) ||
      norm(customer.zipCode) !== norm(selectedCustomer.zip_code)
    );
  })();

  const canSubmitQuote = useMemo(() => {
    const nameOk = customer.isCompany
      ? customer.companyName.trim().length > 0
      : !!customer.firstName && !!customer.lastName;
    return (
      nameOk &&
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
      customerId: selectedCustomer?.id ?? null,
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
      contactPerson: customer.isCompany ? contactPerson : null,
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
      const result = await createJourney(input);
      journeyId = result.journeyId;

      // Post-order extras (contact person, ship-to) must never fail the
      // order; collect warnings for the next screen instead.
      const orderNotices: string[] = [];
      if (result.contactWarning) {
        orderNotices.push(`Contact person: ${result.contactWarning}`);
      }
      if (
        fulfillmentType === "delivery" &&
        selectedCustomer &&
        shipToChoice !== "primary"
      ) {
        try {
          let shipToId: string | null = null;
          if (shipToChoice === "saved") {
            shipToId = shipToAddressId;
          } else if (shipToNew.street.trim()) {
            const created = await addCustomerAddress(selectedCustomer.id, {
              label: shipToNew.label.trim() || null,
              street_address: shipToNew.street.trim(),
              street_address_line_2: shipToNew.line2.trim() || null,
              city: shipToNew.city.trim() || null,
              state: shipToNew.state.trim() || null,
              zip_code: shipToNew.zip.trim() || null,
            });
            shipToId = created.id;
          }
          if (shipToId) {
            await setJourneyShipTo(journeyId, shipToId);
          }
        } catch (e: any) {
          orderNotices.push(
            `Delivery address: ${e?.message ?? "could not be set"}`
          );
        }
      }
      if (orderNotices.length > 0) {
        try {
          window.sessionStorage.setItem(
            "pt_new_order_contact_warning",
            orderNotices.join(" ")
          );
        } catch {
          // best-effort notice only
        }
      }

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

    setShipToSubmitError(null);
    if (
      fulfillmentType === "delivery" &&
      selectedCustomer &&
      existingHasPrimary &&
      shipToChoice === "new" &&
      !shipToNew.street.trim()
    ) {
      setShipToSubmitError(
        "Enter a street address or choose another delivery address"
      );
      return;
    }

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

  function linePickupLocationId(item: LineItem): string {
    return resolveLineItemLocation(
      item,
      { store_id: storeId, fulfillment_type: fulfillmentType },
      stores
    );
  }

  function pickupIsWarehouse(item: LineItem): boolean {
    if ((item.fulfillment_type_override ?? fulfillmentType) !== "pickup") {
      return false;
    }
    const loc = stores.find((s) => s.id === linePickupLocationId(item));
    return !!loc && loc.location_type !== "STORE";
  }

  type StockRow = {
    id: string;
    name: string;
    available: number;
    arriving: number;
  };

  // Stock breakdown for one line: warehouses always, the pickup store for
  // pickup lines, and every other stocked location sorted for the modal.
  function stockBreakdown(item: LineItem): {
    warehouses: StockRow[];
    pickup: StockRow | null;
    others: StockRow[];
  } | null {
    if (!item.product_id || !stockLoaded) return null;

    const stock = locationStock[item.product_id] ?? [];
    const arrivals = inTransitArrivals[item.product_id] ?? {};
    const byLocation = new Map<string, number>();
    for (const row of stock) {
      byLocation.set(
        row.location_id,
        (byLocation.get(row.location_id) ?? 0) + row.available
      );
    }
    const visible = stores.filter(
      (s) => s.location_type !== "WAREHOUSE_QUARANTINE"
    );
    const toRow = (s: Store): StockRow => ({
      id: s.id,
      name: s.name,
      available: byLocation.get(s.id) ?? 0,
      arriving: arrivals[s.id] ?? 0,
    });

    const warehouses = visible
      .filter((s) => s.location_type === "WAREHOUSE")
      .map(toRow);
    const isPickup =
      (item.fulfillment_type_override ?? fulfillmentType) === "pickup";
    const pickupId = linePickupLocationId(item);
    const pickup = isPickup
      ? visible.map(toRow).find((r) => r.id === pickupId) ?? null
      : null;

    const shownIds = new Set<string>(warehouses.map((w) => w.id));
    if (pickup) shownIds.add(pickup.id);
    const others = visible
      .filter((s) => !shownIds.has(s.id))
      .map(toRow)
      .filter((r) => r.available > 0 || r.arriving > 0)
      .sort(
        (a, b) => b.available - a.available || a.name.localeCompare(b.name)
      );

    return { warehouses, pickup, others };
  }

  function stockCountText(r: StockRow): string {
    return `${r.available}${r.arriving > 0 ? `, ${r.arriving} arriving` : ""}`;
  }

  function renderStockBlock(item: LineItem) {
    const bd = stockBreakdown(item);
    if (!bd) {
      return <div className="mt-2 text-xs text-slate-500">Loading…</div>;
    }
    const isPickup =
      (item.fulfillment_type_override ?? fulfillmentType) === "pickup";
    return (
      <div className="mt-2 space-y-0.5 text-xs text-slate-500">
        {bd.warehouses.length > 0 && (
          <div>
            Warehouse:{" "}
            {bd.warehouses.map((w) => `${w.name} ${stockCountText(w)}`).join(" · ")}
          </div>
        )}
        {isPickup && bd.pickup && (
          <div>
            Pickup store: {bd.pickup.name} {stockCountText(bd.pickup)}
          </div>
        )}
        {bd.others.length > 0 && (
          <button
            type="button"
            onClick={() => {
              setOtherStoresQuery("");
              setOtherStoresItemId(item.id);
            }}
            className="text-brand-700 hover:underline"
          >
            Check other stores ({bd.others.length})
          </button>
        )}
      </div>
    );
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

            {selectedCustomer ? (
              <div className="flex items-center justify-between rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-800">
                <span>
                  Using existing customer:{" "}
                  {customerDisplayName(selectedCustomer)}.
                </span>
                <button
                  type="button"
                  onClick={clearSelectedCustomer}
                  className="ml-3 shrink-0 font-medium text-emerald-700 underline hover:text-emerald-900"
                >
                  Change
                </button>
              </div>
            ) : visibleMatches.length > 0 ? (
              <div className="rounded-md border border-slate-200 bg-slate-50 p-3">
                <p className="mb-2 text-xs font-medium uppercase text-slate-500">
                  Possible existing customers
                </p>
                <div className="space-y-2">
                  {visibleMatches.map((m) => {
                    const nameOnly =
                      m.reasons.length === 1 && m.reasons[0] === "name";
                    const addrLine = [
                      [m.street_address, m.street_address_line_2]
                        .filter(Boolean)
                        .join(" "),
                      [m.city, m.state, m.zip_code].filter(Boolean).join(", "),
                    ]
                      .filter(Boolean)
                      .join(" - ");
                    const orderLine =
                      m.journey_count > 0
                        ? `${m.journey_count} order${m.journey_count === 1 ? "" : "s"}${
                            m.last_order_at
                              ? `, last ${new Date(m.last_order_at).toLocaleDateString()}`
                              : ""
                          }`
                        : "No orders yet";
                    return (
                      <div
                        key={m.id}
                        className={`rounded-md border bg-white p-2 text-sm ${
                          nameOnly ? "border-slate-200 opacity-80" : "border-amber-200"
                        }`}
                      >
                        <div className="flex items-start justify-between gap-2">
                          <div className="min-w-0">
                            <p className="font-medium text-slate-900">
                              {customerDisplayName(m)}
                              {m.is_company && (
                                <span className="ml-2 rounded-full bg-slate-100 px-2 py-0.5 text-[11px] font-normal text-slate-500">
                                  Company
                                </span>
                              )}
                            </p>
                            <p className="text-xs text-slate-600">
                              {[formatPhone(m.phone), m.phone2 ? formatPhone(m.phone2) : null]
                                .filter(Boolean)
                                .join(" / ") || "No phone"}
                              {m.email ? ` - ${m.email}` : ""}
                            </p>
                            {addrLine && (
                              <p className="text-xs text-slate-500">{addrLine}</p>
                            )}
                            <p className="text-xs text-slate-500">{orderLine}</p>
                            <div className="mt-1 flex flex-wrap gap-1">
                              {m.reasons.map((r) => (
                                <span
                                  key={r}
                                  className="rounded-full bg-slate-100 px-2 py-0.5 text-[11px] text-slate-600"
                                >
                                  {r === "phone"
                                    ? "Same phone"
                                    : r === "email"
                                      ? "Same email"
                                      : "Same name"}
                                </span>
                              ))}
                            </div>
                          </div>
                          <div className="flex shrink-0 flex-col gap-1">
                            <button
                              type="button"
                              onClick={() => useCustomerMatch(m)}
                              className="rounded-md bg-brand-600 px-2 py-1 text-xs font-medium text-white hover:bg-brand-700"
                            >
                              Use this customer
                            </button>
                            <button
                              type="button"
                              onClick={() =>
                                setDismissedMatchIds((s) => new Set(s).add(m.id))
                              }
                              className="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-600 hover:bg-slate-50"
                            >
                              Not the same person
                            </button>
                          </div>
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            ) : null}

            <label className="flex items-center gap-2 text-sm text-slate-700">
              <input
                type="checkbox"
                checked={customer.isCompany}
                disabled={!!selectedCustomer}
                onChange={(e) => {
                  const checked = e.target.checked;
                  setCustomer((c) => ({
                    ...c,
                    isCompany: checked,
                    companyName:
                      checked && !c.companyName.trim()
                        ? `${c.firstName} ${c.lastName}`.trim()
                        : c.companyName,
                  }));
                }}
                className="h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500"
              />
              This is a company
            </label>
            {customer.isCompany ? (
              <div>
                <label className="block text-sm font-medium text-slate-700">Company name</label>
                <input
                  value={customer.companyName}
                  disabled={!!selectedCustomer}
                  onChange={(e) =>
                    setCustomer((c) => ({ ...c, companyName: e.target.value }))
                  }
                  className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                />
              </div>
            ) : (
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-slate-700">First name</label>
                  <input
                    value={customer.firstName}
                    disabled={!!selectedCustomer}
                    onChange={(e) => setCustomer((c) => ({ ...c, firstName: e.target.value }))}
                    className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-slate-700">Last name</label>
                  <input
                    value={customer.lastName}
                    disabled={!!selectedCustomer}
                    onChange={(e) => setCustomer((c) => ({ ...c, lastName: e.target.value }))}
                    className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                </div>
              </div>
            )}
            {customer.isCompany && (
              <fieldset className="rounded-md border border-slate-200 p-3">
                <legend className="px-1 text-xs font-medium uppercase text-slate-500">
                  Contact person (optional)
                </legend>
                <div className="grid grid-cols-3 gap-3">
                  <div>
                    <label className="block text-sm font-medium text-slate-700">Name</label>
                    <input
                      value={contactPerson.name}
                      onChange={(e) =>
                        setContactPerson((c) => ({ ...c, name: e.target.value }))
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-slate-700">Phone</label>
                    <input
                      type="tel"
                      value={contactPerson.phone}
                      onChange={(e) =>
                        setContactPerson((c) => ({
                          ...c,
                          phone: formatPhoneAsYouType(e.target.value),
                        }))
                      }
                      onBlur={(e) =>
                        setContactPerson((c) => ({
                          ...c,
                          phone: formatPhone(e.target.value),
                        }))
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-slate-700">Role</label>
                    <input
                      value={contactPerson.role}
                      onChange={(e) =>
                        setContactPerson((c) => ({ ...c, role: e.target.value }))
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    />
                  </div>
                </div>
              </fieldset>
            )}
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="block text-sm font-medium text-slate-700">Phone</label>
                <input
                  type="tel"
                  value={customer.phone}
                  onChange={(e) =>
                    setCustomer((c) => ({
                      ...c,
                      phone: formatPhoneAsYouType(e.target.value),
                    }))
                  }
                  onBlur={(e) =>
                    setCustomer((c) => ({ ...c, phone: formatPhone(e.target.value) }))
                  }
                  className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                />
              </div>
              <div>
                <label className="block text-sm font-medium text-slate-700">
                  Second phone <span className="font-normal text-slate-400">(optional)</span>
                </label>
                <input
                  type="tel"
                  value={customer.phone2}
                  onChange={(e) =>
                    setCustomer((c) => ({
                      ...c,
                      phone2: formatPhoneAsYouType(e.target.value),
                    }))
                  }
                  onBlur={(e) =>
                    setCustomer((c) => ({ ...c, phone2: formatPhone(e.target.value) }))
                  }
                  className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                />
              </div>
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
              <label className="block text-sm font-medium text-slate-700">
                How did you hear about us?{" "}
                <span className="font-normal text-slate-400">(optional)</span>
              </label>
              <select
                value={customer.referralSource}
                onChange={(e) =>
                  setCustomer((c) => ({ ...c, referralSource: e.target.value }))
                }
                className="mt-1 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              >
                <option value="">Select…</option>
                {REFERRAL_SOURCES.map((r) => (
                  <option key={r} value={r}>
                    {r}
                  </option>
                ))}
              </select>
            </div>
            {existingHasPrimary ? (
              <div className="rounded-md border border-slate-200 bg-slate-50 px-3 py-2">
                <p className="text-sm text-slate-800">
                  {formatShipToLine({
                    street_address: selectedCustomer!.street_address,
                    street_address_line_2:
                      selectedCustomer!.street_address_line_2,
                    city: selectedCustomer!.city,
                    state: selectedCustomer!.state,
                    zip_code: selectedCustomer!.zip_code,
                  })}
                </p>
                <p className="mt-1 text-xs text-slate-500">
                  Edit it on the customer page.
                </p>
              </div>
            ) : (
              <>
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
                {selectedCustomer && selectedAddressDirty && (
                  <p className="rounded-md bg-amber-50 px-3 py-2 text-xs text-amber-700">
                    This also changes the address on this customer&apos;s earlier orders.
                  </p>
                )}
              </>
            )}
            <div className="flex justify-end gap-2">
              <button
                onClick={() => setStep(0)}
                className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Back
              </button>
              <button
                onClick={() =>
                  (customer.isCompany
                    ? customer.companyName.trim()
                    : customer.firstName && customer.lastName) &&
                  customer.phone &&
                  customer.email &&
                  setStep(2)
                }
                disabled={
                  !(customer.isCompany
                    ? customer.companyName.trim()
                    : customer.firstName && customer.lastName) ||
                  !customer.phone ||
                  !customer.email
                }
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
                {lineItems.map((item) => {
                  const isPickupLine =
                    (item.fulfillment_type_override ?? fulfillmentType) === "pickup";
                  return (
                    <div
                      key={item.id}
                      className="rounded-md border border-slate-200 bg-slate-50 p-2 text-sm"
                    >
                      <div className="mb-1 min-w-0 text-slate-900">
                        <div className="truncate">{item.item_name}</div>
                      </div>
                      <div className="grid grid-cols-12 items-stretch gap-2">
                        <div className="col-span-4 min-w-0">
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
                            className="w-full rounded border border-slate-300 bg-white px-1 py-1 text-xs"
                          >
                            <option value="inherit">Inherit Journey ({fulfillmentType})</option>
                            <option value="delivery" disabled={!hasDeliveryAddress}>Delivery</option>
                            <option value="pickup">Pickup</option>
                          </select>
                        </div>
                        <div className="col-span-3 min-w-0">
                          {isPickupLine && (
                            <select
                              value={item.pickup_location_id ?? storeId}
                              onChange={(e) =>
                                updateLineItem(item.id, {
                                  // m032: pickup_location_id is only valid
                                  // when the line's own override is
                                  // 'pickup', so picking a location on an
                                  // inherited line pins it to pickup.
                                  fulfillment_type_override:
                                    item.fulfillment_type_override ?? "pickup",
                                  pickup_location_id: e.target.value,
                                })
                              }
                              className="w-full rounded border border-slate-300 bg-white px-1 py-1 text-xs"
                            >
                              {stores
                                .filter((s) => s.location_type !== "WAREHOUSE_QUARANTINE")
                                .map((s) => (
                                  <option key={s.id} value={s.id}>{s.name}</option>
                                ))}
                            </select>
                          )}
                        </div>
                        <div className="col-span-1">
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
                        <div className="col-span-2">
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
                        <div className="col-span-2 flex items-center justify-end gap-1 text-slate-600">
                          ${(item.quantity * item.unit_price).toFixed(2)}
                          <button
                            onClick={() => removeLineItem(item.id)}
                            className="rounded p-1 text-slate-400 hover:bg-red-100 hover:text-red-600"
                            aria-label="Remove"
                          >
                            <Trash2 className="h-4 w-4" />
                          </button>
                        </div>
                      </div>
                      {pickupIsWarehouse(item) && (
                        <div className="mt-2 text-xs text-amber-700">
                          Pickup is set to the warehouse. The customer will collect it there, no transfer will be made.
                        </div>
                      )}
                      {item.product_id && renderStockBlock(item)}
                    </div>
                  );
                })}
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
            {selectedCustomer && existingHasPrimary && fulfillmentType === "delivery" && (
              <fieldset className="rounded-md border border-slate-200 p-3">
                <legend className="px-1 text-xs font-medium uppercase text-slate-500">
                  Delivery address
                </legend>
                <div className="space-y-2">
                  <label className="flex items-start gap-2 text-sm text-slate-700">
                    <input
                      type="radio"
                      name="new-order-ship-to"
                      checked={shipToChoice === "primary"}
                      onChange={() => setShipToChoice("primary")}
                      className="mt-1"
                    />
                    <span>
                      <span className="font-medium">Primary address</span>
                      <span className="block text-xs text-slate-500">
                        {formatShipToLine({
                          street_address: selectedCustomer.street_address,
                          street_address_line_2:
                            selectedCustomer.street_address_line_2,
                          city: selectedCustomer.city,
                          state: selectedCustomer.state,
                          zip_code: selectedCustomer.zip_code,
                        }) || "No address on file"}
                      </span>
                    </span>
                  </label>
                  {savedAddresses.map((a) => (
                    <label
                      key={a.id}
                      className="flex items-start gap-2 text-sm text-slate-700"
                    >
                      <input
                        type="radio"
                        name="new-order-ship-to"
                        checked={shipToChoice === "saved" && shipToAddressId === a.id}
                        onChange={() => {
                          setShipToChoice("saved");
                          setShipToAddressId(a.id);
                        }}
                        className="mt-1"
                      />
                      <span>
                        <span className="font-medium">
                          {a.label || "Saved address"}
                        </span>
                        <span className="block text-xs text-slate-500">
                          {formatShipToLine(a)}
                        </span>
                      </span>
                    </label>
                  ))}
                  <label className="flex items-start gap-2 text-sm text-slate-700">
                    <input
                      type="radio"
                      name="new-order-ship-to"
                      checked={shipToChoice === "new"}
                      onChange={() => setShipToChoice("new")}
                      className="mt-1"
                    />
                    <span className="font-medium">New address</span>
                  </label>
                  {shipToChoice === "new" && (
                    <div className="space-y-2 rounded-md border border-slate-200 bg-slate-50 p-3">
                      <input
                        value={shipToNew.label}
                        onChange={(e) =>
                          setShipToNew((a) => ({ ...a, label: e.target.value }))
                        }
                        placeholder="Label (optional, e.g. Cabin)"
                        className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                      />
                      <input
                        value={shipToNew.street}
                        onChange={(e) =>
                          setShipToNew((a) => ({ ...a, street: e.target.value }))
                        }
                        placeholder="Street address"
                        className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                      />
                      <input
                        value={shipToNew.line2}
                        onChange={(e) =>
                          setShipToNew((a) => ({ ...a, line2: e.target.value }))
                        }
                        placeholder="Address Line 2 (optional)"
                        className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                      />
                      <div className="grid grid-cols-3 gap-2">
                        <input
                          placeholder="City"
                          value={shipToNew.city}
                          onChange={(e) =>
                            setShipToNew((a) => ({ ...a, city: e.target.value }))
                          }
                          className="rounded-md border border-slate-300 px-3 py-2 text-sm"
                        />
                        <input
                          placeholder="State"
                          value={shipToNew.state}
                          onChange={(e) =>
                            setShipToNew((a) => ({ ...a, state: e.target.value }))
                          }
                          className="rounded-md border border-slate-300 px-3 py-2 text-sm"
                        />
                        <input
                          placeholder="ZIP"
                          value={shipToNew.zip}
                          onChange={(e) =>
                            setShipToNew((a) => ({ ...a, zip: e.target.value }))
                          }
                          className="rounded-md border border-slate-300 px-3 py-2 text-sm"
                        />
                      </div>
                    </div>
                  )}
                </div>
              </fieldset>
            )}
            <div>
              <label className="block text-sm font-medium text-slate-700">Assigned employee</label>
              <select
                value={assignedEmployeeId ?? ""}
                onChange={(e) => setAssignedEmployeeId(parseAssigneeChoice(e.target.value))}
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
            <div className="flex items-center justify-end gap-2">
              {shipToSubmitError &&
                fulfillmentType === "delivery" &&
                selectedCustomer &&
                shipToChoice === "new" &&
                !shipToNew.street.trim() && (
                  <p
                    role="alert"
                    className="mr-auto rounded-md bg-red-50 px-3 py-2 text-sm text-red-700"
                  >
                    {shipToSubmitError}
                  </p>
                )}
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

            <div className="flex items-center justify-end gap-2">
              {shipToSubmitError &&
                fulfillmentType === "delivery" &&
                selectedCustomer &&
                shipToChoice === "new" &&
                !shipToNew.street.trim() && (
                  <p
                    role="alert"
                    className="mr-auto rounded-md bg-red-50 px-3 py-2 text-sm text-red-700"
                  >
                    {shipToSubmitError}
                  </p>
                )}
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

      {otherStoresItemId && (() => {
        const item = lineItems.find((i) => i.id === otherStoresItemId);
        if (!item) return null;
        const bd = stockBreakdown(item);
        const q = otherStoresQuery.trim().toLowerCase();
        const rows = (bd?.others ?? []).filter((r) =>
          r.name.toLowerCase().includes(q)
        );
        return (
          <Modal
            onClose={() => {
              setOtherStoresItemId(null);
              setOtherStoresQuery("");
            }}
          >
            <div className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
              <h2 className="mb-4 text-lg font-semibold text-slate-900">
                {item.item_name}
              </h2>
              {(bd?.others.length ?? 0) > 8 && (
                <input
                  value={otherStoresQuery}
                  onChange={(e) => setOtherStoresQuery(e.target.value)}
                  placeholder="Filter stores"
                  className="mb-3 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                />
              )}
              <div className="max-h-80 space-y-1 overflow-y-auto">
                {rows.map((r) => (
                  <div
                    key={r.id}
                    className="flex items-center justify-between text-sm"
                  >
                    <span className="text-slate-700">{r.name}</span>
                    <span className="text-slate-500">{stockCountText(r)}</span>
                  </div>
                ))}
                {rows.length === 0 && (
                  <p className="text-sm text-slate-500">No matching stores.</p>
                )}
              </div>
              <div className="mt-4 flex justify-end">
                <button
                  onClick={() => {
                    setOtherStoresItemId(null);
                    setOtherStoresQuery("");
                  }}
                  className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                >
                  Close
                </button>
              </div>
            </div>
          </Modal>
        );
      })()}

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
