"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import Modal, { isAnyModalOpen, openModalCount } from "@/components/Modal";
import { createClient } from "@/lib/supabase/client";
import {
  fetchDeliveryCallAlert,
  fetchDeliveryCutoffContext,
  fetchDeliveryLastCallTime,
} from "@/lib/delivery/queries";
import { confirmationDayLabel } from "@/lib/delivery/calls";
import {
  cutoffMinutes,
  zonedNow,
  zonedTimeToUtcMs,
} from "@/lib/delivery/availability";
import {
  alertStorageKey,
  decideCallAlert,
  readCallAlertSuppression,
  shouldReuseLastCallContext,
  writeCallAlertSuppression,
  type CallAlertState,
  type CallAlertSuppression,
} from "@/lib/delivery/alert";
import { CONFIRMATION_CALLS_CHANGED_EVENT } from "@/lib/delivery/useConfirmationCallCount";
import { describeError } from "@/lib/utils";

const HIDE_PATHS = ["/", "/login", "/logout", "/store-select"];
const FOCUS_THROTTLE_MS = 15_000;
const POLL_MS = 60_000;
const SNOOZE_MS = 15 * 60_000;
const LAST_CALL_TTL_MS = 5 * 60_000;

// `alertOpen` = this pop-up's own Modal is mounted. While it is NOT
// open, any shared Modal counts as busy; while it IS open, only
// layers beyond its own count, so the alert can still re-evaluate
// and auto-close.
function isBusyUi(alertOpen: boolean): boolean {
  if (typeof document === "undefined") return false;
  const modalBusy = alertOpen ? openModalCount() > 1 : isAnyModalOpen();
  if (modalBusy) return true;
  const el = document.activeElement;
  if (el instanceof HTMLElement && el.isContentEditable) return true;
  return (
    el instanceof HTMLInputElement ||
    el instanceof HTMLTextAreaElement ||
    el instanceof HTMLSelectElement
  );
}

/**
 * App-level pop-up: "customers need confirmation calls" once the
 * route is closed and calls remain. Mounted once in the root layout;
 * invisible unless the m139 RPC says show. Never navigates on its
 * own and never touches the page underneath.
 */
