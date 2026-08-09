"use server";

import { createClient } from "@/lib/supabase/server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import type { JourneyEventType } from "./state";

export async function recordEvent(
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

  revalidatePath("/board");
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

  revalidatePath("/board");
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

  const { data: customer, error: customerError } = await supabase
    .from("customers")
    .insert({
      first_name: input.firstName,
      last_name: input.lastName,
      phone: input.phone,
      email: input.email,
    })
    .select("id")
    .single();

  if (customerError || !customer) {
    throw new Error(customerError?.message ?? "Failed to create customer");
  }

  const { data: journey, error: journeyError } = await supabase
    .from("sleep_journeys")
    .insert({
      customer_id: customer.id,
      store_id: input.storeId,
      assigned_employee_id: input.assignedEmployeeId,
      product_summary: input.productSummary,
    })
    .select("id")
    .single();

  if (journeyError || !journey) {
    throw new Error(journeyError?.message ?? "Failed to create journey");
  }

  revalidatePath("/board");
  redirect(`/board`);
}
