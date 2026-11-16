// Unit test for lib/journeys/assignee.ts — plain node script.
// Run: npx tsx scripts/test_journey_assignee.ts
import {
  defaultAssigneeId,
  parseAssigneeChoice,
} from "../lib/journeys/assignee.ts";

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

// ---- default assignee resolution ----
eq(
  defaultAssigneeId({ id: "emp-1" }),
  "emp-1",
  "employee found -> their id"
);
eq(defaultAssigneeId(null), null, "no employee row -> Unassigned");
eq(defaultAssigneeId(undefined), null, "undefined employee -> Unassigned");

// ---- user overrides the default ----
eq(
  parseAssigneeChoice("emp-2"),
  "emp-2",
  "user picks another employee"
);
eq(parseAssigneeChoice(""), null, "user picks Unassigned -> null");

console.log(failures === 0 ? "\nAll tests passed." : `\n${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
