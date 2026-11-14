import { createClient } from "@/lib/supabase/client";
import { fetchCurrentEmployee } from "@/lib/journeys/queries";
import { localTodayISO } from "@/lib/dates";

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

/** Company's week-start day: 1 = Monday, 7 = Sunday (ISO).
 *  Returns null when the RPC is missing (pre-migration 128) so callers
 *  can hide the control; the Delivery page falls back to Monday. */
export async function fetchCompanyWeekStart(): Promise<number | null> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "get_company_week_start"
  );
  if (error) return null;
  return data === 7 ? 7 : 1;
}

/** Set the company's week-start day (1 = Monday, 7 = Sunday). */
export async function setCompanyWeekStart(day: number): Promise<void> {
  const supabase = createClient();
  const { error } = await (supabase as any).rpc("set_company_week_start", {
    p_day: day,
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

/** Whether the signed-in employee may book inside the cutoff window. */
export async function fetchDeliveryBookInsideCutoff(): Promise<boolean> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("has_permission", {
    p_key: "delivery.book_inside_cutoff",
  });
  if (error) return false;
  return data === true;
}

/** Whether the signed-in employee may set arrival windows on the day
 *  plan (delivery.set_windows). OR-ed with manage_calendar by callers. */
export async function fetchDeliverySetWindows(): Promise<boolean> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("has_permission", {
    p_key: "delivery.set_windows",
  });
  if (error) return false;
  return data === true;
}

/** Company delivery-day settings (day hours, window length, day mode).
 *  Read through get_delivery_calendar, which already returns them; the
 *  range is irrelevant so a single day is enough. Null on error so the
 *  UI can hide the section instead of breaking. */
export async function fetchDeliveryDaySettings(): Promise<DeliverySettings | null> {
  try {
    const cal = await fetchDeliveryCalendar(localTodayISO(), localTodayISO());
    return cal.settings;
  } catch {
    return null;
  }
}

/** Save company delivery-day settings. Owner/admin only (the RPC
 *  enforces it); the plain error message is thrown for inline display. */
export async function setDeliveryDaySettings(input: {
  dayStart: string; // "HH:MM"
  dayEnd: string;
  windowHours: number;
  dayMode: "window" | "day_only";
}): Promise<void> {
  const supabase = createClient();
  const { error } = await (supabase as any).rpc("set_delivery_day_settings", {
    p_day_start: input.dayStart,
    p_day_end: input.dayEnd,
    p_window_hours: input.windowHours,
    p_day_mode: input.dayMode,
  });
  if (error) throw new Error(error.message);
}

export type DeliveryStopWindowInput = {
  stop_id: string;
  window_start: string | null; // "HH:MM" or null to clear
  window_end: string | null;
};

/** Write arrival windows for stops on one day. Works on OPEN and CLOSED
 *  days; never touches the route plan version. Returns stops changed. */
export async function setDeliveryStopWindows(
  date: string,
  items: DeliveryStopWindowInput[]
): Promise<number> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "set_delivery_stop_windows",
    { p_date: date, p_items: items }
  );
  if (error) throw new Error(error.message);
  return (data as number) ?? 0;
}

// ---------------------------------------------------------------------------
// D1-b: delivery stops (booking, rescheduling, cancelling)
// ---------------------------------------------------------------------------

export type JourneyDeliveryStop = {
  id: string;
  delivery_date: string;
  inside_cutoff: boolean;
  override_reason: string | null;
  booked_by_name: string | null;
  booked_at: string;
};

export type JourneyDeliveryEvent = {
  action: "BOOKED" | "RESCHEDULED" | "CANCELLED" | "COMPLETED" | string;
  from_date: string | null;
  to_date: string | null;
  reason: string | null;
  override: boolean;
  actor_name: string | null;
  created_at: string;
};

export type EarliestBookable = {
  earliest_date: string;
  cutoff_time: string | null;
  timezone: string;
  today_local: string;
};

export type JourneyDelivery = {
  active_stop: JourneyDeliveryStop | null;
  history: JourneyDeliveryEvent[];
  earliest: EarliestBookable;
};

/** Active stop + history + earliest bookable day for one order. */
export async function fetchJourneyDelivery(
  journeyId: string
): Promise<JourneyDelivery> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "get_journey_delivery",
    { p_journey_id: journeyId }
  );
  if (error) throw error;
  const d = data as JourneyDelivery | null;
  return {
    active_stop: d?.active_stop ?? null,
    history: d?.history ?? [],
    earliest: d?.earliest ?? {
      earliest_date: "",
      cutoff_time: null,
      timezone: "",
      today_local: "",
    },
  };
}

/** Book a delivery day for an order. Returns the new stop id. */
export async function bookDeliveryStop(
  journeyId: string,
  date: string,
  overrideReason?: string
): Promise<string> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "book_delivery_stop",
    {
      p_journey_id: journeyId,
      p_date: date,
      p_override_reason: overrideReason ?? null,
    }
  );
  if (error) throw error;
  return data as string;
}

