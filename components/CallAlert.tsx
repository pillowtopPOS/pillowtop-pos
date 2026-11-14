"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import Modal from "@/components/Modal";
import { createClient } from "@/lib/supabase/client";
import { fetchDeliveryCallAlert } from "@/lib/delivery/queries";
import { confirmationDayLabel } from "@/lib/delivery/calls";
import {
  alertStorageKey,
  decideCallAlert,
  readCallAlertSuppression,
  writeCallAlertSuppression,
  type CallAlertState,
  type CallAlertSuppression,
} from "@/lib/delivery/alert";
import { CONFIRMATION_CALLS_CHANGED_EVENT } from "@/lib/delivery/useConfirmationCallCount";
import { describeError } from "@/lib/utils";

const HIDE_PATHS = ["/", "/login", "/logout", "/store-select"];
const FOCUS_THROTTLE_MS = 15_000;
const POLL_MS = 60_000;
const SNOOZE_MS = 30 * 60_000;

function isBusyUi(): boolean {
  if (typeof document === "undefined") return false;
  // Any OTHER dialog holds the pop-up; our own must not count or the
  // alert could never re-evaluate (or auto-close) while it is open.
  const otherDialog = Array.from(
    document.querySelectorAll('[role="dialog"]')
  ).some(
    (el) =>
      !(el instanceof HTMLElement && el.dataset.testid === "call-alert")
  );
  if (otherDialog) return true;
  const el = document.activeElement;
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
  const userIdRef = useRef<string | null>(null);
  const lastCheckRef = useRef(0);
  const missingLoggedRef = useRef(false);

  const hiddenPath =
    pathname == null ||
    HIDE_PATHS.includes(pathname) ||
    pathname.endsWith("/print") ||
    pathname === "/delivery/calls" ||
    pathname.startsWith("/delivery/calls/");

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

  const runCheck = useCallback(
    async (throttled: boolean) => {
      const now = Date.now();
      if (throttled && now - lastCheckRef.current < FOCUS_THROTTLE_MS) {
        return;
      }
      lastCheckRef.current = now;
      if (hiddenPath) {
        setOpen(false);
        return;
      }
      // Never interrupt typing or talk over another dialog; the next
      // scheduled check retries once they are gone.
      if (isBusyUi()) return;
      try {
        const s = await fetchDeliveryCallAlert();
        setState(s);
        const decision =
          s.date && s.eligible
            ? decideCallAlert(s, Date.now(), suppressionFor(s.date))
            : "hidden";
        setOpen(decision === "show");
      } catch (e) {
        // m139 not installed yet or RPC error: stay silent, one log
        // line per page load, nothing else breaks.
        if (!missingLoggedRef.current) {
          missingLoggedRef.current = true;
          console.info(`Call alert unavailable: ${describeError(e)}`);
        }
      }
    },
    [hiddenPath, suppressionFor]
  );

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(({ data: { session } }) => {
      userIdRef.current = session?.user?.id ?? null;
    });
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
  }, [runCheck]);

  // Path changes re-evaluate immediately (e.g. navigating away from
  // /delivery/calls or onto a hidden route).
  useEffect(() => {
    void runCheck(false);
  }, [pathname, runCheck]);

  function suppress(kind: CallAlertSuppression["kind"], until?: number) {
    if (!state?.date) return;
    persistSuppression(state.date, {
      kind,
      count: state.team_open,
      until,
    });
    setOpen(false);
  }

  if (!open || !state?.date) return null;

  const team = state.team_open;
  const mine = state.my_open;
  const dayLabel = confirmationDayLabel(state.date);

  return (
    <Modal onClose={() => suppress("dismissed")}>
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
          Customers need confirmation calls
        </h2>
        <p className="mt-2 text-sm text-slate-600">
          {team === 1
            ? `1 customer still needs a call for ${dayLabel}.`
            : `${team} customers still need a call for ${dayLabel}.`}
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
            Remind me in 30 minutes
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
