// Unit test for lib/delivery/calls.ts — plain node script, no test
// runner in this repo. Run: node scripts/test_delivery_calls.ts
// (Node 24 strips the types; keep calls.ts to erasable syntax only.)
import {
  CONFIRMATION_OUTCOMES,
  CONFIRMATION_STATUS_META,
  confirmationDayLabel,
  confirmationWindowText,
  lastCallText,
  lastCallWhen,
} from "../lib/delivery/calls.ts";

let failures = 0;
function eq<T>(got: T, want: T, name: string) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures += 1;
  console.log(`${ok ? "PASS" : "FAIL"} ${name}`);
  if (!ok) {
    console.log(`  got:  ${JSON.stringify(got)}`);
    console.log(`  want: ${JSON.stringify(want)}`);
  }
}

// ---- status label mapping --------------------------------------------
eq(CONFIRMATION_STATUS_META.not_called.label, "Not called", "not_called label");
eq(CONFIRMATION_STATUS_META.not_called.tone, "grey", "not_called tone");
eq(CONFIRMATION_STATUS_META.confirmed.label, "Confirmed", "confirmed label");
eq(CONFIRMATION_STATUS_META.confirmed.tone, "green", "confirmed tone");
eq(
  CONFIRMATION_STATUS_META.confirmed_window_changed.label,
  "Window changed since confirmed, call again",
  "window_changed label"
);
eq(
  CONFIRMATION_STATUS_META.confirmed_window_changed.tone,
  "amber",
  "window_changed tone"
);
eq(CONFIRMATION_STATUS_META.left_voicemail.label, "Left voicemail", "voicemail label");
eq(CONFIRMATION_STATUS_META.no_answer.label, "No answer", "no_answer label");
eq(CONFIRMATION_STATUS_META.wrong_number.label, "Wrong number", "wrong_number label");
eq(CONFIRMATION_STATUS_META.wrong_number.tone, "red", "wrong_number tone");
eq(
  CONFIRMATION_STATUS_META.needs_different_day.label,
  "Needs a different day",
  "needs_different_day label"
);
eq(
  CONFIRMATION_STATUS_META.needs_different_day.tone,
  "amber",
  "needs_different_day tone"
);
eq(CONFIRMATION_OUTCOMES.length, 5, "five modal outcomes");
eq(
  CONFIRMATION_OUTCOMES.map((o) => o.value),
  ["confirmed", "left_voicemail", "no_answer", "wrong_number", "needs_different_day"],
  "outcome values match m138 namespace"
);

// ---- date labels: no Date-shift ----------------------------------------
// 2026-11-13 is a Friday; 2026-11-14 a Saturday; 2026-01-01 a Thursday.
eq(confirmationDayLabel("2026-11-13"), "Fri Nov 13", "day label fri");
eq(confirmationDayLabel("2026-11-14"), "Sat Nov 14", "day label sat");
eq(confirmationDayLabel("2026-01-01"), "Thu Jan 1", "day label year boundary");
eq(confirmationDayLabel("2026-12-31"), "Thu Dec 31", "day label dec 31");
// Same answer regardless of the machine's timezone: the helper only
// ever sees the date string, and UTC math cannot shift it.
eq(
  confirmationDayLabel("2027-03-01"),
  "Mon Mar 1",
  "day label monday"
);

// ---- window text --------------------------------------------------------
eq(
  confirmationWindowText("window", "10:00:00", "13:00:00", "2026-11-13"),
  "10:00 AM to 1:00 PM",
  "window mode label"
);
eq(
  confirmationWindowText("day_only", "10:00:00", "13:00:00", "2026-11-13"),
  "Fri Nov 13",
  "day_only shows the date"
);
eq(
  confirmationWindowText("window", null, null, "2026-11-13"),
  "No window set",
  "window mode no window"
);

// ---- last call text -----------------------------------------------------
// now = Fri Nov 13 2026, 6:00 PM local.
const NOW = new Date(2026, 10, 13, 18, 0, 0);
eq(
  lastCallWhen("2026-11-13T16:50:00", NOW),
  "today 4:50 PM",
  "same day"
);
eq(
  lastCallWhen("2026-11-12T16:50:00", NOW),
  "yesterday 4:50 PM",
  "yesterday"
);
eq(
  lastCallWhen("2026-11-10T16:50:00", NOW),
  "Nov 10, 4:50 PM",
  "older day"
);
eq(
  lastCallText(
    { outcome: "left_voicemail", occurred_at: "2026-11-12T16:50:00", by_name: "Sam" },
    NOW
  ),
  "Left voicemail, yesterday 4:50 PM (Sam)",
  "full last-call line"
);
eq(
  lastCallText(
    { outcome: "no_answer", occurred_at: "2026-11-13T09:05:00", by_name: null },
    NOW
  ),
  "No answer, today 9:05 AM",
  "no by_name omits parens"
);
eq(lastCallText(null, NOW), null, "no call -> null");
eq(
  lastCallText({ outcome: null, occurred_at: null, by_name: "Sam" }, NOW),
  null,
  "missing occurred_at -> null"
);

console.log(failures === 0 ? "\nAll tests passed." : `\n${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
