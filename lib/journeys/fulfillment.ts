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
