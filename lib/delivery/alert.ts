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
// team_open rises strictly above count; "snoozed" hides until `until`
// (epoch ms) or until team_open rises above count, whichever first.
export type CallAlertSuppression = {
  kind: "dismissed" | "snoozed";
  count: number;
  until?: number;
};

export function decideCallAlert(
  state: CallAlertState | null | undefined,
  now: number,
  suppression: CallAlertSuppression | null | undefined
): "show" | "hidden" {
  if (!state?.eligible || !state.date) return "hidden";
  if (!state.route_closed || state.team_open <= 0) return "hidden";
  const s = suppression ?? null;
  if (s?.kind === "dismissed" && state.team_open <= s.count) {
    return "hidden";
  }
  if (
    s?.kind === "snoozed" &&
    now < (s.until ?? 0) &&
    state.team_open <= s.count
  ) {
    return "hidden";
  }
  return "show";
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
