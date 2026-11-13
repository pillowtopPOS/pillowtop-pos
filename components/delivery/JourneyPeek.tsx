"use client";

// Read-only journey peek overlay for the delivery screens (D1-c2b 2c).
// Opens in place so the delivery page keeps its date, scroll and any
// unsaved route/window drafts. Everything shown comes from existing
// read paths — no writes, no actions. "Open full journey" is a plain
// link to /board?journey=<id> (the day plan's unsaved-changes guard
// intercepts it like any other navigation when drafts exist).

import { useEffect, useState } from "react";
import Link from "next/link";
import Modal from "@/components/Modal";
import DeliveryContactPanel from "@/components/delivery/DeliveryContactPanel";
import {
  fetchDeliveryDayPlan,
  fetchJourneyDelivery,
  type JourneyDelivery,
} from "@/lib/delivery/queries";
import {
  timeStrToMinutes,
  windowLabel,
} from "@/lib/delivery/windows";
import {
  fetchJourneyById,
  fetchJourneyLineItems,
  fetchTotalPaid,
  type JourneyLineItem,
  type JourneyWithDetails,
} from "@/lib/journeys/queries";
import { formatPhoneDashed } from "@/lib/delivery/calls";

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

function dayLabel(iso: string): string {
  const d = new Date(`${iso.slice(0, 10)}T00:00:00`);
  return `${WEEKDAYS[d.getDay()]} ${MONTHS[d.getMonth()]} ${d.getDate()}`;
}

function money(n: number | null | undefined): string {
  if (n === null || n === undefined) return "—";
  return `$${n.toFixed(2)}`;
}

type StopPeek = {
  deliveryDate: string;
  truckName: string | null;
  windowText: string | null;
  insideCutoff: boolean;
};

// Callers that already know the stop's truck/window/date (the
// confirmation call list) pass them here; the peek then skips the
// get_delivery_day_plan call, which salespeople cannot run.
export type JourneyPeekStopDetails = {
  deliveryDate: string;
  truckName: string | null;
  windowText: string | null;
  insideCutoff?: boolean;
};

