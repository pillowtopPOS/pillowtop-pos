import { createClient } from "@/lib/supabase/client";
import type { SleepJourneyState } from "@/lib/constants";
import type { JourneyEventType } from "./state";

export type JourneyWithDetails = {
  id: string;
  current_state: SleepJourneyState;
  product_summary: string | null;
  price: number | null;
  cancelled_at: string | null;
  fulfillment_type: "delivery" | "pickup";
  delivered_at: string | null;
  inventory_ready_notified_at: string | null;
  trial_length_nights: number | null;
  minimum_adjustment_nights: number | null;
  created_at: string;
  updated_at: string;
  store_id: string;
  assigned_employee_id: string | null;
  customer: {
    id: string;
    first_name: string;
    last_name: string;
    phone: string;
    email: string;
    street_address: string | null;
    street_address_line_2: string | null;
    city: string | null;
    state: string | null;
    zip_code: string | null;
  } | null;
  employee: {
    id: string;
    name: string;
  } | null;
  store: {
    id: string;
    name: string;
    trial_length_nights: number;
    minimum_adjustment_nights: number | null;
    trial_ending_warning_days: number | null;
  } | null;
};

const JOURNEY_DETAIL_SELECT = `id, current_state, product_summary, price, cancelled_at, fulfillment_type, delivered_at, inventory_ready_notified_at, trial_length_nights, minimum_adjustment_nights, created_at, updated_at, store_id, assigned_employee_id,
      customer:customers!customer_id ( id, first_name, last_name, phone, email, street_address, street_address_line_2, city, state, zip_code ),
      employee:employees!assigned_employee_id ( id, name ),
      store:stores!store_id ( id, name, trial_length_nights, minimum_adjustment_nights, trial_ending_warning_days )`;

export type JourneyEvent = {
  id: string;
  journey_id: string;
  event_type: string;
  event_data: Record<string, unknown> | null;
  outcome: string | null;
  triggered_by: string;
  created_at: string;
};

export type JourneyReassignmentEvent = {
  id: string;
  journey_id: string;
  from_store_id: string | null;
  to_store_id: string | null;
  from_employee_id: string | null;
  to_employee_id: string | null;
  reason: string | null;
  actor_employee_id: string | null;
  created_at: string;
  from_store: { id: string; name: string } | null;
  to_store: { id: string; name: string } | null;
  from_employee: { id: string; name: string } | null;
  to_employee: { id: string; name: string } | null;
  actor: { id: string; name: string } | null;
};

export type FollowUp = {
  id: string;
  journey_id: string;
  employee_id: string | null;
  type: "quote" | "deposit" | "interaction" | "sleep_concern";
  due_at: string;
  completed_at: string | null;
  notes: string | null;
  method: string | null;
  journey_interaction_id: string | null;
  sleep_concern_id: string | null;
  journey?: JourneyWithDetails;
  sleep_concerns?: { status: string } | null;
};

export const FOLLOW_UP_METHOD_LABELS: Record<string, string> = {
  call: "Call",
  text: "Text",
  email: "Email",
  in_person: "In person",
};

export type JourneyLineItem = {
  id: string;
  journey_id: string;
  product_id: string | null;
  item_name: string;
  quantity: number;
  unit_price: number;
  fulfillment_type_override?: "delivery" | "pickup" | null;
  pickup_location_id?: string | null;
  pair_group_id?: string | null;
  sold_condition?: string | null;
  trial_ineligible_reason?: string | null;
  created_at: string;
  updated_at: string;
};

export type Opportunity = {
  id: string;
  first_name: string;
  last_name: string;
  phone: string;
  email: string;
  product_summary: string | null;
  source: string | null;
  notes: string | null;
  status: string;
  store_id: string;
  created_at: string;
};

