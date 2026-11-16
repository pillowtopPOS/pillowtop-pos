// Unit tests for lib/format/phone.ts (formatPhone + formatPhoneAsYouType).
// Run: npx tsx scripts/test_phone_format.ts
import { formatPhone, formatPhoneAsYouType } from "../lib/format/phone";

let failures = 0;
function eq(name: string, got: unknown, want: unknown) {
  const ok = got === want;
  if (!ok) failures += 1;
  console.log(`${ok ? "PASS" : "FAIL"} ${name} — got ${JSON.stringify(got)} want ${JSON.stringify(want)}`);
}

// formatPhone: same rules as public.format_phone_dashed (m142)
eq("bare 10 digits", formatPhone("3035550100"), "303-555-0100");
eq("already dashed", formatPhone("303-555-0100"), "303-555-0100");
eq("parentheses", formatPhone("(303) 555-0100"), "303-555-0100");
eq("leading 1", formatPhone("13035550100"), "303-555-0100");
eq("+1", formatPhone("+1 303 555 0100"), "303-555-0100");
eq("11 digits not starting with 1", formatPhone("20355550100"), "20355550100");
eq("extension left as typed", formatPhone("303-555-0100 x12"), "303-555-0100 x12");
eq("7 digit value", formatPhone("5550100"), "5550100");
eq("8 digit value", formatPhone("555-0100"), "555-0100");
eq("empty string", formatPhone(""), "");
eq("null", formatPhone(null), "");
eq("undefined", formatPhone(undefined), "");
eq("whitespace only", formatPhone("   "), "");
eq("surrounding whitespace on 10 digits", formatPhone("  3035550100 "), "303-555-0100");
eq("repeated digits left as typed", formatPhone("1111111111"), "111-111-1111");

// formatPhoneAsYouType: progressive dashes while typing
eq("type 3 digits", formatPhoneAsYouType("303"), "303");
eq("type 4 digits", formatPhoneAsYouType("3035"), "303-5");
eq("type 7 digits", formatPhoneAsYouType("3035550"), "303-555-0");
eq("type 10 digits", formatPhoneAsYouType("3035550100"), "303-555-0100");
eq("type with punctuation", formatPhoneAsYouType("(303) 555"), "303-555");
eq("10 digits starting with 1 formats literally", formatPhoneAsYouType("1303555010"), "130-355-5010");
eq("11 digits leading 1 drops it", formatPhoneAsYouType("13035550100"), "303-555-0100");
eq("over 10 digits keeps raw", formatPhoneAsYouType("30355501001"), "30355501001");
eq("empty", formatPhoneAsYouType(""), "");

// Extension and over-length inputs must survive typing one character at
// a time (the real input path), not just a single whole-string call.
function typeCharByChar(text: string): string {
  let v = "";
  for (const ch of text) v = formatPhoneAsYouType(v + ch);
  return v;
}
for (const [name, text] of [
  ["extension spaced", "303-555-0100 x12"],
  ["extension tight", "303-555-0100x12"],
  ["ext word", "303-555-0100 ext 5"],
  ["12 digits no letters", "303555010012"],
] as const) {
  eq(`as-you-type ${name}`, typeCharByChar(text), text);
  eq(`as-you-type ${name} whole`, formatPhoneAsYouType(text), text);
  eq(`formatPhone leaves ${name} as typed`, formatPhone(text), text);
}
eq("typing normal number still formats", typeCharByChar("3035550199"), "303-555-0199");
eq("typing parens number still formats", typeCharByChar("(720) 555 0144"), "720-555-0144");
eq("typing +1 number still formats", typeCharByChar("+1 303 555 0100"), "303-555-0100");

console.log(failures === 0 ? "\nAll tests passed." : `\n${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
