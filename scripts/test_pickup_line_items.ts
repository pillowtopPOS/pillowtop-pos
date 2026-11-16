// Regression test for the pickup_location_id bug: the m032 trigger
// rejects a line whose pickup_location_id is set while its own
// fulfillment_type_override is null (inherit). The client now pins the
// line to 'pickup' when a location is chosen on an inherited line.
// Verifies the shapes the client sends, live against the DB.
// Run: npx tsx scripts/test_pickup_line_items.ts
import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";

for (const line of readFileSync(".env.local", "utf8").split("\n")) {
  const m = line.match(/^([A-Z_]+)=(.*)$/);
  if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
}
const admin = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, {
  auth: { persistSession: false },
});

let failures = 0;
function check(name: string, ok: boolean, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? `: ${detail}` : ""}`);
  if (!ok) failures += 1;
}

const tag = `pi${Date.now().toString(36)}`;
const f = { companies: [] as string[], stores: [] as string[], customers: [] as string[], journeys: [] as string[] };

async function main() {
  const co = (await admin.from("companies").insert({ name: `__${tag}__`, business_timezone: "America/Denver" }).select("id").single()).data!.id;
  f.companies.push(co);
  const st = (await admin.from("stores").insert({ company_id: co, name: `__${tag}_st__`, location_type: "STORE", is_active: true }).select("id").single()).data!.id;
  const wh = (await admin.from("stores").insert({ company_id: co, name: `__${tag}_wh__`, location_type: "WAREHOUSE", is_active: true }).select("id").single()).data!.id;
  f.stores.push(st, wh);
  const cu = (await admin.from("customers").insert({
    company_id: co, first_name: "P", last_name: "T", phone: "3035550100",
    email: `${tag}@x.com`, street_address: "1 Main", city: "D", state: "CO", zip_code: "80201",
  }).select("id").single()).data!.id;
  f.customers.push(cu);

  const mkJourney = async (fulfillment: "pickup" | "delivery") => {
    const j = await admin.from("sleep_journeys").insert({
      customer_id: cu, store_id: st, current_state: "Active Opportunity", fulfillment_type: fulfillment,
    }).select("id").single();
    f.journeys.push(j.data!.id);
    return j.data!.id;
  };
  const addLine = (journeyId: string, row: object) =>
    admin.from("journey_line_items").insert({
      journey_id: journeyId, item_name: "T112", quantity: 1, unit_price: 1, ...row,
    }).select("id").single();

  // The DB rule itself is unchanged: inherit + location is still refused.
  const jPick = await mkJourney("pickup");
  const inheritBad = await addLine(jPick, { fulfillment_type_override: null, pickup_location_id: wh });
  check("inherit + location still refused by DB", !!inheritBad.error && /only valid for pickup/.test(inheritBad.error.message), inheritBad.error?.message ?? "no error");

  // What the client now sends: picking a location pins the line.
  const pinned = await addLine(jPick, { fulfillment_type_override: "pickup", pickup_location_id: wh });
  check("pickup order, pinned line at warehouse", !pinned.error && !!pinned.data?.id, pinned.error?.message ?? "");

  const pinnedStore = await addLine(jPick, { fulfillment_type_override: "pickup", pickup_location_id: st });
  check("pickup order, pinned line at store", !pinnedStore.error && !!pinnedStore.data?.id, pinnedStore.error?.message ?? "");

  // Delivery order with one explicit pickup line at the warehouse.
  const jDel = await mkJourney("delivery");
  const mixed = await addLine(jDel, { fulfillment_type_override: "pickup", pickup_location_id: wh });
  check("delivery order, pickup line at warehouse", !mixed.error && !!mixed.data?.id, mixed.error?.message ?? "");

  // Plain inherit lines carry no location and stay valid.
  const plain = await addLine(jPick, { fulfillment_type_override: null, pickup_location_id: null });
  check("inherit line without location", !plain.error && !!plain.data?.id, plain.error?.message ?? "");
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
      if (f.stores.length) await admin.from("stores").delete().in("id", f.stores);
      if (f.companies.length) await admin.from("companies").delete().in("id", f.companies);
    } catch {}
    console.log(failures === 0 ? "\nAll tests passed." : `\n${failures} FAILURES`);
    process.exit(failures === 0 ? 0 : 1);
  });