export type Store = {
  id: string;
  company_id: string;
  name: string;
  store_code: string | null;
  address: string | null;
  street_address: string | null;
  city: string | null;
  state: string | null;
  zip_code: string | null;
  phone: string | null;
  is_active: boolean;
  trial_length_nights: number;
  minimum_adjustment_nights: number | null;
  trial_ending_warning_days: number | null;
  location_type: "STORE" | "WAREHOUSE" | "WAREHOUSE_QUARANTINE";
  parent_location_id: string | null;
  assigned_warehouse_id: string | null;
  transfer_schedule_day: number | null;
  // Arrives with migration 066; absent from fetchStores until then so the app
  // keeps working pre-migration. StoreManagement merges it in separately.
  timezone?: string | null;
};

export type EmployeeRole =
  | "owner"
  | "manager"
  | "sales"
  | "admin"
  | "employee";

export type Employee = {
  id: string;
  name: string;
  first_name: string;
  last_name: string | null;
  role: string;
  home_store_id: string | null;
  auth_user_id: string | null;
  birthday: string | null;
  hire_date: string | null;
  is_active: boolean;
};

const EMPLOYEE_COLUMNS =
  "id, name, first_name, last_name, role, home_store_id, auth_user_id, birthday, hire_date, is_active";

export async function fetchJourneys(
  storeId?: string,
  search?: string,
  assignedEmployeeId?: string
): Promise<JourneyWithDetails[]> {
  const supabase = createClient();

  let query = supabase
    .from("sleep_journeys")
    .select(JOURNEY_DETAIL_SELECT)
    .order("updated_at", { ascending: false });

  if (storeId && storeId !== "all") {
    query = query.eq("store_id", storeId);
  }

  if (assignedEmployeeId && assignedEmployeeId !== "all") {
    query = query.eq("assigned_employee_id", assignedEmployeeId);
  }

  const { data, error } = await query;

  if (error) {
    console.error("fetchJourneys error", error);
    return [];
  }

  let journeys = (data as unknown as JourneyWithDetails[]) ?? [];

  if (search?.trim()) {
    const term = search.trim().toLowerCase();
    journeys = journeys.filter((j) => {
      const customer = j.customer;
      if (!customer) return false;
      return (
        `${customer.first_name} ${customer.last_name}`.toLowerCase().includes(term) ||
        customer.phone.toLowerCase().includes(term) ||
        customer.email.toLowerCase().includes(term)
      );
    });
  }

  return journeys;
}

export async function fetchJourneyEvents(journeyId: string): Promise<JourneyEvent[]> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("journey_events")
    .select("*")
    .eq("journey_id", journeyId)
    .order("created_at", { ascending: true });

  if (error) {
    console.error("fetchJourneyEvents error", error);
    return [];
  }

  return (data as unknown as JourneyEvent[]) ?? [];
}

export const REASSIGNMENT_ROLES = ["owner", "admin", "manager"];

export function canReassignJourneys(role: string | null | undefined): boolean {
  return !!role && REASSIGNMENT_ROLES.includes(role);
}

export async function fetchJourneyById(
  journeyId: string
): Promise<JourneyWithDetails | null> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("sleep_journeys")
    .select(JOURNEY_DETAIL_SELECT)
    .eq("id", journeyId)
    .maybeSingle();

  if (error) {
    console.error("fetchJourneyById error", error);
    return null;
  }

  return (data as unknown as JourneyWithDetails) ?? null;
}

export async function fetchJourneyReassignments(
  journeyId: string
): Promise<JourneyReassignmentEvent[]> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("journey_reassignment_events")
    .select(
      `id, journey_id, from_store_id, to_store_id, from_employee_id, to_employee_id, reason, actor_employee_id, created_at,
      from_store:stores!from_store_id ( id, name ),
      to_store:stores!to_store_id ( id, name ),
      from_employee:employees!from_employee_id ( id, name ),
      to_employee:employees!to_employee_id ( id, name ),
      actor:employees!actor_employee_id ( id, name )`
    )
    .eq("journey_id", journeyId)
    .order("created_at", { ascending: false });

  if (error) {
    console.error("fetchJourneyReassignments error", error);
    return [];
  }

  return (data as unknown as JourneyReassignmentEvent[]) ?? [];
}

