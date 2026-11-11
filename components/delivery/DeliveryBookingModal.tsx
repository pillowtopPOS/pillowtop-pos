"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Check } from "lucide-react";
import Modal from "@/components/Modal";
import DeliveryContactPanel from "@/components/delivery/DeliveryContactPanel";
import {
  bookDeliveryStop,
  fetchDeliveryBookInsideCutoff,
  fetchDeliveryCalendar,
  fetchDeliveryManageCalendar,
  fetchJourneyDelivery,
  rescheduleDeliveryStop,
  setDayExtraSlots,
  type DeliveryCalendarDay,
  type JourneyDelivery,
} from "@/lib/delivery/queries";

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];
const MAX_WEEK_OFFSET = 25; // 26 weeks of pages, no hard end before that

function parseDay(iso: string): Date {
  return new Date(`${iso}T00:00:00Z`);
}
function toISODay(d: Date): string {
  return d.toISOString().slice(0, 10);
}
function addDays(iso: string, n: number): string {
  const d = parseDay(iso);
  d.setUTCDate(d.getUTCDate() + n);
  return toISODay(d);
}
// "Wed Nov 11"
function dayLabel(iso: string): string {
  const d = parseDay(iso);
  return `${WEEKDAYS[d.getUTCDay()]} ${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`;
}
// big card header pieces
function weekdayShort(iso: string): string {
  return WEEKDAYS[parseDay(iso).getUTCDay()];
}
function monthShort(iso: string): string {
  return MONTHS[parseDay(iso).getUTCMonth()];
}
function dateNum(iso: string): number {
  return parseDay(iso).getUTCDate();
}

function cutoffTimeLabel(t: string): string {
  const [h, m] = t.split(":").map(Number);
  const suffix = h >= 12 ? "PM" : "AM";
  const hour = h % 12 === 0 ? 12 : h % 12;
  return `${hour}:${String(m).padStart(2, "0")} ${suffix}`;
}

function tzCity(iana: string): string {
  const last = iana.split("/").pop() ?? iana;
  return last.replace(/_/g, " ");
}

type DayState =
  | "open"
  | "full"
  | "past_cutoff"
  | "none"
  | "current";

