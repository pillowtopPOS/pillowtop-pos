// Integration test for migration 142 (customer foundation).
// REQUIRES migration 142 to be installed in the target Supabase project.
// Creates its own fixtures (two companies, auth users, employees,
// customers, journeys), runs every check, then deletes everything.
// Run: npx tsx scripts/test_customer_foundation.ts
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";

for (const line of readFileSync(".env.local", "utf8").split("\n")) {
  const m = line.match(/^([A-Z_]+)=(.*)$/);
  if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
}
const URL_ENV = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const ANON = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY!;

const admin = createClient(URL_ENV, SVC, {
  auth: { autoRefreshToken: false, persistSession: false },
});

let failures = 0;
function check(name: string, ok: boolean, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures += 1;
}

const tag = `cf${Date.now().toString(36)}`;
const PASS = "CfTest123!";

// fixture ids for cleanup
const f = {
  companies: [] as string[],
  stores: [] as string[],
  customers: [] as string[],
  journeys: [] as string[],
  employees: [] as string[],
  users: [] as string[],
};

async function mkUser(email: string) {
  const { data, error } = await admin.auth.admin.createUser({
    email,
    password: PASS,
    email_confirm: true,
  });
  if (error) throw error;
  f.users.push(data.user!.id);
  return data.user!.id;
}

async function signIn(email: string) {
  const c = createClient(URL_ENV, ANON, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data, error } = await c.auth.signInWithPassword({
    email,
    password: PASS,
  });
  if (error) throw error;
  return c;
}

async function rpc(client: SupabaseClient, fn: string, params: object) {
  return (client.rpc as any)(fn, params);
}

