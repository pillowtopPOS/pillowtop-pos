"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import {
  fetchCurrentEmployee,
  fetchStores,
  type Employee,
  type Store,
} from "@/lib/journeys/queries";
import { hasPermission } from "@/lib/inventory/queries";

// Statuses are stored as codes; the page always shows plain English.
const STATUS_LABEL: Record<string, string> = {
  STOCK: "In stock",
  RESERVED: "Held for a customer",
  IN_TRANSIT: "On a transfer",
  STAGED: "Staged for delivery",
  DELIVERED: "Delivered",
  RETURNED: "Returned",
  QUARANTINE: "In quarantine",
  DAMAGED: "Damaged",
  MISSING: "Missing",
  VOID: "Voided",
};

type UnitRow = {
  id: string;
  unit_number: number;
  status: string;
  location_id: string | null;
  disposition: string;
  assigned_requirement_id: string | null;
  delivered_journey_id: string | null;
  purchase_order_line_item_id: string | null;
  voided_at: string | null;
  void_reason: string | null;
  voided_by: string | null;
  created_at: string;
  product_id: string;
};

type UnitEvent = {
  id: string;
  event_type: string;
  actor_id: string | null;
  journey_id: string | null;
  from_status: string | null;
  to_status: string | null;
  from_location_id: string | null;
  to_location_id: string | null;
  created_at: string;
};

type Discrepancy = {
  product_id: string;
  location_id: string;
  disposition: string;
  units_on_hand: number;
  mirror_on_hand: number;
  units_reserved: number;
  mirror_committed: number;
};

type LookupState =
  | { kind: "idle" }
  | { kind: "loading" }
  | { kind: "found"; unit: UnitRow }
  | { kind: "notfound" }
  | { kind: "failed"; message: string };

function eventLine(
  e: UnitEvent,
  locName: (id: string | null) => string,
  actorName: (id: string | null) => string
): string {
  const who = e.actor_id ? ` by ${actorName(e.actor_id)}` : "";
  const to = e.to_status ? STATUS_LABEL[e.to_status] ?? e.to_status : "?";
  const from = e.from_status
    ? STATUS_LABEL[e.from_status] ?? e.from_status
    : null;
  const dest = e.to_location_id ? ` at ${locName(e.to_location_id)}` : "";
  switch (e.event_type) {
    case "UNIT_CREATED":
      return `Received into stock${dest}${who}`;
    case "UNIT_MOVED":
      if (e.from_status === e.to_status) {
        return `Condition or version changed${dest}${who}`;
      }
      return `${from ?? "?"} to ${to}${dest}${who}`;
    case "UNIT_VOIDED":
      return `Voided${who}`;
    case "UNIT_RECLASSIFIED":
      return `Condition changed${dest}${who}`;
    default:
      return `${e.event_type}${who}`;
  }
}

