import { NextResponse } from "next/server";
import { timingSafeEqual } from "node:crypto";
import { createAdminClient } from "@/lib/supabase/admin";
import { processAutomaticTransitions } from "@/lib/journeys/automation";

const TRANSFERS_CRON_KEY = "transfers";

// Vercel's scheduled cron (vercel.json) sends
// "Authorization: Bearer <CRON_SECRET>". Anything else runs nothing.
function authorized(request: Request, secret: string): boolean {
  const auth = request.headers.get("authorization") ?? "";
  const expected = `Bearer ${secret}`;
  const authBytes = Buffer.from(auth, "utf8");
  const expectedBytes = Buffer.from(expected, "utf8");
  if (authBytes.length !== expectedBytes.length) return false;
  return timingSafeEqual(authBytes, expectedBytes);
}

export async function GET(request: Request) {
  const cronSecret = process.env.CRON_SECRET;
  // Fail closed: no configured secret means no caller is trusted.
  if (!cronSecret) {
    return NextResponse.json(
      { error: "Cron not configured" },
      { status: 500 }
    );
  }
  if (!authorized(request, cronSecret)) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  // Service-role client: the transfer cron function is not granted to
  // authenticated users and must run with elevated privileges.
  const admin = createAdminClient();

  try {
    await processAutomaticTransitions();

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

    return NextResponse.json({ ok: true });
  } catch (error: any) {
    return NextResponse.json(
      { error: error.message ?? "Unknown error" },
      { status: 500 }
    );
  }
}
