// ============================================================
// D1-c2b: arrival window math for the day plan. Pure functions,
// no React, no Supabase — unit tested by scripts/test_delivery_windows.ts.
// Times are minutes from midnight.
// ============================================================

export type WindowSpan = { start: number; end: number };

/** Round to the nearest 15 minutes; exact halves round up. */
export function round15(minutes: number): number {
  return Math.floor(minutes / 15 + 0.5) * 15;
}

/**
 * Space n arrival windows across a delivery day.
 * dayStart/dayEnd/windowLen are minutes from midnight.
 * Rules (spec):
 *  - n = 0: empty. L longer than the span: every window is the full day.
 *  - n = 1: centered on the day.
 *  - n * L <= span: back to back from day start.
 *  - otherwise: evenly overlap so the first starts at day start and the
 *    last ends at day end, each start rounded to 15 minutes.
 * Every result is clamped inside [dayStart, dayEnd] with end = start + L
 * (or the full day when L exceeds the span).
 */
export function suggestWindows(
  n: number,
  dayStart: number,
  dayEnd: number,
  windowLen: number
): WindowSpan[] {
  if (n <= 0) return [];
  const span = dayEnd - dayStart;
  if (windowLen > span) {
    return Array.from({ length: n }, () => ({ start: dayStart, end: dayEnd }));
  }
  const clampStart = (s: number) =>
    Math.max(dayStart, Math.min(s, dayEnd - windowLen));
  if (n === 1) {
    const start = clampStart(dayStart + round15((span - windowLen) / 2));
    return [{ start, end: start + windowLen }];
  }
  if (n * windowLen <= span) {
    return Array.from({ length: n }, (_, i) => {
      const start = clampStart(dayStart + i * windowLen);
      return { start, end: start + windowLen };
    });
  }
  const step = (span - windowLen) / (n - 1);
  return Array.from({ length: n }, (_, i) => {
    const raw = i === n - 1 ? dayEnd - windowLen : dayStart + round15(i * step);
    const start = clampStart(raw);
    return { start, end: start + windowLen };
  });
}

/**
 * Fill only the stops that have no window. Suggestions are spaced over
 * ALL n stops in route order, so hand-set windows keep their slots.
 * `windows` is the current window per stop (null = none); returns a new
 * array of the same length with gaps filled and existing values kept.
 */
export function fillMissingWindows(
  windows: (WindowSpan | null)[],
  dayStart: number,
  dayEnd: number,
  windowLen: number
): (WindowSpan | null)[] {
  const n = windows.length;
  const suggestions = suggestWindows(n, dayStart, dayEnd, windowLen);
  return windows.map((w, i) => w ?? suggestions[i]);
}

// ---- time string helpers -------------------------------------------------
// delivery_stops.window_start/end arrive as "HH:MM:SS" (Postgres time).

/** "10:00:00" | "10:00" -> minutes from midnight. Null/invalid -> null. */
export function timeStrToMinutes(value: string | null | undefined): number | null {
  if (!value) return null;
  const m = /^(\d{1,2}):(\d{2})/.exec(value.trim());
  if (!m) return null;
  const h = parseInt(m[1], 10);
  const min = parseInt(m[2], 10);
  if (h > 23 || min > 59) return null;
  return h * 60 + min;
}

/** minutes -> "HH:MM" 24h, for <select> values and RPC "HH:MM" input. */
export function minutesToTimeStr(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

/** minutes -> "10:00 AM". */
export function minutesToLabel(minutes: number): string {
  const h24 = Math.floor(minutes / 60);
  const m = minutes % 60;
  const suffix = h24 < 12 ? "AM" : "PM";
  const h12 = h24 % 12 === 0 ? 12 : h24 % 12;
  return `${h12}:${String(m).padStart(2, "0")} ${suffix}`;
}

/** "10:00 AM to 1:00 PM" for a window pair; nulls -> null. */
export function windowLabel(
  start: number | null,
  end: number | null
): string | null {
  if (start === null || end === null) return null;
  return `${minutesToLabel(start)} to ${minutesToLabel(end)}`;
}