export default function UnitsPage() {
  const supabase = createClient();
  const inputRef = useRef<HTMLInputElement>(null);
  const mounted = useRef(true);
  const lookupSeq = useRef(0);

  const [employee, setEmployee] = useState<Employee | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [companyId, setCompanyId] = useState<string | null>(null);
  const [canSeeDiscrepancies, setCanSeeDiscrepancies] = useState(false);

  const [query, setQuery] = useState("");
  const [searched, setSearched] = useState("");
  const [lookup, setLookup] = useState<LookupState>({ kind: "idle" });
  const [events, setEvents] = useState<UnitEvent[]>([]);
  const [eventsState, setEventsState] = useState<
    "idle" | "loading" | "ready" | "failed"
  >("idle");
  const [actorNames, setActorNames] = useState<Map<string, string>>(new Map());
  const [productInfo, setProductInfo] = useState<{
    item_name: string;
    sku: string;
  } | null>(null);
  const [journeyInfo, setJourneyInfo] = useState<{
    journeyId: string;
    customerName: string | null;
  } | null>(null);
  const [poId, setPoId] = useState<string | null>(null);
  const [voidedByName, setVoidedByName] = useState<string | null>(null);

  const [discState, setDiscState] = useState<
    "idle" | "loading" | "ready" | "failed" | "denied"
  >("idle");
  const [discRows, setDiscRows] = useState<Discrepancy[]>([]);
  const [discProduct, setDiscProduct] = useState<Map<string, string>>(new Map());
  const [showDisc, setShowDisc] = useState(false);

  const locName = (id: string | null) =>
    stores.find((s) => s.id === id)?.name ?? "unknown location";
  const actorName = (id: string | null) =>
    (id && actorNames.get(id)) || "an employee";

  // Mount-time load: employee, stores, company, permission.
  useEffect(() => {
    mounted.current = true;
    let cancelled = false;
    (async () => {
      const [emp, storeList] = await Promise.all([
        fetchCurrentEmployee(),
        fetchStores(),
      ]);
      if (cancelled) return;
      setEmployee(emp);
      setStores(storeList);
      const cid =
        storeList.find((s) => s.id === emp?.home_store_id)?.company_id ??
        null;
      setCompanyId(cid);
      const allowed = await hasPermission("units.manage_settings");
      if (!cancelled) setCanSeeDiscrepancies(allowed);
      inputRef.current?.focus();
    })().catch(() => {});
    return () => {
      cancelled = true;
      mounted.current = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function loadEvents(unitId: string, seq: number) {
    setEventsState("loading");
    const { data, error } = await supabase
      .from("unit_events")
      .select(
        "id, event_type, actor_id, journey_id, from_status, to_status, from_location_id, to_location_id, created_at"
      )
      .eq("unit_id", unitId)
      .order("created_at", { ascending: true })
      .order("id", { ascending: true });
    if (seq !== lookupSeq.current || !mounted.current) return;
    if (error) {
      setEventsState("failed");
      return;
    }
    const rows = (data ?? []) as UnitEvent[];
    setEvents(rows);
    setEventsState("ready");
    const actorIds = Array.from(
      new Set(rows.map((r) => r.actor_id).filter(Boolean))
    ) as string[];
    if (actorIds.length > 0) {
      const { data: emps } = await supabase
        .from("employees")
        .select("id, name")
        .in("id", actorIds);
      if (seq !== lookupSeq.current || !mounted.current) return;
      if (emps) {
        setActorNames(
          new Map(emps.map((e: any) => [e.id, e.name as string]))
        );
      }
    }
  }

  async function runLookup() {
    const digits = query.replace(/\D/g, "");
    if (!digits) return;
    const seq = ++lookupSeq.current;
    setSearched(digits);
    setLookup({ kind: "loading" });
    setEventsState("idle");
    setEvents([]);
    setProductInfo(null);
    setJourneyInfo(null);
    setPoId(null);
    setVoidedByName(null);
    try {
      const { data, error } = await supabase
        .from("units")
        .select(
          "id, unit_number, status, location_id, disposition, assigned_requirement_id, delivered_journey_id, purchase_order_line_item_id, voided_at, void_reason, voided_by, created_at, product_id"
        )
        .eq("unit_number", Number(digits))
        .maybeSingle();
      if (error) throw new Error(error.message);
      if (seq !== lookupSeq.current || !mounted.current) return;
      if (!data) {
        setLookup({ kind: "notfound" });
        inputRef.current?.focus();
        inputRef.current?.select();
        return;
      }
      const unit = data as UnitRow;
      setLookup({ kind: "found", unit });
      inputRef.current?.focus();
      inputRef.current?.select();
      void loadEvents(unit.id, seq);
      // Names come from products_public: the base products table holds
      // cost and is only readable by owner/admin/manager.
      void (async () => {
        const { data: prod } = await supabase
          .from("products_public")
          .select("id, item_name, sku")
          .eq("id", unit.product_id)
          .maybeSingle();
        if (seq !== lookupSeq.current || !mounted.current) return;
        if (prod) setProductInfo({ item_name: prod.item_name, sku: prod.sku });
      })();

      // Assigned or delivered customer: requirement -> journey -> customer.
      let journeyId: string | null = unit.delivered_journey_id;
      if (!journeyId && unit.assigned_requirement_id) {
        const { data: req } = await supabase
          .from("journey_inventory_requirements")
          .select("journey_id")
          .eq("id", unit.assigned_requirement_id)
          .maybeSingle();
        journeyId = req?.journey_id ?? null;
        if (seq !== lookupSeq.current || !mounted.current) return;
      }
      if (journeyId && mounted.current) {
        const { data: j } = await supabase
          .from("sleep_journeys")
          .select("id, customers(first_name, last_name)")
          .eq("id", journeyId)
          .maybeSingle();
        if (seq !== lookupSeq.current || !mounted.current) return;
        if (j) {
          const c = (j as any).customers;
          setJourneyInfo({
            journeyId: j.id,
            customerName: c ? `${c.first_name} ${c.last_name}` : null,
          });
        }
      }
      if (unit.purchase_order_line_item_id && mounted.current) {
        const { data: li } = await supabase
          .from("purchase_order_line_items")
          .select("purchase_order_id")
          .eq("id", unit.purchase_order_line_item_id)
          .maybeSingle();
        if (seq !== lookupSeq.current || !mounted.current) return;
        setPoId(li?.purchase_order_id ?? null);
      }
      if (unit.voided_by && mounted.current) {
        const { data: emp } = await supabase
          .from("employees")
          .select("name")
          .eq("id", unit.voided_by)
          .maybeSingle();
        if (seq !== lookupSeq.current || !mounted.current) return;
        setVoidedByName(emp?.name ?? null);
      }
    } catch (e: any) {
      if (seq === lookupSeq.current && mounted.current) {
        setLookup({
          kind: "failed",
          message: e.message ?? "Something went wrong",
        });
        inputRef.current?.focus();
        inputRef.current?.select();
      }
    }
  }

  async function loadDiscrepancies() {
    if (!companyId) return;
    setDiscState("loading");
    try {
      const { data, error } = await supabase.rpc("get_unit_discrepancies", {
        p_company_id: companyId,
      });
      if (error) {
        if (error.message.includes("permission") || error.message.includes("yours"))
          setDiscState("denied");
        else setDiscState("failed");
        return;
      }
      const rows = (data ?? []) as Discrepancy[];
      setDiscRows(rows);
      setDiscState("ready");
      const ids = Array.from(new Set(rows.map((r) => r.product_id)));
      if (ids.length > 0) {
        const { data: prods } = await supabase
          .from("products_public")
          .select("id, item_name, sku")
          .in("id", ids);
        if (mounted.current)
          setDiscProduct(
            new Map(
              (prods ?? []).map((p: any) => [
                p.id,
                `${p.item_name} (${p.sku})`,
              ])
            )
          );
      }
    } catch {
      if (mounted.current) setDiscState("failed");
    }
  }

  const unit = lookup.kind === "found" ? lookup.unit : null;

  return (
    <main className="mx-auto max-w-2xl p-6">
      <Link
        href="/inventory"
        className="text-sm text-brand-600 hover:underline"
      >
        &larr; Inventory
      </Link>
      <h1 className="mt-1 text-xl font-semibold text-slate-900">Units</h1>
      <p className="mt-1 text-sm text-slate-500">
        Look up a unit by its number or scan its label.
      </p>

      <form
        className="mt-4"
        onSubmit={(e) => {
          e.preventDefault();
          void runLookup();
        }}
      >
        <input
          ref={inputRef}
          inputMode="numeric"
          maxLength={15}
          onFocus={(e) => e.target.select()}
          value={query}
          onChange={(e) => setQuery(e.target.value.replace(/\D/g, ""))}
          placeholder="Unit number"
          className="w-full rounded-md border border-slate-300 px-4 py-3 text-lg"
        />
      </form>

      {lookup.kind === "loading" && (
        <p key="lookup-loading" className="mt-4 text-sm text-slate-500">
          Looking it up...
        </p>
      )}
      {lookup.kind === "notfound" && (
        <p key="lookup-notfound" className="mt-4 text-sm text-slate-700">
          No unit with number {searched}.
        </p>
      )}
      {lookup.kind === "failed" && (
        <div key="lookup-failed" className="mt-4">
          <p className="text-sm text-red-600">{lookup.message}</p>
          <button
            onClick={() => void runLookup()}
            className="mt-2 rounded-md border border-slate-300 px-3 py-1 text-sm text-slate-700 hover:bg-slate-50"
          >
            Retry
          </button>
        </div>
      )}

      {unit && (
        <div key="unit-card" className="mt-6 rounded-lg border border-slate-200 bg-white p-5 shadow-sm">
          <div className="flex items-start justify-between gap-3">
            <p className="text-3xl font-bold text-slate-900">
              #{unit.unit_number}
            </p>
            <span className="rounded-full bg-slate-100 px-3 py-1 text-sm font-medium text-slate-700">
              {STATUS_LABEL[unit.status] ?? unit.status}
            </span>
          </div>
          <dl className="mt-3 space-y-1 text-sm text-slate-700">
            <div>
              <dt className="inline font-medium">Product: </dt>
              <dd className="inline">
                {productInfo?.item_name ?? "Unknown"} (
                {productInfo?.sku ?? "?"})
              </dd>
            </div>
            <div>
              <dt className="inline font-medium">Location: </dt>
              <dd className="inline">{locName(unit.location_id)}</dd>
            </div>
            <div>
              <dt className="inline font-medium">Condition: </dt>
              <dd className="inline">{unit.disposition}</dd>
            </div>
            {journeyInfo && (
              <div>
                <dt className="inline font-medium">Customer: </dt>
                <dd className="inline">
                  <Link
                    href={`/board?journey=${journeyInfo.journeyId}`}
                    className="text-brand-600 hover:underline"
                  >
                    {journeyInfo.customerName ?? "View journey"}
                  </Link>
                </dd>
              </div>
            )}
            {poId && (
              <div>
                <dt className="inline font-medium">Purchase order: </dt>
                <dd className="inline">
                  <Link
                    href={`/purchase-orders/${poId}`}
                    className="text-brand-600 hover:underline"
                  >
                    View
                  </Link>
                </dd>
              </div>
            )}
            {unit.status === "VOID" && (
              <div>
                <dt className="inline font-medium">Voided: </dt>
                <dd className="inline">
                  {unit.voided_at
                    ? new Date(unit.voided_at).toLocaleDateString()
                    : ""}
                  {voidedByName ? ` by ${voidedByName}` : ""}
                  {unit.void_reason ? ` - ${unit.void_reason}` : ""}
                </dd>
              </div>
            )}
          </dl>

          {unit.status !== "VOID" && (
            <a
              href={`/units/labels/print?numbers=${unit.unit_number}`}
              target="_blank"
              rel="noopener noreferrer"
              className="mt-3 inline-block rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50"
            >
              Reprint label
            </a>
          )}

          <h2 className="mt-5 text-sm font-semibold text-slate-900">
            History
          </h2>
          {eventsState === "loading" && (
            <p key="events-loading" className="mt-2 text-sm text-slate-500">
              Loading history...
            </p>
          )}
          {eventsState === "failed" && (
            <div key="events-failed" className="mt-2">
              <p className="text-sm text-red-600">
                History could not be loaded.
              </p>
              <button
                onClick={() =>
                  unit && void loadEvents(unit.id, lookupSeq.current)
                }
                className="mt-1 rounded-md border border-slate-300 px-3 py-1 text-sm text-slate-700 hover:bg-slate-50"
              >
                Retry
              </button>
            </div>
          )}
          {eventsState === "ready" && events.length === 0 && (
            <p key="events-empty" className="mt-2 text-sm text-slate-500">
              No history yet.
            </p>
          )}
          {eventsState === "ready" && events.length > 0 && (
            <ul key="events-list" className="mt-2 space-y-1">
              {events.map((e) => (
                <li key={e.id} className="text-sm text-slate-600">
                  <span className="text-slate-400">
                    {new Date(e.created_at).toLocaleString()}
                  </span>{" "}
                  {eventLine(e, locName, actorName)}
                </li>
              ))}
            </ul>
          )}
        </div>
      )}

      {canSeeDiscrepancies && (
        <div key="disc-section" className="mt-8 rounded-lg border border-slate-200 bg-white p-5">
          <button
            onClick={() => {
              setShowDisc((v) => !v);
              if (discState === "idle" || discState === "failed")
                void loadDiscrepancies();
            }}
            className="text-sm font-semibold text-slate-900 hover:underline"
          >
            Discrepancies
          </button>
          {showDisc && (
            <div key="disc-body" className="mt-3">
              {!companyId && (
                <p key="disc-noco" className="mt-3 text-sm text-slate-600">
                  Your account could not be matched to a company.
                </p>
              )}
              <p className="text-xs text-slate-500">
                When the unit list and the stock count disagree, someone
                should look at why.
              </p>
              {discState === "loading" && (
                <p key="disc-loading" className="mt-3 text-sm text-slate-500">
                  Checking...
                </p>
              )}
              {discState === "failed" && (
                <div key="disc-failed" className="mt-3">
                  <p className="text-sm text-red-600">
                    The check could not run. Try again later.
                  </p>
                  <button
                    onClick={() => void loadDiscrepancies()}
                    className="mt-1 rounded-md border border-slate-300 px-3 py-1 text-sm text-slate-700 hover:bg-slate-50"
                  >
                    Retry
                  </button>
                </div>
              )}
              {discState === "denied" && (
                <p key="disc-denied" className="mt-3 text-sm text-slate-600">
                  You do not have permission to view this.
                </p>
              )}
              {discState === "ready" && discRows.length === 0 && (
                <div key="disc-empty" className="mt-3">
                  <p className="text-sm text-slate-700">
                    Units and stock agree.
                  </p>
                  <p className="mt-1 text-xs text-slate-500">
                    Only products with Unit ID turned on are checked.
                  </p>
                </div>
              )}
              {discState === "ready" && discRows.length > 0 && (
                <table key="disc-table" className="mt-3 w-full text-sm">
                  <thead>
                    <tr className="text-left text-xs text-slate-500">
                      <th className="pb-1">Product</th>
                      <th className="pb-1">Location</th>
                      <th className="pb-1">Condition</th>
                      <th className="pb-1 text-right">Units say</th>
                      <th className="pb-1 text-right">Stock says</th>
                      <th className="pb-1 text-right">Difference</th>
                      <th className="pb-1 text-right">Reserved</th>
                    </tr>
                  </thead>
                  <tbody>
                    {discRows.map((r) => (
                      <tr
                        key={`${r.product_id}-${r.location_id}-${r.disposition}`}
                        className="border-t border-slate-100"
                      >
                        <td className="py-1">
                          {discProduct.get(r.product_id) ?? r.product_id}
                        </td>
                        <td className="py-1">{locName(r.location_id)}</td>
                        <td className="py-1">{r.disposition}</td>
                        <td className="py-1 text-right">{r.units_on_hand}</td>
                        <td className="py-1 text-right">{r.mirror_on_hand}</td>
                        <td className="py-1 text-right font-medium text-amber-700">
                          {r.units_on_hand - r.mirror_on_hand}
                        </td>
                        <td
                          className={`py-1 text-right ${
                            r.units_reserved !== r.mirror_committed
                              ? "font-medium text-amber-700"
                              : ""
                          }`}
                        >
                          {r.units_reserved}/{r.mirror_committed}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>
          )}
        </div>
      )}
    </main>
  );
}
