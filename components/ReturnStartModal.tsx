"use client";

import { useEffect, useRef, useState } from "react";
import Modal from "@/components/Modal";
import {
  commitSleepTrialAction,
  createExchangeDraft,
  quoteSleepTrialAction,
  type ExchangeQuote,
} from "@/lib/journeys/exchange";
import type { SleepTrialEvaluation } from "@/lib/journeys/sleepTrial";

const COMMIT_TIMEOUT_MS = 30000;

function withTimeout<T>(
  work: Promise<T>,
  ms: number,
  message: string
): Promise<T> {
  return Promise.race([
    work,
    new Promise<T>((_, reject) =>
      setTimeout(() => reject(new Error(message)), ms)
    ),
  ]);
}

function money(cents: number | null | undefined): string {
  return `$${((cents ?? 0) / 100).toFixed(2)}`;
}

// Start Return confirm: shows the evaluator's return quote (sale price,
// restocking fee, refund) and commits through the same draft + commit
// path exchanges use. A return commit has no child journey; success just
// refreshes the panel.
export default function ReturnStartModal({
  evaluation,
  onClose,
  onCommitted,
}: {
  evaluation: SleepTrialEvaluation;
  onClose: () => void;
  onCommitted: () => void;
}) {
  const [quote, setQuote] = useState<ExchangeQuote | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);

  useEffect(() => {
    let cancelled = false;
    quoteSleepTrialAction(evaluation.trial_item_id, "RETURN", null)
      .then((q) => {
        if (!cancelled) setQuote(q);
      })
      .catch((e) => {
        if (!cancelled) {
          setLoadError(e?.message ?? "The return quote could not be loaded.");
        }
      });
    return () => {
      cancelled = true;
    };
  }, [evaluation.trial_item_id]);

  const eligible = quote?.action_result?.status === "ELIGIBLE";
  const blockedText =
    quote?.action_result?.explanation ??
    evaluation.actions?.RETURN?.explanation ??
    "This return is not eligible right now.";

  async function confirm() {
    if (!quote || !eligible || inFlight.current) return;
    inFlight.current = true;
    setSaving(true);
    setError(null);
    try {
      const actionId = await withTimeout(
        createExchangeDraft(
          evaluation.trial_item_id,
          "RETURN",
          null,
          null,
          null,
          crypto.randomUUID()
        ),
        COMMIT_TIMEOUT_MS,
        "Starting the return timed out. Check whether it started before trying again."
      );
      await withTimeout(
        commitSleepTrialAction(actionId),
        COMMIT_TIMEOUT_MS,
        "Starting the return timed out. Check whether it started before trying again."
      );
      onCommitted();
      onClose();
    } catch (e: any) {
      setError(e?.message ?? "The return could not be started.");
    } finally {
      inFlight.current = false;
      setSaving(false);
    }
  }

  return (
    <Modal onClose={onClose} saving={saving}>
      <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
        <h2 className="mb-2 text-lg font-semibold text-slate-900">
          Start return
        </h2>
        <p className="mb-3 text-sm text-slate-600">
          {evaluation.item?.product_name ?? "This mattress"} comes back to
          the warehouse for inspection and the trial ends.
        </p>
        {loadError && <p className="mb-3 text-sm text-red-600">{loadError}</p>}
        {!loadError && !quote && (
          <p className="mb-3 text-sm text-slate-500">Loading the return…</p>
        )}
        {quote && (
          <>
            <dl className="mb-3 space-y-1 text-sm">
              <div className="flex justify-between">
                <dt className="text-slate-600">Sale price</dt>
                <dd className="font-medium text-slate-900">
                  {money(quote.original_credit_cents)}
                </dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-slate-600">Restocking fee</dt>
                <dd className="font-medium text-slate-900">
                  {money(quote.locked_fee_cents)}
                </dd>
              </div>
              <div className="flex justify-between border-t border-slate-100 pt-1">
                <dt className="font-medium text-slate-700">
                  Refund to customer
                </dt>
                <dd className="font-semibold text-slate-900">
                  {money(quote.refund_owed_cents)}
                </dd>
              </div>
            </dl>
            {!eligible && (
              <p className="mb-3 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800">
                {blockedText}
              </p>
            )}
          </>
        )}
        {error && <p className="mb-3 text-sm text-red-600">{error}</p>}
        <div className="flex gap-2">
          {quote && eligible && (
            <button
              onClick={confirm}
              disabled={saving}
              className="flex-1 rounded-md bg-teal-700 px-3 py-2 text-sm font-medium text-white hover:bg-teal-800 disabled:opacity-50"
            >
              {saving ? "Starting…" : "Start return"}
            </button>
          )}
          <button
            onClick={onClose}
            className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            {quote && eligible ? "Cancel" : "Close"}
          </button>
        </div>
      </div>
    </Modal>
  );
}
