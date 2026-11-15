// ============================================================
// Part 3c: pure decision logic + suppression storage for the
// "customers need confirmation calls" pop-up. No React, no
// Supabase — unit tested by scripts/test_delivery_alert.ts.
// ============================================================

export type CallAlertState = {
  eligible: boolean;
  date: string | null;
  route_closed: boolean;
  team_open: number;
  my_open: number;
  total_stops?: number;
};

// One active suppression per user+date. "dismissed" hides until
// team_open rises strictly above count or the daily last-call
// checkpoint arrives; "snoozed" hides until `until` (epoch ms) or
// until team_open rises above count, whichever first. `createdAt`
// (epoch ms) marks when the suppression was written; records saved
// before it existed are treated as created before any last-call
// moment, so the once-a-day reminder still reaches them.
export type CallAlertSuppression = {
  kind: "dismissed" | "snoozed";
  count: number;
  until?: number;
  createdAt?: number;
};

/**
 * Show / reminder / hidden for the confirmation-call pop-up.
 * `lastCallAt` is the epoch ms of today's company-timezone last-call
 * moment (companies.delivery_last_call_time), or null when the
 * feature is off. Once per day per user: a suppression created
 * BEFORE that moment is ignored exactly once and the pop-up returns
 * as "reminder"; acting on it writes a fresh suppression whose
 * createdAt is at/after the moment, so normal rules resume and the
 * reminder cannot loop.
 */
export function decideCallAlert(
  state: CallAlertState | null | undefined,
  now: number,
  suppression: CallAlertSuppression | null | undefined,
  lastCallAt?: number | null
): "show" | "reminder" | "hidden" {
  if (!state?.eligible || !state.date) return "hidden";
  if (!state.route_closed || state.team_open <= 0) return "hidden";
  const s = suppression ?? null;
  // A rising count always resurfaces the pop-up, whatever the kind.
  const countRose = !!s && state.team_open > s.count;
  const suppressed =
    !!s &&
    !countRose &&
    (s.kind === "dismissed" ||
      (s.kind === "snoozed" && now < (s.until ?? 0)));
  if (!suppressed || !s) return "show";
  const reminderDue =
    lastCallAt != null &&
    now >= lastCallAt &&
    (s.createdAt == null || s.createdAt < lastCallAt);
  return reminderDue ? "reminder" : "hidden";
}

/**
 * TTL rule shared by the CallAlert last-call context cache and the
 * confirmation-count gate cache: reuse only a fresh, valid result.
 * `hasValidResult` is false when the fetch ran without a signed-in
 * user or came back without a timezone, so those are never reused
 * and the next check refetches.
 */
export function shouldReuseCachedContext(
  cachedAt: number | null,
  now: number,
  ttlMs: number,
  hasValidResult: boolean
): boolean {
  return (
    hasValidResult && cachedAt !== null && now - cachedAt < ttlMs
  );
}

// ------------------------------------------------------------
// Pop-up copy. Pure presentation strings for CallAlert — no
// behavior. `total` is team_open (everyone needing a call),
// `mine` is my_open, `reminder` selects the second-call wording.
// ------------------------------------------------------------

export type CallAlertCopy = {
  title: string;
  support: string;
  reassurance: string;
  // Which tab the call list should open on: "all" when nothing is
  // mine, so a covering coworker sees the customers.
  scope: "mine" | "all";
};

export function callAlertCopy(
  total: number,
  mine: number,
  reminder: boolean
): CallAlertCopy {
  const t = Math.max(total, 0);
  const m = Math.max(mine, 0);
  const plural = t > 1;
  return {
    title: reminder
      ? plural
        ? `${t} customers still need a second call`
        : "1 customer still needs a second call"
      : plural
        ? `${t} customers need confirmation calls`
        : "1 customer needs a confirmation call",
    support: !plural
      ? m >= 1
        ? "This customer is assigned to you."
        : "This customer is not assigned to you."
      : m >= t
        ? `All ${t} are assigned to you.`
        : m === 0
          ? "None of these are assigned to you."
          : m === 1
            ? `1 of the ${t} is assigned to you.`
            : `${m} of the ${t} are assigned to you.`,
    reassurance: plural
      ? "These calls stay on the call list until someone logs them."
      : "This call stays on the call list until someone logs it.",
    scope: m > 0 ? "mine" : "all",
  };
}

export function alertStorageKey(userId: string, date: string): string {
  return `delivery-call-alert:${userId}:${date}`;
}

// localStorage is the durable copy; a module-level Map keeps
// suppression working when storage is unavailable or throws.
const memoryStore = new Map<string, CallAlertSuppression>();

export function readCallAlertSuppression(
  key: string
): CallAlertSuppression | null {
  try {
    const raw = window.localStorage.getItem(key);
    if (raw) {
      const parsed = JSON.parse(raw) as CallAlertSuppression;
      if (parsed && typeof parsed === "object") return parsed;
    }
  } catch {
    // storage unavailable or corrupt value — fall through to memory
  }
  return memoryStore.get(key) ?? null;
}

export function writeCallAlertSuppression(
  key: string,
  value: CallAlertSuppression
): void {
  memoryStore.set(key, value);
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // storage unavailable — the memory copy still applies
  }
}
