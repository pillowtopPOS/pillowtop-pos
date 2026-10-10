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

  // A journey whose trial item is parked on an open exchange/return must
  // not auto-complete — the trial clock is suspended for the item, so the
  // journey stays in Sleep Trial until the action resolves. Set-based
  // lookup (the parked set stays small); on failure we log and treat
  // nothing as parked rather than silently completing exchanges.
  const { data: parkedItems, error: parkedError } = await supabase
    .from("sleep_trial_items")
    .select("journey_id")
    .in("status", ["EXCHANGE_IN_PROGRESS", "RETURN_IN_PROGRESS"]);
  if (parkedError) {
    console.error(
      "processAutomaticTransitions: parked trial item lookup failed",
      parkedError
    );
  }
  const parkedJourneyIds = new Set(
    (parkedItems ?? []).map((i: { journey_id: string }) => i.journey_id)
  );

  for (const journey of trialJourneys ?? []) {
    if (!journey.delivered_at) continue;
    if (parkedJourneyIds.has(journey.id)) continue;

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
