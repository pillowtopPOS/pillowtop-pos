"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import Modal from "@/components/Modal";
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
function shortDay(iso: string): string {
  const d = parseDay(iso);
  return `${WEEKDAYS[d.getUTCDay()]} ${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`;
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
  mode,
  stopId,
  currentDate,
  onClose,
  onDone,
}: {
  journeyId: string;
  customerName: string;
  journeyNumber: string | null;
  mode: "book" | "reschedule";
  stopId?: string;
  currentDate?: string;
  onClose: () => void;
  onDone: () => void | Promise<void>;
}) {
  const [loading, setLoading] = useState(true);
  const [delivery, setDelivery] = useState<JourneyDelivery | null>(null);
  const [days, setDays] = useState<DeliveryCalendarDay[]>([]);
  const [canManageCalendar, setCanManageCalendar] = useState(false);
  const [canInsideCutoff, setCanInsideCutoff] = useState(false);
  const [selected, setSelected] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [addingSpot, setAddingSpot] = useState<string | null>(null);
  const [spotAddedFor, setSpotAddedFor] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const rangeRef = useRef<{ start: string; end: string } | null>(null);
  const loadSeq = useRef(0);

  const loadDays = useCallback(async () => {
    const range = rangeRef.current;
    if (!range) return;
    const seq = ++loadSeq.current;
    const cal = await fetchDeliveryCalendar(range.start, range.end);
    if (seq === loadSeq.current) setDays(cal.days);
  }, []);

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const [dj, manageCal, insideCutoff] = await Promise.all([
          fetchJourneyDelivery(journeyId),
          fetchDeliveryManageCalendar(),
          fetchDeliveryBookInsideCutoff(),
        ]);
        if (!alive) return;
        setDelivery(dj);
        setCanManageCalendar(manageCal);
        setCanInsideCutoff(insideCutoff);
        // Next 4 weeks starting TOMORROW in the warehouse's timezone.
        const tomorrow = addDays(dj.earliest.today_local || "", 1);
        const start = tomorrow || addDays(new Date().toISOString().slice(0, 10), 1);
        const end = addDays(start, 27);
        rangeRef.current = { start, end };
        const cal = await fetchDeliveryCalendar(start, end);
        if (!alive) return;
        setDays(cal.days);
      } catch {
        if (alive) setError("We couldn't load the delivery days. Please try again.");
      } finally {
        if (alive) setLoading(false);
      }
    })();
    return () => {
      alive = false;
    };
  }, [journeyId]);

  const earliest = delivery?.earliest ?? null;
  const earliestDate = earliest?.earliest_date ?? null;
  const todayLocal = earliest?.today_local ?? null;

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
    // Inside-cutoff permission makes past-cutoff days selectable.
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
    try {
      await loadDays();
    } catch {
      // keep stale numbers; the next action will surface any error
    }
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
      await onDone();
      onClose();
    } catch (e: any) {
      // Show the server's plain-English refusal verbatim and refresh the
      // numbers — the day may have filled a second ago.
      const msg = e?.message ?? "Couldn't save the delivery. Please try again.";
      setError(
        spotAddedFor === selected
          ? `A spot was added to ${shortDay(selected)} but the booking did not go through: ${msg}`
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
    const dayAfter = todayLocal ? addDays(todayLocal, 2) : null;
    if (dayAfter && earliest.earliest_date === dayAfter) {
      return `Orders booked after ${t}${suffix} start the day after tomorrow.`;
    }
    return `Orders booked before ${t}${suffix} can start tomorrow.`;
  })();

  return (
    <Modal onClose={onClose} saving={submitting}>
      <div
        className="w-full max-w-lg rounded-lg border border-slate-200 bg-white p-5 shadow-lg"
        data-testid="delivery-booking-modal"
      >
        <h2 className="text-lg font-semibold text-slate-900">
          {mode === "reschedule" ? "Reschedule delivery" : "Book delivery"}
        </h2>
        <p className="mt-0.5 text-sm text-slate-600">
          {customerName}
          {journeyNumber ? ` · ${journeyNumber}` : ""}
        </p>
        {cutoffLine && (
          <p className="mt-2 text-xs text-slate-500" data-testid="cutoff-line">
            {cutoffLine}
          </p>
        )}

        {loading ? (
          <p className="py-8 text-center text-sm text-slate-500">Loading days…</p>
        ) : (
          <div className="mt-3 grid max-h-72 grid-cols-4 gap-2 overflow-y-auto sm:grid-cols-7">
            {days.map((d) => {
              const s = dayState(d);
              const open = Math.max(0, d.capacity - d.booked_count);
              const isSelected = selected === d.date;
              const sel = selectable(d);
              return (
                <button
                  key={d.date}
                  type="button"
                  data-testid={`delivery-day-${d.date}`}
                  data-state={s}
                  disabled={!sel && s !== "full"}
                  onClick={() => {
                    if (sel) {
                      setSelected(d.date);
                      setError(null);
                    }
                  }}
                  className={`rounded-md border px-2 py-2 text-center text-xs ${
                    isSelected
                      ? "border-brand-600 bg-brand-600 text-white"
                      : sel
                        ? "border-slate-300 bg-white text-slate-700 hover:bg-slate-50"
                        : "border-slate-200 bg-slate-50 text-slate-400"
                  } ${s === "full" ? "cursor-default" : ""}`}
                >
                  <div className="font-medium">
                    {shortDay(d.date)}
                    {s === "current" && (
                      <span className="ml-1 rounded bg-slate-200 px-1 text-[10px] text-slate-600">
                        Current
                      </span>
                    )}
                  </div>
                  <div className="mt-0.5">
                    {s === "none"
                      ? "No delivery"
                      : s === "full"
                        ? "Full"
                        : s === "past_cutoff" && !canInsideCutoff
                          ? "Past cutoff"
                          : s === "past_cutoff"
                            ? "Past cutoff"
                            : `${open} open`}
                  </div>
                  {s === "full" && canManageCalendar && (
                    <span
                      role="button"
                      tabIndex={0}
                      data-testid={`delivery-add-spot-${d.date}`}
                      onClick={(e) => {
                        e.stopPropagation();
                        handleAddSpot(d);
                      }}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") {
                          e.stopPropagation();
                          handleAddSpot(d);
                        }
                      }}
                      className="mt-1 inline-block rounded border border-slate-300 bg-white px-1.5 py-0.5 text-[10px] font-medium text-slate-600 hover:bg-slate-100"
                    >
                      {addingSpot === d.date ? "Adding…" : "Add a spot"}
                    </span>
                  )}
                </button>
              );
            })}
          </div>
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

        {selected && (
          <p className="mt-3 text-sm text-slate-700" data-testid="delivery-selected-day">
            {mode === "reschedule" ? "Move to" : "Book for"}{" "}
            <span className="font-semibold">{shortDay(selected)}</span>
            {selectedIsInsideCutoff && canInsideCutoff && " (inside cutoff)"}
          </p>
        )}

        {error && (
          <p className="mt-2 text-sm text-red-600" data-testid="delivery-booking-error">
            {error}
          </p>
        )}

        <div className="mt-4 flex gap-2">
          <button
            type="button"
            data-testid="delivery-book-cancel"
            onClick={onClose}
            disabled={submitting}
            className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            type="button"
            data-testid="delivery-book-submit"
            onClick={handleSubmit}
            disabled={!canSubmit}
            className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
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
