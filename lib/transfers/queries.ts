import { createClient } from "@/lib/supabase/client";
import { fetchCurrentEmployee, type Employee, type Store } from "@/lib/journeys/queries";
import type { Product } from "@/lib/inventory/queries";

export type TransferRequestWithDetails = {
  id: string;
  origin_location_id: string;
  destination_location_id: string;
  variant_id: string;
  quantity: number;
  source_type: string;
  source_reference_id: string | null;
  request_group_id: string | null;
  status: string;
  requested_by: string | null;
  approved_by: string | null;
  approved_at: string | null;
  transfer_id: string | null;
  created_at: string;
  origin: { id: string; name: string } | null;
  destination: { id: string; name: string } | null;
  variant: { id: string; item_name: string } | null;
  requester: { id: string; name: string } | null;
  approver: { id: string; name: string } | null;
};

export type TransferWithDetails = {
  id: string;
  reference_code: string | null;
  origin_location_id: string;
  destination_location_id: string;
  status: string;
  scheduled_date: string;
  created_at: string;
  in_transit_at: string | null;
  finalized_at: string | null;
  finalized_by: string | null;
  origin: { id: string; name: string } | null;
  destination: { id: string; name: string } | null;
  line_items: TransferLineItem[];
};

export type TransferLineItem = {
  id: string;
  transfer_id: string;
  variant_id: string;
  quantity_requested: number;
  quantity_shipped: number;
  quantity_received: number;
  reported_quantity_received: number | null;
  reported_reason: string | null;
  reported_note: string | null;
  reported_by: string | null;
  reported_at: string | null;
  reporter: { id: string; name: string } | null;
  variant: { id: string; item_name: string } | null;
};

export type OverstockSuggestion = {
  store_id: string;
  store_name: string;
  variant_id: string;
  item_name: string;
  ats: number;
  target_quantity: number;
  excess: number;
};

export type RestockCandidate = {
  store_id: string;
  store_name: string;
  variant_id: string;
  item_name: string;
  sku: string | null;
  par_level_id: string;
  reorder_point: number;
  target_quantity: number;
  ats: number;
  suggested: number;
};

export type RestockGenerationMode = "automatic" | "manual";

export async function fetchTransferRequests(
  status?: string
): Promise<TransferRequestWithDetails[]> {
  const supabase = createClient();
  let query = (supabase as any)
    .from("transfer_requests")
    .select(
      `*,
      origin:stores!origin_location_id ( id, name ),
      destination:stores!destination_location_id ( id, name ),
      variant:products!variant_id ( id, item_name ),
      requester:employees!requested_by ( id, name ),
      approver:employees!approved_by ( id, name )`
    )
    .order("created_at", { ascending: false });
  if (status) query = query.eq("status", status);
  const { data, error } = await query;
  if (error) {
    console.error("fetchTransferRequests error", error);
    return [];
  }
  return (data as unknown as TransferRequestWithDetails[]) ?? [];
}

export async function fetchTransfers(
  status?: string
): Promise<TransferWithDetails[]> {
  const supabase = createClient();
  let query = (supabase as any)
    .from("transfers")
    .select(
      `*,
      origin:stores!origin_location_id ( id, name ),
      destination:stores!destination_location_id ( id, name ),
      line_items:transfer_line_items!transfer_id (
        id, transfer_id, variant_id, quantity_requested, quantity_shipped, quantity_received,
        reported_quantity_received, reported_reason, reported_note, reported_by, reported_at,
        reporter:employees!reported_by ( id, name ),
        variant:products!variant_id ( id, item_name )
      )`
    )
    .order("created_at", { ascending: false });
  if (status) query = query.eq("status", status);
  const { data, error } = await query;
  if (error) {
    console.error("fetchTransfers error", error);
    return [];
  }
  return (data as unknown as TransferWithDetails[]) ?? [];
}

async function insertTransferRequest(payload: {
  origin_location_id: string;
  destination_location_id: string;
  variant_id: string;
  quantity: number;
  source_type: "manual" | "manager_requested";
  source_reference_id?: string | null;
  request_group_id?: string | null;
}) {
  const supabase = createClient();
  const {
    data: { session },
  } = await supabase.auth.getSession();
  if (!session?.user) throw new Error("Not authenticated");

  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  // Validate origin has enough available Prime stock before creating the request.
  const [
    { data: position },
    { data: store },
    { data: product },
  ] = await Promise.all([
    (supabase as any)
      .from("inventory_positions_public")
      .select("ats")
      .eq("variant_id", payload.variant_id)
      .eq("location_id", payload.origin_location_id)
      .eq("disposition", "Prime")
      .is("sublocation_id", null)
      .maybeSingle(),
    (supabase as any)
      .from("stores")
      .select("name")
      .eq("id", payload.origin_location_id)
      .maybeSingle(),
    (supabase as any)
      .from("products")
      .select("item_name")
      .eq("id", payload.variant_id)
      .maybeSingle(),
  ]);

  const available = position?.ats ?? 0;
  if (payload.quantity > available) {
    throw new Error(
      `Origin "${store?.name ?? payload.origin_location_id}" only has ${available} units of "${
        product?.item_name ?? payload.variant_id
      }" available; requested ${payload.quantity}.`
    );
  }

  const { error } = await (supabase as any).from("transfer_requests").insert({
    origin_location_id: payload.origin_location_id,
    destination_location_id: payload.destination_location_id,
    variant_id: payload.variant_id,
    quantity: payload.quantity,
    source_type: payload.source_type,
    source_reference_id: payload.source_reference_id ?? null,
    status: "pending_approval",
    requested_by: employee.id,
    approved_by: null,
    approved_at: null,
    transfer_id: null,
    request_group_id: payload.request_group_id ?? null,
  });

  if (error) throw new Error(error.message);
}

