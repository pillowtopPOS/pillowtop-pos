"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import Modal from "@/components/Modal";
import DeliveryBookingModal from "@/components/delivery/DeliveryBookingModal";
import DeliveryContactPanel from "@/components/delivery/DeliveryContactPanel";
import {
  cancelDeliveryStop,
  fetchJourneyDelivery,
  type JourneyDelivery,
  type JourneyDeliveryEvent,
} from "@/lib/delivery/queries";
import type { JourneyWithDetails } from "@/lib/journeys/queries";

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

function parseDay(iso: string): Date {
  return iso.includes("T") ? new Date(iso) : new Date(`${iso}T00:00:00`);
}
function dayLabel(iso: string): string {
  const d = parseDay(iso);
  return `${WEEKDAYS[d.getDay()]} ${MONTHS[d.getMonth()]} ${d.getDate()}`;
}
function shortStamp(iso: string): string {
  return parseDay(iso).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
}
function actorLabel(name: string | null): string {
  return name ?? "System";
}

// One plain-English line per stop-history row.
function historyLine(e: JourneyDeliveryEvent): string {
  const who = `by ${actorLabel(e.actor_name)}, ${shortStamp(e.created_at)}`;
  const overrideNote =
    (e.action === "BOOKED" || e.action === "RESCHEDULED") &&
    e.override &&
    e.reason
      ? `. Inside cutoff: ${e.reason}`
      : "";
  switch (e.action) {
    case "BOOKED":
      return (
        (e.to_date
          ? `Booked for ${dayLabel(e.to_date)} ${who}`
          : `Booked ${who}`) + overrideNote
      );
    case "RESCHEDULED":
      return (
        `Moved from ${e.from_date ? dayLabel(e.from_date) : "?"} to ${
          e.to_date ? dayLabel(e.to_date) : "?"
        } ${who}` + overrideNote
      );
    case "CANCELLED":
      if (!e.actor_name && e.reason === "Order is no longer scheduled") {
        return "Released by the system: order is no longer scheduled";
      }
      return `Cancelled${e.reason ? `: ${e.reason}` : ""}`;
    case "COMPLETED":
      return "Completed";
    default:
      return "Updated";
  }
}

