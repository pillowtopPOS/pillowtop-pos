// Unit tests for lib/delivery/alert.ts — the pop-up decision logic
// and suppression storage. Run: node scripts/test_delivery_alert.ts
import {
  alertStorageKey,
  decideCallAlert,
  readCallAlertSuppression,
  shouldReuseCachedContext,
  writeCallAlertSuppression,
  type CallAlertState,
} from "../lib/delivery/alert.ts";

let failures = 0;
function check(name: string, actual: unknown, expected: unknown) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failures++;
  console.log(
    `${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : ` — got ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`}`
  );
}

const base: CallAlertState = {
  eligible: true,
  date: "2026-11-16",
  route_closed: true,
  team_open: 4,
  my_open: 2,
  total_stops: 14,
};
const NOW = Date.parse("2026-11-15T20:00:00Z");

// --- gating ---
check("not eligible", decideCallAlert({ ...base, eligible: false }, NOW, null), "hidden");
check("route open", decideCallAlert({ ...base, route_closed: false }, NOW, null), "hidden");
check("zero open", decideCallAlert({ ...base, team_open: 0 }, NOW, null), "hidden");
check("no date", decideCallAlert({ ...base, date: null }, NOW, null), "hidden");
check("null state", decideCallAlert(null, NOW, null), "hidden");
check("shown", decideCallAlert(base, NOW, null), "show");
check("one open still shows", decideCallAlert({ ...base, team_open: 1 }, NOW, null), "show");

// --- dismissed ---
check(
  "dismissed same count hidden",
  decideCallAlert(base, NOW, { kind: "dismissed", count: 4 }),
  "hidden"
);
check(
  "dismissed lower count hidden",
  decideCallAlert(base, NOW, { kind: "dismissed", count: 6 }),
  "hidden"
);
check(
  "dismissed then count rises shown",
  decideCallAlert({ ...base, team_open: 5 }, NOW, { kind: "dismissed", count: 4 }),
  "show"
);

// --- snoozed ---
const until = NOW + 30 * 60_000;
check(
  "snooze before time hidden",
  decideCallAlert(base, NOW + 1000, { kind: "snoozed", count: 4, until }),
  "hidden"
);
check(
  "snooze after time shown",
  decideCallAlert(base, until + 1, { kind: "snoozed", count: 4, until }),
  "show"
);
check(
  "snooze then count rises shown early",
  decideCallAlert({ ...base, team_open: 5 }, NOW + 1000, { kind: "snoozed", count: 4, until }),
  "show"
);
check(
  "snooze same count at boundary hidden",
  decideCallAlert(base, until - 1, { kind: "snoozed", count: 4, until }),
  "hidden"
);