async function main() {
  // ---- preflight: is m142 installed? ----
  const probe = await admin.rpc("format_phone_dashed", { p_phone: "3035550100" });
  if (probe.error) {
    console.log(`SKIP: migration 142 not installed (${probe.error.message})`);
    console.log("Install supabase/migrations/142_customer_foundation.sql first.");
    process.exit(2);
  }
  check("format_phone_dashed formats", probe.data === "303-555-0100", String(probe.data));

  // ---- fixtures ----
  // Company A + store, Company B + store
  const coA = (await admin.from("companies").insert({ name: `__${tag}_A__`, business_timezone: "America/Denver" }).select("id").single()).data!.id;
  const coB = (await admin.from("companies").insert({ name: `__${tag}_B__`, business_timezone: "America/Denver" }).select("id").single()).data!.id;
  f.companies.push(coA, coB);
  const stA = (await admin.from("stores").insert({ company_id: coA, name: `__${tag}_stA__`, location_type: "STORE", is_active: true }).select("id").single()).data!.id;
  const stB = (await admin.from("stores").insert({ company_id: coB, name: `__${tag}_stB__`, location_type: "STORE", is_active: true }).select("id").single()).data!.id;
  f.stores.push(stA, stB);

  // Auth users: A employee (manager, store A), B employee (manager, store B), C no employee
  const emailA = `${tag}a@test.invalid`;
  const emailB = `${tag}b@test.invalid`;
  const emailC = `${tag}c@test.invalid`;
  const uidA = await mkUser(emailA);
  const uidB = await mkUser(emailB);
  await mkUser(emailC);
  const empA = (await admin.from("employees").insert({ first_name: "Cf", last_name: "A", role: "manager", home_store_id: stA, auth_user_id: uidA, is_active: true }).select("id").single()).data!.id;
  const empB = (await admin.from("employees").insert({ first_name: "Cf", last_name: "B", role: "manager", home_store_id: stB, auth_user_id: uidB, is_active: true }).select("id").single()).data!.id;
  f.employees.push(empA, empB);

  const custInsert = (row: object) =>
    admin.from("customers").insert(row).select("id").single();

  // Company A customers (service role: company_id stays null unless set)
  const c1 = (await custInsert({ company_id: coA, first_name: "Jane", last_name: "Doe", phone: "(303) 555-0100", email: "jane@x.com", street_address: "1 Main", city: "Denver", state: "CO", zip_code: "80000" })).data!.id;
  const c2 = (await custInsert({ company_id: coA, first_name: "John", last_name: "Roe", phone: "555-000-1111", phone2: "3035550199", email: "john@x.com" })).data!.id;
  const c3 = (await custInsert({ company_id: coA, first_name: "Jen", last_name: "Smith", phone: "555-222-3333", email: "JANE.SMITH@X.COM" })).data!.id;
  const c4 = (await custInsert({ company_id: coA, first_name: "Al", last_name: "Match", phone: "555-444-5555", email: "al@x.com" })).data!.id;
  const c5 = (await custInsert({ company_id: coB, first_name: "Jane", last_name: "Doe", phone: "303-555-0100", email: "jane@x.com" })).data!.id;
  const c6 = (await custInsert({ company_id: coA, first_name: "Zed", last_name: "Nobody", phone: "555-999-0000", email: "zed@x.com" })).data!.id;
  // six extra phone-twins of c1 to prove the limit of 5
  for (let i = 0; i < 6; i++) {
    const r = await custInsert({ company_id: coA, first_name: `Twin${i}`, last_name: "Phone", phone: "3035550100", email: `twin${i}@x.com` });
    f.customers.push(r.data!.id);
  }
  f.customers.push(c1, c2, c3, c4, c5, c6);

  // journeys for c1 (2 orders, different created_at) - pickup avoids the address trigger
  for (const daysAgo of [10, 2]) {
    const j = await admin.from("sleep_journeys").insert({
      customer_id: c1, store_id: stA, current_state: "Active Opportunity",
      fulfillment_type: "pickup",
    }).select("id").single();
    f.journeys.push(j.data!.id);
    await admin.from("sleep_journeys").update({ created_at: new Date(Date.now() - daysAgo * 864e5).toISOString() }).eq("id", j.data!.id);
  }

  const asA = await signIn(emailA);
  const asB = await signIn(emailB);
  const asC = await signIn(emailC);
  const anonClient = createClient(URL_ENV, ANON, { auth: { persistSession: false } });

  // ---- format trigger ----
  const trig = await admin.from("customers").insert({ first_name: "Tr", last_name: "Ig", phone: "3035550166", phone2: "+1 (303) 555-0177", email: "tr@x.com" }).select("id,phone,phone2").single();
  f.customers.push(trig.data!.id);
  check("trigger formats phone", trig.data!.phone === "303-555-0166", trig.data!.phone);
  check("trigger formats phone2", trig.data!.phone2 === "303-555-0177", String(trig.data!.phone2));
  const odd = await admin.from("customers").insert({ first_name: "Odd", last_name: "Num", phone: "555-0166", email: "odd@x.com" }).select("id,phone").single();
  f.customers.push(odd.data!.id);
  check("odd-length phone left as typed", odd.data!.phone === "555-0166", odd.data!.phone);

  // ---- company_id trigger: authenticated insert gets caller's company ----
  const viaUser = await asA.from("customers").insert({ first_name: "Via", last_name: "User", phone: "3035550000", email: "via@x.com" }).select("id,company_id").single();
  check("authenticated insert sets company_id", viaUser.data?.company_id === coA, String(viaUser.data?.company_id));
  if (viaUser.data) f.customers.push(viaUser.data.id);
  // service-role insert with no company stays null
  const svcNull = await admin.from("customers").insert({ first_name: "Svc", last_name: "Null", phone: "3035550001", email: "svc@x.com" }).select("id,company_id").single();
  f.customers.push(svcNull.data!.id);
  check("service-role insert leaves company_id null", svcNull.data!.company_id === null, String(svcNull.data!.company_id));

  // ---- find_matching_customers ----
  // phone across formats (input parens vs stored dashed)
  let r = await rpc(asA, "find_matching_customers", { p_first: "", p_last: "", p_phone: "(303) 555-0100", p_email: "" });
  let rows = (r.data ?? []) as any[];
  check("phone match across formats", rows.some((x) => x.id === c1), `got ${rows.length} rows`);
  check("phone+email ranks first", rows[0]?.id === c1, `first=${rows[0]?.id}`);
  check("limit 5", rows.length <= 5, `got ${rows.length}`);
  check("no cross-company leak", !rows.some((x) => x.id === c5));
  check("unrelated customer absent", !rows.some((x) => x.id === c6));

  // second phone
  r = await rpc(asA, "find_matching_customers", { p_first: "", p_last: "", p_phone: "303-555-0199", p_email: "" });
  rows = (r.data ?? []) as any[];
  check("phone2 match", rows.some((x) => x.id === c2), `got ${rows.length}`);

  // email case-insensitive
  r = await rpc(asA, "find_matching_customers", { p_first: "", p_last: "", p_phone: "", p_email: "  JANE.SMITH@X.COM " });
  rows = (r.data ?? []) as any[];
  check("email case-insensitive match", rows.some((x) => x.id === c3), `got ${rows.length}`);

  // name-only ranked last: query matching c4 by name plus c1 by phone
  r = await rpc(asA, "find_matching_customers", { p_first: "Al", p_last: "Match", p_phone: "3035550100", p_email: "jane@x.com" });
  rows = (r.data ?? []) as any[];
  const iC4 = rows.findIndex((x) => x.id === c4);
  const iPhone = rows.findIndex((x) => x.id === c1);
  check("name-only ranked last", iC4 === -1 || iPhone === -1 || iC4 > iPhone, `c4@${iC4} c1@${iPhone}`);
  const nameOnlyRow = rows.find((x) => x.id === c4);
  check("name-only reasons", nameOnlyRow ? JSON.stringify(nameOnlyRow.reasons) === '["name"]' : true, JSON.stringify(nameOnlyRow?.reasons));

  // journey_count + last_order_at on c1
  const c1row = rows.find((x) => x.id === c1);
  check("journey_count", c1row?.journey_count === 2, String(c1row?.journey_count));
  check("last_order_at present", !!c1row?.last_order_at, String(c1row?.last_order_at));

  // cross-company isolation: user B sees only company B matches
  r = await rpc(asB, "find_matching_customers", { p_first: "", p_last: "", p_phone: "3035550100", p_email: "" });
  const rowsB = (r.data ?? []) as any[];
  check("company B sees own match", rowsB.some((x) => x.id === c5));
  check("company B does not see company A", !rowsB.some((x) => x.id === c1 || x.id === c2));

  // no company raises
  r = await rpc(asC, "find_matching_customers", { p_first: "A", p_last: "B", p_phone: "", p_email: "" });
  check("no company raises", !!r.error, r.error?.message ?? "no error");

  // anon denied
  r = await rpc(anonClient, "find_matching_customers", { p_first: "A", p_last: "B", p_phone: "", p_email: "" });
  check("anon denied", !!r.error, r.error?.message ?? "no error");

  // ---- cleanup ----
  await admin.from("journey_events").delete().in("journey_id", f.journeys);
  await admin.from("sleep_journeys").delete().in("id", f.journeys);
  await admin.from("customers").delete().in("id", f.customers);
  await admin.from("employees").delete().in("id", f.employees);
  await admin.from("stores").delete().in("id", f.stores);
  await admin.from("companies").delete().in("id", f.companies);
  for (const u of f.users) await admin.auth.admin.deleteUser(u);
}

main()
  .catch((e) => {
    failures += 1;
    console.log(`FAIL run: ${e?.message ?? e}`);
  })
  .finally(async () => {
    // best-effort cleanup even on failure
    try {
      if (f.journeys.length) {
        await admin.from("journey_events").delete().in("journey_id", f.journeys);
        await admin.from("sleep_journeys").delete().in("id", f.journeys);
      }
      if (f.customers.length) await admin.from("customers").delete().in("id", f.customers);
      if (f.employees.length) await admin.from("employees").delete().in("id", f.employees);
      if (f.stores.length) await admin.from("stores").delete().in("id", f.stores);
      if (f.companies.length) await admin.from("companies").delete().in("id", f.companies);
      for (const u of f.users) await admin.auth.admin.deleteUser(u);
    } catch {}
    console.log(failures === 0 ? "\nAll tests passed." : `\n${failures} FAILURES`);
    process.exit(failures === 0 ? 0 : 1);
  });