async function insertReassignment(row: {
  journey_id: string;
  to_store_id?: string;
  to_employee_id?: string;
  reason: string | null;
}) {
  const supabase = createClient();

  const {
    data: { session },
    error: sessionError,
  } = await supabase.auth.refreshSession();

  if (sessionError || !session?.user) {
    throw new Error("Not authenticated");
  }

  const { error } = await supabase.from("journey_reassignment_events").insert(row);
  if (error) throw new Error(error.message);
}

export async function updateJourneyFulfillment(
  journeyId: string,
  fulfillmentType: "delivery" | "pickup"
) {
  const supabase = createClient();
  const { error } = await supabase
    .from("sleep_journeys")
    .update({ fulfillment_type: fulfillmentType })
    .eq("id", journeyId);
  if (error) throw new Error(error.message);
}

export async function reassignJourneyStore(
  journeyId: string,
  toStoreId: string,
  reason?: string
) {
  await insertReassignment({
    journey_id: journeyId,
    to_store_id: toStoreId,
    reason: reason?.trim() ? reason.trim() : null,
  });
}

export async function reassignJourneyEmployee(
  journeyId: string,
  toEmployeeId: string,
  reason?: string
) {
  await insertReassignment({
    journey_id: journeyId,
    to_employee_id: toEmployeeId,
    reason: reason?.trim() ? reason.trim() : null,
  });
}

export async function fetchJourneyFollowUps(journeyId: string): Promise<FollowUp[]> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("follow_ups")
    .select("*")
    .eq("journey_id", journeyId)
    .order("due_at", { ascending: true });

  if (error) {
    console.error("fetchJourneyFollowUps error", error);
    return [];
  }

  return (data as unknown as FollowUp[]) ?? [];
}

export async function fetchStores(activeOnly = false): Promise<Store[]> {
  const supabase = createClient();
  let query = supabase
    .from("stores")
    .select(
      "id, company_id, name, store_code, address, street_address, city, state, zip_code, phone, is_active, trial_length_nights, minimum_adjustment_nights, trial_ending_warning_days, location_type, parent_location_id, assigned_warehouse_id, transfer_schedule_day"
    )
    .order("name");
  if (activeOnly) {
    query = query.eq("is_active", true);
  }
  const { data, error } = await query;
  if (error) {
    console.error("fetchStores error", error);
    return [];
  }
  return (data as unknown as Store[]) ?? [];
}

export async function createStore(store: Partial<Store>) {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("stores")
    .insert({
      company_id: store.company_id,
      name: store.name,
      store_code: store.store_code?.trim() || null,
      street_address: store.street_address,
      city: store.city,
      state: store.state,
      zip_code: store.zip_code,
      phone: store.phone,
      is_active: store.is_active ?? true,
      // Store-level trial fields are retired (L5): trial terms come from the
      // company Sleep Trial policy. The columns still exist until Phase 4 and
      // take their DB defaults (120/60/14).
      location_type: (store.location_type as any) ?? "STORE",
      assigned_warehouse_id: store.assigned_warehouse_id ?? null,
      transfer_schedule_day: store.transfer_schedule_day ?? null,
      // undefined is dropped by JSON serialization, so pre-migration callers
      // that don't pass a timezone don't break on the missing column.
      timezone: store.timezone,
    })
    .select("id")
    .single();

  if (error) throw new Error(error.message);
  return (data as { id: string } | null)?.id;
}

export async function updateStore(id: string, updates: Partial<Store>) {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("stores")
    .update({
      name: updates.name,
      // undefined → field omitted from the PATCH, so partial updates
      // (e.g. toggling is_active) don't wipe an existing store code.
      store_code: updates.store_code === undefined ? undefined : updates.store_code?.trim() || null,
      street_address: updates.street_address,
      city: updates.city,
      state: updates.state,
      zip_code: updates.zip_code,
      phone: updates.phone,
      is_active: updates.is_active,
      // Store-level trial fields are retired (L5) — no longer written here.
      assigned_warehouse_id: updates.assigned_warehouse_id,
      transfer_schedule_day: updates.transfer_schedule_day ?? null,
      // undefined → field omitted from the PATCH; null clears the override.
      timezone: updates.timezone,
    })
    .eq("id", id)
    .select("id")
    .maybeSingle();

  if (error) throw new Error(error.message);
  if (!data) throw new Error("Store update failed — row not found or not authorized.");
}

