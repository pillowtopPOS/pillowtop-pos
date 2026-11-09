import { createClient } from "@/lib/supabase/client";
import { fetchCurrentEmployee } from "@/lib/journeys/queries";

export type DeliveryTruckDay = {
  truck_id: string;
  name: string;
  home_location_id: string | null;
  home_location_name: string | null;
  home_location_type: string | null;
  on: boolean;
  source: "pattern" | "exception" | string;
  stop_cap: number;
};

export type DeliveryCalendarDay = {
  date: string;
  extra_slots: number;
  capacity: number;
  booked_count: number;
  trucks: DeliveryTruckDay[];
};

export type DeliveryTruckInfo = {
  id: string;
  name: string;
  home_location_id: string | null;
  home_location_name: string | null;
  default_stop_cap: number;
  weekly_pattern: number[];
  sort_order: number;
};

export type DeliverySettings = {
  delivery_limit_type: "stops" | "time" | "both" | string;
  delivery_window_hours: number;
  delivery_day_mode: "window" | "day_only" | string;
  delivery_day_start: string;
  delivery_day_end: string;
};

export type DeliveryCalendar = {
  settings: DeliverySettings | null;
  trucks: DeliveryTruckInfo[];
  days: DeliveryCalendarDay[];
};

/** One call returns settings, the truck list, and every day in the range. */
export async function fetchDeliveryCalendar(
  startDate: string,
  endDate: string
): Promise<DeliveryCalendar> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc("get_delivery_calendar", {
    p_start_date: startDate,
    p_end_date: endDate,
  });
  if (error) throw error;
  const cal = data as DeliveryCalendar | null;
  return {
    settings: cal?.settings ?? null,
    trucks: cal?.trucks ?? [],
    days: cal?.days ?? [],
  };
}

/** The caller's business "today" in their home store's timezone
 *  (stores.timezone -> companies.business_timezone), same source the
 *  rest of the app uses. Returns null when unavailable — callers fall
 *  back to the browser date. */
export async function fetchDeliveryBusinessToday(): Promise<string | null> {
  const employee = await fetchCurrentEmployee();
  if (!employee?.home_store_id) return null;
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc("business_today", {
    p_store_id: employee.home_store_id,
  });
  if (error) return null;
  return (data as string | null) ?? null;
}

/** Turn a truck on/off for one date, or clear back to the weekly pattern
 *  (pOn = null). The RPC enforces delivery.manage_trucks and company
 *  scope; errors are thrown for the caller to translate. */
export async function setTruckDateState(
  truckId: string,
  date: string,
  pOn: boolean | null
): Promise<void> {
  const supabase = createClient();
  const { error } = await (supabase as any).rpc("set_truck_date_state", {
    p_truck_id: truckId,
    p_date: date,
    p_on: pOn,
  });
  if (error) throw error;
}

/** Set the absolute extra-slots value for one date (0 removes the row).
 *  The RPC enforces delivery.manage_calendar; errors are thrown. */
export async function setDayExtraSlots(
  date: string,
  extraSlots: number
): Promise<void> {
  const supabase = createClient();
  const { error } = await (supabase as any).rpc("set_day_extra_slots", {
    p_date: date,
    p_extra_slots: extraSlots,
  });
  if (error) throw error;
}

/** Whether the signed-in employee may manage trucks / the calendar.
 *  False on error — the UI simply hides editing affordances. */
export async function fetchDeliveryManageTrucks(): Promise<boolean> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("has_permission", {
    p_key: "delivery.manage_trucks",
  });
  if (error) return false;
  return data === true;
}

/** Whether the signed-in employee may adjust per-day extra slots. */
export async function fetchDeliveryManageCalendar(): Promise<boolean> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("has_permission", {
    p_key: "delivery.manage_calendar",
  });
  if (error) return false;
  return data === true;
}
