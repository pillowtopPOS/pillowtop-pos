"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import {
  fetchCurrentEmployee,
  fetchStores,
  fetchJourneys,
  type Employee,
  type Store,
  type JourneyWithDetails,
} from "@/lib/journeys/queries";
import type { POFulfillmentType } from "@/lib/purchase-orders/queries";
import type { Product } from "@/lib/inventory/queries";
import LineEditor from "../LineEditor";
import ProductSearch from "../ProductSearch";

type DraftLine = {
  variant_id: string;
  item_name: string;
  quantity_ordered: number;
  unit_cost: number;
};

export default function NewPurchaseOrderPage() {
  const router = useRouter();
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [vendor, setVendor] = useState("");
  const [destination, setDestination] = useState("");
  const [lines, setLines] = useState<DraftLine[]>([]);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);

  const [fulfillment, setFulfillment] = useState<POFulfillmentType>("stock");
  const [journeys, setJourneys] = useState<JourneyWithDetails[]>([]);
  const [journeyQuery, setJourneyQuery] = useState("");
  const [journey, setJourney] = useState<JourneyWithDetails | null>(null);
  const [shipStreet, setShipStreet] = useState("");
  const [shipStreet2, setShipStreet2] = useState("");
  const [shipCity, setShipCity] = useState("");
  const [shipState, setShipState] = useState("");
  const [shipZip, setShipZip] = useState("");

  const canWrite = ["owner", "admin", "manager"].includes(
    employee?.role ?? "",
  );

  useEffect(() => {
    Promise.all([
      fetchCurrentEmployee(),
      fetchStores(true),
      fetchJourneys(),
    ])
      .then(([e, st, j]) => {
        setEmployee(e);
        setStores(st);
        setJourneys(j.filter((x) => !x.cancelled_at));
        setDestination((d) => d || st[0]?.id || "");
      })
      .finally(() => setLoaded(true));
  }, []);

  const journeyOptions = journeys.filter((j) => {
    const q = journeyQuery.trim().toLowerCase();
    if (!q) return true;
    const c = j.customer;
    if (!c) return false;
    return (
      `${c.first_name} ${c.last_name}`.toLowerCase().includes(q) ||
      (c.phone ?? "").toLowerCase().includes(q) ||
      (c.email ?? "").toLowerCase().includes(q)
    );
  });

  function selectJourney(j: JourneyWithDetails) {
    setJourney(j);
    setJourneyQuery("");
    const c = j.customer;
    setShipStreet(c?.street_address ?? "");
    setShipStreet2(c?.street_address_line_2 ?? "");
    setShipCity(c?.city ?? "");
    setShipState(c?.state ?? "");
    setShipZip(c?.zip_code ?? "");
    if (j.store_id) setDestination(j.store_id);
  }

  function addProduct(p: Product) {
    if (lines.some((l) => l.variant_id === p.id)) return;
    setLines((x) => [
      ...x,
      {
        variant_id: p.id,
        item_name: p.item_name,
        quantity_ordered: 1,
        unit_cost: p.cost ?? 0,
      },
    ]);
  }

  async function createPO() {
    if (!vendor.trim() || !destination || !lines.length) return;
    setSaving(true);
    setError(null);
    const s = createClient();
    const { data, error: poError } = await s
      .from("purchase_orders")
      .insert({
        vendor_name: vendor.trim(),
        destination_location_id: destination,
        status: "draft",
        created_by: employee?.id,
        fulfillment_type: fulfillment,
        customer_journey_id: journey?.id ?? null,
        ship_street_address: shipStreet.trim() || null,
        ship_street_address_line_2: shipStreet2.trim() || null,
        ship_city: shipCity.trim() || null,
        ship_state: shipState.trim() || null,
        ship_zip_code: shipZip.trim() || null,
      })
      .select("id")
      .single();
    if (poError || !data) {
      setError(poError?.message ?? "Failed to create purchase order");
      setSaving(false);
      return;
    }
    const { error: lineError } = await s
      .from("purchase_order_line_items")
      .insert(
        lines.map((l) => ({
          purchase_order_id: data.id,
          variant_id: l.variant_id,
          quantity_ordered: l.quantity_ordered,
          unit_cost: l.unit_cost,
        })),
      );
    if (lineError) {
      setError(lineError.message);
      setSaving(false);
      return;
    }
    router.push("/purchase-orders");
  }

  if (loaded && !canWrite) {
    return (
      <main className="min-h-screen bg-slate-50 p-6">
        <div className="mx-auto max-w-3xl">
          <p className="text-sm text-slate-600">
            Only owners, admins, and managers can create purchase orders.{" "}
            <Link href="/purchase-orders" className="text-brand-600">
              Back to list
            </Link>
          </p>
        </div>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-slate-50 p-6">
      <div className="mx-auto max-w-3xl">
        <Link
          href="/purchase-orders"
          className="text-sm text-slate-500 hover:text-slate-700"
        >
          ← Purchase Orders
        </Link>
        <h1 className="mt-2 text-2xl font-semibold text-slate-900">
          New Purchase Order
        </h1>

        <section className="mt-6 rounded-lg border bg-white p-5">
          <div className="mb-4 flex items-center gap-2 text-sm">
            <span className="text-slate-500">Fulfillment:</span>
            <div className="flex rounded-md border border-slate-300">
              {(["stock", "drop_ship"] as const).map((t) => (
                <button
                  key={t}
                  type="button"
                  onClick={() => setFulfillment(t)}
                  className={`px-3 py-1.5 text-sm ${
                    fulfillment === t
                      ? "bg-brand-600 text-white"
                      : "bg-white text-slate-600"
                  }`}
                >
                  {t === "stock" ? "Stock" : "Drop Ship"}
                </button>
              ))}
            </div>
          </div>

          <div className="grid gap-3 sm:grid-cols-2">
            <input
              value={vendor}
              onChange={(e) => setVendor(e.target.value)}
              placeholder="Vendor name"
              className="rounded border px-3 py-2"
            />
            <select
              value={destination}
              onChange={(e) => setDestination(e.target.value)}
              className="rounded border px-3 py-2"
            >
              {stores
                .filter((s) => s.location_type !== "WAREHOUSE_QUARANTINE")
                .map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                  </option>
                ))}
            </select>
          </div>
          {fulfillment === "drop_ship" && (
            <p className="mt-1 text-xs text-slate-500">
              Destination is the store this sale is attributed to — goods ship
              directly to the customer.
            </p>
          )}

          {fulfillment === "drop_ship" && (
            <div className="mt-4 rounded-md border border-slate-200 bg-slate-50 p-3">
              <p className="text-xs font-medium uppercase tracking-wide text-slate-500">
                Ship To
              </p>
              <div className="relative mt-2">
                <input
                  value={journeyQuery}
                  onChange={(e) => setJourneyQuery(e.target.value)}
                  placeholder="Link a customer journey (optional) — search by name…"
                  className="w-full rounded border px-3 py-2 text-sm"
                />
                {journeyQuery.trim() && journeyOptions.length > 0 && (
                  <div className="absolute z-10 mt-1 max-h-48 w-full overflow-y-auto rounded-md border border-slate-200 bg-white shadow-lg">
                    {journeyOptions.slice(0, 10).map((j) => (
                      <button
                        key={j.id}
                        type="button"
                        onClick={() => selectJourney(j)}
                        className="flex w-full items-center justify-between px-3 py-2 text-left text-sm hover:bg-slate-50"
                      >
                        <span>
                          {j.customer
                            ? `${j.customer.first_name} ${j.customer.last_name}`
                            : "Journey"}
                        </span>
                        <span className="text-xs text-slate-400">
                          {j.product_summary ?? ""}
                        </span>
                      </button>
                    ))}
                  </div>
                )}
              </div>
              {journey && (
                <p className="mt-2 text-xs text-slate-600">
                  Linked to{" "}
                  {journey.customer
                    ? `${journey.customer.first_name} ${journey.customer.last_name}`
                    : "journey"}
                  {journey.store?.name ? ` · ${journey.store.name}` : ""}{" "}
                  <button
                    type="button"
                    onClick={() => setJourney(null)}
                    className="text-brand-600"
                  >
                    remove
                  </button>
                </p>
              )}
              <div className="mt-3 grid gap-2 sm:grid-cols-2">
                <input
                  value={shipStreet}
                  onChange={(e) => setShipStreet(e.target.value)}
                  placeholder="Street address"
                  className="rounded border px-3 py-2 text-sm"
                />
                <input
                  value={shipStreet2}
                  onChange={(e) => setShipStreet2(e.target.value)}
                  placeholder="Apt / suite (optional)"
                  className="rounded border px-3 py-2 text-sm"
                />
                <input
                  value={shipCity}
                  onChange={(e) => setShipCity(e.target.value)}
                  placeholder="City"
                  className="rounded border px-3 py-2 text-sm"
                />
                <div className="grid grid-cols-2 gap-2">
                  <input
                    value={shipState}
                    onChange={(e) => setShipState(e.target.value)}
                    placeholder="State"
                    className="rounded border px-3 py-2 text-sm"
                  />
                  <input
                    value={shipZip}
                    onChange={(e) => setShipZip(e.target.value)}
                    placeholder="ZIP"
                    className="rounded border px-3 py-2 text-sm"
                  />
                </div>
              </div>
            </div>
          )}

          <div className="mt-4">
            <ProductSearch
              placeholder="Search products to add…"
              excludeIds={lines.map((l) => l.variant_id)}
              onSelect={addProduct}
            />
          </div>

          <div className="mt-3 space-y-2">
            {lines.map((l, i) => (
              <LineEditor
                key={l.variant_id}
                name={l.item_name}
                quantity={l.quantity_ordered}
                unitCost={l.unit_cost}
                onQuantity={(v) =>
                  setLines((x) =>
                    x.map((a, j) =>
                      j === i ? { ...a, quantity_ordered: v } : a,
                    ),
                  )
                }
                onCost={(v) =>
                  setLines((x) =>
                    x.map((a, j) => (j === i ? { ...a, unit_cost: v } : a)),
                  )
                }
                onRemove={() => setLines((x) => x.filter((_, j) => j !== i))}
              />
            ))}
          </div>

          {error && <p className="mt-3 text-sm text-red-600">{error}</p>}

          <div className="mt-4 flex justify-end">
            <button
              disabled={saving || !vendor.trim() || !lines.length}
              onClick={() => void createPO()}
              className="rounded bg-brand-600 px-4 py-2 text-white disabled:opacity-50"
            >
              {saving ? "Creating…" : "Create"}
            </button>
          </div>
        </section>
      </div>
    </main>
  );
}
