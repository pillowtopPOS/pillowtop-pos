import { createClient } from "@/lib/supabase/client";

// ============================================================
// Pickup promise dates (migrations 170-171). Thin wrappers over
// get_pickup_dates and set_pickup_date - components never call the
// RPCs directly. All "overdue" and "ready" math lives server-side;
// this file only types and fetches.
// ============================================================

export type PickupDateInfo = {
  journey_id: string;
  expected_date: string | null;
  effective_date: string | null;
  is_default: boolean;
  units_remaining: number;
  store_id: string;
};

export type SetPickupDateResult = {
  expected_pickup_date: string;
  previous_effective_date: string | null;
  changed: boolean;
};

/** Pickup date info for a batch of journeys, keyed by journey id.
 *  Invisible ids are skipped server-side. */
export async function fetchPickupDates(
  journeyIds: string[]
): Promise<Record<string, PickupDateInfo>> {
  if (journeyIds.length === 0) return {};
  const supabase = createClient();
  const { data, error } = await supabase.rpc("get_pickup_dates", {
    p_journey_ids: journeyIds,
  });
  if (error) throw new Error(error.message);
  const map: Record<string, PickupDateInfo> = {};
  for (const row of (data as PickupDateInfo[] | null) ?? []) {
    map[row.journey_id] = row;
  }
  return map;
}

/** Set or move a journey's expected pickup date. dateISO is 'YYYY-MM-DD'.
 *  The server requires a reason only when the date moves later than the
 *  date currently in effect; pass it through when the caller collected
 *  one. The database's plain-English errors are thrown as-is. */
export async function setPickupDate(
  journeyId: string,
  dateISO: string,
  reason?: string | null
): Promise<SetPickupDateResult> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("set_pickup_date", {
    p_journey_id: journeyId,
    p_date: dateISO,
    p_reason: reason ?? null,
  });
  if (error) throw new Error(error.message);
  return data as SetPickupDateResult;
}