export default function DeliveryBookingModal({
  journeyId,
  customerName,
  journeyNumber,
  deliveryAddress,
  mode,
  stopId,
  currentDate,
  onClose,
  onDone,
}: {
  journeyId: string;
  customerName: string;
  journeyNumber: string | null;
  // One-line street, city, state, zip — null/empty means no address on
  // file (warning only, never a block).
  deliveryAddress?: string | null;
  mode: "book" | "reschedule";
  stopId?: string;
  currentDate?: string;
  onClose: () => void;
  onDone: () => void | Promise<void>;
}) {
  const [loading, setLoading] = useState(true);
  const [delivery, setDelivery] = useState<JourneyDelivery | null>(null);
  const [days, setDays] = useState<DeliveryCalendarDay[]>([]);
  const [daysLoading, setDaysLoading] = useState(false);
  const [canManageCalendar, setCanManageCalendar] = useState(false);
  const [canInsideCutoff, setCanInsideCutoff] = useState(false);
  const [tomorrow, setTomorrow] = useState<string | null>(null);
  const [weekOffset, setWeekOffset] = useState(0);
  const [selected, setSelected] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [addingSpot, setAddingSpot] = useState<string | null>(null);
  const [spotAddedFor, setSpotAddedFor] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [initFailed, setInitFailed] = useState(false);
  const pageCache = useRef<Map<string, DeliveryCalendarDay[]>>(new Map());
  const loadSeq = useRef(0);

  const pageStart = useCallback(
    (offset: number) =>
      tomorrow ? addDays(tomorrow, offset * 7) : null,
    [tomorrow]
  );
  const pageEnd = useCallback(
    (offset: number) => {
      const s = pageStart(offset);
      return s ? addDays(s, 6) : null;
    },
    [pageStart]
  );

  const loadPage = useCallback(
    async (offset: number) => {
      const start = pageStart(offset);
      const end = pageEnd(offset);
      if (!start || !end) return;
      const cached = pageCache.current.get(start);
      if (cached) {
        setDays(cached);
        return;
      }
      const seq = ++loadSeq.current;
      setDaysLoading(true);
      try {
        const cal = await fetchDeliveryCalendar(start, end);
        pageCache.current.set(start, cal.days);
        if (seq === loadSeq.current) setDays(cal.days);
      } catch {
        if (seq === loadSeq.current) {
          setError("We couldn't load the delivery days. Please try again.");
        }
      } finally {
        if (seq === loadSeq.current) setDaysLoading(false);
      }
    },
    [pageStart, pageEnd]
  );

  // First page of data: journey delivery info + permissions, then the
  // first week of days starting tomorrow (warehouse timezone).
  const loadInitial = useCallback(async () => {
    setLoading(true);
    setInitFailed(false);
    setError(null);
    try {
      const [dj, manageCal, insideCutoff] = await Promise.all([
        fetchJourneyDelivery(journeyId),
        fetchDeliveryManageCalendar(),
        fetchDeliveryBookInsideCutoff(),
      ]);
      setDelivery(dj);
      setCanManageCalendar(manageCal);
      setCanInsideCutoff(insideCutoff);
      const t = dj.earliest.today_local
        ? addDays(dj.earliest.today_local, 1)
        : addDays(new Date().toISOString().slice(0, 10), 1);
      setTomorrow(t);
      setWeekOffset(0);
    } catch {
      setInitFailed(true);
    } finally {
      setLoading(false);
    }
  }, [journeyId]);

  useEffect(() => {
    loadInitial();
  }, [loadInitial]);

  // Load (or reuse the cached) page whenever the week changes.
  useEffect(() => {
    if (tomorrow) loadPage(weekOffset);
  }, [tomorrow, weekOffset, loadPage]);

  const earliest = delivery?.earliest ?? null;
  const earliestDate = earliest?.earliest_date ?? null;

  function dayState(d: DeliveryCalendarDay): DayState {
    if (d.date === currentDate) return "current";
    if (d.capacity <= 0) return "none";
    const open = Math.max(0, d.capacity - d.booked_count);
    if (open <= 0) return "full";
    if (earliestDate && d.date < earliestDate) return "past_cutoff";
    return "open";
  }

  function selectable(d: DeliveryCalendarDay): boolean {
    const s = dayState(d);
    if (s === "open") return true;
    if (s === "past_cutoff" && canInsideCutoff) return true;
    return false;
  }

  const selectedIsInsideCutoff =
    selected !== null &&
    earliestDate !== null &&
    selected < earliestDate;

  const canSubmit =
    selected !== null &&
    !submitting &&
    (!selectedIsInsideCutoff || reason.trim().length > 0);

  async function refreshDays() {
    const start = pageStart(weekOffset);
    if (start) pageCache.current.delete(start);
    await loadPage(weekOffset);
  }

  async function handleAddSpot(d: DeliveryCalendarDay) {
    if (addingSpot) return;
    setAddingSpot(d.date);
    setError(null);
    try {
      await setDayExtraSlots(d.date, d.extra_slots + 1);
      setSpotAddedFor(d.date);
      await refreshDays();
    } catch {
      setError("Couldn't add a spot. Please try again.");
    } finally {
      setAddingSpot(null);
    }
  }

  function pickDay(d: DeliveryCalendarDay) {
    if (!selectable(d)) return;
    setSelected(d.date);
    setError(null);
  }

  async function handleSubmit() {
    if (!canSubmit || !selected) return;
    setSubmitting(true);
    setError(null);
    const overrideReason = selectedIsInsideCutoff ? reason.trim() : undefined;
    try {
      if (mode === "reschedule" && stopId) {
        await rescheduleDeliveryStop(stopId, selected, overrideReason);
      } else {
        await bookDeliveryStop(journeyId, selected, overrideReason);
      }
      // The booking already succeeded — a refresh failure must never be
      // reported as a failed booking. onDone shows its own notice.
      try {
        await onDone();
      } catch {
        // parent handles the notice; nothing to do here
      }
      onClose();
    } catch (e: any) {
      // Show the server's plain-English refusal verbatim and refresh the
      // numbers — the day may have filled a second ago.
      const msg = e?.message ?? "Couldn't save the delivery. Please try again.";
      setError(
        spotAddedFor === selected
          ? `A spot was added to ${dayLabel(selected)} but the booking did not go through: ${msg}`
          : msg
      );
      await refreshDays();
      setSubmitting(false);
    }
  }

  // Cutoff explanation in plain words, from server data only.
  const cutoffLine = (() => {
    if (!earliest) return null;
    if (!earliest.cutoff_time) {
      return "No cutoff. Earliest day is tomorrow.";
    }
    const t = cutoffTimeLabel(earliest.cutoff_time);
    const city = tzCity(earliest.timezone || "");
    const suffix = city ? ` (${city} time)` : "";
    const dayAfter = earliest.today_local
      ? addDays(earliest.today_local, 2)
      : null;
    if (dayAfter && earliest.earliest_date === dayAfter) {
      return `Orders booked after ${t}${suffix} start the day after tomorrow.`;
    }
    return `Orders booked before ${t}${suffix} can start tomorrow.`;
  })();

  const rangeStart = pageStart(weekOffset);
  const rangeEnd = pageEnd(weekOffset);
  const hasAddress = (deliveryAddress ?? "").trim().length > 0;

  return (
    <Modal onClose={onClose} saving={submitting}>
      <div
        className="flex max-h-[92vh] w-full max-w-5xl flex-col rounded-xl border border-slate-200 bg-white shadow-xl"
        data-testid="delivery-booking-modal"
      >
        {/* Header */}
        <div className="border-b border-slate-100 px-5 pb-4 pt-5 sm:px-8">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-xl font-semibold text-slate-900">
                {mode === "reschedule" ? "Reschedule delivery" : "Book delivery"}
              </h2>
              <p className="mt-0.5 text-sm text-slate-600">
                {customerName}
                {journeyNumber ? ` · ${journeyNumber}` : ""}
              </p>
              {hasAddress ? (
                <p className="mt-0.5 text-xs text-slate-500">{deliveryAddress}</p>
              ) : (
                <p className="mt-0.5 text-xs text-amber-700">
                  No delivery address on file. You can still book, but add one
                  before the delivery day.
                </p>
              )}
            </div>
            <div className="flex items-center gap-2">
              <button
                type="button"
                data-testid="delivery-week-back"
                disabled={weekOffset === 0}
                onClick={() => setWeekOffset((w) => Math.max(0, w - 1))}
                className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-40"
              >
                Back
              </button>
              <button
                type="button"
                data-testid="delivery-week-next"
                disabled={weekOffset >= MAX_WEEK_OFFSET}
                onClick={() => setWeekOffset((w) => Math.min(MAX_WEEK_OFFSET, w + 1))}
                className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-40"
              >
                Next 7 days
              </button>
            </div>
          </div>
          <div className="mt-3 flex flex-wrap items-baseline justify-between gap-2">
            <p className="text-sm font-medium text-slate-700">
              {rangeStart && rangeEnd
                ? `${dayLabel(rangeStart)} to ${dayLabel(rangeEnd)}`
                : ""}
            </p>
            {cutoffLine && (
              <p className="text-xs text-slate-500" data-testid="cutoff-line">
                {cutoffLine}
              </p>
            )}
          </div>
        </div>

        {/* Contact panel: fetched fresh when the window opens. Warns
            and informs only; booking is never affected. */}
        <div className="border-b border-slate-100 px-5 pb-3 sm:px-8">
          <DeliveryContactPanel
            journeyId={journeyId}
            customerName={customerName}
            journeyNumber={journeyNumber}
          />
        </div>

        {/* Scrollable day area */}
        <div className="flex-1 overflow-y-auto px-5 py-4 sm:px-8">
          {initFailed ? (
            <div className="py-10 text-center" data-testid="delivery-load-error">
              <p className="text-sm text-slate-600">
                We couldn't load the delivery days. Try again.
              </p>
              <button
                type="button"
                data-testid="delivery-retry"
                onClick={loadInitial}
                className="mt-3 rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Retry
              </button>
            </div>
          ) : loading ? (
            <p className="py-10 text-center text-sm text-slate-500">
              Loading days…
            </p>
          ) : daysLoading && days.length === 0 ? (
            <p className="py-10 text-center text-sm text-slate-500">
              Loading days…
            </p>
          ) : days.length === 0 ? (
            error ? null : (
              <p
                className="py-10 text-center text-sm text-slate-500"
                data-testid="delivery-no-days"
              >
                No delivery days are set up yet. Ask a manager to set up trucks
                and the weekly schedule.
              </p>
            )
          ) : (
            <>
              <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4 xl:grid-cols-7">
                {days.map((d) => {
                  const s = dayState(d);
                  const open = Math.max(0, d.capacity - d.booked_count);
                  const pct =
                    d.capacity > 0
                      ? Math.min(100, Math.round((d.booked_count / d.capacity) * 100))
                      : 0;
                  const isSelected = selected === d.date;
                  const sel = selectable(d);
                  const barColor =
                    s === "full"
                      ? "bg-red-400"
                      : s === "none"
                        ? "bg-slate-200"
                        : s === "past_cutoff"
                          ? "bg-slate-300"
                          : "bg-brand-500";
                  const cardClass = isSelected
                    ? "border-brand-600 bg-brand-600 text-white"
                    : s === "full"
                      ? "border-red-200 bg-red-50/60 text-slate-700"
                      : s === "past_cutoff"
                        ? "border-slate-300 bg-slate-100 text-slate-600"
                        : s === "none"
                          ? "border-slate-200 bg-[repeating-linear-gradient(45deg,#f8fafc,#f8fafc_8px,#f1f5f9_8px,#f1f5f9_16px)] text-slate-400"
                          : s === "current"
                            ? "border-brand-400 bg-white text-slate-800"
                            : "border-slate-300 bg-white text-slate-800 hover:border-brand-400 hover:shadow-sm";
                  return (
                    <div
                      key={d.date}
                      role={sel ? "button" : undefined}
                      tabIndex={sel ? 0 : undefined}
                      aria-disabled={!sel}
                      aria-pressed={isSelected}
                      aria-label={`${dayLabel(d.date)}, ${
                        s === "none"
                          ? "no delivery"
                          : s === "full"
                            ? "full"
                            : s === "past_cutoff"
                              ? canInsideCutoff
                                ? "override"
                                : "past cutoff"
                              : s === "current"
                                ? "current"
                                : `${open} open`
                      }`}
                      data-testid={`delivery-day-${d.date}`}
                      data-state={s}
                      onClick={() => pickDay(d)}
                      onKeyDown={(e) => {
                        if (sel && (e.key === "Enter" || e.key === " ")) {
                          e.preventDefault();
                          pickDay(d);
                        }
                      }}
                      className={`flex min-h-[96px] flex-col justify-between gap-3 rounded-xl border p-4 transition max-sm:flex-row max-sm:items-center sm:min-h-[148px] ${
                        sel ? "cursor-pointer" : "cursor-default"
                      } ${cardClass}`}
                    >
                      <div className="flex items-start justify-between gap-2 max-sm:shrink-0">
                        <div>
                          <p
                            className={`text-[11px] font-semibold uppercase tracking-wide ${
                              isSelected ? "text-brand-100" : "text-slate-400"
                            }`}
                          >
                            {weekdayShort(d.date)}
                          </p>
                          <p className="mt-1 flex items-baseline gap-1.5">
                            <span className="text-3xl font-bold leading-none">
                              {dateNum(d.date)}
                            </span>
                            <span
                              className={`text-sm font-medium ${
                                isSelected ? "text-brand-100" : "text-slate-500"
                              }`}
                            >
                              {monthShort(d.date)}
                            </span>
                          </p>
                        </div>
                        {isSelected && (
                          <span className="flex h-6 w-6 items-center justify-center rounded-full bg-white/20">
                            <Check className="h-4 w-4" strokeWidth={3} />
                          </span>
                        )}
                        {s === "current" && !isSelected && (
                          <span className="rounded-full bg-brand-50 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-brand-700">
                            Current
                          </span>
                        )}
                      </div>

                      <div className="max-sm:text-right">
                        <p
                          className={`text-lg font-semibold leading-tight ${
                            isSelected ? "text-white" : ""
                          }`}
                        >
                          {s === "none"
                            ? "No delivery"
                            : s === "full"
                              ? "Full"
                              : s === "past_cutoff"
                                ? canInsideCutoff
                                  ? "Override"
                                  : "Past cutoff"
                                : s === "current"
                                  ? `${open} open`
                                  : `${open} open`}
                        </p>
                        <div
                          className={`mt-2 h-1.5 w-full overflow-hidden rounded-full max-sm:ml-auto max-sm:w-28 ${
                            isSelected ? "bg-white/25" : "bg-slate-200"
                          }`}
                        >
                          <div
                            className={`h-full rounded-full ${
                              isSelected ? "bg-white" : barColor
                            }`}
                            style={{ width: `${pct}%` }}
                          />
                        </div>
                        <p
                          className={`mt-1 text-[11px] ${
                            isSelected ? "text-brand-100" : "text-slate-400"
                          }`}
                        >
                          {d.capacity > 0
                            ? `${d.booked_count} of ${d.capacity} booked`
                            : "No trucks scheduled"}
                        </p>
                        {s === "full" && canManageCalendar && (
                          <button
                            type="button"
                            data-testid={`delivery-add-spot-${d.date}`}
                            disabled={addingSpot !== null}
                            onClick={(e) => {
                              e.stopPropagation();
                              handleAddSpot(d);
                            }}
                            className="mt-2 rounded-md border border-slate-300 bg-white px-2.5 py-1 text-xs font-medium text-slate-700 shadow-sm hover:bg-slate-50 disabled:opacity-50"
                          >
                            {addingSpot === d.date ? "Adding…" : "Add a spot"}
                          </button>
                        )}
                        {s === "past_cutoff" && canInsideCutoff && (
                          <p className="mt-1 text-[10px] font-medium uppercase tracking-wide text-amber-600">
                            Needs a reason
                          </p>
                        )}
                      </div>
                    </div>
                  );
                })}
              </div>

              {daysLoading && days.length > 0 && (
                <p className="mt-3 text-center text-xs text-slate-400">
                  Updating days…
                </p>
              )}

              {selected && (
                <p
                  className="mt-4 text-sm text-slate-700"
                  data-testid="delivery-selected-day"
                >
                  {mode === "reschedule" ? "Move to" : "Book for"}{" "}
                  <span className="font-semibold">{dayLabel(selected)}</span>
                  {selectedIsInsideCutoff && canInsideCutoff && " (inside cutoff)"}
                </p>
              )}

              {selectedIsInsideCutoff && (
                <div className="mt-3">
                  <label
                    htmlFor="delivery-cutoff-reason"
                    className="block text-sm font-medium text-slate-700"
                  >
                    Reason for booking inside the cutoff
                  </label>
                  <textarea
                    id="delivery-cutoff-reason"
                    data-testid="delivery-cutoff-reason"
                    value={reason}
                    onChange={(e) => setReason(e.target.value)}
                    rows={2}
                    className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    placeholder="Why does this order need an earlier day?"
                  />
                </div>
              )}

            </>
          )}

          {error && !initFailed && (
            <p
              className="mt-3 text-sm text-red-600"
              data-testid="delivery-booking-error"
            >
              {error}
            </p>
          )}
        </div>

        {/* Fixed footer */}
        <div className="flex gap-2 border-t border-slate-100 px-5 py-4 sm:px-8">
          <button
            type="button"
            data-testid="delivery-book-cancel"
            onClick={onClose}
            disabled={submitting}
            className="flex-1 rounded-md border border-slate-300 bg-white px-4 py-2.5 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            type="button"
            data-testid="delivery-book-submit"
            onClick={handleSubmit}
            disabled={!canSubmit}
            className="flex-1 rounded-md bg-brand-600 px-4 py-2.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
          >
            {submitting
              ? "Saving…"
              : mode === "reschedule"
                ? "Reschedule"
                : "Book delivery"}
          </button>
        </div>
      </div>
    </Modal>
  );
}
