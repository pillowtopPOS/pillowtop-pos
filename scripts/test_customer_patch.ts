// Unit test for the customer detail patch builder. No database or
// browser needed: exercises lib/customers/form.ts.
// Run: npx tsx scripts/test_customer_patch.ts
import {
  buildCustomerPatch,
  customerFormDirty,
  customerFormFromDetail,
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
    ...overrides,
  };
}

const saved = baseForm();

// unchanged form produces an empty patch
check("no changes -> empty patch", Object.keys(buildCustomerPatch(saved, saved)).length === 0);
check("no changes -> not dirty", !customerFormDirty(saved, saved));

// a changed field lands in the patch under its column name
const edited = baseForm({ city: "Boulder", phone2: "720-555-0144" });
const patch = buildCustomerPatch(edited, saved);
check("city change -> patch", patch.city === "Boulder", JSON.stringify(patch.city));
check("phone2 change -> patch", patch.phone2 === "720-555-0144", JSON.stringify(patch.phone2));
check("unchanged fields absent", patch.first_name === undefined && patch.email === undefined);

// blanking optional fields sends null, not ""
const blanked = baseForm({ phone2: "", streetAddressLine2: "", referralSource: "" });
const blankPatch = buildCustomerPatch(blanked, baseForm({ phone2: "720-555-0144", streetAddressLine2: "Apt 2", referralSource: "Other" }));
check("blanked phone2 -> null", blankPatch.phone2 === null, JSON.stringify(blankPatch.phone2));
check("blanked line2 -> null", blankPatch.street_address_line_2 === null);
check("blanked referral -> null", blankPatch.referral_source === null);

// company toggle sends is_company and company_name only
const asCompany = baseForm({ isCompany: true, companyName: "Acme" });
const companyPatch = buildCustomerPatch(asCompany, saved);
check("company toggle -> is_company", companyPatch.is_company === true);
check("company toggle -> company_name", companyPatch.company_name === "Acme");
check("company toggle skips person names", companyPatch.first_name === undefined && companyPatch.last_name === undefined);

// customer_since is read-only on the page and never appears in a patch
const withSince = { ...saved, customerSince: "2020-01-15" } as CustomerFormState & { customerSince: string };
check("no customer_since key ever", !("customer_since" in buildCustomerPatch(withSince, withSince)));

// formFromDetail maps nulls to empty strings for the inputs
const detail = {
  is_company: true,
  company_name: "Acme",
  first_name: "Acme",
  last_name: "",
  phone: "3035550100",
  phone2: null,
  email: "a@x.com",
  street_address: null,
  street_address_line_2: null,
  city: null,
  state: null,
  zip_code: null,
  referral_source: "Other",
  customer_since: "2019-12-31",
} as unknown as CustomerDetail;
const f = customerFormFromDetail(detail);
check("formFromDetail company", f.isCompany === true && f.companyName === "Acme");
check("formFromDetail formats phone", f.phone === "303-555-0100", f.phone);
check("formFromDetail nulls -> empty", f.phone2 === "" && f.city === "");
check("formFromDetail referral kept", f.referralSource === "Other");

console.log(failures === 0 ? "\nAll tests passed." : `\n${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
