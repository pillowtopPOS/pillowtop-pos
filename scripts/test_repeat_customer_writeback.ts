// Regression test: picking an existing customer on /journeys/new must not
// blank fields the customer already has. Exercises syncRepeatCustomerFields,
// the exact write-back createJourney runs for a repeat customer, with the
// form values a "Find a customer" pick produces (full record loaded via
// get_customer, formatted like useCustomerMatch does).
// Run: npx tsx scripts/test_repeat_customer_writeback.ts
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
import { syncRepeatCustomerFields } from "../lib/journeys/queries";
import { formatPhone } from "../lib/format/phone";

for (const line of readFileSync(".env.local", "utf8").split("\n")) {
  const m = line.match(/^([A-Z_]+)=(.*)$/);
  if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
}
const URL_ENV = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const ANON = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const PASS = "WbTest123!";

const admin = createClient(URL_ENV, SVC, { auth: { persistSession: false } });

let failures = 0;
function check(name: string, ok: boolean, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? `: ${detail}` : ""}`);
  if (!ok) failures += 1;
}

const tag = `wb${Date.now().toString(36)}`;
const f = { companies: [] as string[], stores: [] as string[], customers: [] as string[], journeys: [] as string[], employees: [] as string[], users: [] as string[] };

async function main() {
  const co = (await admin.from("companies").insert({ name: `__${tag}__`, business_timezone: "America/Denver" }).select("id").single()).data!.id;
  f.companies.push(co);
  const st = (await admin.from("stores").insert({ company_id: co, name: `__${tag}_st__`, location_type: "STORE", is_active: true }).select("id").single()).data!.id;
  f.stores.push(st);

  const email = `${tag}@test.invalid`;
  const { data: u, error: ue } = await admin.auth.admin.createUser({ email, password: PASS, email_confirm: true });
  if (ue) throw ue;
  f.users.push(u.user!.id);
  const emp = (await admin.from("employees").insert({ first_name: "W", last_name: "B", role: "manager", home_store_id: st, auth_user_id: u.user!.id, is_active: true }).select("id").single()).data!.id;
  f.employees.push(emp);

  const cust = (await admin.from("customers").insert({
    company_id: co, first_name: "Rae", last_name: "Referral",
    phone: "3035550142", phone2: "7205550163",
    email: `${tag}@x.com`, referral_source: "Google",
    street_address: "9 Referral Way", street_address_line_2: "Suite 4",
    city: "Denver", state: "CO", zip_code: "80202",
  }).select("id").single()).data!.id;
  f.customers.push(cust);

  // customers UPDATE is RLS-gated on having a visible journey (m036).
  const j = (await admin.from("sleep_journeys").insert({
    customer_id: cust, store_id: st, current_state: "Active Opportunity",
    fulfillment_type: "delivery",
  }).select("id").single()).data!.id;
  f.journeys = f.journeys ?? [];
  f.journeys.push(j);

  const c = createClient(URL_ENV, ANON, { auth: { persistSession: false } });
  const { error: se } = await c.auth.signInWithPassword({ email, password: PASS });
  if (se) throw se;

  // What the fixed pick path produces: get_customer detail mapped through
  // useCustomerMatch (formatPhone on phones, "" for missing referral).
  // Same RPC the app calls, through the signed-in client (the browser
  // client in lib/customers/api has no session under tsx).
  const { data: detail, error: de } = await (c.rpc as any)("get_customer", { p_id: cust });
  if (de) throw de;
  const formCustomer = {
    firstName: detail.first_name,
    lastName: detail.last_name,
    isCompany: detail.is_company,
    companyName: detail.company_name ?? "",
    phone: formatPhone(detail.phone) || "",
    phone2: formatPhone(detail.phone2),
    email: detail.email ?? "",
    referralSource: detail.referral_source ?? "",
    streetAddress: detail.street_address ?? "",
    streetAddressLine2: detail.street_address_line_2 ?? "",
    city: detail.city ?? "",
    state: detail.state ?? "",
    zipCode: detail.zip_code ?? "",
  };

  await syncRepeatCustomerFields(c as unknown as SupabaseClient, cust, formCustomer);

  const after = (await admin.from("customers").select(
    "phone, phone2, email, referral_source, street_address, street_address_line_2, city, state, zip_code"
  ).eq("id", cust).single()).data!;

  check("referral_source preserved", after.referral_source === "Google", String(after.referral_source));
  check("phone preserved", (after.phone ?? "").replace(/\D/g, "") === "3035550142", String(after.phone));
  check("phone2 preserved", (after.phone2 ?? "").replace(/\D/g, "") === "7205550163", String(after.phone2));
  check("email preserved", after.email === `${tag}@x.com`, String(after.email));
  check("street preserved", after.street_address === "9 Referral Way", String(after.street_address));
  check("line2 preserved", after.street_address_line_2 === "Suite 4", String(after.street_address_line_2));
  check("city/state/zip preserved",
    after.city === "Denver" && after.state === "CO" && after.zip_code === "80202",
    `${after.city}, ${after.state} ${after.zip_code}`);

  // Sanity: the buggy shape (referralSource: "") would have nulled it.
  // Prove the write-back still works when the form value genuinely differs.
  await syncRepeatCustomerFields(c as unknown as SupabaseClient, cust, { ...formCustomer, referralSource: "Friend or family" });
  const changed = (await admin.from("customers").select("referral_source").eq("id", cust).single()).data!;
  check("genuine referral change still writes", changed.referral_source === "Friend or family", String(changed.referral_source));
}

main()
  .catch((e) => { failures += 1; console.log(`FAIL run: ${e?.message ?? e}`); })
  .finally(async () => {
    try {
      if (f.journeys.length) {
        await admin.from("journey_line_items").delete().in("journey_id", f.journeys);
        await admin.from("journey_events").delete().in("journey_id", f.journeys);
        await admin.from("sleep_journeys").delete().in("id", f.journeys);
      }
      if (f.customers.length) await admin.from("customers").delete().in("id", f.customers);
      if (f.employees.length) await admin.from("employees").delete().in("id", f.employees);
      if (f.stores.length) await admin.from("stores").delete().in("id", f.stores);
      if (f.companies.length) await admin.from("companies").delete().in("id", f.companies);
      if (f.users.length) for (const id of f.users) await admin.auth.admin.deleteUser(id);
    } catch {}
    console.log(failures === 0 ? "\nAll tests passed." : `\n${failures} FAILURES`);
    process.exit(failures === 0 ? 0 : 1);
  });
