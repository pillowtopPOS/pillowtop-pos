import { createClient } from "@/lib/supabase/client";

export type POProduct = {
  id: string;
  sku: string;
  item_name: string;
  cost: number | null;
};

export type POLine = {
  id: string;
  variant_id: string;
  quantity_ordered: number;
  quantity_received: number;
  unit_cost: number;
};

export type POFulfillmentType = "stock" | "drop_ship";

export type POJourney = {
  id: string;
  customer: {
    id: string;
    first_name: string;
    last_name: string;
  } | null;
} | null;

export type PurchaseOrder = {
  id: string;
  reference_code: string | null;
  vendor_name: string;
  destination_location_id: string;
  fulfillment_type: POFulfillmentType;
  customer_journey_id: string | null;
  ship_street_address: string | null;
  ship_street_address_line_2: string | null;
  ship_city: string | null;
  ship_state: string | null;
  ship_zip_code: string | null;
  shipped_at: string | null;
  tracking_number: string | null;
  status: string;
  created_at: string;
  submitted_at: string | null;
  received_at: string | null;
  journey: POJourney;
  lines: POLine[];
};

export type POEvent = {
  id: string;
  event_type: string;
  event_data: Record<string, unknown>;
  created_at: string;
  actor: { id: string; name: string } | null;
};

// Line items are editable until the order is closed.
export const PO_EDITABLE_STATUSES = [
  "draft",
  "submitted",
  "partially_received",
];

const PO_SELECT = `*, purchase_order_line_items(*),
  journey:sleep_journeys!customer_journey_id (
    id,
    customer:customers!customer_id ( id, first_name, last_name )
  )`;

function mapPO(x: any): PurchaseOrder {
  return { ...x, lines: x.purchase_order_line_items ?? [] };
}

export async function fetchPurchaseOrders(): Promise<PurchaseOrder[]> {
  const supabase = createClient();
  const { data, error } = await (supabase as any)
    .from("purchase_orders")
    .select(PO_SELECT)
    .order("created_at", { ascending: false });
  if (error) {
    console.error("fetchPurchaseOrders error", error);
    return [];
  }
  return (data ?? []).map(mapPO);
}

export async function fetchPurchaseOrder(
  id: string,
): Promise<PurchaseOrder | null> {
  const supabase = createClient();
  const { data, error } = await (supabase as any)
    .from("purchase_orders")
    .select(PO_SELECT)
    .eq("id", id)
    .maybeSingle();
  if (error) {
    console.error("fetchPurchaseOrder error", error);
    return null;
  }
  return data ? mapPO(data) : null;
}

export async function fetchPOProducts(): Promise<POProduct[]> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("products_public")
    .select("id,sku,item_name,cost")
    .order("item_name");
  if (error) {
    console.error("fetchPOProducts error", error);
    return [];
  }
  return (data as POProduct[]) ?? [];
}

export async function fetchPOEvents(poId: string): Promise<POEvent[]> {
  const supabase = createClient();
  const { data, error } = await (supabase as any)
    .from("purchase_order_events")
    .select(
      "id, event_type, event_data, created_at, actor:employees!actor_id ( id, name )",
    )
    .eq("purchase_order_id", poId)
    .order("created_at", { ascending: true });
  if (error) {
    console.error("fetchPOEvents error", error);
    return [];
  }
  return (data as unknown as POEvent[]) ?? [];
}

// Sum of quantity_ordered * unit_cost across all lines.
export function poTotal(lines: POLine[]): number {
  return lines.reduce(
    (sum, l) => sum + l.quantity_ordered * Number(l.unit_cost ?? 0),
    0,
  );
}
