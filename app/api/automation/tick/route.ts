import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { processAutomaticTransitions } from "@/lib/journeys/automation";

// Signed-in users tick the automation for THEIR company only (the
// Sidebar polls this every 60s). In-memory throttle: one run per
// company per 60s per server instance; best effort on serverless.
const TICK_THROTTLE_MS = 60_000;
const lastTickAt = new Map<string, number>();

export async function POST() {
  const supabase = createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    return NextResponse.json({ error: "Not authenticated" }, { status: 401 });
  }

  // Resolve the caller's company through their active employee row's
  // home store (same join the employees settings route uses).
  const admin = createAdminClient();
  const { data: employee } = await admin
    .from("employees")
    .select("stores!inner(company_id)")
    .eq("auth_user_id", user.id)
    .eq("is_active", true)
    .maybeSingle();
  const stores = (employee as { stores?: unknown } | null)?.stores;
  const companyId = Array.isArray(stores)
    ? ((stores[0] as { company_id?: string })?.company_id ?? null)
    : ((stores as { company_id?: string } | null)?.company_id ?? null);
  if (!companyId) {
    return NextResponse.json(
      { error: "No company for this user" },
      { status: 403 }
    );
  }

  const now = Date.now();
  if (now - (lastTickAt.get(companyId) ?? 0) < TICK_THROTTLE_MS) {
    return NextResponse.json({ ok: true, skipped: true });
  }
  lastTickAt.set(companyId, now);

  try {
    await processAutomaticTransitions(companyId);
    return NextResponse.json({ ok: true });
  } catch (error: any) {
    return NextResponse.json(
      { error: error.message ?? "Unknown error" },
      { status: 500 }
    );
  }
}

export function GET() {
  return NextResponse.json({ error: "Method not allowed" }, { status: 405 });
}