/** Move an active stop to a new day. Returns the new stop id. */
export async function rescheduleDeliveryStop(
  stopId: string,
  date: string,
  overrideReason?: string
): Promise<string> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "reschedule_delivery_stop",
    {
      p_stop_id: stopId,
      p_new_date: date,
      p_override_reason: overrideReason ?? null,
    }
  );
  if (error) throw error;
  return data as string;
}

/** Cancel an active stop. The order returns to Ready to Schedule. */
export async function cancelDeliveryStop(
  stopId: string,
  reason: string
): Promise<void> {
  const supabase = createClient();
  const { error } = await (supabase as any).rpc(
    "cancel_delivery_stop",
    { p_stop_id: stopId, p_reason: reason }
  );
  if (error) throw error;
}

/** Company cutoff setting + whether the caller may edit it. */
export async function fetchDeliveryCutoff(): Promise<{
  cutoff_time: string | null;
  can_edit: boolean;
} | null> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "get_delivery_cutoff"
  );
  if (error || !data) return null;
  return data as { cutoff_time: string | null; can_edit: boolean };
}

/** Timezone + cutoff for the journey-independent earliest-bookable
 *  calculation on the /delivery landing view. Mirrors
 *  get_earliest_bookable_date's timezone pick (store timezone, else
 *  company business_timezone) using the caller's home store. Null
 *  when the employee or store can't be resolved. */
export async function fetchDeliveryCutoffContext(): Promise<{
  timezone: string | null;
  cutoff_time: string | null;
} | null> {
  const employee = await fetchCurrentEmployee();
  if (!employee?.home_store_id) return null;
  const supabase = createClient();
  const { data: store } = await supabase
    .from("stores")
    .select("timezone, company_id")
    .eq("id", employee.home_store_id)
    .maybeSingle();
  const companyId = (store as { company_id?: string } | null)?.company_id;
  if (!companyId) return null;
  const { data: company } = await supabase
    .from("companies")
    .select("business_timezone, delivery_cutoff_time")
    .eq("id", companyId)
    .maybeSingle();
  const c = company as {
    business_timezone?: string | null;
    delivery_cutoff_time?: string | null;
  } | null;
  const s = store as { timezone?: string | null } | null;
  return {
    timezone: s?.timezone ?? c?.business_timezone ?? null,
    cutoff_time: c?.delivery_cutoff_time ?? null,
  };
}

// ---------------------------------------------------------------------------
// D1-c1: day plan — close and assign (migration 132)
// ---------------------------------------------------------------------------

export type DeliveryDayPlanInfo = {
  status: "OPEN" | "CLOSED" | string;
  version: number;
  closed_at: string | null;
  closed_by_name: string | null;
  reopened_at: string | null;
  reviewed_at: string | null;
};

export type DeliveryDayPlanTruck = {
  truck_id: string;
  name: string;
  stop_cap: number;
  on: boolean;
  assigned_off: boolean;
};

export type DeliveryDayPlanStop = {
  stop_id: string;
  journey_id: string;
  journey_number: string | null;
  customer_name: string | null;
  phone: string | null;
  street_address: string | null;
  street_address_line_2: string | null;
  city: string | null;
  state: string | null;
  zip_code: string | null;
  delivery_address: string | null;
  truck_id: string | null;
  route_position: number | null;
  booked_by: string | null;
  booked_by_name: string | null;
  booked_at: string;
  inside_cutoff: boolean;
  window_start: string | null;
  window_end: string | null;
};

export type DeliveryDayReleasedStop = {
  stop_id: string;
  journey_id: string;
  journey_number: string | null;
  customer_name: string | null;
  truck_id: string | null;
  reason_kind: "cancelled" | "moved" | string;
  moved_to_date: string | null;
  cancel_reason: string | null;
  cancelled_at: string | null;
};

export type DeliveryDayPlan = {
  plan: DeliveryDayPlanInfo;
  trucks: DeliveryDayPlanTruck[];
  stops: DeliveryDayPlanStop[];
  released_after_review: DeliveryDayReleasedStop[];
  capacity: number;
  booked_count: number;
  today_local: string;
};

export type DeliveryAssignmentSuggestion = {
  assignments: { truck_id: string; name: string; stop_ids: string[] }[];
  overflow: string[];
};

/** Full day plan for the close-and-assign screen. Read is allowed for
 *  anyone who can see the delivery calendar. */
export async function fetchDeliveryDayPlan(
  date: string
): Promise<DeliveryDayPlan> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "get_delivery_day_plan",
    { p_date: date }
  );
  if (error) throw error;
  const d = data as DeliveryDayPlan | null;
  return {
    plan: d?.plan ?? {
      status: "OPEN",
      version: 0,
      closed_at: null,
      closed_by_name: null,
      reopened_at: null,
      reviewed_at: null,
    },
    trucks: d?.trucks ?? [],
    stops: d?.stops ?? [],
    released_after_review: d?.released_after_review ?? [],
    capacity: d?.capacity ?? 0,
    booked_count: d?.booked_count ?? 0,
    today_local: d?.today_local ?? "",
  };
}

