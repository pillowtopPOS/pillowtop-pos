"use client";

import { useEffect, useRef, useState } from "react";
import { fetchConfirmationStoreId } from "@/lib/delivery/queries";
import {
  fetchOverdueFulfillments,
  type OverdueFulfillment,
} from "@/lib/journeys/pickup";

// Fired after a pickup date is set or a fulfillment completes so the
// banner and badge refresh immediately instead of waiting for the poll.
export const OVERDUE_FULFILLMENTS_CHANGED_EVENT =
  "overdue-fulfillments-changed";

const FOCUS_THROTTLE_MS = 15_000;
const POLL_MS = 5 * 60_000;

export type OverdueFulfillmentsState = {
  items: OverdueFulfillment[];
  count: number;
  loading: boolean;
};

/**
 * Shared "overdue pickups and deliveries" list for the My Work banner
 * and the sidebar badge. Store-scoped like the confirmation call count
 * but intentionally separate from it: the nag shows all day to everyone
 * at the active store, so it does NOT use the call-list permission or
 * cutoff gate. Refreshes on mount, on tab focus / visibility (15s
 * throttle), every 5 minutes, and immediately on
 * OVERDUE_FULFILLMENTS_CHANGED_EVENT. A failed fetch keeps the last
 * known list; the two banners can never hide or break each other.
 */
export function useOverdueFulfillments(): OverdueFulfillmentsState {
  const [state, setState] = useState<OverdueFulfillmentsState>({
    items: [],
    count: 0,
    loading: true,
  });
  const lastFetchRef = useRef(0);

  useEffect(() => {
    let alive = true;

    const fetchItems = async () => {
      try {
        // Fresh read every fetch: a /store-select switch must change the
        // store scope without a reload. Null lets the RPC fall back to
        // the caller's home store.
        const storeId = await fetchConfirmationStoreId();
        const items = await fetchOverdueFulfillments(storeId);
        if (!alive) return;
        // Most overdue first, then order number, so the banner and any
        // future consumer see the same order. Journey numbers are
        // zero-padded (SJ-XXX-00012) so lexical sort matches numeric.
        items.sort(
          (a, b) =>
            b.days_overdue - a.days_overdue ||
            (a.journey_number ?? "").localeCompare(b.journey_number ?? "")
        );
        setState({ items, count: items.length, loading: false });
      } catch {
        // Keep the last known list on transient failures; only the
        // first-load spinner clears.
        if (alive) setState((s) => (s.loading ? { ...s, loading: false } : s));
      }
    };

    const fetchThrottled = () => {
      if (Date.now() - lastFetchRef.current < FOCUS_THROTTLE_MS) return;
      lastFetchRef.current = Date.now();
      void fetchItems();
    };

    const onVisibility = () => {
      if (document.visibilityState === "visible") fetchThrottled();
    };
    const onChanged = () => {
      lastFetchRef.current = Date.now();
      void fetchItems();
    };

    lastFetchRef.current = Date.now();
    void fetchItems();
    const interval = setInterval(fetchItems, POLL_MS);
    window.addEventListener("focus", fetchThrottled);
    document.addEventListener("visibilitychange", onVisibility);
    window.addEventListener(OVERDUE_FULFILLMENTS_CHANGED_EVENT, onChanged);

    return () => {
      alive = false;
      clearInterval(interval);
      window.removeEventListener("focus", fetchThrottled);
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener(OVERDUE_FULFILLMENTS_CHANGED_EVENT, onChanged);
    };
  }, []);

  return state;
}
