"use client";

import { useEffect, useRef, useState } from "react";
import {
  fetchDeliveryConfirmationList,
  fetchDeliveryCutoffContext,
  fetchDeliveryLogConfirmationCalls,
} from "./queries";
import {
  cutoffMinutes,
  zonedNow,
  type DeliveryCutoffContext,
} from "./availability";

// Fired by /delivery/calls after a call is logged so every badge
// refreshes immediately instead of waiting for the next poll.
export const CONFIRMATION_CALLS_CHANGED_EVENT =
  "delivery-confirmation-calls-changed";

const FOCUS_THROTTLE_MS = 15_000;
const POLL_MS = 5 * 60_000;

export type ConfirmationCallCount = {
  count: number;
  // The day the count is for (the RPC's default pick), for labels.
  date: string | null;
};

const EMPTY: ConfirmationCallCount = { count: 0, date: null };

/**
 * Shared "customers to call" count for the My Work banner and the
 * sidebar pill, so the two can never disagree. Counts items from
 * get_delivery_confirmation_list(null, 'mine') whose status is not
 * 'confirmed'. Shows nothing without delivery.log_confirmation_calls
 * or before the company cutoff (company timezone); with no cutoff
 * configured it stays hidden. Refreshes on mount, on tab focus /
 * visibility (15s throttle), every 5 minutes, and immediately on
 * CONFIRMATION_CALLS_CHANGED_EVENT.
 */
export function useConfirmationCallCount(): ConfirmationCallCount {
  const [state, setState] = useState<ConfirmationCallCount>(EMPTY);
  const gateRef = useRef<{
    canLog: boolean;
    ctx: DeliveryCutoffContext | null;
  } | null>(null);
  const lastFetchRef = useRef(0);

  useEffect(() => {
    let alive = true;

    const ensureGate = async () => {
      if (gateRef.current) return gateRef.current;
      const [canLog, ctx] = await Promise.all([
        fetchDeliveryLogConfirmationCalls().catch(() => false),
        fetchDeliveryCutoffContext().catch(() => null),
      ]);
      gateRef.current = { canLog, ctx };
      return gateRef.current;
    };

    // After the cutoff = cutoff time reached in the company timezone,
    // same >= rule as get_earliest_bookable_date. No cutoff configured
    // means the feature stays hidden.
    const afterCutoff = (ctx: DeliveryCutoffContext | null) => {
      const cutoff = cutoffMinutes(ctx?.cutoff_time);
      const z = zonedNow(new Date(), ctx?.timezone);
      return cutoff !== null && z !== null && z.minutes >= cutoff;
    };

    const fetchCount = async () => {
      try {
        const gate = await ensureGate();
        if (!alive) return;
        if (!gate.canLog || !gate.ctx?.cutoff_time || !afterCutoff(gate.ctx)) {
          setState(EMPTY);
          return;
        }
        const list = await fetchDeliveryConfirmationList(null, "mine");
        if (!alive) return;
        const count = list.items.filter(
          (i) => i.status !== "confirmed"
        ).length;
        setState({ count, date: list.date });
      } catch {
        // Keep the last known count on transient failures.
      }
    };

    const fetchThrottled = () => {
      if (Date.now() - lastFetchRef.current < FOCUS_THROTTLE_MS) return;
      lastFetchRef.current = Date.now();
      void fetchCount();
    };

    const onVisibility = () => {
      if (document.visibilityState === "visible") fetchThrottled();
    };
    const onChanged = () => {
      lastFetchRef.current = Date.now();
      void fetchCount();
    };

    lastFetchRef.current = Date.now();
    void fetchCount();
    const interval = setInterval(fetchCount, POLL_MS);
    window.addEventListener("focus", fetchThrottled);
    document.addEventListener("visibilitychange", onVisibility);
    window.addEventListener(CONFIRMATION_CALLS_CHANGED_EVENT, onChanged);

    return () => {
      alive = false;
      clearInterval(interval);
      window.removeEventListener("focus", fetchThrottled);
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener(CONFIRMATION_CALLS_CHANGED_EVENT, onChanged);
    };
  }, []);

  return state;
}
