// Unit tests for lib/customers/search.ts phoneDigitsMatch (board digit
// search after the m142 phone backfill). Run: npx tsx scripts/test_customer_search.ts
import { phoneDigitsMatch } from "../lib/customers/search";

let failures = 0;
function ok(name: string, cond: boolean, detail = "") {
  if (!cond) failures += 1;
  console.log(`${cond ? "PASS" : "FAIL"} ${name}${detail ? ` — ${detail}` : ""}`);
}

ok("digits term vs dashed phone", phoneDigitsMatch("303-555-0100", "3035550100"));
ok("digits term vs bare phone", phoneDigitsMatch("3035550100", "3035550100"));
ok("partial digits", phoneDigitsMatch("303-555-0100", "55501"));
ok("phone2 style input", phoneDigitsMatch("(303) 555-0199", "3035550199"));
ok("term under 3 digits rejected", !phoneDigitsMatch("303-555-0100", "30"));
ok("non-digit term rejected", !phoneDigitsMatch("303-555-0100", "abc"));
ok("no match", !phoneDigitsMatch("303-555-0100", "9995550100"));
ok("null phone", !phoneDigitsMatch(null, "3035550100"));
ok("empty phone", !phoneDigitsMatch("", "3035550100"));
ok("punctuation in term still digits", phoneDigitsMatch("303-555-0100", "(303) 555"));

console.log(failures === 0 ? "\nAll tests passed." : `\n${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
