import { createAdminClient } from "@/lib/supabase/admin";
import { revalidatePath } from "next/cache";

export async function processAutomaticTransitions() {
  const supabase = createAdminClient();
  const now = new Date();

  // Deliveries that were scheduled for a date that has passed
  const { data: scheduledJourneys, error: scheduledError } = await supabase
    .from("sleep_journeys")
    .select("id, current_state")
    .eq("current_state", "Scheduled");

  if (scheduledError) throw new Error(scheduledError.message);

  for (const journey of scheduledJourneys ?? []) {
    const { data: events } = await supabase
      .from("journey_events")
      .select("event_data, created_at")
      .eq("journey_id", journey.id)
      .eq("event_type", "delivery_scheduled")
      .order("created_at", { ascending: false })
      .limit(1);

    const latest = events?.[0];
    if (!latest) continue;

    const deliveryDate = latest.event_data?.delivery_date as string | undefined;
    if (!deliveryDate) continue;

    const due = new Date(`${deliveryDate}T00:00:00`);
    if (due <= now) {
      const { data: existing } = await supabase
        .from("journey_events")
        .select("id")
        .eq("journey_id", journey.id)
        .eq("event_type", "delivery_completed")
        .limit(1);

      if (!existing || existing.length === 0) {
        await supabase.from("journey_events").insert({
          journey_id: journey.id,
          event_type: "delivery_completed",
          event_data: {},
          triggered_by: "system",
        });
      }
    }
  }

  // Sleep trials that have exceeded the store's trial length
  const { data: trialJourneys, error: trialError } = await supabase
    .from("sleep_journeys")
    .select("id, store_id, current_state")
    .eq("current_state", "Sleep Trial");

  if (trialError) throw new Error(trialError.message);

  for (const journey of trialJourneys ?? []) {
    const { data: deliveryEvent } = await supabase
      .from("journey_events")
      .select("created_at")
      .eq("journey_id", journey.id)
      .eq("event_type", "delivery_completed")
      .order("created_at", { ascending: false })
      .limit(1)
      .single();

    if (!deliveryEvent) continue;

    const { data: store } = await supabase
      .from("stores")
      .select("trial_length_nights")
      .eq("id", journey.store_id)
      .single();

    const nights = store?.trial_length_nights ?? 120;
    const deliveredAt = new Date(deliveryEvent.created_at);
    const trialEnds = new Date(
      deliveredAt.getTime() + nights * 24 * 60 * 60 * 1000
    );

    if (trialEnds <= now) {
      const { data: existing } = await supabase
        .from("journey_events")
        .select("id")
        .eq("journey_id", journey.id)
        .eq("event_type", "trial_completed")
        .limit(1);

      if (!existing || existing.length === 0) {
        await supabase.from("journey_events").insert({
          journey_id: journey.id,
          event_type: "trial_completed",
          event_data: {},
          triggered_by: "system",
        });
      }
    }
  }

  revalidatePath("/board");
}
