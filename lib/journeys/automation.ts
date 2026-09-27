import { createAdminClient } from "@/lib/supabase/admin";
import { revalidatePath } from "next/cache";

export async function processAutomaticTransitions() {
  const supabase = createAdminClient();
  const now = new Date();

  // Sleep trials that have exceeded their trial length. The anchor is
  // sleep_journeys.delivered_at — the actual delivery date — and the
  // journey's own policy snapshot when present (migration 057), falling
  // back to the store's current trial length for legacy rows.
  const { data: trialJourneys, error: trialError } = await supabase
    .from("sleep_journeys")
    .select("id, store_id, current_state, delivered_at, trial_length_nights")
    .eq("current_state", "Sleep Trial");

  if (trialError) throw new Error(trialError.message);

  for (const journey of trialJourneys ?? []) {
    if (!journey.delivered_at) continue;

    let nights = journey.trial_length_nights;
    if (nights == null) {
      const { data: store } = await supabase
        .from("stores")
        .select("trial_length_nights")
        .eq("id", journey.store_id)
        .single();
      nights = store?.trial_length_nights ?? 120;
    }
    const deliveredAt = new Date(`${journey.delivered_at}T00:00:00`);
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
