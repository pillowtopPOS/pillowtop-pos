// Regression test for line fulfillment payloads (m032 contract).
// Unit-checks lineItemFulfillmentPayload for the Pickup -> Delivery
// stale-location bug, then inserts every generated payload shape into
// the live test DB to prove the trigger accepts them.
// Run: npx tsx scripts/test_line_fulfillment_payload.ts
import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
import { lineItemFulfillmentPayload } from "../lib/journeys/fulfillment";

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

const tag = `lf${Date.now().toString(36)}`;
const f = { companies: [] as string[], stores: [] as string[], customers: [] as string[], journeys: [] as string[] };

async function main() {
  // ---- payload unit cases ----
  // Pickup order, inherited line with a chosen location, order flips to
  // Delivery: effective is Delivery, so no override and no location.
  const flipped = lineItemFulfillmentPayload({
    explicitChoice: null,
    pickupLocationId: "loc-1",
    orderFulfillment: "delivery",
  });
  check("pickup->delivery inherited line sends no location",
    flipped.fulfillmentTypeOverride === null && flipped.pickupLocationId === null,
    JSON.stringify(flipped));

  // Delivery order, explicit Pickup line at the warehouse keeps both.
  const mixed = lineItemFulfillmentPayload({
    explicitChoice: "pickup",
    pickupLocationId: "wh-1",
    orderFulfillment: "delivery",
  });
  check("delivery order explicit pickup keeps override+location",
    mixed.fulfillmentTypeOverride === "pickup" && mixed.pickupLocationId === "wh-1",
    JSON.stringify(mixed));

  // Pickup order, inherited line, warehouse chosen: location forces the
  // explicit 'pickup' override m032 requires.
  const inheritedLoc = lineItemFulfillmentPayload({
    explicitChoice: null,
    pickupLocationId: "wh-1",
    orderFulfillment: "pickup",
  });
  check("inherited pickup line with location pins override",
    inheritedLoc.fulfillmentTypeOverride === "pickup" && inheritedLoc.pickupLocationId === "wh-1",
    JSON.stringify(inheritedLoc));

  // Plain pickup, no location: stays inherit (null), no location.
  const plain = lineItemFulfillmentPayload({
    explicitChoice: null,
    pickupLocationId: null,
    orderFulfillment: "pickup",
  });
  check("plain pickup stays inherit",
    plain.fulfillmentTypeOverride === null && plain.pickupLocationId === null,
    JSON.stringify(plain));

  // Explicit delivery line on a pickup order.
  const delLine = lineItemFulfillmentPayload({
    explicitChoice: "delivery",
    pickupLocationId: "loc-1",
    orderFulfillment: "pickup",
  });
  check("explicit delivery drops location",
    delLine.fulfillmentTypeOverride === "delivery" && delLine.pickupLocationId === null,
    JSON.stringify(delLine));

  // ---- live DB: every payload shape inserts cleanly ----
  const co = (await admin.from("companies").insert({ name: `__${tag}__`, business_timezone: "America/Denver" }).select("id").single()).data!.id;
  f.companies.push(co);
  const st = (await admin.from("stores").insert({ company_id: co, name: `__${tag}_st__`, location_type: "STORE", is_active: true }).select("id").single()).data!.id;
  const wh = (await admin.from("stores").insert({ company_id: co, name: `__${tag}_wh__`, location_type: "WAREHOUSE", is_active: true }).select("id").single()).data!.id;
  f.stores.push(st, wh);
  const cu = (await admin.from("customers").insert({
    company_id: co, first_name: "L", last_name: "F", phone: "3035550100",
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

  // The exact bug shape: order was pickup with a location chosen, then
  // flipped to delivery. Payload must produce a valid delivery line.
  const jFlip = await mkJourney("delivery");
  const flipPayload = lineItemFulfillmentPayload({
    explicitChoice: null, pickupLocationId: wh, orderFulfillment: "delivery",
  });
  const flipLine = await addLine(jFlip, {
    fulfillment_type_override: flipPayload.fulfillmentTypeOverride,
    pickup_location_id: flipPayload.pickupLocationId,
  });
  check("flipped order line inserts (no location)", !flipLine.error && !!flipLine.data?.id, flipLine.error?.message ?? "");

  // Mixed: delivery order, explicit pickup line at the warehouse.
  const jMix = await mkJourney("delivery");
  const mixPayload = lineItemFulfillmentPayload({
    explicitChoice: "pickup", pickupLocationId: wh, orderFulfillment: "delivery",
  });
  const mixLine = await addLine(jMix, {
    fulfillment_type_override: mixPayload.fulfillmentTypeOverride,
    pickup_location_id: mixPayload.pickupLocationId,
  });
  check("mixed order pickup line at warehouse", !mixLine.error && !!mixLine.data?.id, mixLine.error?.message ?? "");

  // Pickup order, inherited line with warehouse location chosen.
  const jPick = await mkJourney("pickup");
  const inhPayload = lineItemFulfillmentPayload({
    explicitChoice: null, pickupLocationId: wh, orderFulfillment: "pickup",
  });
  const inhLine = await addLine(jPick, {
    fulfillment_type_override: inhPayload.fulfillmentTypeOverride,
    pickup_location_id: inhPayload.pickupLocationId,
  });
  check("pickup order inherited+location at warehouse", !inhLine.error && !!inhLine.data?.id, inhLine.error?.message ?? "");

  // Pickup order, plain inherited line, no location.
  const plainPayload = lineItemFulfillmentPayload({
    explicitChoice: null, pickupLocationId: null, orderFulfillment: "pickup",
  });
  const plainLine = await addLine(jPick, {
    fulfillment_type_override: plainPayload.fulfillmentTypeOverride,
    pickup_location_id: plainPayload.pickupLocationId,
  });
  check("pickup order plain inherit line", !plainLine.error && !!plainLine.data?.id, plainLine.error?.message ?? "");

  // Explicit delivery line on a pickup order drops any location.
  const delPayload = lineItemFulfillmentPayload({
    explicitChoice: "delivery", pickupLocationId: st, orderFulfillment: "pickup",
  });
  const delLineRow = await addLine(jPick, {
    fulfillment_type_override: delPayload.fulfillmentTypeOverride,
    pickup_location_id: delPayload.pickupLocationId,
  });
  check("pickup order explicit delivery line", !delLineRow.error && !!delLineRow.data?.id, delLineRow.error?.message ?? "");
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
