"use client";

// D1-c2b part 3a: the night-before confirmation call list. Read-only
// list plus the log-call modal; all data comes from m138's
// get_delivery_confirmation_list / log_delivery_confirmation. Dates
// stay YYYY-MM-DD strings end to end — no local-timezone math.

import { Suspense, useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import JourneyPeek, {
  type JourneyPeekStopDetails,
} from "@/components/delivery/JourneyPeek";
import ConfirmationCallModal from "@/components/delivery/ConfirmationCallModal";
import DeliveryBookingModal from "@/components/delivery/DeliveryBookingModal";
import {
  fetchDeliveryConfirmationList,
  fetchDeliveryLogConfirmationCalls,
  type ConfirmationCallList,
  type ConfirmationCallListItem,
} from "@/lib/delivery/queries";
import {
  CONFIRMATION_PILL_CLASSES,
  CONFIRMATION_STATUS_META,
  confirmationDayLabel,
  confirmationWindowText,
  formatPhoneDashed,
  lastCallText,
  type ConfirmationCallStatus,
} from "@/lib/delivery/calls";
import { CONFIRMATION_CALLS_CHANGED_EVENT } from "@/lib/delivery/useConfirmationCallCount";

function statusMeta(status: string) {
  return (
    CONFIRMATION_STATUS_META[status as ConfirmationCallStatus] ?? {
      label: status,
      tone: "grey" as const,
    }
  );
}

function CallsInner() {
  const router = useRouter();
  const [allowed, setAllowed] = useState<boolean | null>(null);
  const [data, setData] = useState<ConfirmationCallList | null>(null);
  const [scope, setScope] = useState<"mine" | "all">("mine");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [noAccess, setNoAccess] = useState(false);
  const [logItem, setLogItem] = useState<ConfirmationCallListItem | null>(
    null
  );
  const [booking, setBooking] = useState<ConfirmationCallListItem | null>(null);
  // DeliveryBookingModal calls onDone() and THEN always calls onClose(),
  // so onClose can't trust render state — it would still see the old
  // closure. This ref records "the reschedule actually landed" and is
  // the only thing onClose trusts. Reset each time the window opens.
  const movedRef = useRef(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [peek, setPeek] = useState<{
    journeyId: string;
    stop: JourneyPeekStopDetails;
  } | null>(null);
  const loadSeq = useRef(0);

  const load = useCallback(async (date: string | null, sc: "mine" | "all") => {
    const seq = ++loadSeq.current;
    setLoading(true);
    setError(null);
    try {
      const res = await fetchDeliveryConfirmationList(date, sc);
      if (seq !== loadSeq.current) return;
      setData(res);
    } catch (e) {
      if (seq !== loadSeq.current) return;
      const msg = (e as Error)?.message ?? "";
      if (/permission/i.test(msg)) {
        setNoAccess(true);
        setData(null);
      } else {
        setError(msg || "We couldn't load the call list. Please try again.");
        setData(null);
      }
    } finally {
      if (seq === loadSeq.current) setLoading(false);
    }
  }, []);

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(async ({ data: { session } }) => {
      if (!session?.user) {
        router.push("/login");
        return;
      }
      const perm = await fetchDeliveryLogConfirmationCalls();
      setAllowed(perm);
      if (!perm) {
        setLoading(false);
        return;
      }
      // p_date null: the RPC picks the next delivery day and returns it
      // as `date`, which every later fetch reuses explicitly.
      load(null, "mine");
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const pickDate = (iso: string) => {
    if (!data || iso === data.date) return;
    load(iso, scope);
  };

  const pickScope = (sc: "mine" | "all") => {
    if (sc === scope) return;
    setScope(sc);
    load(data?.date ?? null, sc);
  };

  const refresh = () => {
    load(data?.date ?? null, scope);
  };

  // Tell every mounted badge (My Work banner, sidebar pill) that the
  // to-call count may have changed — they refetch on this event.
  const notifyCallsChanged = () => {
    window.dispatchEvent(new Event(CONFIRMATION_CALLS_CHANGED_EVENT));
  };

  // Quiet background refetch on tab focus — no loading flash, no
  // notice, at most once per 15s, and never while a modal is open.
  const lastQuietRef = useRef(0);
  const quietRefresh = useCallback(() => {
    const now = Date.now();
    if (now - lastQuietRef.current < 15_000) return;
    lastQuietRef.current = now;
    fetchDeliveryConfirmationList(data?.date ?? null, scope)
      .then(setData)
      .catch(() => {});
  }, [data?.date, scope]);

  useEffect(() => {
    const onFocus = () => {
      if (logItem || booking || peek) return;
      quietRefresh();
    };
    const onVisibility = () => {
      if (document.visibilityState === "visible") onFocus();
    };
    window.addEventListener("focus", onFocus);
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      window.removeEventListener("focus", onFocus);
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [logItem, booking, peek, quietRefresh]);

  const items = data?.items ?? [];
  const confirmedCount = items.filter((i) => i.status === "confirmed").length;

  const windowTextFor = (item: ConfirmationCallListItem): string =>
    confirmationWindowText(
      data?.day_mode ?? "window",
      item.window_start,
      item.window_end,
      data?.date ?? ""
    );

  return (
    <div className="mx-auto max-w-4xl px-4 py-6" data-testid="calls-page">
      <div className="mb-4">
        <Link
          href="/delivery"
          className="text-sm text-blue-700 hover:underline"
        >
          ← Delivery calendar
        </Link>
      </div>

      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-semibold text-slate-900">
          Confirmation calls
        </h1>
        <div
          className="flex rounded-md border border-slate-300 text-sm"
          role="group"
          aria-label="Call list scope"
        >
          {(
            [
              ["mine", "Mine"],
              ["all", "Everyone"],
            ] as ["mine" | "all", string][]
          ).map(([value, label]) => (
            <button
              key={value}
              type="button"
              onClick={() => pickScope(value)}
              aria-pressed={scope === value}
              className={`px-3 py-1.5 ${
                scope === value
                  ? "bg-slate-900 font-medium text-white"
                  : "text-slate-600 hover:bg-slate-50"
              } ${value === "mine" ? "rounded-l-md" : "rounded-r-md border-l border-slate-300"}`}
            >
              {label}
            </button>
          ))}
        </div>
      </div>

      {notice && (
        <p className="mb-3 rounded-md border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700">
          {notice}
        </p>
      )}

      {allowed === false || noAccess ? (
        <p className="rounded-lg border border-slate-200 bg-white px-6 py-10 text-center text-sm text-slate-600">
          You do not have access to the call list.
        </p>
      ) : loading && !data ? (
        <p className="py-10 text-center text-sm text-slate-500">Loading…</p>
      ) : error ? (
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-6 text-center">
          <p className="text-sm text-red-700">{error}</p>
          <button
            onClick={refresh}
            className="mt-3 rounded-md border border-red-300 px-3 py-1.5 text-sm text-red-700 hover:bg-red-100"
          >
            Try again
          </button>
        </div>
      ) : data ? (
        <>
          {/* Day picker — dates come straight from the RPC as strings.
              Counts are company-wide, so they only show in Everyone. */}
          {data.date && data.available_dates.length > 0 && (
            <div className="mb-3 flex flex-wrap gap-2">
              {data.available_dates.map((d) => {
                const active = d.date === data.date;
                return (
                  <button
                    key={d.date}
                    type="button"
                    onClick={() => pickDate(d.date)}
                    aria-pressed={active}
                    className={`rounded-md border px-3 py-1.5 text-sm ${
                      active
                        ? "border-slate-900 bg-slate-900 font-medium text-white"
                        : "border-slate-300 bg-white text-slate-700 hover:bg-slate-50"
                    }`}
                  >
                    {confirmationDayLabel(d.date)}
                    {scope === "all" ? ` (${d.stop_count})` : ""}
                  </button>
                );
              })}
            </div>
          )}

          {data.date && (
            <p className="mb-3 text-sm text-slate-600">
              {confirmedCount} of {items.length} confirmed
              {` · ${confirmationDayLabel(data.date)}`}
            </p>
          )}

          {!data.date ? (
            <p className="rounded-lg border border-dashed border-slate-300 bg-white px-6 py-10 text-center text-sm text-slate-600">
              No upcoming deliveries to call.
            </p>
          ) : items.length === 0 ? (
            <p className="rounded-lg border border-dashed border-slate-300 bg-white px-6 py-10 text-center text-sm text-slate-600">
              {scope === "mine"
                ? "None of your stops are on this day. Try another day or Everyone."
                : "No deliveries to call for this day."}
            </p>
          ) : (
            <ul className="space-y-2">
              {items.map((item) => {
                const meta = statusMeta(item.status);
                const winText = windowTextFor(item);
                const lastCall = lastCallText(item.last_call);
                return (
                  <li
                    key={item.stop_id}
                    data-testid={`call-row-${item.stop_id}`}
                    className="rounded-lg border border-slate-200 bg-white px-4 py-3"
                  >
                    <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                      <div className="min-w-0 flex-1">
                        <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
                          <span className="text-sm font-semibold text-slate-900">
                            {item.customer_name ?? "Customer"}
                          </span>
                          <button
                            type="button"
                            data-testid={`call-journey-${item.journey_id}`}
                            onClick={() =>
                              setPeek({
                                journeyId: item.journey_id,
                                stop: {
                                  deliveryDate: data.date ?? "",
                                  truckName: item.truck_name,
                                  windowText: winText,
                                  insideCutoff: false,
                                },
                              })
                            }
                            className="text-sm font-medium text-blue-700 hover:underline"
                          >
                            {item.journey_number ?? "Order"}
                          </button>
                          {scope === "all" && item.assigned_employee_name && (
                            <span className="text-xs text-slate-500">
                              {item.assigned_employee_name}
                            </span>
                          )}
                          <span
                            className={`rounded-full px-2 py-0.5 text-xs font-medium ${CONFIRMATION_PILL_CLASSES[meta.tone]}`}
                          >
                            {meta.label}
                          </span>
                        </div>
                        <div className="mt-1 space-y-0.5 text-sm text-slate-600">
                          {item.customer_phone ? (
                            <p className="select-text">
                              {formatPhoneDashed(item.customer_phone)}
                            </p>
                          ) : (
                            <p className="text-slate-400">No phone on file</p>
                          )}
                          {item.delivery_address ? (
                            <p>{item.delivery_address}</p>
                          ) : (
                            <p className="font-medium text-amber-700">
                              No address on file
                            </p>
                          )}
                          <p>
                            {item.truck_name ? `${item.truck_name} · ` : ""}
                            {winText}
                          </p>
                          <p className="text-xs text-slate-500">
                            {item.attempts} attempt
                            {item.attempts === 1 ? "" : "s"}
                            {lastCall ? ` · ${lastCall}` : ""}
                          </p>
                        </div>
                      </div>
                      <button
                        type="button"
                        data-testid={`call-log-${item.stop_id}`}
                        onClick={() => setLogItem(item)}
                        className="w-full shrink-0 rounded-md border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50 sm:w-auto"
                      >
                        {item.status === "not_called" ? "Log call" : "Call again"}
                      </button>
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
        </>
      ) : null}

      {logItem && data?.date && (
        <ConfirmationCallModal
          journeyId={logItem.journey_id}
          stopId={logItem.stop_id}
          customerName={logItem.customer_name}
          customerPhone={logItem.customer_phone}
          windowText={windowTextFor(logItem)}
          onClose={() => setLogItem(null)}
          onSaved={(msg) => {
            setLogItem(null);
            setNotice(msg ?? null);
            refresh();
            notifyCallsChanged();
          }}
          onPickNewDay={() => {
            // The call is already saved; hand off to the reschedule
            // window exactly like the order panel's Reschedule does.
            movedRef.current = false;
            setBooking(logItem);
            setLogItem(null);
          }}
        />
      )}

      {booking && data?.date && (
        <DeliveryBookingModal
          journeyId={booking.journey_id}
          customerName={booking.customer_name ?? "Customer"}
          customerPhone={booking.customer_phone}
          journeyNumber={booking.journey_number}
          deliveryAddress={booking.delivery_address}
          mode="reschedule"
          stopId={booking.stop_id}
          currentDate={data.date}
          onClose={() => {
            // Runs after onDone on a successful move — the ref, not
            // state, says which path this close took.
            const moved = movedRef.current;
            movedRef.current = false;
            setBooking(null);
            if (!moved) {
              setNotice("Call saved. The delivery was not moved.");
              refresh();
            }
            notifyCallsChanged();
          }}
          onDone={async () => {
            movedRef.current = true;
            setBooking(null);
            setNotice("Delivery moved.");
            refresh();
            notifyCallsChanged();
          }}
        />
      )}

      {peek && (
        <JourneyPeek
          journeyId={peek.journeyId}
          stopDetails={peek.stop}
          onClose={() => setPeek(null)}
        />
      )}
    </div>
  );
}

export default function DeliveryCallsPage() {
  return (
    <Suspense
      fallback={
        <div className="mx-auto max-w-4xl px-4 py-6">
          <p className="py-10 text-center text-sm text-slate-500">Loading…</p>
        </div>
      }
    >
      <CallsInner />
    </Suspense>
  );
}
