// Integration test for migration 143 (Customers module RPCs).
// REQUIRES migration 143 to be installed in the target Supabase project.
// Creates its own fixtures (company, store, manager + sales users,
// customers incl. a company customer, journeys), runs every check, then
// deletes everything it created.
// Run: npx tsx scripts/test_customers_module.ts
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

const tag = `cm${Date.now().toString(36)}`;
const PASS = "CmTest123!";

const f = {
  companies: [] as string[],
  stores: [] as string[],
  customers: [] as string[],
  journeys: [] as string[],
  interactions: [] as string[],
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

async function search(client: SupabaseClient, q: string) {
  const r = await rpc(client, "search_customers", {
    p_query: q,
    p_limit: 25,
    p_offset: 0,
  });
  return r as { data: any; error: any };
}

function itemsOf(r: { data: any }): any[] {
  return (r.data?.items ?? []) as any[];
}

async function main() {
  // ---- fixtures first (needed for the preflight probe) ----
  const co = (await admin.from("companies").insert({ name: `__${tag}__`, business_timezone: "America/Denver" }).select("id").single()).data!.id;
  f.companies.push(co);
  const st = (await admin.from("stores").insert({ company_id: co, name: `__${tag}_st__`, location_type: "STORE", is_active: true }).select("id").single()).data!.id;
  f.stores.push(st);

  const emailMgr = `${tag}mgr@test.invalid`;
  const emailSales = `${tag}sales@test.invalid`;
  const uidMgr = await mkUser(emailMgr);
  const uidSales = await mkUser(emailSales);
  const empMgr = (await admin.from("employees").insert({ first_name: "Cm", last_name: "Mgr", role: "manager", home_store_id: st, auth_user_id: uidMgr, is_active: true }).select("id").single()).data!.id;
  const empSales = (await admin.from("employees").insert({ first_name: "Cm", last_name: "Sales", role: "sales", home_store_id: st, auth_user_id: uidSales, is_active: true }).select("id").single()).data!.id;
  f.employees.push(empMgr, empSales);

  const custInsert = (row: object) =>
    admin.from("customers").insert(row).select("id").single();

  // A: person with a unique name + dashed phone; B: merge source with 2 orders;
  // C: company customer; D: sales-merge attempt target (kept).
  const cA = (await custInsert({ company_id: co, first_name: "Zara", last_name: "Quinn", phone: "(303) 555-0142", email: `${tag}a@x.com`, city: "Denver", state: "CO", customer_since: "2020-01-15" })).data!.id;
  const cB = (await custInsert({ company_id: co, first_name: "Ben", last_name: "Wren", phone: "303-555-0177", email: `${tag}b@x.com` })).data!.id;
  const cC = (await custInsert({ company_id: co, is_company: true, company_name: `Acme ${tag}`, first_name: `Acme ${tag}`, last_name: "", phone: "303-555-0188", email: `${tag}c@x.com` })).data!.id;
  const cD = (await custInsert({ company_id: co, first_name: "Dee", last_name: "Lot", phone: "303-555-0199", email: `${tag}d@x.com` })).data!.id;
  f.customers.push(cA, cB, cC, cD);

  for (let i = 0; i < 2; i++) {
    const j = await admin.from("sleep_journeys").insert({
      customer_id: cB, store_id: st, current_state: "Active Opportunity",
      fulfillment_type: "pickup",
    }).select("id").single();
    f.journeys.push(j.data!.id);
  }

  const asMgr = await signIn(emailMgr);
  const asSales = await signIn(emailSales);

  // ---- preflight: is m143 installed? ----
  const probe = await search(asMgr, tag);
  if (probe.error) {
    console.log(`SKIP: migration 143 not installed (${probe.error.message})`);
    console.log("Install supabase/migrations/143_customers_module.sql first.");
    process.exit(2);
  }

  // ---- search_customers ----
  let r = await search(asMgr, "Zara");
  check("search by name", !r.error && itemsOf(r).some((x) => x.id === cA), r.error?.message ?? "");

  r = await search(asMgr, "3035550142");
  check("search phone across formats", !r.error && itemsOf(r).some((x) => x.id === cA), r.error?.message ?? "");

  r = await search(asMgr, `Acme ${tag}`);
  const companyHit = itemsOf(r).find((x) => x.id === cC);
  check("search company name", !!companyHit && companyHit.is_company === true, JSON.stringify(companyHit?.is_company));

  r = await search(asMgr, "%");
  check("literal % does not error or match everything", !r.error && !itemsOf(r).some((x) => x.id === cA), r.error?.message ?? `total=${r.data?.total}`);

  // ---- update_customer: company on and off ----
  r = await rpc(asMgr, "update_customer", {
    p_id: cA,
    p_patch: { is_company: true, company_name: `Zara Holdings ${tag}` },
  });
  const asCompany = r.data;
  check("update to company", !r.error && asCompany?.is_company === true && asCompany?.company_name === `Zara Holdings ${tag}`, r.error?.message ?? JSON.stringify(asCompany?.company_name));
  check("company name mirrored to first_name", asCompany?.first_name === `Zara Holdings ${tag}` && asCompany?.last_name === "", `${asCompany?.first_name} / ${asCompany?.last_name}`);

  r = await rpc(asMgr, "update_customer", {
    p_id: cA,
    p_patch: { is_company: false, first_name: "Zara", last_name: "Quinn" },
  });
  const asPerson = r.data;
  check("update back to person", !r.error && asPerson?.is_company === false && asPerson?.first_name === "Zara" && asPerson?.last_name === "Quinn", r.error?.message ?? "");

  // unticking a company without a last name is refused
  await rpc(asMgr, "update_customer", { p_id: cA, p_patch: { is_company: true, company_name: `Tmp ${tag}` } });
  const badOff = await rpc(asMgr, "update_customer", { p_id: cA, p_patch: { is_company: false, first_name: "Zara" } });
  check("untick company requires last name", !!badOff.error, badOff.error?.message ?? "no error");
  // restore person state for later checks
  await rpc(asMgr, "update_customer", { p_id: cA, p_patch: { is_company: false, first_name: "Zara", last_name: "Quinn" } });

  // ---- merge_customers ----
  // sales role is refused
  const salesMerge = await rpc(asSales, "merge_customers", { p_keep: cA, p_remove: cD });
  check("sales merge refused", !!salesMerge.error, salesMerge.error?.message ?? "no error");
  const dStill = await admin.from("customers").select("id").eq("id", cD).maybeSingle();
  check("refused merge left customer", !!dStill.data, "");

  // manager merge: B's 2 orders move to A, B is deleted
  const beforeA = (await admin.from("sleep_journeys").select("id").eq("customer_id", cA)).data!.length;
  const mgrMerge = await rpc(asMgr, "merge_customers", { p_keep: cA, p_remove: cB });
  check("manager merge succeeds", !mgrMerge.error, mgrMerge.error?.message ?? "");
  check("merge reports moved journeys", mgrMerge.data?.moved_journeys === 2, String(mgrMerge.data?.moved_journeys));
  const afterA = (await admin.from("sleep_journeys").select("id").eq("customer_id", cA)).data!.length;
  check("orders moved to kept customer", afterA === beforeA + 2, `${beforeA} -> ${afterA}`);
  const bGone = await admin.from("customers").select("id").eq("id", cB).maybeSingle();
  check("removed customer deleted", !bGone.data, "");
  const logRow = await admin.from("customer_merge_log").select("id, moved_journeys").eq("removed_customer_id", cB).maybeSingle();
  check("merge logged", !!logRow.data && logRow.data.moved_journeys === 2, "");

  // get_customer returns the merged order list
  const got = await rpc(asMgr, "get_customer", { p_id: cA });
  check("get_customer journey_count", got.data?.journey_count === afterA, String(got.data?.journey_count));

  // ---- customer_contacts ----
  // cA has orders after the merge so contact RLS allows writes; cD has
  // no orders, so is_customer_visible is false and the insert must fail.
  const cInsert = await asMgr
    .from("customer_contacts")
    .insert({
      customer_id: cA,
      name: `Pat ${tag}`,
      role_label: "Office manager",
      phone: "303-555-0166",
      email: `${tag}pat@x.com`,
    })
    .select("id, name")
    .single();
  check("contact add on customer with order", !cInsert.error && !!cInsert.data?.id, cInsert.error?.message ?? "");
  const contactId = cInsert.data?.id as string;

  const cUpdate = await asMgr
    .from("customer_contacts")
    .update({ role_label: "Billing", phone: "303-555-0170" })
    .eq("id", contactId)
    .select("id, role_label, phone")
    .single();
  check("contact update", !cUpdate.error && cUpdate.data?.role_label === "Billing" && cUpdate.data?.phone === "303-555-0170", cUpdate.error?.message ?? JSON.stringify(cUpdate.data));

  const noOrder = await asMgr
    .from("customer_contacts")
    .insert({ customer_id: cD, name: `Nope ${tag}` });
  check("contact refused for customer with no orders", !!noOrder.error, noOrder.error?.message ?? "no error");

  // journey_interactions.contact_id is ON DELETE SET NULL (m056): the
  // activity row survives a contact delete with contact_id nulled.
  const inter = await admin
    .from("journey_interactions")
    .insert({
      journey_id: f.journeys[0],
      customer_id: cA,
      interaction_type: "internal_note",
      channel: "internal",
      direction: "internal",
      summary: `contact fk ${tag}`,
      contact_id: contactId,
      contact_name_snapshot: `Pat ${tag}`,
      occurred_at: new Date().toISOString(),
    })
    .select("id")
    .single();
  check("interaction linked to contact", !inter.error && !!inter.data?.id, inter.error?.message ?? "");
  if (inter.data?.id) f.interactions.push(inter.data.id);

  const cDelete = await asMgr.from("customer_contacts").delete().eq("id", contactId);
  check("contact delete succeeds", !cDelete.error, cDelete.error?.message ?? "");
  const interAfter = await admin
    .from("journey_interactions")
    .select("contact_id, contact_name_snapshot")
    .eq("id", f.interactions[0])
    .single();
  check(
    "activity row kept with contact_id nulled",
    interAfter.data?.contact_id === null && interAfter.data?.contact_name_snapshot === `Pat ${tag}`,
    JSON.stringify(interAfter.data)
  );
}

main()
  .catch((e) => {
    failures += 1;
    console.log(`FAIL run: ${e?.message ?? e}`);
  })
  .finally(async () => {
    try {
      if (f.interactions.length) {
        await admin.from("journey_interactions").delete().in("id", f.interactions);
      }
      if (f.journeys.length) {
        await admin.from("journey_events").delete().in("journey_id", f.journeys);
        await admin.from("sleep_journeys").delete().in("id", f.journeys);
      }
      if (f.customers.length) await admin.from("customers").delete().in("id", f.customers);
      if (f.companies.length) {
        await admin.from("customer_merge_log").delete().in("company_id", f.companies);
      }
      if (f.employees.length) await admin.from("employees").delete().in("id", f.employees);
      if (f.stores.length) await admin.from("stores").delete().in("id", f.stores);
      if (f.companies.length) await admin.from("companies").delete().in("id", f.companies);
      for (const u of f.users) await admin.auth.admin.deleteUser(u);
    } catch {}
    console.log(failures === 0 ? "\nAll tests passed." : `\n${failures} FAILURES`);
    process.exit(failures === 0 ? 0 : 1);
  });