export async function countActiveJourneysForStore(storeId: string): Promise<number> {
  const supabase = createClient();
  const { count, error } = await supabase
    .from("sleep_journeys")
    .select("id", { count: "exact", head: true })
    .eq("store_id", storeId)
    .neq("current_state", "Completed")
    .neq("current_state", "Cancelled")
    .is("cancelled_at", null);

  if (error) {
    console.error("countActiveJourneysForStore error", error);
    return 0;
  }
  return count ?? 0;
}

export async function fetchEmployees(activeOnly = false): Promise<Employee[]> {
  const supabase = createClient();
  let query = supabase.from("employees").select(EMPLOYEE_COLUMNS).order("name");
  if (activeOnly) {
    query = query.eq("is_active", true);
  }
  const { data, error } = await query;
  if (error) {
    console.error("fetchEmployees error", error);
    return [];
  }
  return (data as unknown as Employee[]) ?? [];
}

export type EmployeeInput = {
  first_name: string;
  last_name: string | null;
  role: EmployeeRole;
  home_store_id: string | null;
  birthday: string | null;
  hire_date: string | null;
  is_active: boolean;
};

// No `.select()` here: the employees SELECT policy gates on is_employee_visible(),
// a security-definer function that re-queries employees and cannot see the row being
// inserted, so a RETURNING clause fails the policy and rolls the insert back.
export async function createEmployee(input: EmployeeInput) {
  const supabase = createClient();
  const { error } = await supabase.from("employees").insert({
    first_name: input.first_name,
    last_name: input.last_name,
    role: input.role,
    home_store_id: input.home_store_id,
    birthday: input.birthday,
    hire_date: input.hire_date,
    is_active: input.is_active,
  });

  if (error) throw new Error(error.message);
}

export type CreateEmployeeWithLoginInput = EmployeeInput & {
  email: string;
  password: string;
};

export async function createEmployeeWithLogin(input: CreateEmployeeWithLoginInput): Promise<Employee> {
  const res = await fetch("/api/employees", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });

  const data = await res.json();
  if (!res.ok) {
    throw new Error(data.error ?? "Failed to create employee");
  }

  return data.employee;
}

export async function fetchEmployeeRoles(): Promise<string[]> {
  const res = await fetch("/api/employee-roles");
  if (!res.ok) {
    const data = await res.json();
    throw new Error(data.error ?? "Failed to load employee roles");
  }

  const data = await res.json();
  return data.roles ?? [];
}

export async function updateEmployee(
  id: string,
  updates: Partial<EmployeeInput>
) {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("employees")
    .update(updates)
    .eq("id", id)
    .select("id")
    .maybeSingle();

  if (error) throw new Error(error.message);
  if (!data) {
    throw new Error("Employee update failed — row not found or not authorized.");
  }
}

export type Celebration = {
  employee_id: string;
  first_name: string;
  type: "birthday" | "anniversary";
  years: number | null;
};

function isSameMonthDay(date: string, today: Date) {
  const [, month, day] = date.split("-").map(Number);
  return month === today.getMonth() + 1 && day === today.getDate();
}

function yearsSince(date: string, today: Date) {
  const [year, month, day] = date.split("-").map(Number);
  let years = today.getFullYear() - year;
  const monthDayPassed =
    today.getMonth() + 1 > month ||
    (today.getMonth() + 1 === month && today.getDate() >= day);
  if (!monthDayPassed) years -= 1;
  return years;
}

