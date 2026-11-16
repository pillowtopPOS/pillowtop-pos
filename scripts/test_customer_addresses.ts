// Integration test for migration 145 (saved customer addresses and
// per-order ship-to). REQUIRES m145 installed in the target project.
// Creates its own fixtures, runs every check, deletes everything it made.
// Run: npx tsx scripts/test_customer_addresses.ts
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
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? `: ${detail}` : ""}`);
  if (!ok) failures += 1;
}

const tag = `ca${Date.now().toString(36)}`;
const PASS = "CaTest123!";

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
  // ---- fixtures ----
  const coA = (await admin.from("companies").insert({ name: `__${tag}a__`, business_timezone: "America/Denver" }).select("id").single()).data!.id;
  const coB = (await admin.from("companies").insert({ name: `__${tag}b__`, business_timezone: "America/Denver" }).select("id").single()).data!.id;
  f.companies.push(coA, coB);
  const stA = (await admin.from("stores").insert({ company_id: coA, name: `__${tag}_st__`, location_type: "STORE", is_active: true }).select("id").single()).data!.id;
  f.stores.push(stA);

  const emailMgr = `${tag}mgr@test.invalid`;
  const uidMgr = await mkUser(emailMgr);
  const empMgr = (await admin.from("employees").insert({ first_name: "Ca", last_name: "Mgr", role: "manager", home_store_id: stA, auth_user_id: uidMgr, is_active: true }).select("id").single()).data!.id;
  f.employees.push(empMgr);

  const custA = (await admin.from("customers").insert({
    company_id: coA, first_name: "Ada", last_name: "Voss",
    phone: "303-555-0101", email: `${tag}a@x.com`, street_address: "1 Primary Rd", city: "Denver", state: "CO", zip_code: "80201",
  }).select("id").single()).data!.id;
  const custA2 = (await admin.from("customers").insert({
    company_id: coA, first_name: "Ben", last_name: "Okafor",
    phone: "303-555-0102", email: `${tag}a2@x.com`,
  }).select("id").single()).data!.id;
  const custB = (await admin.from("customers").insert({
    company_id: coB, first_name: "Cross", last_name: "Company",
    phone: "303-555-0103", email: `${tag}b@x.com`,
  }).select("id").single()).data!.id;
  f.customers.push(custA, custA2, custB);

  const j1 = (await admin.from("sleep_journeys").insert({
    customer_id: custA, store_id: stA, current_state: "Active Opportunity",
    fulfillment_type: "delivery",
  }).select("id").single()).data!.id;
  const j2 = (await admin.from("sleep_journeys").insert({
    customer_id: custA, store_id: stA, current_state: "Active Opportunity",
    fulfillment_type: "delivery",
  }).select("id").single()).data!.id;
  f.journeys.push(j1, j2);

  const asMgr = await signIn(emailMgr);

  // ---- preflight: is m145 installed? ----
  const probe = await rpc(asMgr, "add_customer_address", {
    p_customer_id: custA, p_label: null, p_street_address: "__probe__",
    p_street_address_line_2: null, p_city: null, p_state: null, p_zip_code: null,
  });
  // probe creates a real row; delete it right away via admin
  if (probe.data?.id) {
    await admin.from("customer_addresses").delete().eq("id", probe.data.id);
  }
  if (probe.error) {
    console.log(`SKIP: migration 145 not installed (${probe.error.message})`);
    console.log("Install supabase/migrations/145_customer_addresses.sql first.");
    process.exit(2);
  }

  // ---- add + dedupe ----
  const add1 = await rpc(asMgr, "add_customer_address", {
    p_customer_id: custA, p_label: "Cabin", p_street_address: "9 Pine Trail",
    p_street_address_line_2: "Unit 2", p_city: "Idaho Springs", p_state: "CO", p_zip_code: "80452",
  });
  check("add address", !add1.error && !!add1.data?.id, add1.error?.message ?? "");
  const addrId = add1.data?.id as string;

  const addDup = await rpc(asMgr, "add_customer_address", {
    p_customer_id: custA, p_label: "Different label", p_street_address: " 9 pine trail ",
    p_street_address_line_2: null, p_city: null, p_state: null, p_zip_code: "80452",
  });
  check("dedupe on street+zip returns same row", !addDup.error && addDup.data?.id === addrId, `${addDup.data?.id} vs ${addrId}`);

  // ---- update ----
  const upd = await rpc(asMgr, "update_customer_address", {
    p_address_id: addrId,
    p_patch: { label: "Lake house", city: "Georgetown" },
  });
  check("update address", !upd.error && upd.data?.label === "Lake house" && upd.data?.city === "Georgetown", upd.error?.message ?? JSON.stringify(upd.data));

  // ---- get_customer carries addresses + counts ----
  const got = await rpc(asMgr, "get_customer", { p_id: custA });
  const gotAddr = (got.data?.addresses ?? []).find((a: any) => a.id === addrId);
  check("get_customer returns saved address", !!gotAddr && gotAddr.label === "Lake house", got.error?.message ?? "");
  check("get_customer primary_open_orders", typeof got.data?.primary_open_orders === "number", String(got.data?.primary_open_orders));

  // ---- set ship-to ----
  const set1 = await rpc(asMgr, "set_journey_ship_to", { p_journey_id: j1, p_address_id: addrId });
  check("set ship-to saved address", !set1.error && set1.data?.changed === true && set1.data?.ship_to_address_id === addrId, set1.error?.message ?? JSON.stringify(set1.data));
  const jRow = await admin.from("sleep_journeys").select("ship_to_address_id").eq("id", j1).single();
  check("journey row updated", jRow.data?.ship_to_address_id === addrId, String(jRow.data?.ship_to_address_id));

  // address of another customer is refused
  const addOther = await rpc(asMgr, "add_customer_address", {
    p_customer_id: custA2, p_label: null, p_street_address: "77 Other St",
    p_street_address_line_2: null, p_city: null, p_state: null, p_zip_code: "80014",
  });
  const otherAddrId = addOther.data?.id as string;
  const wrongCust = await rpc(asMgr, "set_journey_ship_to", { p_journey_id: j1, p_address_id: otherAddrId });
  check("ship-to refuses another customer's address", !!wrongCust.error, wrongCust.error?.message ?? "no error");

  // ---- PostgREST embed used by JOURNEY_DETAIL_SELECT ----
  const embed = await asMgr
    .from("sleep_journeys")
    .select("id, ship_to:customer_addresses!ship_to_address_id ( id, label, street_address )")
    .eq("id", j1)
    .single();
  const embedded = (embed.data as any)?.ship_to;
  check("ship_to embed resolves", !embed.error && embedded?.id === addrId && embedded?.label === "Lake house", embed.error?.message ?? JSON.stringify(embedded));

  // ---- archive blocked while an open order ships there ----
  const blocked = await rpc(asMgr, "archive_customer_address", { p_address_id: addrId });
  check("archive blocked by open order", !!blocked.error && /open order/.test(blocked.error?.message ?? ""), blocked.error?.message ?? "no error");

  // back to primary, then archive succeeds
  const reset = await rpc(asMgr, "set_journey_ship_to", { p_journey_id: j1, p_address_id: null });
  check("ship-to back to primary", !reset.error && reset.data?.ship_to_address_id === null, reset.error?.message ?? "");
  const arch = await rpc(asMgr, "archive_customer_address", { p_address_id: addrId });
  check("archive succeeds once clear", !arch.error && !!arch.data?.archived_at, arch.error?.message ?? "");

  // archived address can no longer be selected
  const reuse = await rpc(asMgr, "set_journey_ship_to", { p_journey_id: j1, p_address_id: addrId });
  check("archived address refused", !!reuse.error, reuse.error?.message ?? "no error");

  // ---- delivered refusal ----
  await admin.from("sleep_journeys").update({ delivered_at: new Date().toISOString() }).eq("id", j2);
  const delRefuse = await rpc(asMgr, "set_journey_ship_to", { p_journey_id: j2, p_address_id: otherAddrId });
  check("delivered order refuses ship-to", !!delRefuse.error && /delivered/i.test(delRefuse.error?.message ?? ""), delRefuse.error?.message ?? "no error");
  await admin.from("sleep_journeys").update({ delivered_at: null }).eq("id", j2);

  // ---- cross company ----
  const cross = await rpc(asMgr, "add_customer_address", {
    p_customer_id: custB, p_label: null, p_street_address: "1 Elsewhere Ave",
    p_street_address_line_2: null, p_city: null, p_state: null, p_zip_code: "99999",
  });
  check("cross-company customer refused", !!cross.error, cross.error?.message ?? "no error");
}

main()
  .catch((e) => {
    failures += 1;
    console.log(`FAIL run: ${e?.message ?? e}`);
  })
  .finally(async () => {
    try {
      if (f.companies.length) {
        await admin.from("journey_ship_to_log").delete().in("company_id", f.companies);
      }
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
