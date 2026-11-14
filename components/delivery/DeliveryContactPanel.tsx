"use client";

import { useCallback, useEffect, useState } from "react";
import DeliveryContactModal from "@/components/delivery/DeliveryContactModal";
import {
  CONFIRMATION_STATUS_META,
  type ConfirmationCallStatus,
} from "@/lib/delivery/calls";
import {
  CONTACT_OUTCOME_LABELS,
  contactWhenLabel,
  getDeliveryContactHistory,
  contactDisplayNote,
  pastOutcomePhrase,
  relativeMinutesLabel,
  type DeliveryContactEntry,
  type DeliveryContactHistory,
} from "@/lib/delivery/contacts";

// Shared contact panel: last call, recent-contact notice, hold states,
// quick "Log a call", and a short history across the customer's orders.
// It warns and informs only; booking is never affected.
export default function DeliveryContactPanel({
  journeyId,
  customerName,
  customerPhone,
  journeyNumber,
  showLogButton = true,
}: {
  journeyId: string;
  customerName?: string | null;
  customerPhone?: string | null;
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
  const [showAllHistory, setShowAllHistory] = useState(false);

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

  // History: newest first (the RPC already sorts). Collapsed shows the
  // 4 newest entries; "Show all" reveals the rest. CONFIRMATION and
  // SCHEDULING entries get headings only when both kinds are present.
  const historyAll = data?.contacts ?? [];
  const confirmations = historyAll.filter((h) => h.purpose === "CONFIRMATION");
  const scheduling = historyAll.filter((h) => h.purpose !== "CONFIRMATION");
  const bothKinds = confirmations.length > 0 && scheduling.length > 0;
  const visibleHistory = showAllHistory
    ? historyAll
    : historyAll.slice(0, 4);
  const visibleSet = new Set<DeliveryContactEntry>(visibleHistory);

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
                  {confirmations.length > 0 && scheduling.length === 0
                    ? "No scheduling calls yet."
                    : "No calls logged yet."}
                </p>
              )}

              {/* No held or callback-due notices here: inside the
                  scheduling window and order panel the panel only
                  informs, it never suggests not scheduling. */}
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

          {historyAll.length > 0 && (
            <div
              className="mt-2 space-y-2 border-t border-slate-200 pt-2"
              data-testid="contact-panel-history"
            >
              {bothKinds ? (
                <>
                  <div>
                    <p className="mb-1 text-[10px] font-semibold uppercase tracking-wide text-slate-400">
                      Night-before confirmations
                    </p>
                    <ul className="space-y-1.5">
                      {confirmations
                        .filter((h) => visibleSet.has(h))
                        .map((h, i) => (
                          <HistoryEntry key={entryKey(h, i)} h={h} />
                        ))}
                    </ul>
                  </div>
                  <div>
                    <p className="mb-1 text-[10px] font-semibold uppercase tracking-wide text-slate-400">
                      Scheduling contacts
                    </p>
                    <ul className="space-y-1.5">
                      {scheduling
                        .filter((h) => visibleSet.has(h))
                        .map((h, i) => (
                          <HistoryEntry key={entryKey(h, i)} h={h} />
                        ))}
                    </ul>
                  </div>
                </>
              ) : (
                <ul className="space-y-1.5">
                  {historyAll
                    .filter((h) => visibleSet.has(h))
                    .map((h, i) => (
                      <HistoryEntry key={entryKey(h, i)} h={h} />
                    ))}
                </ul>
              )}
              {historyAll.length > 4 && (
                <button
                  type="button"
                  data-testid="contact-panel-history-toggle"
                  onClick={() => setShowAllHistory((v) => !v)}
                  className="text-xs font-medium text-brand-600 hover:text-brand-700"
                >
                  {showAllHistory
                    ? "Show less"
                    : `Show all (${historyAll.length})`}
                </button>
              )}
            </div>
          )}
        </>
      )}

      {logging && (
        <DeliveryContactModal
          journeyId={journeyId}
          customerName={customerName ?? lc?.customer_name ?? null}
          customerPhone={customerPhone}
          onClose={() => setLogging(false)}
          onSaved={() => setReloadKey((k) => k + 1)}
        />
      )}
    </div>
  );
}

function entryKey(h: DeliveryContactEntry, i: number): string {
  return `${h.journey_id}-${h.occurred_at}-${i}`;
}

// One history entry: type tag, bold outcome, time on line one; who
// logged it plus the person's own note on line two. The generated
// summary sentence is stripped by contactDisplayNote, so CONFIRMATION
// rows read as outcome + note only.
function HistoryEntry({ h }: { h: DeliveryContactEntry }) {
  const isConf = h.purpose === "CONFIRMATION";
  const outcomeLabel = isConf
    ? (CONFIRMATION_STATUS_META[h.contact_outcome as ConfirmationCallStatus]
        ?.label ?? "Confirmation call")
    : (CONTACT_OUTCOME_LABELS[h.contact_outcome ?? ""] ?? "Contact");
  const note = contactDisplayNote(h.note);
  return (
    <li className="rounded-md border border-slate-200 bg-white px-2.5 py-2">
      <div className="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
        <span
          className={`rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${
            isConf
              ? "bg-blue-50 text-blue-700"
              : "bg-slate-100 text-slate-500"
          }`}
        >
          {isConf ? "Confirmation call" : "Scheduling call"}
        </span>
        <span className="text-xs font-semibold text-slate-800">
          {outcomeLabel}
        </span>
        <span className="text-xs text-slate-400">
          {contactWhenLabel(h.occurred_at)}
        </span>
      </div>
      <p className="mt-0.5 text-xs text-slate-500">
        {h.employee_name ?? "Someone"}
        {note ? ` · ${note}` : ""}
      </p>
    </li>
  );
}