// Company-wide: RLS already scopes employees to the caller's company, and celebrations
// are intentionally not filtered by store. Matching ignores the year.
export async function fetchTodaysCelebrations(
  today: Date = new Date()
): Promise<Celebration[]> {
  const employees = await fetchEmployees(true);
  const celebrations: Celebration[] = [];

  for (const employee of employees) {
    if (employee.birthday && isSameMonthDay(employee.birthday, today)) {
      celebrations.push({
        employee_id: employee.id,
        first_name: employee.first_name,
        type: "birthday",
        years: null,
      });
    }

    if (employee.hire_date && isSameMonthDay(employee.hire_date, today)) {
      const years = yearsSince(employee.hire_date, today);
      if (years > 0) {
        celebrations.push({
          employee_id: employee.id,
          first_name: employee.first_name,
          type: "anniversary",
          years,
        });
      }
    }
  }

  return celebrations;
}

export async function countActiveJourneysForEmployee(
  employeeId: string
): Promise<number> {
  const supabase = createClient();
  const { count, error } = await supabase
    .from("sleep_journeys")
    .select("id", { count: "exact", head: true })
    .eq("assigned_employee_id", employeeId)
    .neq("current_state", "Completed")
    .is("cancelled_at", null);

  if (error) {
    console.error("countActiveJourneysForEmployee error", error);
    return 0;
  }
  return count ?? 0;
}

export async function fetchCurrentEmployee(): Promise<Employee | null> {
  const supabase = createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  const { data, error } = await supabase
    .from("employees")
    .select(EMPLOYEE_COLUMNS)
    .eq("auth_user_id", user.id)
    .maybeSingle();

  if (error) {
    console.error("fetchCurrentEmployee error", error);
    return null;
  }

  return (data as unknown as Employee) ?? null;
}

export function subscribeToJourneyChanges(callback: () => void) {
  const supabase = createClient();

  const channel = supabase
    .channel("journey_changes")
    .on(
      "postgres_changes",
      { event: "*", schema: "public", table: "sleep_journeys" },
      callback
    )
    .on(
      "postgres_changes",
      { event: "INSERT", schema: "public", table: "journey_events" },
      callback
    )
    .subscribe();

  return () => {
    supabase.removeChannel(channel);
  };
}

export async function recordJourneyEvent(
  journeyId: string,
  eventType: JourneyEventType,
  eventData: Record<string, unknown> = {}
) {
  const supabase = createClient();

  const {
    data: { session },
    error: sessionError,
  } = await supabase.auth.refreshSession();

  if (sessionError || !session?.user) {
    throw new Error("Not authenticated");
  }

  const user = session.user;

  const { error } = await supabase.from("journey_events").insert({
    journey_id: journeyId,
    event_type: eventType,
    event_data: eventData,
    triggered_by: user.id,
  });

  if (error) {
    throw new Error(error.message);
  }
}

export async function cancelJourney(journeyId: string, reason: string) {
  const supabase = createClient();

  const {
    data: { session },
    error: sessionError,
  } = await supabase.auth.refreshSession();

  if (sessionError || !session?.user) {
    throw new Error("Not authenticated");
  }

  const user = session.user;

  const { error } = await supabase.from("journey_events").insert({
    journey_id: journeyId,
    event_type: "journey_cancelled",
    event_data: { reason },
    triggered_by: user.id,
  });

  if (error) {
    throw new Error(error.message);
  }
}

export async function fetchJourneyLineItems(
  journeyId: string
): Promise<JourneyLineItem[]> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("journey_line_items")
    .select("*")
    .eq("journey_id", journeyId)
    .order("created_at", { ascending: true });

  if (error) {
    console.error("fetchJourneyLineItems error", error);
    return [];
  }
  return (data as unknown as JourneyLineItem[]) ?? [];
}

