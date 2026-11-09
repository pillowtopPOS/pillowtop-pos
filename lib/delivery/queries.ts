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
  home_location_type: string | null;
  default_stop_cap: number;
  weekly_pattern: number[];
  sort_order: number;
};

export type ArchivedDeliveryTruck = DeliveryTruckInfo & {
  archived_at: string;
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
  archived_trucks?: ArchivedDeliveryTruck[];
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
    archived_trucks: cal?.archived_trucks ?? [],
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

/** Create a truck. Returns the new truck id. */
export async function createDeliveryTruck(input: {
  name: string;
  homeLocationId: string | null;
  defaultStopCap: number;
  weeklyPattern: number[];
}): Promise<string> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc("create_delivery_truck", {
    p_name: input.name,
    p_home_location_id: input.homeLocationId,
    p_default_stop_cap: input.defaultStopCap,
    p_weekly_pattern: input.weeklyPattern,
  });
  if (error) throw error;
  return data as string;
}

/** Rename / re-home / re-cap a truck. */
export async function updateDeliveryTruck(input: {
  truckId: string;
  name: string;
  homeLocationId: string | null;
  defaultStopCap: number;
}): Promise<void> {
  const supabase = createClient();
  const { error } = await (supabase as any).rpc("update_delivery_truck", {
    p_truck_id: input.truckId,
    p_name: input.name,
    p_home_location_id: input.homeLocationId,
    p_default_stop_cap: input.defaultStopCap,
  });
  if (error) throw error;
}

/** Archive (true) or restore (false) a truck. */
export async function setDeliveryTruckArchived(
  truckId: string,
  archived: boolean
): Promise<void> {
  const supabase = createClient();
  const { error } = await (supabase as any).rpc("set_delivery_truck_archived", {
    p_truck_id: truckId,
    p_archived: archived,
  });
  if (error) throw error;
}

/** Replace a truck's weekly pattern (ISO weekdays 1=Mon..7=Sun). */
export async function setTruckWeekdayPattern(
  truckId: string,
  weekdays: number[]
): Promise<void> {
  const supabase = createClient();
  const { error } = await (supabase as any).rpc("set_truck_weekday_pattern", {
    p_truck_id: truckId,
    p_weekdays: weekdays,
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