export async function createManualTransferRequest(payload: {
  origin_location_id: string;
  destination_location_id: string;
  variant_id: string;
  quantity: number;
  request_group_id?: string | null;
}) {
  await insertTransferRequest({ ...payload, source_type: "manual" });
}

export async function createRestockTransferRequest(payload: {
  origin_location_id: string;
  destination_location_id: string;
  variant_id: string;
  quantity: number;
  source_reference_id?: string | null;
}) {
  await insertTransferRequest({ ...payload, source_type: "manager_requested" });
}

export async function approveTransferRequest(requestId: string) {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("approve_transfer_request", {
    p_request_id: requestId,
    p_employee_id: employee.id,
  });
  if (error) throw new Error(error.message);
}

export async function rejectTransferRequest(requestId: string) {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("reject_transfer_request", {
    p_request_id: requestId,
    p_employee_id: employee.id,
  });
  if (error) throw new Error(error.message);
}

export async function cancelTransferRequest(requestId: string) {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("cancel_transfer_request", {
    p_request_id: requestId,
    p_employee_id: employee.id,
  });
  if (error) throw new Error(error.message);
}

// Manual, on-demand consolidation run (owner/admin only, enforced server-side).
// Runs the same logic as the daily cron but bypasses the once-per-day guard.
export async function runTransferConsolidationNow() {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("run_transfer_consolidation_now", {
    p_employee_id: employee.id,
  });
  if (error) throw new Error(error.message);
}

// When consolidation last actually ran — cron_state.updated_at for the
// 'transfers' task (stamped by both the daily job and manual runs).
export async function fetchTransferConsolidationLastRun(): Promise<string | null> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("cron_state")
    .select("updated_at")
    .eq("task_name", "transfers")
    .maybeSingle();
  if (error) throw new Error(error.message);
  return (data as { updated_at: string } | null)?.updated_at ?? null;
}

// Expedite: convert one approved, unconsolidated request into a real transfer
// for a chosen scheduled date, ignoring the destination store's schedule day.
export async function expediteTransferRequest(requestId: string, scheduledDate: string) {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("expedite_transfer_request", {
    p_request_id: requestId,
    p_employee_id: employee.id,
    p_scheduled_date: scheduledDate,
  });
  if (error) throw new Error(error.message);
}

// Edit a pending request's quantity (warehouse/owner/admin only, enforced
// server-side; re-validated against real origin availability).
export async function updateTransferRequestQuantity(requestId: string, quantity: number) {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("update_transfer_request_quantity", {
    p_request_id: requestId,
    p_employee_id: employee.id,
    p_new_quantity: quantity,
  });
  if (error) throw new Error(error.message);
}

// Expedite a whole request group: one transfer with all members as line
// items, atomically, for a chosen scheduled date.
export async function expediteTransferRequestGroup(groupId: string, scheduledDate: string) {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("expedite_transfer_request_group", {
    p_group_id: groupId,
    p_employee_id: employee.id,
    p_scheduled_date: scheduledDate,
  });
  if (error) throw new Error(error.message);
}

export async function markTransferInTransit(
  transferId: string,
  shipped?: Record<string, number>
) {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("mark_transfer_in_transit", {
    p_transfer_id: transferId,
    p_employee_id: employee.id,
    p_shipped: shipped ?? null,
  });
  if (error) throw new Error(error.message);
}

export async function finalizeTransfer(
  transferId: string,
  received: Record<string, number>
) {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("finalize_transfer", {
    p_transfer_id: transferId,
    p_received: received,
    p_employee_id: employee.id,
  });
  if (error) throw new Error(error.message);
}

export type ReceiptLineReport = {
  line_item_id: string;
  quantity_received: number;
  reason: "missing" | "damaged" | "wrong_item" | "other" | null;
  note: string | null;
};

export async function confirmTransferReceipt(
  transferId: string,
  reports: ReceiptLineReport[]
) {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("confirm_transfer_receipt", {
    p_transfer_id: transferId,
    p_employee_id: employee.id,
    p_line_reports: reports,
  });
  if (error) throw new Error(error.message);
}