export async function createJourneyLineItem(
  item: Omit<JourneyLineItem, "id" | "created_at" | "updated_at">
) {
  const supabase = createClient();
  const { error } = await supabase.from("journey_line_items").insert({
    journey_id: item.journey_id,
    product_id: item.product_id,
    item_name: item.item_name,
    quantity: item.quantity,
    unit_price: item.unit_price,
    fulfillment_type_override: item.fulfillment_type_override ?? null,
    pickup_location_id: item.pickup_location_id ?? null,
  });
  if (error) throw new Error(error.message);
}

export async function updateJourneyLineItem(
  id: string,
  updates: {
    quantity?: number;
    unit_price?: number;
    fulfillment_type_override?: "delivery" | "pickup" | null;
    pickup_location_id?: string | null;
  }
) {
  const supabase = createClient();
  const { error } = await supabase
    .from("journey_line_items")
    .update(updates)
    .eq("id", id);
  if (error) throw new Error(error.message);
}

export async function deleteJourneyLineItem(id: string) {
  const supabase = createClient();
  const { error } = await supabase.from("journey_line_items").delete().eq("id", id);
  if (error) throw new Error(error.message);
}

export async function updateCustomerAddress(
  customerId: string,
  address: {
    street_address: string | null;
    street_address_line_2: string | null;
    city: string | null;
    state: string | null;
    zip_code: string | null;
  }
) {
  const supabase = createClient();
  const { data, error, status, statusText } = await supabase
    .from("customers")
    .update(address)
    .eq("id", customerId)
    .select("id")
    .maybeSingle();

  if (error) throw new Error(error.message);
  if (!data) {
    throw new Error(
      status === 204
        ? "Customer address was not updated. You may not have permission to edit this customer."
        : `Customer address update returned no row (${status} ${statusText}).`
    );
  }
}

export type CustomerInput = {
  firstName: string;
  lastName: string;
  phone: string;
  email: string;
  streetAddress?: string;
  streetAddressLine2?: string;
  city?: string;
  state?: string;
  zipCode?: string;
};

export type LineItemInput = {
  productId: string | null;
  itemName: string;
  quantity: number;
  unitPrice: number;
  fulfillmentTypeOverride?: "delivery" | "pickup" | null;
  pickupLocationId?: string | null;
};

type BaseCreateInput = {
  customer: CustomerInput;
  lineItems: LineItemInput[];
  storeId: string;
  assignedEmployeeId: string | null;
  fulfillmentType?: "delivery" | "pickup";
};

export type QuoteCreateInput = BaseCreateInput & {
  mode: "quote";
  quoteNotes?: string;
};

export type PurchaseCreateInput = BaseCreateInput & {
  mode: "purchase";
  paymentAmount: string;
  paymentMethod: string;
  followUpDueAt?: string;
};

export type CreateJourneyInput = QuoteCreateInput | PurchaseCreateInput;

export async function createJourney(input: CreateJourneyInput): Promise<string> {
  const supabase = createClient();

  const {
    data: { session },
    error: sessionError,
  } = await supabase.auth.refreshSession();

  if (sessionError || !session?.user) {
    throw new Error("Not authenticated");
  }

  const customerId = crypto.randomUUID();

  const { error: customerError } = await supabase.from("customers").insert({
    id: customerId,
    first_name: input.customer.firstName,
    last_name: input.customer.lastName,
    phone: input.customer.phone,
    email: input.customer.email,
    street_address: input.customer.streetAddress ?? null,
    street_address_line_2: input.customer.streetAddressLine2 ?? null,
    city: input.customer.city ?? null,
    state: input.customer.state ?? null,
    zip_code: input.customer.zipCode ?? null,
  });

  if (customerError) {
    throw new Error(customerError.message);
  }

  const firstItem = input.lineItems[0];
  const firstProductId = firstItem?.productId ?? null;

  const { data: journey, error: journeyError } = await supabase
    .from("sleep_journeys")
    .insert({
      customer_id: customerId,
      store_id: input.storeId,
      assigned_employee_id: input.assignedEmployeeId,
      product_id: firstProductId,
      product_summary: firstItem?.itemName ?? null,
      fulfillment_type: input.fulfillmentType ?? "delivery",
    })
    .select("id")
    .single();

  if (journeyError || !journey) {
    throw new Error(journeyError?.message ?? "Failed to create journey");
  }

  if (input.lineItems.length > 0) {
    const { error: itemsError } = await supabase
      .from("journey_line_items")
      .insert(
        input.lineItems.map((item) => ({
          journey_id: journey.id,
          product_id: item.productId,
          item_name: item.itemName,
          quantity: item.quantity,
          unit_price: item.unitPrice,
          fulfillment_type_override: item.fulfillmentTypeOverride ?? null,
          pickup_location_id: item.pickupLocationId ?? null,
        }))
      );

    if (itemsError) {
      throw new Error(itemsError.message);
    }
  }

  const total = input.lineItems.reduce(
    (sum, item) => sum + item.quantity * item.unitPrice,
    0
  );

  if (input.mode === "quote") {
    await recordJourneyEvent(
      journey.id,
      "quote_sent",
      {
        amount: total,
        notes: input.quoteNotes,
      }
    );
  }

  return journey.id;
}