export type DeliveryRouteStopInput = {
  stop_id: string;
  truck_id: string | null;
  route_position: number | null;
};

/** Save the whole route draft for a day. Returns the new plan version.
 *  Throws the RPC's plain-language errors for the caller to show. */
export async function saveDeliveryDayRoute(
  date: string,
  expectedVersion: number,
  stops: DeliveryRouteStopInput[]
): Promise<number> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "save_delivery_day_route",
    {
      p_date: date,
      p_expected_version: expectedVersion,
      p_stops: stops,
    }
  );
  if (error) throw error;
  return data as number;
}

/** Close a day for routing. Returns the new plan version. */
export async function closeDeliveryDay(
  date: string,
  expectedVersion: number
): Promise<number> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "close_delivery_day",
    { p_date: date, p_expected_version: expectedVersion }
  );
  if (error) throw error;
  return data as number;
}

/** Reopen a closed day. Assignments and order are kept. */
export async function reopenDeliveryDay(
  date: string,
  expectedVersion: number
): Promise<number> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "reopen_delivery_day",
    { p_date: date, p_expected_version: expectedVersion }
  );
  if (error) throw error;
  return data as number;
}

// ---------------------------------------------------------------------------
// D1-c2b part 3a: night-before confirmation call list (migration 138)
// ---------------------------------------------------------------------------

export type ConfirmationCallListDate = {
  date: string;
  stop_count: number;
};

export type ConfirmationLastCall = {
  outcome: string | null;
  occurred_at: string | null;
  by_name: string | null;
  note: string | null;
  window_snapshot: Record<string, unknown> | null;
};

export type ConfirmationCallListItem = {
  stop_id: string;
  journey_id: string;
  journey_number: string | null;
  customer_name: string | null;
  customer_phone: string | null;
  customer_email: string | null;
  delivery_address: string | null;
  truck_id: string | null;
  truck_name: string | null;
  route_position: number | null;
  window_start: string | null;
  window_end: string | null;
  outside_day_hours: boolean;
  assigned_employee_id: string | null;
  assigned_employee_name: string | null;
  status: string;
  attempts: number;
  last_call: ConfirmationLastCall | null;
};

export type ConfirmationCallList = {
  date: string | null;
  day_mode: string;
  day_start: string | null;
  day_end: string | null;
  available_dates: ConfirmationCallListDate[];
  scope: string;
  items: ConfirmationCallListItem[];
};

/** The night-before call list. p_date null lets the RPC pick the next
 *  delivery day; the response's `date` is the day actually returned. */
export async function fetchDeliveryConfirmationList(
  date: string | null,
  scope: "mine" | "all"
): Promise<ConfirmationCallList> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "get_delivery_confirmation_list",
    { p_date: date, p_scope: scope }
  );
  if (error) throw new Error(error.message);
  const d = data as ConfirmationCallList | null;
  return {
    date: d?.date ?? null,
    day_mode: d?.day_mode ?? "window",
    day_start: d?.day_start ?? null,
    day_end: d?.day_end ?? null,
    available_dates: d?.available_dates ?? [],
    scope: d?.scope ?? scope,
    items: d?.items ?? [],
  };
}

/** Whether the signed-in employee may view/log confirmation calls. */
export async function fetchDeliveryLogConfirmationCalls(): Promise<boolean> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("has_permission", {
    p_key: "delivery.log_confirmation_calls",
  });
  if (error) return false;
  return data === true;
}

/** Log one confirmation call. The idempotency key makes retries safe:
 *  the same key returns the already-written row instead of doubling. */
export async function logDeliveryConfirmation(input: {
  journeyId: string;
  stopId: string;
  outcome: string;
  note?: string | null;
  idempotencyKey: string;
}): Promise<{ interaction_id: string; deduplicated: boolean }> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "log_delivery_confirmation",
    {
      p_journey_id: input.journeyId,
      p_stop_id: input.stopId,
      p_outcome: input.outcome,
      p_note: input.note?.trim() ? input.note.trim() : null,
      p_occurred_at: null,
      p_idempotency_key: input.idempotencyKey,
    }
  );
  if (error) throw new Error(error.message);
  const d = data as { interaction_id?: string; deduplicated?: boolean } | null;
  return {
    interaction_id: d?.interaction_id ?? "",
    deduplicated: d?.deduplicated ?? false,
  };
}

/** Read-only zip-grouping proposal. Saves nothing; the caller applies
 *  it to the on-screen draft. */
export async function suggestDeliveryAssignments(
  date: string
): Promise<DeliveryAssignmentSuggestion> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "suggest_delivery_assignments",
    { p_date: date }
  );
  if (error) throw error;
  const d = data as DeliveryAssignmentSuggestion | null;
  return {
    assignments: d?.assignments ?? [],
    overflow: d?.overflow ?? [],
  };
}
