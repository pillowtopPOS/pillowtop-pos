// Unit test for the customer detail patch builder and the customer_since
// guard. No database or browser needed: exercises lib/customers/form.ts.
// Run: npx tsx scripts/test_customer_patch.ts
import {
  buildCustomerPatch,
  customerFormDirty,
  customerFormFromDetail,
  customerSinceError,
  type CustomerFormState,
} from "../lib/customers/form";
import type { CustomerDetail } from "../lib/customers/api";

let failures = 0;
function check(name: string, ok: boolean, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? `: ${detail}` : ""}`);
  if (!ok) failures += 1;
}

function baseForm(overrides: Partial<CustomerFormState> = {}): CustomerFormState {
  return {
    isCompany: false,
    companyName: "",
    firstName: "Jane",
    lastName: "Doe",
    phone: "303-555-0100",
    phone2: "",
    email: "jane@x.com",
    streetAddress: "1 Main",
    streetAddressLine2: "",
    city: "Denver",
    state: "CO",
    zipCode: "80000",
    referralSource: "",
    customerSince: "2020-01-15",
    ...overrides,
  };
}

const saved = baseForm();

// unchanged form produces an empty patch
check("no changes -> empty patch", Object.keys(buildCustomerPatch(saved, saved)).length === 0);
check("no changes -> not dirty", !customerFormDirty(saved, saved));

// cleared customer_since IS included in the patch (server would reject it)
const cleared = baseForm({ customerSince: "" });
const clearedPatch = buildCustomerPatch(cleared, saved);
check("cleared date -> patch has customer_since", clearedPatch.customer_since === "", JSON.stringify(clearedPatch.customer_since));
check("cleared date -> dirty", customerFormDirty(cleared, saved));

// the guard rejects it before anything is sent
check("cleared date -> inline error", customerSinceError(cleared, saved) === "Customer since needs a date.", String(customerSinceError(cleared, saved)));

// half-typed / malformed values are rejected the same way
for (const bad of ["2024-0", "01/15/2020", "2024-13-40", "not-a-date"]) {
  const f = baseForm({ customerSince: bad });
  check(`bad date ${JSON.stringify(bad)} -> error`, customerSinceError(f, saved) === "Customer since needs a date.", String(customerSinceError(f, saved)));
}

// a valid new date passes the guard and lands in the patch
const moved = baseForm({ customerSince: "2021-06-01" });
check("valid date -> no error", customerSinceError(moved, saved) === null, String(customerSinceError(moved, saved)));
check("valid date -> patch", buildCustomerPatch(moved, saved).customer_since === "2021-06-01");

// unchanged date never errors even when empty on both sides
const emptyBoth = baseForm({ customerSince: "" });
const savedEmpty = baseForm({ customerSince: "" });
check("empty on both sides -> no error", customerSinceError(emptyBoth, savedEmpty) === null);

// formFromDetail slices timestamps to the date input format
const detail = {
  customer_since: "2019-12-31",
} as unknown as CustomerDetail;
check("formFromDetail keeps date", customerFormFromDetail(detail).customerSince === "2019-12-31", customerFormFromDetail(detail).customerSince);

console.log(failures === 0 ? "\nAll tests passed." : `\n${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