export type PaymentOutcome =
  | "SUCCEEDED"
  | "FAILED"
  | "UNKNOWN"
  | "CANCELLED"
  | "VOIDED"
  | "REFUNDED";

export async function fetchTotalPaid(journeyId: string): Promise<number> {
  const supabase = createClient();
  const { data, error } = await (supabase.rpc as any)("total_paid", {
    p_journey_id: journeyId,
  });
  if (error) throw new Error(error.message);
  return (data as number) ?? 0;
}

export async function recordPayment(
  journeyId: string,
  amount: number,
  paymentMethod: string,
  depositApprovalId?: string
): Promise<{ paymentEventId: string; outcome: PaymentOutcome }> {
  const supabase = createClient();

  const {
    data: { session },
    error: sessionError,
  } = await supabase.auth.refreshSession();

  if (sessionError || !session?.user) {
    throw new Error("Not authenticated");
  }

  const outcome: PaymentOutcome = paymentMethod.includes("timeout")
    ? "UNKNOWN"
    : paymentMethod.includes("failure")
    ? "FAILED"
    : "SUCCEEDED";

  const { data, error } = await supabase.rpc("record_payment_event", {
    p_journey_id: journeyId,
    p_event_data: { amount, payment_method: paymentMethod },
    p_idempotency_key: crypto.randomUUID(),
    p_outcome: outcome,
    p_actor_id: session.user.id,
    p_deposit_approval_id: depositApprovalId ?? null,
  });

  if (error) {
    throw new Error(error.message);
  }

  return { paymentEventId: data as string, outcome };
}

export async function recordPaymentEvent(options: {
  journeyId: string;
  amount: number;
  paymentMethod: string;
  idempotencyKey: string;
  outcome: PaymentOutcome;
  followUpDueAt?: string;
  depositApprovalId?: string;
}) {
  const supabase = createClient();

  const {
    data: { session },
    error: sessionError,
  } = await supabase.auth.refreshSession();

  if (sessionError || !session?.user) {
    throw new Error("Not authenticated");
  }

  const eventData: Record<string, unknown> = {
    amount: options.amount,
    payment_method: options.paymentMethod,
  };

  if (options.followUpDueAt) {
    eventData.follow_up_due_at = options.followUpDueAt;
  }

  const { data, error } = await supabase.rpc("record_payment_event", {
    p_journey_id: options.journeyId,
    p_event_data: eventData,
    p_idempotency_key: options.idempotencyKey,
    p_outcome: options.outcome,
    p_actor_id: session.user.id,
    p_deposit_approval_id: options.depositApprovalId ?? null,
  });

  if (error) {
    throw new Error(error.message);
  }

  return data as string;
}

