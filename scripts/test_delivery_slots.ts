// Unit tests for lib/delivery/availability.ts pure helpers.
// Run: node scripts/test_delivery_slots.ts
import {
  addDaysISO,
  cutoffMinutes,
  cutoffNoteLine,
  earliestBookableDate,
  firstOpenDayOnOrAfter,
  openSlotLabel,
  slotDayParts,
  zonedNow,
} from "../lib/delivery/availability.ts";

let failures = 0;
function check(name: string, actual: unknown, expected: unknown) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failures++;
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${ok ? "" : ` — got ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`}`);
}

// --- slotDayParts (UTC math, no timezone shift) ---
check("slot parts fri", slotDayParts("2026-11-13"), {
  weekday: "Fri",
  dayNum: 13,
  month: "Nov",
});
check("slot parts year boundary", slotDayParts("2026-12-31"), {
  weekday: "Thu",
  dayNum: 31,
  month: "Dec",
});

// --- cutoffMinutes ---
check("cutoff 15:00", cutoffMinutes("15:00"), 900);
check("cutoff 15:00:00", cutoffMinutes("15:00:00"), 900);
check("cutoff null", cutoffMinutes(null), null);
check("cutoff garbage", cutoffMinutes("abc"), null);

// --- zonedNow ---
// 2026-11-13T22:30:00Z is 3:30 PM in Denver (MST, UTC-7).
const denver = { timezone: "America/Denver", cutoff_time: "17:00" };
check(
  "zonedNow denver",
  zonedNow(new Date("2026-11-13T22:30:00Z"), "America/Denver"),
  { dateIso: "2026-11-13", minutes: 15 * 60 + 30 }
);
check("zonedNow bad tz", zonedNow(new Date(), "Not/AZone"), null);
check("zonedNow null tz", zonedNow(new Date(), null), null);

// --- earliestBookableDate: before cutoff -> tomorrow; at/after -> +2 ---
check(
  "earliest before cutoff",
  earliestBookableDate(denver, new Date("2026-11-13T22:30:00Z")), // 3:30 PM Denver
  "2026-11-14"
);
check(
  "earliest after cutoff",
  earliestBookableDate(denver, new Date("2026-11-14T00:30:00Z")), // 5:30 PM Denver Nov 13
  "2026-11-15"
);
check(
  "earliest exactly at cutoff",
  earliestBookableDate(denver, new Date("2026-11-14T00:00:00Z")), // 5:00 PM Denver
  "2026-11-15"
);
check("earliest no tz", earliestBookableDate({ timezone: null, cutoff_time: "17:00" }), null);
check(
  "earliest no cutoff -> tomorrow",
  earliestBookableDate({ timezone: "America/Denver", cutoff_time: null }, new Date("2026-11-13T22:30:00Z")),
  "2026-11-14"
);

// --- cutoffNoteLine ---
check(
  "note before cutoff",
  cutoffNoteLine(denver, "2026-11-14", new Date("2026-11-13T22:30:00Z")),
  "Orders booked before 5:00 PM (Denver time) can start tomorrow."
);
check(
  "note after cutoff",
  cutoffNoteLine(denver, "2026-11-15", new Date("2026-11-14T00:30:00Z")),
  "Orders booked after 5:00 PM (Denver time) start the day after tomorrow."
);
check(
  "note no cutoff",
  cutoffNoteLine({ timezone: "America/Denver", cutoff_time: null }, "2026-11-14"),
  "No cutoff. Earliest day is tomorrow."
);
check("note no ctx", cutoffNoteLine(null, "2026-11-14"), null);

// --- openSlotLabel ---
check("open slots", openSlotLabel({ capacity: 14, booked_count: 9, trucks: [{ on: true }] }), "5 open");
check("full", openSlotLabel({ capacity: 14, booked_count: 14, trucks: [{ on: true }] }), "Full");
check("overbooked clamps", openSlotLabel({ capacity: 14, booked_count: 20, trucks: [{ on: true }] }), "Full");
check("no delivery no trucks on", openSlotLabel({ capacity: 0, booked_count: 0, trucks: [{ on: false }] }), "No delivery");
check("no delivery empty trucks", openSlotLabel({ capacity: 0, booked_count: 0, trucks: [] }), "No delivery");
check("closed trucks on zero cap", openSlotLabel({ capacity: 0, booked_count: 0, trucks: [{ on: true }] }), "Closed");
check("missing day", openSlotLabel(undefined), "");

// --- firstOpenDayOnOrAfter ---
const day = (date: string, capacity: number, booked: number, on = true) => ({
  date,
  capacity,
  booked_count: booked,
  trucks: [{ on }],
});
// (1) Sat before cutoff, Sun has no delivery -> badge lands Mon.
check(
  "badge skips no-delivery earliest",
  firstOpenDayOnOrAfter("2026-11-15", [
    day("2026-11-14", 10, 2),
    day("2026-11-15", 0, 0, false),
    day("2026-11-16", 10, 3),
  ]),
  "2026-11-16"
);
// (2) Sun itself open -> badge stays Sun.
check(
  "badge on open earliest",
  firstOpenDayOnOrAfter("2026-11-15", [
    day("2026-11-15", 10, 2),
    day("2026-11-16", 10, 3),
  ]),
  "2026-11-15"
);
// (3) Earliest day full, next day open -> next open day.
check(
  "badge skips full earliest",
  firstOpenDayOnOrAfter("2026-11-15", [
    day("2026-11-15", 10, 10),
    day("2026-11-16", 10, 4),
  ]),
  "2026-11-16"
);
// (4) Every day full -> no badge.
check(
  "badge none when all full",
  firstOpenDayOnOrAfter("2026-11-15", [
    day("2026-11-15", 10, 10),
    day("2026-11-16", 10, 12),
  ]),
  null
);
// (5) Earliest date beyond the visible week -> no badge.
check(
  "badge none when earliest beyond week",
  firstOpenDayOnOrAfter("2026-11-25", [
    day("2026-11-14", 10, 2),
    day("2026-11-15", 10, 3),
  ]),
  null
);
check("badge null earliest", firstOpenDayOnOrAfter(null, [day("2026-11-15", 10, 1)]), null);

// --- addDaysISO ---
check("addDays month", addDaysISO("2026-11-30", 1), "2026-12-01");
check("addDays negative", addDaysISO("2026-11-01", -1), "2026-10-31");

if (failures) {
  console.log(`\n${failures} FAILURES`);
  process.exit(1);
}
console.log("\nAll tests passed.");
