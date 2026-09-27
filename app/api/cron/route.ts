import { NextResponse } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { processAutomaticTransitions } from "@/lib/journeys/automation";

const TRANSFERS_CRON_KEY = "transfers";

export async function GET(request: Request) {
  const cronSecret = process.env.CRON_SECRET;
  const auth = request.headers.get("authorization");

  // Service-role client: the transfer cron function is not granted to
  // authenticated users and must run with elevated privileges.
  const admin = createAdminClient();

  try {
    // Phase 7c automation (inventory readiness/reservation) is polled every 60s
    // from the Board page with no authorization header. It must run regardless of
    // CRON_SECRET so the existing UI-triggered automation keeps working.
    await processAutomaticTransitions();

    // The transfer threshold/consolidation is privileged: it inserts and updates
    // transfer state and must be triggered only by a trusted caller. If
    // CRON_SECRET is configured, the caller must present it. If not configured,
    // the route still runs transfer logic (maintaining the pre-existing open
    // behavior for setups without a cron secret).
    const canRunTransfers = !cronSecret || auth === `Bearer ${cronSecret}`;

    if (canRunTransfers) {
      const today = new Date();
      const todayStr = today.toISOString().split("T")[0];

      const { data: state } = await admin
        .from("cron_state")
        .select("last_run_date")
        .eq("task_name", TRANSFERS_CRON_KEY)
        .maybeSingle();

      if (state?.last_run_date !== todayStr) {
        const { error: rpcError } = await admin.rpc(
          "run_transfer_cron_for_date",
          {
            p_run_date: todayStr,
          }
        );
        if (rpcError) throw new Error(rpcError.message);

        await admin.from("cron_state").upsert(
          {
            task_name: TRANSFERS_CRON_KEY,
            last_run_date: todayStr,
            updated_at: new Date().toISOString(),
          },
          { onConflict: "task_name" }
        );
      }
    }

    return NextResponse.json({ ok: true });
  } catch (error: any) {
    return NextResponse.json(
      { error: error.message ?? "Unknown error" },
      { status: 500 }
    );
  }
}
