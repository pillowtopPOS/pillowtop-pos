"use client";

import { useEffect, useState } from "react";
import Modal from "@/components/Modal";
import {
  CONTACT_OUTCOMES,
  HOLD_OUTCOMES,
  addDaysToISODate,
  contactWhenLabel,
  getDeliveryContactHistory,
  getDeliveryContactHoldDaysCached,
  holdUntilDayLabel,
  localTodayISO,
  logDeliveryContact,
  pastOutcomePhrase,
  relativeMinutesLabel,
  type ContactOutcome,
  type DeliveryContactHistory,
} from "@/lib/delivery/contacts";

// One modal for logging a delivery contact everywhere it is needed
// (My Work, scheduling window, order panel, Add Update flows). It is a
// tool, not a boss: Save is the only action and nothing is ever blocked
// by contact state.
export default function DeliveryContactModal({
  journeyId,
  customerName,
  onClose,
  onSaved,
}: {
  journeyId: string;
  customerName?: string | null;
  onClose: () => void;
  onSaved?: () => void | Promise<void>;
}) {
  const [outcome, setOutcome] = useState<ContactOutcome | null>(null);
  const [note, setNote] = useState("");
  const [callbackAfter, setCallbackAfter] = useState("");
  const [datePrefilled, setDatePrefilled] = useState(false);
  const [holdDays, setHoldDays] = useState<number | null>(null);
  const [history, setHistory] = useState<DeliveryContactHistory | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // One key per modal open; a retry after a failure reuses it so the
  // server returns the original row instead of duplicating.
  const [idempotencyKey] = useState(() => crypto.randomUUID());

  useEffect(() => {
    let live = true;
    getDeliveryContactHoldDaysCached().then((d) => {
      if (live) setHoldDays(d?.hold_days ?? null);
    });
    // Informational only: warn when the customer is already on hold or
    // was contacted in the last hour. Silent on loading/failure.
    getDeliveryContactHistory(journeyId, 5)
      .then((h) => {
        if (live) setHistory(h);
      })
      .catch(() => {});
    return () => {
      live = false;
    };
  }, [journeyId]);

  const showCallback = outcome !== null && HOLD_OUTCOMES.includes(outcome);
  const callbackRequired = outcome === "not_ready";

  function pickOutcome(o: ContactOutcome) {
    setOutcome(o);
    setError(null);
    if (!HOLD_OUTCOMES.includes(o)) {
      setCallbackAfter("");
      setDatePrefilled(false);
      return;
    }
    // Prefill: today + hold days when holds are on; for "not ready yet"
    // with holds off, tomorrow is the sensible nudge.
    const today = localTodayISO();
    const days = holdDays ?? 0;
    const next =
      days > 0
        ? addDaysToISODate(today, days)
        : o === "not_ready"
        ? addDaysToISODate(today, 1)
        : "";
    setCallbackAfter(next);
    setDatePrefilled(next !== "");
  }

  const canSave =
    outcome !== null &&
    !saving &&
    (!callbackRequired || callbackAfter.length > 0);

  // Top-of-box warning: held or contacted within the last hour. Purely
  // informational - Save is never disabled by it.
  const lc = history?.last_contact ?? null;
  const banner = (() => {
    if (!lc) return null;
    const who = lc.employee_name ?? "Someone";
    const cust = lc.customer_name ?? customerName ?? "the customer";
    const verb = lc.contact_outcome === "texted" ? "texted" : "called";
    if (history?.held) {
      const until = holdUntilDayLabel(history.hold_until);
      return `${who} ${verb} ${cust} ${contactWhenLabel(
        lc.occurred_at
      )}, ${pastOutcomePhrase(lc.contact_outcome)}. Already contacted${
        until ? `, wait until ${until}` : ""
      }. You can still log another contact.`;
    }
    const mins = history?.recent_contact_minutes;
    if (mins != null && mins <= 60) {
      return `${who} ${verb} ${cust} ${relativeMinutesLabel(
        mins
      )}, ${pastOutcomePhrase(lc.contact_outcome)}.`;
    }
    return null;
  })();

  async function save() {
    if (!canSave || !outcome) return;
    setSaving(true);
    setError(null);
    try {
      await logDeliveryContact({
        journey_id: journeyId,
        purpose: "SCHEDULING",
        outcome,
        note: note.trim() || null,
        callback_after: callbackAfter || null,
        idempotency_key: idempotencyKey,
      });
      try {
        await onSaved?.();
      } catch {
        // The contact is saved; a refresh failure must not look like a
        // failed save.
      }
      onClose();
    } catch (e: any) {
      setError(e?.message ?? "Couldn't save the contact. Please try again.");
      setSaving(false);
    }
  }

  return (
    <Modal onClose={onClose} saving={saving}>
      <div
        className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-5 shadow-lg"
        data-testid="contact-modal"
      >
        <h2 className="text-lg font-semibold text-slate-900">
          Log a call
        </h2>
        <p className="mt-0.5 text-sm text-slate-500">
          {customerName ? `${customerName} · ` : ""}How did it go?
        </p>

        {banner && (
          <p
            className="mt-3 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900"
            data-testid="contact-modal-banner"
          >
            {banner}
          </p>
        )}

        <div className="mt-4 grid grid-cols-1 gap-2 sm:grid-cols-2">
          {CONTACT_OUTCOMES.map((o) => (
            <button
              key={o.value}
              type="button"
              data-testid={`contact-outcome-${o.value}`}
              onClick={() => pickOutcome(o.value)}
              className={`min-h-[44px] rounded-md border px-3 py-2.5 text-left text-sm font-medium ${
                outcome === o.value
                  ? "border-brand-600 bg-brand-600 text-white"
                  : "border-slate-300 bg-white text-slate-700 hover:bg-slate-50"
              }`}
            >
              {o.label}
              {o.value === "spoke" && (
                <span
                  className={`mt-0.5 block text-xs font-normal ${
                    outcome === o.value ? "text-amber-100" : "text-slate-500"
                  }`}
                >
                  No day picked yet. If they picked a day, just book it.
                </span>
              )}
            </button>
          ))}
        </div>

        <label
          htmlFor="contact-note"
          className="mt-4 block text-xs font-medium uppercase text-slate-500"
        >
          Note (optional)
        </label>
        <textarea
          id="contact-note"
          data-testid="contact-note"
          value={note}
          onChange={(e) => setNote(e.target.value)}
          rows={2}
          className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          placeholder="Anything worth remembering?"
        />

        {showCallback && (
          <div className="mt-3">
            <label
              htmlFor="contact-callback-date"
              className="block text-xs font-medium uppercase text-slate-500"
            >
              {datePrefilled
                ? "Reach out again on"
                : "Callback date (optional)"}
            </label>
            <input
              id="contact-callback-date"
              data-testid="contact-callback-date"
              type="date"
              min={localTodayISO()}
              value={callbackAfter}
              onChange={(e) => setCallbackAfter(e.target.value)}
              className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
            />
            {datePrefilled && (
              <p className="mt-1 text-xs text-slate-500">
                If we have not heard back by then, this order comes back as
                Callback due.
              </p>
            )}
            {callbackRequired && !callbackAfter && (
              <p className="mt-1 text-xs text-amber-700">
                Pick the day the customer asked us to call back.
              </p>
            )}
          </div>
        )}

        {error && (
          <p
            className="mt-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700"
            data-testid="contact-error"
          >
            {error}
          </p>
        )}

        <div className="mt-4 flex gap-2">
          <button
            type="button"
            data-testid="contact-cancel"
            onClick={onClose}
            disabled={saving}
            className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2.5 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            type="button"
            data-testid="contact-save"
            onClick={save}
            disabled={!canSave}
            className="flex-1 rounded-md bg-brand-600 px-3 py-2.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
          >
            {saving ? "Saving…" : "Save contact"}
          </button>
        </div>
      </div>
    </Modal>
  );
}