export default function JourneyDelivery({
  journey,
  onChanged,
  openBookingSignal = false,
}: {
  journey: JourneyWithDetails;
  onChanged: () => void | Promise<void>;
  // True when the board URL carried ?book=1 (My Work handoff). Opens the
  // picker once, then clears the param so a refresh doesn't reopen it.
  openBookingSignal?: boolean;
}) {
  const router = useRouter();
  const [delivery, setDelivery] = useState<JourneyDelivery | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [booking, setBooking] = useState<"book" | "reschedule" | null>(null);
  const [cancelling, setCancelling] = useState(false);
  const [cancelReason, setCancelReason] = useState("");
  const [cancelBusy, setCancelBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const noticeTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const isDelivery = journey.fulfillment_type === "delivery";
  const show =
    isDelivery &&
    !journey.cancelled_at &&
    (journey.current_state === "Ready to Schedule" ||
      journey.current_state === "Scheduled");

  const refresh = useCallback(async () => {
    try {
      const d = await fetchJourneyDelivery(journey.id);
      setDelivery(d);
    } catch {
      // Keep any previously loaded data on screen; a cold-load failure
      // leaves delivery null and the section shows its retry state.
    }
  }, [journey.id]);

  useEffect(() => {
    if (!show) {
      setDelivery(null);
      return;
    }
    setLoading(true);
    refresh().finally(() => setLoading(false));
  }, [show, refresh, journey.current_state]);

  function flashNotice(text: string) {
    setNotice(text);
    if (noticeTimer.current) clearTimeout(noticeTimer.current);
    noticeTimer.current = setTimeout(() => setNotice(null), 5000);
  }

  async function handleBookingDone() {
    flashNotice(
      booking === "reschedule"
        ? "Delivery rescheduled."
        : "Delivery booked."
    );
    try {
      await refresh();
      await onChanged();
    } catch {
      flashNotice(
        "Delivery booked, but the page didn't refresh. Reload to see it."
      );
    }
  }

  async function submitCancel() {
    const stop = delivery?.active_stop;
    if (!stop || !cancelReason.trim() || cancelBusy) return;
    setCancelBusy(true);
    setError(null);
    try {
      await cancelDeliveryStop(stop.id, cancelReason.trim());
      setCancelling(false);
      setCancelReason("");
      flashNotice("Delivery cancelled. The order is back in Needs scheduling.");
      await refresh();
      await onChanged();
    } catch (e: any) {
      setError(e?.message ?? "Couldn't cancel the delivery. Please try again.");
    } finally {
      setCancelBusy(false);
    }
  }

  // My Work handoff: ?book=1 opens the picker once, then the param is
  // stripped so closing/reopening the panel doesn't relaunch it.
  const signalHandled = useRef(false);
  useEffect(() => {
    // Re-arm whenever the param is absent so a later ?book=1 (even for
    // the same mounted panel) opens the picker again.
    if (!openBookingSignal) {
      signalHandled.current = false;
      return;
    }
    if (signalHandled.current || !show || loading) {
      return;
    }
    signalHandled.current = true;
    const canBook =
      journey.current_state === "Ready to Schedule" ||
      (journey.current_state === "Scheduled" && !delivery?.active_stop);
    if (canBook) setBooking("book");
    router.replace(`/board?journey=${journey.id}`);
  }, [openBookingSignal, show, loading, journey, delivery, router]);

  if (!show) return null;

  const stop = delivery?.active_stop ?? null;
  const latest = delivery?.history?.[0] ?? null;
  const releasedBySystem =
    latest !== null &&
    latest.action === "CANCELLED" &&
    latest.actor_name === null &&
    latest.reason === "Order is no longer scheduled";
  const customerName = journey.customer
    ? `${journey.customer.first_name} ${journey.customer.last_name}`
    : "Customer";
  const deliveryAddress = [
    journey.customer?.street_address,
    [journey.customer?.city, journey.customer?.state, journey.customer?.zip_code]
      .filter(Boolean)
      .join(" "),
  ]
    .filter(Boolean)
    .join(", ");

  return (
    <div className="mt-3 border-t border-slate-100 pt-3" data-testid="journey-delivery">
      {!delivery ? (
        loading ? (
          <p className="text-xs text-slate-400">Loading delivery…</p>
        ) : (
          <div data-testid="delivery-load-error">
            <p className="text-xs text-slate-600">
              We couldn't load the delivery details. Try again.
            </p>
            <button
              type="button"
              data-testid="delivery-retry"
              onClick={() => {
                setLoading(true);
                refresh().finally(() => setLoading(false));
              }}
              className="mt-2 rounded-md border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50"
            >
              Retry
            </button>
          </div>
        )
      ) : (
        <>
          {journey.current_state === "Scheduled" && stop && (
            <div data-testid="delivery-active-stop">
              <p className="text-sm font-semibold text-slate-900">
                Delivery: {dayLabel(stop.delivery_date)}
              </p>
              <p className="mt-0.5 text-xs text-slate-500">
                Booked by {stop.booked_by_name ?? "System"},{" "}
                {shortStamp(stop.booked_at)}
                {stop.inside_cutoff && " · Inside cutoff"}
              </p>
              {stop.inside_cutoff && stop.override_reason && (
                <p className="mt-0.5 text-xs text-amber-700">
                  Reason: {stop.override_reason}
                </p>
              )}
              <div className="mt-2 flex gap-2">
                <button
                  type="button"
                  data-testid="delivery-reschedule-open"
                  onClick={() => setBooking("reschedule")}
                  className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
                >
                  Reschedule
                </button>
                <button
                  type="button"
                  data-testid="delivery-cancel-open"
                  onClick={() => {
                    setCancelReason("");
                    setError(null);
                    setCancelling(true);
                  }}
                  className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-red-700 hover:bg-red-50"
                >
                  Cancel delivery
                </button>
              </div>
            </div>
          )}

          {journey.current_state === "Scheduled" && !stop && (
            <div data-testid="delivery-no-stop">
              <p className="text-sm font-semibold text-slate-900">
                Not on the calendar
              </p>
              <button
                type="button"
                data-testid="book-delivery-open"
                onClick={() => setBooking("book")}
                className="mt-2 w-full rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700"
              >
                Book delivery
              </button>
            </div>
          )}

          {journey.current_state === "Ready to Schedule" && (
            <button
              type="button"
              data-testid="book-delivery-open"
              onClick={() => setBooking("book")}
              className="w-full rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700"
            >
              Book delivery
            </button>
          )}

          {/* Call log: Ready to Schedule gets the Log a call button;
              Scheduled shows history only until the confirmation slice. */}
          <div className="mt-3">
            <DeliveryContactPanel
              journeyId={journey.id}
              customerName={customerName}
              journeyNumber={journey.journey_number ?? null}
              showLogButton={journey.current_state === "Ready to Schedule"}
            />
          </div>

          {releasedBySystem && (
            <p
              className="mt-2 rounded-md bg-amber-50 px-3 py-2 text-xs text-amber-800"
              data-testid="delivery-release-notice"
            >
              This order's delivery day was released because the order
              changed. Book a new day.
            </p>
          )}

          {error && !cancelling && (
            <p className="mt-2 text-xs text-red-600" data-testid="delivery-error">
              {error}
            </p>
          )}
          {notice && (
            <p
              className="mt-2 rounded-md bg-emerald-50 px-3 py-2 text-xs text-emerald-800"
              data-testid="delivery-notice"
            >
              {notice}
            </p>
          )}

          {delivery && delivery.history.length > 0 && (
            <div className="mt-3" data-testid="delivery-history">
              <p className="text-xs font-semibold uppercase tracking-wide text-slate-400">
                Delivery history
              </p>
              <ul className="mt-1 space-y-1">
                {delivery.history.slice(0, 8).map((h, i) => (
                  <li key={i} className="text-xs text-slate-600">
                    {historyLine(h)}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </>
      )}

      {booking && (
        <DeliveryBookingModal
          journeyId={journey.id}
          customerName={customerName}
          journeyNumber={journey.journey_number ?? null}
          deliveryAddress={deliveryAddress || null}
          mode={booking}
          stopId={stop?.id}
          currentDate={stop?.delivery_date}
          onClose={() => setBooking(null)}
          onDone={handleBookingDone}
        />
      )}

      {cancelling && (
        <Modal onClose={() => setCancelling(false)} saving={cancelBusy}>
          <div
            className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-5 shadow-lg"
            data-testid="delivery-cancel-modal"
          >
            <h2 className="text-lg font-semibold text-slate-900">
              Cancel delivery
            </h2>
            <p className="mt-1 text-sm text-slate-600">
              {customerName}
              {journey.journey_number ? ` · ${journey.journey_number}` : ""}
              {stop ? ` · ${dayLabel(stop.delivery_date)}` : ""}
            </p>
            <label
              htmlFor="delivery-cancel-reason"
              className="mt-3 block text-sm font-medium text-slate-700"
            >
              Reason for cancelling
            </label>
            <textarea
              id="delivery-cancel-reason"
              data-testid="delivery-cancel-reason"
              value={cancelReason}
              onChange={(e) => setCancelReason(e.target.value)}
              rows={3}
              className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              placeholder="Why is this delivery being cancelled?"
            />
            {error && (
              <p className="mt-2 text-sm text-red-600">{error}</p>
            )}
            <div className="mt-4 flex gap-2">
              <button
                type="button"
                data-testid="delivery-cancel-dismiss"
                onClick={() => setCancelling(false)}
                disabled={cancelBusy}
                className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
              >
                Keep delivery
              </button>
              <button
                type="button"
                data-testid="delivery-cancel-confirm"
                onClick={submitCancel}
                disabled={!cancelReason.trim() || cancelBusy}
                className="flex-1 rounded-md bg-red-600 px-3 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
              >
                {cancelBusy ? "Cancelling…" : "Cancel delivery"}
              </button>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}
