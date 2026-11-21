import { createAdminClient } from "@/lib/supabase/admin";
import { needsTrialCompleted } from "@/lib/journeys/state";
import { revalidatePath } from "next/cache";

// companyId scopes every read/write below to one company (used by the
// signed-in /api/automation/tick route). sleep_journeys has no
// company_id column  -  the journey's store carries it  -  so scoping
// resolves the company's store ids first and filters on store_id.
// Omitted (the nightly /api/cron), behavior is unchanged.
export async function processAutomaticTransitions(companyId?: string) {
  const supabase = createAdminClient();
  const now = new Date();

  let storeIds: string[] | null = null;
  if (companyId) {
    const { data: stores, error: storesError } = await supabase
      .from("stores")
      .select("id")
      .eq("company_id", companyId);
    if (storesError) throw new Error(storesError.message);
    storeIds = (stores ?? []).map((s: { id: string }) => s.id);
    if (storeIds.length === 0) {
      revalidatePath("/board");
      return;
    }
  }

  // Sleep trials that have exceeded their trial length. The anchor is
  // sleep_journeys.delivered_at  -  the actual delivery date  -  and the
  // journey's own policy snapshot when present (migration 057), falling
  // back to the store's current trial length for legacy rows.
  let journeyQuery = supabase
    .from("sleep_journeys")
    .select("id, store_id, current_state, delivered_at, trial_length_nights")
    .eq("current_state", "Sleep Trial");
  if (storeIds) journeyQuery = journeyQuery.in("store_id", storeIds);
  const { data: trialJourneys, error: trialError } = await journeyQuery;

  if (trialError) throw new Error(trialError.message);

  // A journey whose trial item is parked on an open exchange/return must
  // not auto-complete  -  the trial clock is suspended for the item, so the
  // journey stays in Sleep Trial until the action resolves. Set-based
  // lookup (the parked set stays small); on failure we log and treat
  // nothing as parked rather than silently completing exchanges.
  let parkedQuery = supabase
    .from("sleep_trial_items")
    .select("journey_id")
    .in("status", ["EXCHANGE_IN_PROGRESS", "RETURN_IN_PROGRESS"]);
  if (companyId) parkedQuery = parkedQuery.eq("company_id", companyId);
  const { data: parkedItems, error: parkedError } = await parkedQuery;
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
      // store_id comes from the already company-filtered journey set,
      // so this read cannot cross companies either way.
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
      // 164: a reopen derives the journey back to Sleep Trial, so only a
      // trial_completed newer than the latest sleep_trial_action_reopened
      // counts  -  an older one is history from the first close.
      const [{ data: existing }, { data: reopens }] = await Promise.all([
        supabase
          .from("journey_events")
          .select("created_at")
          .eq("journey_id", journey.id)
          .eq("event_type", "trial_completed")
          .order("created_at", { ascending: false })
          .limit(1),
        supabase
          .from("journey_events")
          .select("created_at")
          .eq("journey_id", journey.id)
          .eq("event_type", "sleep_trial_action_reopened")
          .order("created_at", { ascending: false })
          .limit(1),
      ]);

      if (
        needsTrialCompleted(
          (existing ?? [])[0]?.created_at,
          (reopens ?? [])[0]?.created_at
        )
      ) {
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