export default function CallAlert() {
  const pathname = usePathname();
  const [open, setOpen] = useState(false);
  const [state, setState] = useState<CallAlertState | null>(null);
  // True when the pop-up is showing because the daily last-call
  // checkpoint overrode an older suppression ("second call" text).
  const [reminder, setReminder] = useState(false);
  const userIdRef = useRef<string | null>(null);
  const sessionRef = useRef<Promise<string | null> | null>(null);
  const lastCheckRef = useRef(0);
  const missingLoggedRef = useRef(false);
  // Company timezone + last-call time with a short TTL, so a sign-in
  // or a settings change is picked up without a page reload. Results
  // without a timezone (signed out, unresolved employee) are never
  // cached; a valid result with last_call_time null (feature off) is.
  const lastCallRef = useRef<{
    at: number;
    value: { timezone: string | null; last_call_time: string | null };
  } | null>(null);
  const getLastCallContext = useCallback(async () => {
    const cached = lastCallRef.current;
    if (
      cached &&
      shouldReuseLastCallContext(
        cached.at,
        Date.now(),
        LAST_CALL_TTL_MS,
        cached.value.timezone != null
      )
    ) {
      return cached.value;
    }
    const [ctx, lc] = await Promise.all([
      fetchDeliveryCutoffContext().catch(() => null),
      fetchDeliveryLastCallTime().catch(() => null),
    ]);
    const value = {
      timezone: ctx?.timezone ?? null,
      last_call_time: lc?.last_call_time ?? null,
    };
    lastCallRef.current =
      value.timezone !== null ? { at: Date.now(), value } : null;
    return value;
  }, []);
  // The alert's own open state, readable inside runCheck without a
  // stale closure (runCheck is created once).
  const openRef = useRef(false);
  openRef.current = open;
  // Same for the hidden-path check — keeps runCheck's identity stable
  // so effects subscribe once instead of on every navigation.
  const hiddenPathRef = useRef(false);

  const hiddenPath =
    pathname == null ||
    HIDE_PATHS.includes(pathname) ||
    pathname.endsWith("/print") ||
    pathname === "/delivery/calls" ||
    pathname.startsWith("/delivery/calls/");
  hiddenPathRef.current = hiddenPath;

  const suppressionFor = useCallback(
    (date: string): CallAlertSuppression | null => {
      const uid = userIdRef.current;
      if (!uid) return null;
      return readCallAlertSuppression(alertStorageKey(uid, date));
    },
    []
  );

  const persistSuppression = useCallback(
    (date: string, value: CallAlertSuppression) => {
      const uid = userIdRef.current;
      if (uid) writeCallAlertSuppression(alertStorageKey(uid, date), value);
    },
    []
  );

  // Session user id, fetched once and shared — runCheck awaits it so
  // suppression is never read without the user it belongs to. A null
  // result (signed out, session still loading) is NOT cached: the ref
  // resets so the next check retries the lookup.
  const getUserId = useCallback(() => {
    if (!sessionRef.current) {
      sessionRef.current = createClient()
        .auth.getSession()
        .then(({ data: { session } }) => {
          const id = session?.user?.id ?? null;
          if (id === null) sessionRef.current = null;
          return id;
        });
    }
    return sessionRef.current;
  }, []);

  const runCheck = useCallback(
    async (throttled: boolean) => {
      const now = Date.now();
      if (throttled && now - lastCheckRef.current < FOCUS_THROTTLE_MS) {
        return;
      }
      lastCheckRef.current = now;
      if (hiddenPathRef.current) {
        setOpen(false);
        return;
      }
      // Never interrupt typing or talk over another modal; the next
      // scheduled check retries once they are gone.
      if (isBusyUi(openRef.current)) return;
      // A check started on one page can finish after navigation; the
      // path is re-verified after every await and right before the
      // pop-up is opened so it can never appear on a hidden route.
      const bailIfHidden = () => {
        if (!hiddenPathRef.current) return false;
        setOpen(false);
        setReminder(false);
        return true;
      };
      try {
        userIdRef.current = await getUserId();
        // Signed out (or session not resolved yet): never call the
        // RPC — it would just log a permission error.
        if (!userIdRef.current) return;
        if (bailIfHidden()) return;
        const s = await fetchDeliveryCallAlert();
        if (bailIfHidden()) return;
        setState(s);
        // Today's last-call moment in the company timezone, when the
        // m140 setting exists. Evaluated fresh on every check so a tab
        // left open across the checkpoint still fires once.
        const lc = await getLastCallContext();
        if (bailIfHidden()) return;
        let lastCallAt: number | null = null;
        if (lc?.last_call_time && lc.timezone) {
          const z = zonedNow(new Date(now), lc.timezone);
          const mins = cutoffMinutes(lc.last_call_time);
          if (z && mins !== null) {
            lastCallAt = zonedTimeToUtcMs(z.dateIso, mins, lc.timezone);
          }
        }
        const decision =
          s.date && s.eligible
            ? decideCallAlert(
                s,
                now,
                suppressionFor(s.date),
                lastCallAt
              )
            : "hidden";
        if (bailIfHidden()) return;
        setReminder(decision === "reminder");
        setOpen(decision !== "hidden");
      } catch (e) {
        // m139 not installed yet or RPC error: stay silent, one log
        // line per page load, nothing else breaks.
        if (!missingLoggedRef.current) {
          missingLoggedRef.current = true;
          console.info(`Call alert unavailable: ${describeError(e)}`);
        }
      }
    },
    [suppressionFor, getUserId, getLastCallContext]
  );

  useEffect(() => {
    void getUserId();
    void runCheck(false);

    const onFocus = () => void runCheck(true);
    const onVisibility = () => {
      if (document.visibilityState === "visible") void runCheck(true);
    };
    const interval = setInterval(() => {
      if (document.visibilityState === "visible") void runCheck(false);
    }, POLL_MS);
    const onChanged = () => {
      lastCheckRef.current = Date.now();
      void runCheck(false);
    };

    window.addEventListener("focus", onFocus);
    document.addEventListener("visibilitychange", onVisibility);
    window.addEventListener(CONFIRMATION_CALLS_CHANGED_EVENT, onChanged);
    return () => {
      clearInterval(interval);
      window.removeEventListener("focus", onFocus);
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener(CONFIRMATION_CALLS_CHANGED_EVENT, onChanged);
    };
  }, [runCheck, getUserId, getLastCallContext]);

  // Path changes re-evaluate immediately (e.g. navigating away from
  // /delivery/calls or onto a hidden route). The mount effect already
  // ran the first check, so skip this effect's initial run.
  const pathnameInitRef = useRef(true);
  useEffect(() => {
    if (pathnameInitRef.current) {
      pathnameInitRef.current = false;
      return;
    }
    void runCheck(false);
  }, [pathname, runCheck]);

  function suppress(kind: CallAlertSuppression["kind"], until?: number) {
    if (!state?.date) return;
    persistSuppression(state.date, {
      kind,
      count: state.team_open,
      until,
      createdAt: Date.now(),
    });
    setOpen(false);
  }

  if (!open || !state?.date) return null;

  const team = state.team_open;
  const mine = state.my_open;
  const dayLabel = confirmationDayLabel(state.date);

  return (
    <Modal onClose={() => suppress("dismissed")} closeOnBackdrop={false}>
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="call-alert-title"
        data-testid="call-alert"
        className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-5 shadow-lg"
      >
        <h2
          id="call-alert-title"
          className="text-base font-semibold text-slate-900"
        >
          {reminder
            ? "Customers still need confirmation"
            : "Customers need confirmation calls"}
        </h2>
        <p className="mt-2 text-sm text-slate-600">
          {reminder ? (
            <>
              {team === 1
                ? "1 customer is still unconfirmed. Time for the second call."
                : `${team} customers are still unconfirmed. Time for the second call.`}
            </>
          ) : team === 1 ? (
            `1 customer still needs a call for ${dayLabel}.`
          ) : (
            `${team} customers still need a call for ${dayLabel}.`
          )}
        </p>
        {mine > 0 && (
          <p className="mt-1 text-sm text-slate-500">
            {mine === 1 ? "1 of them is yours." : `${mine} of them are yours.`}
          </p>
        )}
        <div className="mt-4 flex flex-col gap-2">
          <Link
            href="/delivery/calls"
            onClick={() => suppress("dismissed")}
            className="rounded-md bg-brand-600 px-3 py-2 text-center text-sm font-medium text-white hover:bg-brand-700"
          >
            Open call list
          </Link>
          <button
            type="button"
            onClick={() => suppress("snoozed", Date.now() + SNOOZE_MS)}
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            Remind me in 15 minutes
          </button>
          <button
            type="button"
            onClick={() => suppress("dismissed")}
            className="rounded-md px-3 py-2 text-sm font-medium text-slate-500 hover:bg-slate-50"
          >
            Dismiss
          </button>
        </div>
      </div>
    </Modal>
  );
}