export async function reconcilePayment(
  paymentEventId: string,
  newOutcome: PaymentOutcome
): Promise<string> {
  const supabase = createClient();

  const {
    data: { session },
    error: sessionError,
  } = await supabase.auth.refreshSession();

  if (sessionError || !session?.user) {
    throw new Error("Not authenticated");
  }

  const { data, error } = await supabase.rpc("reconcile_payment_event", {
    p_event_id: paymentEventId,
    p_new_outcome: newOutcome,
    p_source: "manual",
    p_actor_id: session.user.id,
    p_notes: null,
  });

  if (error) {
    throw new Error(error.message);
  }

  return data as string;
}

export async function fetchOpportunities(storeId?: string): Promise<Opportunity[]> {
  const supabase = createClient();
  let query = supabase
    .from("opportunities")
    .select("*")
    .order("created_at", { ascending: false });

  if (storeId && storeId !== "all") {
    query = query.eq("store_id", storeId);
  }

  const { data, error } = await query;
  if (error) {
    console.error("fetchOpportunities error", error);
    return [];
  }

  return (data as unknown as Opportunity[]) ?? [];
}

export type PendingApproval = {
  id: string;
  journey_id: string;
  trial_item_id: string | null;
  exception_type: string;
  action: string;
  rule_reference: string | null;
  requested_terms: Record<string, unknown> | null;
  requested_at: string;
  requester_employee_id: string | null;
  requester_name: string | null;
  reason_label: string | null;
  reason_note: string | null;
  customer_name: string | null;
};

export type MyWorkItem =
  | { kind: "follow_up"; data: FollowUp & { journey: JourneyWithDetails | null } }
  | { kind: "opportunity"; data: Opportunity }
  | { kind: "approval"; data: PendingApproval };

export async function fetchMyWork(): Promise<MyWorkItem[]> {
  const supabase = createClient();

  const [
    { data: followUps, error: followError },
    { data: opportunities, error: oppError },
    { data: approvals, error: apprError },
  ] =
    await Promise.all([
      supabase
        .from("follow_ups")
        .select("*, sleep_concerns(status)")
        .is("completed_at", null)
        .order("due_at", { ascending: true }),
      supabase
        .from("opportunities")
        .select("*")
        .eq("status", "new")
        .order("created_at", { ascending: false }),
      // Sleep-trial exceptions pending the caller's decision (075 — the
      // My Work APPROVAL kind). Derived at query time server-side so the
      // approver set is never a stale copy.
      supabase.rpc("list_pending_exception_approvals"),
    ]);

  if (followError) console.error("fetchMyWork follow_ups error", followError);
  if (oppError) console.error("fetchMyWork opportunities error", oppError);
  if (apprError) console.error("fetchMyWork approvals error", apprError);

  const journeyIds = ((followUps as unknown as FollowUp[]) ?? [])
    .map((f) => f.journey_id)
    .filter((id, idx, arr) => arr.indexOf(id) === idx);

  const { data: journeys, error: journeyError } = await supabase
    .from("sleep_journeys")
    .select(JOURNEY_DETAIL_SELECT)
    .in("id", journeyIds);

  if (journeyError) console.error("fetchMyWork sleep_journeys error", journeyError);

  const journeyMap = new Map<string, JourneyWithDetails>();
  for (const j of (journeys as unknown as JourneyWithDetails[]) ?? []) {
    journeyMap.set(j.id, j);
  }

  const items: MyWorkItem[] = [];

  for (const f of (followUps as unknown as FollowUp[]) ?? []) {
    items.push({
      kind: "follow_up",
      data: { ...f, journey: journeyMap.get(f.journey_id) ?? null } as FollowUp & {
        journey: JourneyWithDetails | null;
      },
    });
  }

  for (const o of (opportunities as unknown as Opportunity[]) ?? []) {
    items.push({ kind: "opportunity", data: o });
  }

  for (const a of (approvals as unknown as PendingApproval[]) ?? []) {
    items.push({ kind: "approval", data: a });
  }

  return items;
}

export async function completeFollowUp(followUpId: string) {
  const supabase = createClient();
  const { error } = await supabase.rpc("complete_follow_up", {
    p_follow_up_id: followUpId,
  });

  if (error) throw new Error(error.message);
}