export async function fetchOverstockSuggestions(
  stores: Store[]
): Promise<OverstockSuggestion[]> {
  const warehouses = stores.filter(
    (s) => s.location_type === "WAREHOUSE" || s.location_type === "WAREHOUSE_QUARANTINE"
  );
  if (warehouses.length === 0) return [];

  const warehouseIds = warehouses.map((s) => s.id);

  const supabase = createClient();
  const [{ data: parLevels }, { data: positions }] = await Promise.all([
    (supabase as any)
      .from("par_levels")
      .select("store_id, variant_id, target_quantity, variant:products!variant_id(id,item_name)")
      .in("store_id", warehouseIds),
    (supabase as any)
      .from("inventory_positions_public")
      .select("variant_id, location_id, ats")
      .in("location_id", warehouseIds)
      .eq("disposition", "Prime")
      .is("sublocation_id", null),
  ]);

  const suggestions: OverstockSuggestion[] = [];
  const levelMap = new Map<string, { target: number; name: string }>();
  for (const pl of (parLevels as any[]) ?? []) {
    const key = `${pl.store_id}:${pl.variant_id}`;
    levelMap.set(key, {
      target: pl.target_quantity,
      name: pl.variant?.item_name ?? "Unknown",
    });
  }

  for (const pos of (positions as any[]) ?? []) {
    const key = `${pos.location_id}:${pos.variant_id}`;
    const level = levelMap.get(key);
    if (!level) continue;
    const ats = pos.ats ?? 0;
    if (ats > level.target) {
      suggestions.push({
        store_id: pos.location_id,
        store_name:
          warehouses.find((w) => w.id === pos.location_id)?.name ?? "Unknown",
        variant_id: pos.variant_id,
        item_name: level.name,
        ats,
        target_quantity: level.target,
        excess: ats - level.target,
      });
    }
  }

  return suggestions;
}

// ---- Restock mode + candidates ----
//
// fetchRestockCandidates implements the exact same comparison the
// threshold_auto cron performs in run_transfer_cron_for_date():
//   ats <= reorder_point AND target_quantity - ats > 0
// The two must not drift apart — if the cron check changes, change this too.

export async function fetchRestockGenerationMode(
  companyId: string
): Promise<RestockGenerationMode> {
  const supabase = createClient();
  const { data, error } = await (supabase as any)
    .from("companies")
    .select("restock_generation_mode")
    .eq("id", companyId)
    .maybeSingle();
  if (error) {
    console.error("fetchRestockGenerationMode error", error);
    return "automatic";
  }
  return (data?.restock_generation_mode as RestockGenerationMode) ?? "automatic";
}

export async function fetchRestockCandidates(
  stores: Store[],
  employee: Employee | null
): Promise<RestockCandidate[]> {
  // Managers see only their home store; owner/admin see every store.
  // Warehouses are never candidates — they are the restock origin, not a
  // destination; warehouse replenishment goes through Purchase Orders.
  const scoped = (
    employee?.role === "manager" && employee.home_store_id
      ? stores.filter((s) => s.id === employee.home_store_id)
      : stores
  ).filter((s) => s.location_type === "STORE");
  const storeIds = scoped.map((s) => s.id);
  if (storeIds.length === 0) return [];

  const supabase = createClient();
  const [{ data: parLevels }, { data: positions }, { data: prods }] =
    await Promise.all([
      (supabase as any)
        .from("par_levels")
        .select("id, store_id, variant_id, reorder_point, target_quantity")
        .in("store_id", storeIds),
      (supabase as any)
        .from("inventory_positions_public")
        .select("variant_id, location_id, ats")
        .in("location_id", storeIds)
        .eq("disposition", "Prime")
        .is("sublocation_id", null),
      (supabase as any)
        .from("products_public")
        .select("id, item_name, sku"),
    ]);

  const atsMap = new Map<string, number>();
  for (const pos of (positions as any[]) ?? []) {
    atsMap.set(`${pos.location_id}:${pos.variant_id}`, pos.ats ?? 0);
  }
  const prodMap = new Map<string, { item_name: string; sku: string | null }>();
  for (const p of (prods as any[]) ?? []) {
    prodMap.set(p.id, { item_name: p.item_name, sku: p.sku ?? null });
  }
  const storeName = new Map(scoped.map((s) => [s.id, s.name]));

  const candidates: RestockCandidate[] = [];
  for (const pl of (parLevels as any[]) ?? []) {
    const ats = atsMap.get(`${pl.store_id}:${pl.variant_id}`) ?? 0;
    if (ats > pl.reorder_point) continue;
    const suggested = pl.target_quantity - ats;
    if (suggested <= 0) continue;
    const prod = prodMap.get(pl.variant_id);
    candidates.push({
      store_id: pl.store_id,
      store_name: storeName.get(pl.store_id) ?? "Unknown",
      variant_id: pl.variant_id,
      item_name: prod?.item_name ?? "Unknown",
      sku: prod?.sku ?? null,
      par_level_id: pl.id,
      reorder_point: pl.reorder_point,
      target_quantity: pl.target_quantity,
      ats,
      suggested,
    });
  }

  return candidates;
}
