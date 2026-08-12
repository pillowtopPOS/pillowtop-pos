import { createClient } from "@/lib/supabase/client";
import type { SleepJourneyState } from "@/lib/constants";
import type { JourneyEventType } from "./state";

export type JourneyWithDetails = {
  id: string;
  current_state: SleepJourneyState;
  product_summary: string | null;
  price: number | null;
  cancelled_at: string | null;
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
  } | null;
  employee: {
    id: string;
    name: string;
  } | null;
  store: {
    id: string;
    name: string;
  } | null;
};

export type JourneyEvent = {
  id: string;
  journey_id: string;
  event_type: string;
  event_data: Record<string, unknown> | null;
  triggered_by: string;
  created_at: string;
};

export type FollowUp = {
  id: string;
  journey_id: string;
  type: "quote" | "deposit";
  due_at: string;
  completed_at: string | null;
  notes: string | null;
  journey?: JourneyWithDetails;
};

export type JourneyLineItem = {
  id: string;
  journey_id: string;
  product_id: string | null;
  item_name: string;
  quantity: number;
  unit_price: number;
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
  address: string | null;
  street_address: string | null;
  city: string | null;
  state: string | null;
  zip_code: string | null;
  phone: string | null;
  is_active: boolean;
  trial_length_nights: number;
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
    .select(
      `id, current_state, product_summary, price, cancelled_at, created_at, updated_at, store_id, assigned_employee_id,
      customer:customers!customer_id ( id, first_name, last_name, phone, email ),
      employee:employees!assigned_employee_id ( id, name ),
      store:stores!store_id ( id, name )`
    )
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
      "id, company_id, name, address, street_address, city, state, zip_code, phone, is_active, trial_length_nights"
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
      street_address: store.street_address,
      city: store.city,
      state: store.state,
      zip_code: store.zip_code,
      phone: store.phone,
      is_active: store.is_active ?? true,
      trial_length_nights: store.trial_length_nights ?? 120,
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
      street_address: updates.street_address,
      city: updates.city,
      state: updates.state,
      zip_code: updates.zip_code,
      phone: updates.phone,
      is_active: updates.is_active,
      trial_length_nights: updates.trial_length_nights,
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

export async function createEmployee(input: EmployeeInput) {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("employees")
    .insert({
      first_name: input.first_name,
      last_name: input.last_name,
      role: input.role,
      home_store_id: input.home_store_id,
      birthday: input.birthday,
      hire_date: input.hire_date,
      is_active: input.is_active,
    })
    .select("id")
    .single();

  if (error) throw new Error(error.message);
  return (data as { id: string } | null)?.id;
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
  });
  if (error) throw new Error(error.message);
}

export async function updateJourneyLineItem(
  id: string,
  updates: { quantity?: number; unit_price?: number }
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

export type CustomerInput = {
  firstName: string;
  lastName: string;
  phone: string;
  email: string;
};

export type LineItemInput = {
  productId: string | null;
  itemName: string;
  quantity: number;
  unitPrice: number;
};

type BaseCreateInput = {
  customer: CustomerInput;
  lineItems: LineItemInput[];
  storeId: string;
  assignedEmployeeId: string | null;
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

export async function createJourney(input: CreateJourneyInput) {
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
  } else {
    const paidNum = parseFloat(input.paymentAmount) || 0;

    if (paidNum >= total) {
      await recordJourneyEvent(
        journey.id,
        "payment_completed",
        {
          amount: paidNum,
          payment_method: input.paymentMethod,
        }
      );
    } else {
      await recordJourneyEvent(
        journey.id,
        "deposit_received",
        {
          amount: paidNum,
          payment_method: input.paymentMethod,
          follow_up_due_at: input.followUpDueAt || undefined,
        }
      );
    }
  }
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

export type MyWorkItem =
  | { kind: "follow_up"; data: FollowUp & { journey: JourneyWithDetails | null } }
  | { kind: "opportunity"; data: Opportunity };

export async function fetchMyWork(): Promise<MyWorkItem[]> {
  const supabase = createClient();

  const [{ data: followUps, error: followError }, { data: opportunities, error: oppError }] =
    await Promise.all([
      supabase
        .from("follow_ups")
        .select("*")
        .is("completed_at", null)
        .order("due_at", { ascending: true }),
      supabase
        .from("opportunities")
        .select("*")
        .eq("status", "new")
        .order("created_at", { ascending: false }),
    ]);

  if (followError) console.error("fetchMyWork follow_ups error", followError);
  if (oppError) console.error("fetchMyWork opportunities error", oppError);

  const journeyIds = ((followUps as unknown as FollowUp[]) ?? [])
    .map((f) => f.journey_id)
    .filter((id, idx, arr) => arr.indexOf(id) === idx);

  const { data: journeys, error: journeyError } = await supabase
    .from("sleep_journeys")
    .select(
      `id, current_state, product_summary, price, cancelled_at, created_at, updated_at, store_id, assigned_employee_id,
      customer:customers!customer_id ( id, first_name, last_name, phone, email ),
      employee:employees!assigned_employee_id ( id, name ),
      store:stores!store_id ( id, name )`
    )
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

  return items;
}

export async function completeFollowUp(followUpId: string) {
  const supabase = createClient();
  const { error } = await supabase
    .from("follow_ups")
    .update({ completed_at: new Date().toISOString() })
    .eq("id", followUpId);

  if (error) throw new Error(error.message);
}
