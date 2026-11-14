// Unit tests for lib/delivery/alert.ts — the pop-up decision logic
// and suppression storage. Run: node scripts/test_delivery_alert.ts
import {
  alertStorageKey,
  decideCallAlert,
  readCallAlertSuppression,
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
