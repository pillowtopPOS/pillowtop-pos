import { createClient } from "@/lib/supabase/client";
import type { SleepJourneyState } from "@/lib/constants";
import type { JourneyEventType } from "./state";

export type JourneyWithDetails = {
  id: string;
  current_state: SleepJourneyState;
  product_summary: string | null;
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

export type Store = {
  id: string;
  name: string;
  address: string | null;
  trial_length_nights: number;
};

export type Employee = {
  id: string;
  name: string;
  role: string;
  home_store_id: string | null;
};

export async function fetchJourneys(
  storeId?: string,
  search?: string,
  assignedEmployeeId?: string
): Promise<JourneyWithDetails[]> {
  const supabase = createClient();

  let query = supabase
    .from("sleep_journeys")
    .select(
      `id, current_state, product_summary, cancelled_at, created_at, updated_at, store_id, assigned_employee_id,
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

export async function fetchStores(): Promise<Store[]> {
  const supabase = createClient();
  const { data, error } = await supabase.from("stores").select("id, name, address, trial_length_nights").order("name");
  if (error) {
    console.error("fetchStores error", error);
    return [];
  }
  return (data as unknown as Store[]) ?? [];
}

export async function fetchEmployees(): Promise<Employee[]> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("employees")
    .select("id, name, role, home_store_id")
    .order("name");
  if (error) {
    console.error("fetchEmployees error", error);
    return [];
  }
  return (data as unknown as Employee[]) ?? [];
}

export async function fetchCurrentEmployee(): Promise<Employee | null> {
  const supabase = createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  const { data, error } = await supabase
    .from("employees")
    .select("id, name, role, home_store_id")
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

export type NewJourneyInput = {
  firstName: string;
  lastName: string;
  phone: string;
  email: string;
  productSummary: string;
  storeId: string;
  assignedEmployeeId: string | null;
};

export async function createJourney(input: NewJourneyInput) {
  const supabase = createClient();

  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

  if (userError || !user) {
    throw new Error("Not authenticated");
  }

  const customerId = crypto.randomUUID();

  const { error: customerError } = await supabase.from("customers").insert({
    id: customerId,
    first_name: input.firstName,
    last_name: input.lastName,
    phone: input.phone,
    email: input.email,
  });

  if (customerError) {
    throw new Error(customerError.message);
  }

  const { error: journeyError } = await supabase.from("sleep_journeys").insert({
    customer_id: customerId,
    store_id: input.storeId,
    assigned_employee_id: input.assignedEmployeeId,
    product_summary: input.productSummary,
  });

  if (journeyError) {
    throw new Error(journeyError.message);
  }
}

export async function recordJourneyEvent(
  journeyId: string,
  eventType: JourneyEventType,
  eventData: Record<string, unknown> = {}
) {
  const supabase = createClient();

  const {
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

  if (userError || !user) {
    throw new Error("Not authenticated");
  }

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
    data: { user },
    error: userError,
  } = await supabase.auth.getUser();

  if (userError || !user) {
    throw new Error("Not authenticated");
  }

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
