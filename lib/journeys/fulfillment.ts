import type { Store } from "@/lib/journeys/queries";

type FulfillmentLineItem = {
  fulfillment_type_override?: "delivery" | "pickup" | null;
  pickup_location_id?: string | null;
};

type FulfillmentJourney = {
  store_id: string;
  fulfillment_type: "delivery" | "pickup";
};

export function resolveLineItemLocation(
  item: FulfillmentLineItem,
  journey: FulfillmentJourney,
  stores: Pick<Store, "id" | "assigned_warehouse_id">[]
): string {
  const effectiveType = item.fulfillment_type_override ?? journey.fulfillment_type;
  if (effectiveType === "pickup") {
    return item.pickup_location_id ?? journey.store_id;
  }

  const journeyStore = stores.find((store) => store.id === journey.store_id);
  return journeyStore?.assigned_warehouse_id ?? journey.store_id;
}

// The line's own dropdown choice: null means the line follows the order.
// Picking a pickup LOCATION alone does not count as an explicit choice.
export type LineFulfillmentChoice = "delivery" | "pickup" | null;

export function effectiveLineFulfillment(
  choice: LineFulfillmentChoice,
  orderFulfillment: "delivery" | "pickup"
): "delivery" | "pickup" {
  return choice ?? orderFulfillment;
}

// DB payload for one line. m032 allows pickup_location_id only when the
// line's own fulfillment_type_override is 'pickup', so a chosen location
// on an otherwise-inherited pickup line is sent with an explicit 'pickup'
// override. When the effective fulfillment matches the order's, the
// override is stored null (inherit) and no location is sent.
export function lineItemFulfillmentPayload(opts: {
  explicitChoice: LineFulfillmentChoice;
  pickupLocationId?: string | null;
  orderFulfillment: "delivery" | "pickup";
}): {
  fulfillmentTypeOverride: "delivery" | "pickup" | null;
  pickupLocationId: string | null;
} {
  const effective = effectiveLineFulfillment(
    opts.explicitChoice,
    opts.orderFulfillment
  );
  if (effective === "delivery") {
    return {
      fulfillmentTypeOverride:
        effective === opts.orderFulfillment ? null : "delivery",
      pickupLocationId: null,
    };
  }
  const location = opts.pickupLocationId ?? null;
  if (location) {
    return { fulfillmentTypeOverride: "pickup", pickupLocationId: location };
  }
  return {
    fulfillmentTypeOverride:
      effective === opts.orderFulfillment ? null : "pickup",
    pickupLocationId: null,
  };
}