// --- last-call checkpoint (companies.delivery_last_call_time, m140) ---
// LAST = today's last-call moment as epoch ms; NOW is before it.
const LAST = NOW + 60_000;
check(
  "last call off: dismissed stays hidden",
  decideCallAlert(base, LAST + 1000, { kind: "dismissed", count: 4, createdAt: NOW - 1000 }, null),
  "hidden"
);
check(
  "before last call: dismissed hidden",
  decideCallAlert(base, LAST - 1, { kind: "dismissed", count: 4, createdAt: NOW - 1000 }, LAST),
  "hidden"
);
check(
  "after last call, older dismissed -> reminder",
  decideCallAlert(base, LAST + 1, { kind: "dismissed", count: 4, createdAt: LAST - 1 }, LAST),
  "reminder"
);
check(
  "after last call, newer dismissed -> hidden",
  decideCallAlert(base, LAST + 1, { kind: "dismissed", count: 4, createdAt: LAST + 1 }, LAST),
  "hidden"
);
check(
  "legacy record without createdAt -> reminder",
  decideCallAlert(base, LAST + 1, { kind: "dismissed", count: 4 }, LAST),
  "reminder"
);
check(
  "snoozed past last call, created before -> reminder",
  decideCallAlert(base, LAST + 1, { kind: "snoozed", count: 4, until: LAST + 30 * 60_000, createdAt: LAST - 1 }, LAST),
  "reminder"
);
check(
  "snoozed created after last call -> hidden",
  decideCallAlert(base, LAST + 1, { kind: "snoozed", count: 4, until: LAST + 30 * 60_000, createdAt: LAST + 1 }, LAST),
  "hidden"
);
check(
  "count rise after last call shows normal text",
  decideCallAlert({ ...base, team_open: 5 }, LAST + 1, { kind: "dismissed", count: 4, createdAt: LAST - 1 }, LAST),
  "show"
);
check(
  "no suppression after last call shows normal",
  decideCallAlert(base, LAST + 1, null, LAST),
  "show"
);
// Next day, before that day's last-call moment: yesterday's dismissal
// does not fire the reminder early.
const NEXT_LAST = LAST + 24 * 3600_000;
check(
  "next day before last call stays hidden",
  decideCallAlert(base, NEXT_LAST - 1, { kind: "dismissed", count: 4, createdAt: LAST - 1 }, NEXT_LAST),
  "hidden"
);
check(
  "next day after last call -> reminder again",
  decideCallAlert(base, NEXT_LAST + 1, { kind: "dismissed", count: 4, createdAt: LAST - 1 }, NEXT_LAST),
  "reminder"
);

// --- cached-context TTL helper (CallAlert + count gate) ---
const TTL = 5 * 60_000;
check(
  "fresh valid result reused",
  shouldReuseCachedContext(NOW, NOW + 1000, TTL, true),
  true
);
check(
  "fresh result at ttl boundary refetched",
  shouldReuseCachedContext(NOW, NOW + TTL, TTL, true),
  false
);
check(
  "expired result refetched",
  shouldReuseCachedContext(NOW, NOW + TTL + 1, TTL, true),
  false
);
check(
  "invalid result never reused",
  shouldReuseCachedContext(NOW, NOW + 1000, TTL, false),
  false
);
check(
  "no cache refetched",
  shouldReuseCachedContext(null, NOW, TTL, true),
  false
);
check(
  "no cache invalid refetched",
  shouldReuseCachedContext(null, NOW, TTL, false),
  false
);

// --- date changes -> suppression is keyed per date ---
check(
  "key includes user and date",
  alertStorageKey("u1", "2026-11-16"),
  "delivery-call-alert:u1:2026-11-16"
);
check(
  "different date different key",
  alertStorageKey("u1", "2026-11-17") !== alertStorageKey("u1", "2026-11-16"),
  true
);
// A suppression written for one date does not exist under another.
writeCallAlertSuppression(alertStorageKey("u-test", "2026-11-16"), {
  kind: "dismissed",
  count: 4,
});
check(
  "other date has no suppression",
  readCallAlertSuppression(alertStorageKey("u-test", "2026-11-17")),
  null
);
check(
  "same date reads suppression back",
  readCallAlertSuppression(alertStorageKey("u-test", "2026-11-16")),
  { kind: "dismissed", count: 4 }
);

// --- storage failure path: window/localStorage throwing still works ---
const realWindow = (globalThis as any).window;
(globalThis as any).window = {
  localStorage: {
    getItem() { throw new Error("denied"); },
    setItem() { throw new Error("denied"); },
  },
};
writeCallAlertSuppression("k-fail", { kind: "snoozed", count: 2, until: NOW + 1000 });
check(
  "memory fallback survives storage failure",
  readCallAlertSuppression("k-fail"),
  { kind: "snoozed", count: 2, until: NOW + 1000 }
);
if (realWindow === undefined) {
  delete (globalThis as any).window;
} else {
  (globalThis as any).window = realWindow;
}

if (failures) {
  console.log(`\n${failures} FAILURES`);
  process.exit(1);
}
console.log("\nAll tests passed.");
