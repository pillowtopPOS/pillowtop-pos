"use client";

import { useCallback, useEffect, useState } from "react";
import DeliveryContactModal from "@/components/delivery/DeliveryContactModal";
import {
  CONTACT_OUTCOME_LABELS,
  contactWhenLabel,
  getDeliveryContactHistory,
  contactDisplayNote,
  pastOutcomePhrase,
  relativeMinutesLabel,
  type DeliveryContactHistory,
} from "@/lib/delivery/contacts";

// Shared contact panel: last call, recent-contact notice, hold states,
// quick "Log a call", and a short history across the customer's orders.
// It warns and informs only; booking is never affected.
export default function DeliveryContactPanel({
  journeyId,
  customerName,
  journeyNumber,
  showLogButton = true,
}: {
  journeyId: string;
  customerName?: string | null;
  journeyNumber?: string | null;
  // Scheduled orders show history only; the confirmation-call slice
  // will add its own log action.
  showLogButton?: boolean;
}) {
  const [data, setData] = useState<DeliveryContactHistory | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [logging, setLogging] = useState(false);
  const [reloadKey, setReloadKey] = useState(0);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setData(await getDeliveryContactHistory(journeyId, 20));
    } catch {
      setError("We couldn't load the call history. Try again.");
    } finally {
      setLoading(false);
    }
  }, [journeyId]);

  useEffect(() => {
    load();
  }, [load, reloadKey]);

  const lc = data?.last_contact ?? null;
  const recentMin = data?.recent_contact_minutes ?? null;
  const showRecent =
    lc !== null && recentMin !== null && recentMin <= 60;
  const history = (data?.contacts ?? []).slice(0, 5);

  return (
    <div
      className="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2.5"
      data-testid="contact-panel"
    >
      {loading ? (
        <div className="space-y-2" aria-hidden="true">
          <div className="h-3 w-2/3 animate-pulse rounded bg-slate-200" />
          <div className="h-3 w-1/2 animate-pulse rounded bg-slate-200" />
        </div>
      ) : error ? (
        <div data-testid="contact-panel-error">
          <p className="text-xs text-slate-600">{error}</p>
          <button
            type="button"
            data-testid="contact-panel-retry"
            onClick={() => setReloadKey((k) => k + 1)}
            className="mt-1 text-xs font-medium text-brand-600 hover:text-brand-700"
          >
            Try again
          </button>
        </div>
      ) : (
        <>
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="min-w-0">
              {lc ? (
                showRecent ? (
                  // Under an hour old: the notice carries the same facts
                  // as the plain last-contact line, so only it shows.
                  <p
                    className="mt-1 rounded-md bg-amber-50 px-2 py-1 text-xs text-amber-800"
                    data-testid="contact-panel-recent-notice"
                  >
                    <span data-testid="contact-panel-last">
                      {lc.employee_name ?? "Someone"}{" "}
                      {lc.contact_outcome === "texted" ? "texted" : "called"}{" "}
                      {lc.customer_name ?? customerName ?? "the customer"}{" "}
                      {relativeMinutesLabel(recentMin)},{" "}
                      {pastOutcomePhrase(lc.contact_outcome)}.
                    </span>
                  </p>
                ) : (
                  <p
                    className="text-xs text-slate-700"
                    data-testid="contact-panel-last"
                  >
                    <span className="font-medium">
                      {lc.employee_name ?? "Someone"}
                    </span>{" "}
                    {lc.contact_outcome === "texted" ? "texted" : "called"}{" "}
                    {lc.customer_name ?? customerName ?? "the customer"}
                    {!lc.on_this_order && lc.journey_number
                      ? ` about order ${lc.journey_number}`
                      : ""}
                    {", "}
                    {pastOutcomePhrase(lc.contact_outcome)}
                    {", "}
                    {contactWhenLabel(lc.occurred_at)}
                  </p>
                )
              ) : (
                <p
                  className="text-xs text-slate-500"
                  data-testid="contact-panel-last"
                >
                  No calls logged yet.
                </p>
              )}

              {data?.held && (
                <p
                  className="mt-1 rounded-md bg-sky-50 px-2 py-1 text-xs text-sky-800"
                  data-testid="contact-panel-held"
                >
                  We are waiting on the customer
                  {lc?.occurred_at && contactWhenLabel(lc.occurred_at)
                    ? ` (since ${contactWhenLabel(lc.occurred_at)})`
                    : ""}
                  . You can still schedule.
                </p>
              )}
              {data?.callback_due && (
                <p className="mt-1 rounded-md bg-sky-50 px-2 py-1 text-xs text-sky-800">
                  Callback date reached.
                </p>
              )}
              {data?.bad_number && (
                <p className="mt-1 rounded-md bg-amber-50 px-2 py-1 text-xs text-amber-800">
                  Last call hit a wrong number. Check the phone number before
                  calling.
                </p>
              )}
            </div>

            {showLogButton && (
              <button
                type="button"
                data-testid="contact-panel-log-btn"
                onClick={() => setLogging(true)}
                className="shrink-0 rounded-md border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50"
              >
                Log a call
              </button>
            )}
          </div>

          {history.length > 0 && (
            <ul
              className="mt-2 space-y-0.5 border-t border-slate-200 pt-2"
              data-testid="contact-panel-history"
            >
              {history.map((h, i) => (
                <li key={`${h.journey_id}-${h.occurred_at}-${i}`} className="text-xs text-slate-600">
                  <span className="font-medium">
                    {h.employee_name ?? "Someone"}
                  </span>{" "}
                  ·{" "}
                  {CONTACT_OUTCOME_LABELS[h.contact_outcome ?? ""] ??
                    (h.purpose === "CONFIRMATION"
                      ? "Confirmation contact"
                      : "Contact")}{" "}
                  · {contactWhenLabel(h.occurred_at)}
                  {!h.on_this_order && h.journey_number
                    ? ` · on order ${h.journey_number}`
                    : ""}
                  {contactDisplayNote(h.note)
                    ? ` · ${contactDisplayNote(h.note)}`
                    : ""}
                </li>
              ))}
            </ul>
          )}
        </>
      )}

      {logging && (
        <DeliveryContactModal
          journeyId={journeyId}
          customerName={customerName ?? lc?.customer_name ?? null}
          onClose={() => setLogging(false)}
          onSaved={() => setReloadKey((k) => k + 1)}
        />
      )}
    </div>
  );
}