export default function JourneyPeek({
  journeyId,
  onClose,
  stopDetails,
}: {
  journeyId: string;
  onClose: () => void;
  stopDetails?: JourneyPeekStopDetails | null;
}) {
  const [journey, setJourney] = useState<JourneyWithDetails | null | undefined>(
    undefined
  );
  const [items, setItems] = useState<JourneyLineItem[]>([]);
  const [paid, setPaid] = useState(0);
  const [delivery, setDelivery] = useState<JourneyDelivery | null>(null);
  const [stop, setStop] = useState<StopPeek | null>(null);
  const [detailsLoading, setDetailsLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const j = await fetchJourneyById(journeyId);
      if (cancelled) return;
      setJourney(j);
      if (!j) {
        setDetailsLoading(false);
        return;
      }
      const [its, p, del] = await Promise.all([
        fetchJourneyLineItems(journeyId),
        fetchTotalPaid(journeyId).catch(() => 0),
        fetchJourneyDelivery(journeyId).catch(() => null),
      ]);
      if (cancelled) return;
      setItems(its);
      setPaid(p);
      setDelivery(del);
      if (stopDetails) {
        // Caller-supplied stop info (call list): no day-plan call —
        // that RPC is calendar-rights-gated and fails for salespeople.
        setStop({
          deliveryDate: stopDetails.deliveryDate,
          truckName: stopDetails.truckName,
          windowText: stopDetails.windowText,
          insideCutoff: stopDetails.insideCutoff ?? false,
        });
        setDetailsLoading(false);
        return;
      }
      // The stop row itself is RLS-locked; the day plan is the existing
      // read path that carries truck + window for one date.
      const active = del?.active_stop;
      if (active) {
        try {
          const plan = await fetchDeliveryDayPlan(active.delivery_date);
          if (cancelled) return;
          const row = plan.stops.find((s) => s.stop_id === active.id);
          if (row) {
            const truck = plan.trucks.find((t) => t.truck_id === row.truck_id);
            const ws = timeStrToMinutes(row.window_start);
            const we = timeStrToMinutes(row.window_end);
            setStop({
              deliveryDate: active.delivery_date,
              truckName: truck?.name ?? null,
              windowText: windowLabel(ws, we),
              insideCutoff: active.inside_cutoff,
            });
          } else {
            setStop({
              deliveryDate: active.delivery_date,
              truckName: null,
              windowText: null,
              insideCutoff: active.inside_cutoff,
            });
          }
        } catch {
          if (!cancelled)
            setStop({
              deliveryDate: active.delivery_date,
              truckName: null,
              windowText: null,
              insideCutoff: active.inside_cutoff,
            });
        }
      }
      if (!cancelled) setDetailsLoading(false);
    })();
    return () => {
      cancelled = true;
    };
  }, [journeyId, stopDetails]);

  const customer = journey?.customer ?? null;
  const customerName = customer
    ? `${customer.first_name} ${customer.last_name}`.trim()
    : null;
  const balance =
    journey && !journey.cancelled_at && journey.price !== null
      ? journey.price - paid
      : null;

  return (
    <Modal onClose={onClose}>
      <div
        data-testid="journey-peek"
        className="max-h-[85vh] w-full max-w-lg overflow-y-auto rounded-lg border border-slate-200 bg-white p-5 shadow-lg"
      >
        {journey === undefined ? (
          <p className="py-8 text-center text-sm text-slate-500">Loading…</p>
        ) : journey === null ? (
          <div className="py-6 text-center">
            <p className="text-sm text-slate-700">
              You do not have access to this order.
            </p>
            <button
              type="button"
              onClick={onClose}
              className="mt-4 rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50"
            >
              Close
            </button>
          </div>
        ) : (
          <>
            <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
              <h2 className="text-lg font-semibold text-slate-900">
                {journey.journey_number ?? "Order"}
              </h2>
              <span className="rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700">
                {journey.cancelled_at ? "Cancelled" : journey.current_state}
              </span>
              {journey.sale_kind === "EXCHANGE" && (
                <span className="rounded-full bg-indigo-100 px-2 py-0.5 text-xs font-medium text-indigo-700">
                  Exchange
                </span>
              )}
            </div>
            {customerName && (
              <p className="mt-1 text-sm font-medium text-slate-800">
                {customerName}
              </p>
            )}

            <div className="mt-3 space-y-1 text-sm text-slate-700">
              {customer?.phone && (
                <p>Phone: {formatPhoneDashed(customer.phone)}</p>
              )}
              {customer?.email && <p>Email: {customer.email}</p>}
              {customer &&
                (() => {
                  const addrLine = [
                    [
                      customer.street_address,
                      customer.street_address_line_2,
                    ]
                      .filter(Boolean)
                      .join(" "),
                    [customer.city, customer.state, customer.zip_code]
                      .filter(Boolean)
                      .join(", "),
                  ]
                    .filter(Boolean)
                    .join(" · ");
                  return addrLine ? (
                    <p>{addrLine}</p>
                  ) : (
                    <p className="font-medium text-amber-700">
                      No address on file
                    </p>
                  );
                })()}
              {journey.store?.name && <p>Store: {journey.store.name}</p>}
            </div>

            <div className="mt-4">
              <h3 className="text-xs font-semibold uppercase tracking-wide text-slate-500">
                Items
              </h3>
              {detailsLoading ? (
                <p className="mt-1 text-sm text-slate-400">Loading…</p>
              ) : items.length === 0 ? (
                <p className="mt-1 text-sm text-slate-400">No items.</p>
              ) : (
                <ul className="mt-1 space-y-0.5 text-sm text-slate-700">
                  {items.map((it) => (
                    <li key={it.id}>
                      {it.item_name} × {it.quantity}
                      <span className="text-slate-500">
                        {" "}
                        — {money(it.unit_price)} each
                      </span>
                    </li>
                  ))}
                </ul>
              )}
            </div>

            <div className="mt-4">
              <h3 className="text-xs font-semibold uppercase tracking-wide text-slate-500">
                Payment
              </h3>
              {detailsLoading ? (
                <p className="mt-1 text-sm text-slate-400">Loading…</p>
              ) : (
              <p className="mt-1 text-sm text-slate-700">
                {journey.cancelled_at
                  ? `Cancelled. Paid ${money(paid)}.`
                  : journey.price !== null
                    ? `Price ${money(journey.price)} · Paid ${money(paid)} · Balance ${money(balance)}`
                    : `Paid ${money(paid)}`}
              </p>
              )}
            </div>

            <div className="mt-4">
              <h3 className="text-xs font-semibold uppercase tracking-wide text-slate-500">
                Delivery
              </h3>
              {detailsLoading ? (
                <p className="mt-1 text-sm text-slate-400">Loading…</p>
              ) : stop ? (
                <div className="mt-1 text-sm text-slate-700">
                  <p>
                    {dayLabel(stop.deliveryDate)}
                    {stop.truckName ? ` · ${stop.truckName}` : ""}
                    {stop.insideCutoff ? " · Inside cutoff" : ""}
                  </p>
                  <p className={stop.windowText ? "" : "text-slate-400"}>
                    {stop.windowText ?? "No window set"}
                  </p>
                </div>
              ) : delivery?.active_stop ? (
                <p className="mt-1 text-sm text-slate-700">
                  {dayLabel(delivery.active_stop.delivery_date)}
                  {delivery.active_stop.inside_cutoff
                    ? " · Inside cutoff"
                    : ""}
                </p>
              ) : (
                <p className="mt-1 text-sm text-slate-400">
                  No delivery booked.
                </p>
              )}
            </div>

            <div className="mt-4 border-t border-slate-100 pt-3">
              <DeliveryContactPanel
                journeyId={journey.id}
                customerName={customerName}
                customerPhone={customer?.phone ?? null}
                journeyNumber={journey.journey_number}
                showLogButton={false}
              />
            </div>

            <div className="mt-4 flex gap-2">
              <Link
                href={`/board?journey=${journey.id}`}
                target="_blank"
                rel="noopener noreferrer"
                data-testid="journey-peek-open-full"
                className="flex-1 rounded-md bg-slate-900 px-3 py-2 text-center text-sm font-medium text-white hover:bg-slate-800"
              >
                Open full journey
              </Link>
              <button
                type="button"
                onClick={onClose}
                className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Close
              </button>
            </div>
          </>
        )}
      </div>
    </Modal>
  );
}
