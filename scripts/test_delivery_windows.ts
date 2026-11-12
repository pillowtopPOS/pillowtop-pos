// Unit test for lib/delivery/windows.ts — plain node script, no test
// runner in this repo. Run: node scripts/test_delivery_windows.ts
// (Node 24 strips the types; keep windows.ts to erasable syntax only.)
import {
  suggestWindows,
  fillMissingWindows,
  round30,
  timeStrToMinutes,
  minutesToLabel,
  windowLabel,
  validateWindowDraft,
  windowSelectOptions,
  type WindowSpan,
} from "../lib/delivery/windows.ts";

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
const T = (h: number, m = 0) => h * 60 + m;
const D = 600; // 10:00 AM
const E = 1140; // 7:00 PM
const span = (s: number, e: number): WindowSpan => ({ start: s, end: e });
const list = (arr: [number, number][]) => arr.map(([s, e]) => span(s, e));

// 1. 8 stops, 3h — suggested starts on 30-minute marks:
// 10:00, 11:00, 11:30, 12:30, 1:30, 2:30, 3:00, 4:00 (last ends 7 PM).
console.log("8 stops, 3h (day 10AM-7PM):");
eq(
  suggestWindows(8, D, E, 180),
  list([
    [600, 780], [660, 840], [690, 870], [750, 930],
    [810, 990], [870, 1050], [900, 1080], [960, 1140],
  ]),
  "matches spec"
);
// 2. 3 stops, 3h
console.log("3 stops, 3h:");
eq(suggestWindows(3, D, E, 180), list([[600, 780], [780, 960], [960, 1140]]), "matches spec");
// 3. 2 stops, 3h
console.log("2 stops, 3h:");
eq(suggestWindows(2, D, E, 180), list([[600, 780], [780, 960]]), "matches spec");
// 4. 1 stop, 3h
console.log("1 stop, 3h:");
eq(suggestWindows(1, D, E, 180), list([[780, 960]]), "matches spec");
// 5. 4 stops, 3h
console.log("4 stops, 3h:");
eq(
  suggestWindows(4, D, E, 180),
  list([[600, 780], [720, 900], [840, 1020], [960, 1140]]),
  "matches spec"
);
// 6. 5 stops, 3h
console.log("5 stops, 3h:");
eq(
  suggestWindows(5, D, E, 180),
  list([[600, 780], [690, 870], [780, 960], [870, 1050], [960, 1140]]),
  "matches spec"
);
// 7. 12 stops, 4h — 30-minute rounding makes stops 5 and 6 collide at
// 12:30 (both round to the same mark); that is expected with 12 windows.
console.log("12 stops, 4h:");
eq(
  suggestWindows(12, D, E, 240),
  list([
    [600, 840], [630, 870], [660, 900], [690, 930], [720, 960],
    [750, 990], [750, 990], [780, 1020], [810, 1050], [840, 1080],
    [870, 1110], [900, 1140],
  ]),
  "matches spec"
);

// Fill only empty stops: 3 of 8 hand set keep values, rest get the
// spacing positions computed over all 8.
console.log("fill only empty stops (3 of 8 preset):");
const preset: (WindowSpan | null)[] = [
  span(600, 780), null, null, span(700, 880), null, null, span(900, 1080), null,
];
const filled = fillMissingWindows(preset, D, E, 180);
eq(filled[0], preset[0], "preset 0 kept");
eq(filled[3], preset[3], "preset 3 kept");
eq(filled[6], preset[6], "preset 6 kept");
const all8 = suggestWindows(8, D, E, 180);
eq(filled[1], all8[1], "slot 1 = spacing position 1");
eq(filled[2], all8[2], "slot 2 = spacing position 2");
eq(filled[4], all8[4], "slot 4 = spacing position 4");
eq(filled[5], all8[5], "slot 5 = spacing position 5");
eq(filled[7], all8[7], "slot 7 = spacing position 7");

// Clamping: 9AM-5PM day, 4 stops, 3h. span 480 < n*L 720 -> overlap.
// step = (480-180)/3 = 100 -> round30 gives offsets 0, 90, 210; starts
// 540, 630, 750, last forced 1020-180=840; all inside the day.
console.log("clamp 9AM-5PM, 4 stops, 3h:");
eq(
  suggestWindows(4, T(9), T(17), 180),
  list([[540, 720], [630, 810], [750, 930], [840, 1020]]),
  "matches spec"
);
// Edge: window longer than the day -> full day for everyone.
eq(
  suggestWindows(3, D, E, 600),
  list([[600, 1140], [600, 1140], [600, 1140]]),
  "L > span gives full day"
);
eq(suggestWindows(0, D, E, 180), [], "n=0 empty");
eq(round30(45), 60, "round30 half up");
eq(round30(44), 30, "round30 down");
eq(round30(75), 90, "round30 half up 2");
eq(timeStrToMinutes("10:00:00"), 600, "time parse HH:MM:SS");
eq(timeStrToMinutes("9:30"), 570, "time parse HH:MM");
eq(minutesToLabel(750), "12:30 PM", "label");
eq(windowLabel(600, 780), "10:00 AM to 1:00 PM", "window label");
eq(windowLabel(null, 780), null, "window label null");

// Draft validity rule (client-side): both-or-neither, end after start.
console.log("validateWindowDraft:");
eq(validateWindowDraft("10:00", "13:00"), null, "valid window ok");
eq(validateWindowDraft(null, null), null, "both null = clear, ok");
eq(validateWindowDraft("10:00", null), "incomplete", "start only incomplete");
eq(validateWindowDraft(null, "13:00"), "incomplete", "end only incomplete");
eq(validateWindowDraft("13:00", "10:00"), "end_not_after_start", "end before start");
eq(validateWindowDraft("10:00", "10:00"), "end_not_after_start", "end equal start");
eq(validateWindowDraft("10:00:30", "10:00:45"), "end_not_after_start", "seconds parse, still invalid");
eq(validateWindowDraft("10:00", "26:00"), "incomplete", "unparseable end counts as unset");
eq(validateWindowDraft("25:00", "26:00"), null, "both unparseable reads as clear");

// Editor select options: standard list plus out-of-range current value.
console.log("windowSelectOptions:");
const std = windowSelectOptions(null);
eq(std.length, 65, "base list is 65 quarter hours 6AM-10PM");
eq(std[0], 360, "first option 6:00 AM");
eq(std[std.length - 1], 1320, "last option 10:00 PM");
const early = windowSelectOptions("05:30");
eq(early[0], 330, "5:30 AM prepended");
eq(early.length, 66, "one extra option");
const late = windowSelectOptions("23:30");
eq(late[late.length - 1], 1410, "11:30 PM appended");
eq(late.length, 66, "one extra option late");
const odd = windowSelectOptions("10:51");
eq(odd.includes(651), true, "10:51 AM included as extra");
eq(windowSelectOptions("10:00").length, 65, "in-range value adds nothing");

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
