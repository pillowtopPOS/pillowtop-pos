"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { Lock, Pencil, Check, X } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import {
  fetchCurrentEmployee,
  fetchStores,
  type Employee,
  type Store,
} from "@/lib/journeys/queries";
import { searchProducts, fetchProductStock, type Product } from "@/lib/inventory/queries";
import { isStoreConfirmedToday } from "@/lib/journeys/storeConfirm";
import Modal from "@/components/Modal";
import { localTodayISO } from "@/lib/dates";
import {
  fetchTransferRequests,
  fetchTransfers,
  createManualTransferRequest,
  createRestockTransferRequest,
  approveTransferRequest,
  rejectTransferRequest,
  cancelTransferRequest,
  updateTransferRequestQuantity,
  expediteTransferRequest,
  expediteTransferRequestGroup,
  runTransferConsolidationNow,
  fetchTransferConsolidationLastRun,
  markTransferInTransit,
  finalizeTransfer,
  confirmTransferReceipt,
  fetchOverstockSuggestions,
  fetchRestockCandidates,
  fetchRestockGenerationMode,
  type TransferRequestWithDetails,
  type TransferWithDetails,
  type OverstockSuggestion,
  type TransferLineItem,
  type RestockCandidate,
  type RestockGenerationMode,
  type ReceiptLineReport,
} from "@/lib/transfers/queries";

const RECEIPT_REASON_LABELS: Record<string, string> = {
  missing: "Missing / not on truck",
  damaged: "Damaged",
  wrong_item: "Wrong item shipped",
  other: "Other",
};

const STATUS_CLASS = {
  pending_approval: "text-amber-700 bg-amber-50",
  approved: "text-emerald-700 bg-emerald-50",
  consolidated: "text-blue-700 bg-blue-50",
  rejected: "text-slate-600 bg-slate-100",
  cancelled: "text-slate-500 bg-slate-100",
  pending: "text-amber-700 bg-amber-50",
  in_transit: "text-blue-700 bg-blue-50",
  finalized: "text-emerald-700 bg-emerald-50",
};

export default function TransfersPage() {
  const router = useRouter();
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [loading, setLoading] = useState(true);
  const [tab, setTab] = useState<"requests" | "transfers" | "overstock" | "restock">("requests");

  const [requests, setRequests] = useState<TransferRequestWithDetails[]>([]);
  const [transfers, setTransfers] = useState<TransferWithDetails[]>([]);
  const [overstock, setOverstock] = useState<OverstockSuggestion[]>([]);

  const [restockMode, setRestockMode] = useState<RestockGenerationMode>("automatic");
  const [restockCandidates, setRestockCandidates] = useState<RestockCandidate[]>([]);
  const [restockSelected, setRestockSelected] = useState<Record<string, boolean>>({});
  const [restockQty, setRestockQty] = useState<Record<string, string>>({});
  const [restockOrigin, setRestockOrigin] = useState<Record<string, string>>({});
  const [restockingStore, setRestockingStore] = useState<string | null>(null);

  const [requestFilter, setRequestFilter] = useState<string>("");
  const [transferFilter, setTransferFilter] = useState<string>("");

  const [manualForm, setManualForm] = useState({
    origin_location_id: "",
    destination_location_id: "",
    productQuery: "",
  });
  const [productOptions, setProductOptions] = useState<Product[]>([]);
  const [originStock, setOriginStock] = useState<Record<string, number>>({});
  const [manualCart, setManualCart] = useState<
    { variant_id: string; item_name: string; ats: number; qty: string }[]
  >([]);
  const [creating, setCreating] = useState(false);
  const [expeditingId, setExpeditingId] = useState<string | null>(null);
  const [expeditingGroupId, setExpeditingGroupId] = useState<string | null>(null);
  const [expediteDate, setExpediteDate] = useState("");
  const [expandedGroups, setExpandedGroups] = useState<Record<string, boolean>>({});
  const [editingQtyId, setEditingQtyId] = useState<string | null>(null);
  const [editingQtyValue, setEditingQtyValue] = useState("");

  const [finalizing, setFinalizing] = useState<TransferWithDetails | null>(null);
  const [finalizeSubmitting, setFinalizeSubmitting] = useState(false);
  const [receivedMap, setReceivedMap] = useState<Record<string, number>>({});

  const [activeStoreId, setActiveStoreId] = useState<string | null>(null);
  const [storeConfirmedToday, setStoreConfirmedToday] = useState(false);
  const [confirming, setConfirming] = useState<TransferWithDetails | null>(null);
  const [receiptMap, setReceiptMap] = useState<
    Record<string, { qty: string; reason: string; note: string }>
  >({});
  const [confirmSubmitting, setConfirmSubmitting] = useState(false);
  const [expediteSubmitting, setExpediteSubmitting] = useState(false);
  const [lastConsolidationRun, setLastConsolidationRun] = useState<string | null>(null);
  const [runningConsolidation, setRunningConsolidation] = useState(false);

  const canManage =
    employee?.role === "owner" ||
    employee?.role === "admin" ||
    employee?.role === "manager";

  // Approval is restricted to owner/admin or employees based at a warehouse.
  const canApprove =
    employee?.role === "owner" ||
    employee?.role === "admin" ||
    stores.find((s) => s.id === employee?.home_store_id)?.location_type ===
      "WAREHOUSE";

  function lockedReviewButton(label: string, message?: string) {
    return (
      <button
        type="button"
        onClick={() =>
          window.alert(
            message ??
              "Transfer request review is restricted to warehouse-based employees. An owner, admin, or warehouse team member needs to handle this request."
          )
        }
        className="inline-flex cursor-not-allowed items-center gap-1 text-xs text-slate-400"
      >
        <Lock className="h-3 w-3" /> {label}
      </button>
    );
  }

  async function loadAll() {
    const [reqs, trs, os, lastRun] = await Promise.all([
      fetchTransferRequests(),
      fetchTransfers(),
      fetchOverstockSuggestions(stores),
      fetchTransferConsolidationLastRun(),
    ]);
    setRequests(reqs);
    setTransfers(trs);
    setOverstock(os);
    setLastConsolidationRun(lastRun);
  }

  // "5 minutes ago" style label for the last consolidation run.
  function relativeTime(iso: string): string {
    const seconds = Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 1000));
    if (seconds < 60) return "just now";
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes} minute${minutes === 1 ? "" : "s"} ago`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours} hour${hours === 1 ? "" : "s"} ago`;
    const days = Math.floor(hours / 24);
    if (days < 7) return `${days} day${days === 1 ? "" : "s"} ago`;
    return new Date(iso).toLocaleDateString();
  }

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(async ({ data: { session } }) => {
      if (!session?.user) {
        router.push("/login");
        return;
      }
      setActiveStoreId(session.user.user_metadata?.active_store_id ?? null);
      setStoreConfirmedToday(isStoreConfirmedToday(session.user));
      const [e, s] = await Promise.all([fetchCurrentEmployee(), fetchStores()]);
      setEmployee(e);
      setStores(s);
      setLoading(false);
    });
  }, [router]);

  useEffect(() => {
    if (!loading) loadAll();
  }, [loading]);

  // Load the company's restock mode, then (manual mode only) the candidates.
  useEffect(() => {
    if (loading || !employee || stores.length === 0) return;
    const companyId = stores.find(
      (s) => s.id === employee.home_store_id
    )?.company_id;
    if (!companyId) return;
    fetchRestockGenerationMode(companyId).then(async (mode) => {
      setRestockMode(mode);
      if (mode === "manual") {
        const candidates = await fetchRestockCandidates(stores, employee);
        setRestockCandidates(candidates);
        // Seed each candidate's suggested quantity into real form state so the
        // displayed default is also the submitted value.
        setRestockQty(
          Object.fromEntries(
            candidates.map((c) => [
              restockKey(c.store_id, c.variant_id),
              String(c.suggested),
            ])
          )
        );
      }
    });
  }, [loading, employee, stores]);

  useEffect(() => {
    const t = setTimeout(async () => {
      if (manualForm.productQuery.trim()) {
        const products = await searchProducts(manualForm.productQuery);
        setProductOptions(products);
        if (manualForm.origin_location_id && products.length > 0) {
          const stock = await fetchProductStock(
            products.map((p) => p.id),
            manualForm.origin_location_id
          );
          setOriginStock(
            Object.fromEntries(
              Object.entries(stock).map(([id, s]) => [id, s.ats])
            )
          );
        } else {
          setOriginStock({});
        }
      } else {
        setProductOptions([]);
        setOriginStock({});
      }
    }, 200);
    return () => clearTimeout(t);
  }, [manualForm.productQuery, manualForm.origin_location_id]);

  const filteredRequests = useMemo(() => {
    if (!requestFilter) return requests;
    return requests.filter((r) => r.status === requestFilter);
  }, [requests, requestFilter]);

  // Requests sharing a request_group_id collapse into one row; the group's
  // position follows its first member in the (created_at desc) list.
  const requestRows = useMemo(() => {
    const byGroup = new Map<string, TransferRequestWithDetails[]>();
    for (const r of filteredRequests) {
      if (r.request_group_id) {
        const list = byGroup.get(r.request_group_id) ?? [];
        list.push(r);
        byGroup.set(r.request_group_id, list);
      }
    }
    const rows: (
      | { kind: "single"; request: TransferRequestWithDetails }
      | { kind: "group"; groupId: string; members: TransferRequestWithDetails[] }
    )[] = [];
    const seen = new Set<string>();
    for (const r of filteredRequests) {
      if (!r.request_group_id) {
        rows.push({ kind: "single", request: r });
      } else if (!seen.has(r.request_group_id)) {
        seen.add(r.request_group_id);
        rows.push({
          kind: "group",
          groupId: r.request_group_id,
          members: byGroup.get(r.request_group_id)!,
        });
      }
    }
    return rows;
  }, [filteredRequests]);

  const filteredTransfers = useMemo(() => {
    if (!transferFilter) return transfers;
    return transfers.filter((t) => t.status === transferFilter);
  }, [transfers, transferFilter]);

  // Restock candidates grouped by destination store (already role-scoped by
  // fetchRestockCandidates: managers get only their home store).
  const restockByStore = useMemo(() => {
    const map = new Map<string, RestockCandidate[]>();
    for (const c of restockCandidates) {
      const list = map.get(c.store_id) ?? [];
      list.push(c);
      map.set(c.store_id, list);
    }
    return map;
  }, [restockCandidates]);

  function restockKey(storeId: string, variantId: string) {
    return `${storeId}:${variantId}`;
  }

  function restockOriginFor(storeId: string): string {
    return (
      restockOrigin[storeId] ??
      stores.find((s) => s.id === storeId)?.assigned_warehouse_id ??
      ""
    );
  }

  async function handleRequestRestock(storeId: string) {
    const group = restockByStore.get(storeId) ?? [];
    const selected = group.filter(
      (c) => restockSelected[restockKey(c.store_id, c.variant_id)]
    );
    if (selected.length === 0) return;
    const origin = restockOriginFor(storeId);
    if (!origin) {
      window.alert("Select an origin location for the restock request.");
      return;
    }
    if (origin === storeId) {
      window.alert("Origin and destination must be different locations.");
      return;
    }
    for (const c of selected) {
      const raw = restockQty[restockKey(c.store_id, c.variant_id)] ?? String(c.suggested);
      const qty = parseInt(raw, 10);
      if (!qty || qty <= 0) {
        window.alert(`Enter a valid quantity for ${c.item_name}.`);
        return;
      }
    }

    setRestockingStore(storeId);
    try {
      for (const c of selected) {
        await createRestockTransferRequest({
          origin_location_id: origin,
          destination_location_id: storeId,
          variant_id: c.variant_id,
          quantity: parseInt(
            restockQty[restockKey(c.store_id, c.variant_id)] ?? String(c.suggested),
            10
          ),
          source_reference_id: c.par_level_id,
        });
      }
      setRestockSelected((prev) => {
        const next = { ...prev };
        for (const c of selected) delete next[restockKey(c.store_id, c.variant_id)];
        return next;
      });
      setRestockQty((prev) => {
        const next = { ...prev };
        for (const c of selected) delete next[restockKey(c.store_id, c.variant_id)];
        return next;
      });
      window.alert(
        `${selected.length} restock request${selected.length === 1 ? "" : "s"} created and pending approval.`
      );
      await loadAll();
    } catch (err: any) {
      window.alert(err.message ?? "Failed to create restock requests");
    } finally {
      setRestockingStore(null);
    }
  }

  // Add a searched product to the request cart. Re-adding a product already
  // in the cart bumps that row's quantity by 1 (blank -> 1) instead of
  // creating a duplicate row.
  function addToCart(p: Product) {
    const ats = manualForm.origin_location_id
      ? originStock[p.id] ?? 0
      : 0;
    setManualCart((prev) =>
      prev.some((i) => i.variant_id === p.id)
        ? prev.map((i) =>
            i.variant_id === p.id
              ? { ...i, qty: String((parseInt(i.qty, 10) || 0) + 1) }
              : i
          )
        : [...prev, { variant_id: p.id, item_name: p.item_name, ats, qty: "" }]
    );
    setManualForm((f) => ({ ...f, productQuery: "" }));
    setProductOptions([]);
    setOriginStock({});
  }

  function setCartQty(variantId: string, qty: string) {
    setManualCart((prev) =>
      prev.map((i) => (i.variant_id === variantId ? { ...i, qty } : i))
    );
  }

  function removeFromCart(variantId: string) {
    setManualCart((prev) => prev.filter((i) => i.variant_id !== variantId));
  }

  // Origin changed: refresh each cart row's ATS against the new origin.
  async function handleOriginChange(originId: string) {
    setManualForm((f) => ({ ...f, origin_location_id: originId }));
    setOriginStock({});
    if (manualCart.length > 0 && originId) {
      const stock = await fetchProductStock(
        manualCart.map((i) => i.variant_id),
        originId
      );
      setManualCart((prev) =>
        prev.map((i) => ({ ...i, ats: stock[i.variant_id]?.ats ?? 0 }))
      );
    }
  }

  async function handleCreateManual(e: React.FormEvent) {
    e.preventDefault();
    if (!canManage) return;
    if (!manualForm.origin_location_id || !manualForm.destination_location_id) {
      window.alert("Select an origin and destination");
      return;
    }
    if (manualForm.origin_location_id === manualForm.destination_location_id) {
      window.alert("The origin and destination can't be the same location");
      return;
    }
    if (manualCart.length === 0) {
      window.alert("Add at least one product to the request");
      return;
    }
    const originName =
      stores.find((s) => s.id === manualForm.origin_location_id)?.name ??
      "Origin";
    for (const item of manualCart) {
      const qty = parseInt(item.qty, 10);
      if (item.qty.trim() === "" || Number.isNaN(qty) || qty <= 0) {
        window.alert(`Enter a valid quantity for ${item.item_name}.`);
        return;
      }
      if (qty > item.ats) {
        window.alert(
          `Origin "${originName}" only has ${item.ats} units of "${item.item_name}" available; requested ${qty}.`
        );
        return;
      }
    }
    setCreating(true);
    try {
      // A multi-item submission shares one request_group_id so the Requests
      // tab can display and act on it as a single unit.
      const groupId = manualCart.length > 1 ? crypto.randomUUID() : null;
      for (const item of manualCart) {
        await createManualTransferRequest({
          origin_location_id: manualForm.origin_location_id,
          destination_location_id: manualForm.destination_location_id,
          variant_id: item.variant_id,
          quantity: parseInt(item.qty, 10),
          request_group_id: groupId,
        });
      }
      setManualForm({
        origin_location_id: "",
        destination_location_id: "",
        productQuery: "",
      });
      setManualCart([]);
      setProductOptions([]);
      setOriginStock({});
      await loadAll();
    } catch (err: any) {
      window.alert(err.message ?? "Failed to create request");
    } finally {
      setCreating(false);
    }
  }

  async function actOnRequest(requestId: string, action: "approve" | "reject" | "cancel") {
    try {
      if (action === "approve") await approveTransferRequest(requestId);
      if (action === "reject") await rejectTransferRequest(requestId);
      if (action === "cancel") await cancelTransferRequest(requestId);
      await loadAll();
    } catch (err: any) {
      window.alert(err.message ?? "Action failed");
    }
  }

  // Manual consolidation run — same daily logic, bypasses the once-per-day
  // guard. Owner/admin only (also enforced by the RPC).
  async function handleRunConsolidation() {
    setRunningConsolidation(true);
    try {
      await runTransferConsolidationNow();
      await loadAll();
    } catch (err: any) {
      window.alert(err.message ?? "Failed to run consolidation");
    } finally {
      setRunningConsolidation(false);
    }
  }

  // Expedite: turn an approved request (or a whole request group) into a
  // shippable transfer for a chosen date, skipping the destination store's
  // schedule day.
  function handleExpedite(requestId: string) {
    setExpediteDate(localTodayISO());
    setExpeditingId(requestId);
  }

  function handleExpediteGroup(groupId: string) {
    setExpediteDate(localTodayISO());
    setExpeditingGroupId(groupId);
  }

  async function confirmExpedite() {
    if (!expediteDate || (!expeditingId && !expeditingGroupId)) return;
    setExpediteSubmitting(true);
    try {
      if (expeditingGroupId) {
        await expediteTransferRequestGroup(expeditingGroupId, expediteDate);
      } else {
        await expediteTransferRequest(expeditingId!, expediteDate);
      }
      setExpeditingId(null);
      setExpeditingGroupId(null);
      await loadAll();
    } catch (err: any) {
      window.alert(err.message ?? "Failed to expedite request");
    } finally {
      setExpediteSubmitting(false);
    }
  }

  // Group-level Approve/Reject/Cancel: loop the existing single-request
  // functions across eligible members; report any partial failure.
  async function actOnRequestGroup(
    members: TransferRequestWithDetails[],
    action: "approve" | "reject" | "cancel"
  ) {
    // Bulk actions only touch still-pending members; anything already
    // approved/rejected/cancelled is skipped and reported as such.
    const eligible = members.filter((m) => m.status === "pending_approval");
    const verb = { approve: "approved", reject: "rejected", cancel: "cancelled" }[action];
    if (eligible.length === 0) {
      window.alert(`All ${members.length} items were already handled; nothing was ${verb}.`);
      return;
    }
    const fn =
      action === "approve"
        ? approveTransferRequest
        : action === "reject"
        ? rejectTransferRequest
        : cancelTransferRequest;
    const failed: string[] = [];
    let succeeded = 0;
    for (const m of eligible) {
      try {
        await fn(m.id);
        succeeded++;
      } catch {
        failed.push(m.variant?.item_name ?? m.id);
      }
    }
    await loadAll();
    const skipped = members.length - eligible.length;
    const parts = [`${succeeded} of ${members.length} items were ${verb}`];
    if (skipped > 0) parts.push(`${skipped} already handled`);
    if (failed.length > 0) parts.push(`failed: ${failed.join(", ")}`);
    if (skipped > 0 || failed.length > 0) {
      window.alert(parts.join("; ") + ".");
    }
  }

  async function saveQtyEdit(requestId: string) {
    const qty = parseInt(editingQtyValue, 10);
    if (editingQtyValue.trim() === "" || Number.isNaN(qty) || qty <= 0) {
      window.alert("Enter a valid quantity.");
      return;
    }
    try {
      await updateTransferRequestQuantity(requestId, qty);
      setEditingQtyId(null);
      await loadAll();
    } catch (err: any) {
      window.alert(err.message ?? "Failed to update quantity");
    }
  }

  function statusBadge(status: string) {
    return (
      <span
        className={`rounded-full px-2 py-0.5 text-xs font-medium ${
          STATUS_CLASS[status as keyof typeof STATUS_CLASS] ??
          "text-slate-600 bg-slate-100"
        }`}
      >
        {status}
      </span>
    );
  }

  function renderRequestRow(r: TransferRequestWithDetails) {
    return (
      <tr key={r.id} className="border-b border-slate-100">
        <td className="px-3 py-2">{r.variant?.item_name ?? "Unknown"}</td>
        {qtyCell(r)}
        <td className="px-3 py-2">
          {r.origin?.name ?? "?"} → {r.destination?.name ?? "?"}
        </td>
        <td className="px-3 py-2">{r.source_type}</td>
        <td className="px-3 py-2">{statusBadge(r.status)}</td>
        <td className="px-3 py-2">
          <div className="flex items-center gap-2">
            {canManage && r.status === "pending_approval" && (
              <>
                {canApprove ? (
                  <button
                    onClick={() => actOnRequest(r.id, "approve")}
                    className="text-xs text-emerald-700 hover:underline"
                  >
                    Approve
                  </button>
                ) : (
                  lockedReviewButton("Approve")
                )}
                {canApprove ? (
                  <button
                    onClick={() => actOnRequest(r.id, "reject")}
                    className="text-xs text-red-700 hover:underline"
                  >
                    Reject
                  </button>
                ) : (
                  lockedReviewButton("Reject")
                )}
              </>
            )}
            {r.status === "approved" && canApprove && (
              <button
                onClick={() => handleExpedite(r.id)}
                className="text-xs text-brand-700 hover:underline"
              >
                Expedite
              </button>
            )}
            {canManage &&
              (r.status === "approved" || r.status === "pending_approval") &&
              (canApprove ? (
                <button
                  onClick={() => actOnRequest(r.id, "cancel")}
                  className="text-xs text-slate-600 hover:underline"
                >
                  Cancel
                </button>
              ) : (
                lockedReviewButton("Cancel")
              ))}
          </div>
        </td>
      </tr>
    );
  }

  function qtyCell(r: TransferRequestWithDetails, small?: boolean) {
    const editable = r.status === "pending_approval" && canApprove;
    const base = small ? "px-3 py-1.5 text-xs text-slate-600" : "px-3 py-2";
    if (editingQtyId === r.id) {
      return (
        <td className={base}>
          <div className="flex items-center gap-1">
            <input
              type="number"
              min={1}
              autoFocus
              value={editingQtyValue}
              onChange={(e) => setEditingQtyValue(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") saveQtyEdit(r.id);
                if (e.key === "Escape") setEditingQtyId(null);
              }}
              className="w-16 rounded-md border border-slate-300 px-1.5 py-0.5 text-xs"
            />
            <button
              type="button"
              onClick={() => saveQtyEdit(r.id)}
              className="text-emerald-700 hover:text-emerald-800"
              aria-label="Save quantity"
            >
              <Check className="h-3.5 w-3.5" />
            </button>
            <button
              type="button"
              onClick={() => setEditingQtyId(null)}
              className="text-slate-400 hover:text-slate-600"
              aria-label="Cancel edit"
            >
              <X className="h-3.5 w-3.5" />
            </button>
          </div>
        </td>
      );
    }
    return (
      <td className={base}>
        <span className="inline-flex items-center gap-1.5">
          {r.quantity}
          {editable && (
            <button
              type="button"
              onClick={() => {
                setEditingQtyId(r.id);
                setEditingQtyValue(String(r.quantity));
              }}
              className="text-slate-400 hover:text-slate-600"
              aria-label="Edit quantity"
            >
              <Pencil className="h-3 w-3" />
            </button>
          )}
        </span>
      </td>
    );
  }

  function renderGroupRows(groupId: string, members: TransferRequestWithDetails[]) {
    const expanded = expandedGroups[groupId] ?? false;
    const statuses = new Set(members.map((m) => m.status));
    const status = statuses.size === 1 ? members[0].status : "mixed";
    const anyPending = members.some((m) => m.status === "pending_approval");
    const allApproved = members.every(
      (m) => m.status === "approved" && m.transfer_id === null
    );
    return [
      <tr key={groupId} className="border-b border-slate-100 bg-slate-50/50">
        <td className="px-3 py-2">
          <button
            type="button"
            onClick={() =>
              setExpandedGroups((prev) => ({ ...prev, [groupId]: !expanded }))
            }
            className="text-xs text-brand-700 hover:underline"
          >
            {expanded ? "▾" : "▸"} {members.length} items
          </button>
        </td>
        <td className="px-3 py-2">
          {members.reduce((sum, m) => sum + m.quantity, 0)}
        </td>
        <td className="px-3 py-2">
          {members[0].origin?.name ?? "?"} → {members[0].destination?.name ?? "?"}
        </td>
        <td className="px-3 py-2">{members[0].source_type}</td>
        <td className="px-3 py-2">
          {status === "mixed" ? (
            <span className="rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600">
              {Array.from(statuses)
                .map(
                  (s) =>
                    `${members.filter((m) => m.status === s).length} ${s.replace(/_/g, " ")}`
                )
                .join(", ")}
            </span>
          ) : (
            statusBadge(status)
          )}
        </td>
        <td className="px-3 py-2">
          <div className="flex items-center gap-2">
            {canManage && anyPending && (
              <>
                {canApprove ? (
                  <button
                    onClick={() => actOnRequestGroup(members, "approve")}
                    className="text-xs text-emerald-700 hover:underline"
                  >
                    Approve all
                  </button>
                ) : (
                  lockedReviewButton("Approve")
                )}
                {canApprove ? (
                  <button
                    onClick={() => actOnRequestGroup(members, "reject")}
                    className="text-xs text-red-700 hover:underline"
                  >
                    Reject all
                  </button>
                ) : (
                  lockedReviewButton("Reject")
                )}
              </>
            )}
            {allApproved && canApprove && (
              <button
                onClick={() => handleExpediteGroup(groupId)}
                className="text-xs text-brand-700 hover:underline"
              >
                Expedite
              </button>
            )}
            {canManage &&
              anyPending &&
              (canApprove ? (
                <button
                  onClick={() => actOnRequestGroup(members, "cancel")}
                  className="text-xs text-slate-600 hover:underline"
                >
                  Cancel all
                </button>
              ) : (
                lockedReviewButton("Cancel")
              ))}
          </div>
        </td>
      </tr>,
      ...(expanded
        ? members.map((m) => (
            <tr key={m.id} className="border-b border-slate-100 bg-white">
              <td className="px-3 py-1.5 pl-8 text-xs text-slate-600">
                {m.variant?.item_name ?? "Unknown"}
              </td>
              {qtyCell(m, true)}
              <td className="px-3 py-1.5" colSpan={2}></td>
              <td className="px-3 py-1.5">{statusBadge(m.status)}</td>
              <td className="px-3 py-1.5">
                <div className="flex items-center gap-2">
                  {canManage && m.status === "pending_approval" && (
                    <>
                      {canApprove ? (
                        <button
                          onClick={() => actOnRequest(m.id, "approve")}
                          className="text-xs text-emerald-700 hover:underline"
                        >
                          Approve
                        </button>
                      ) : (
                        lockedReviewButton("Approve")
                      )}
                      {canApprove ? (
                        <button
                          onClick={() => actOnRequest(m.id, "reject")}
                          className="text-xs text-red-700 hover:underline"
                        >
                          Reject
                        </button>
                      ) : (
                        lockedReviewButton("Reject")
                      )}
                    </>
                  )}
                  {canManage &&
                    (m.status === "approved" || m.status === "pending_approval") &&
                    (canApprove ? (
                      <button
                        onClick={() => actOnRequest(m.id, "cancel")}
                        className="text-xs text-slate-600 hover:underline"
                      >
                        Cancel
                      </button>
                    ) : (
                      lockedReviewButton("Cancel")
                    ))}
                </div>
              </td>
            </tr>
          ))
        : []),
    ];
  }

  async function handleMarkInTransit(t: TransferWithDetails) {
    try {
      await markTransferInTransit(t.id);
      await loadAll();
    } catch (err: any) {
      window.alert(err.message ?? "Failed to mark in transit");
    }
  }

  function openFinalize(t: TransferWithDetails) {
    const initial: Record<string, number> = {};
    for (const line of t.line_items) {
      initial[line.id] = line.quantity_shipped;
    }
    setReceivedMap(initial);
    setFinalizing(t);
  }

  async function handleFinalize() {
    if (!finalizing) return;
    setFinalizeSubmitting(true);
    try {
      await finalizeTransfer(finalizing.id, receivedMap);
      setFinalizing(null);
      await loadAll();
    } catch (err: any) {
      window.alert(err.message ?? "Failed to finalize transfer");
    } finally {
      setFinalizeSubmitting(false);
    }
  }

  // Confirm Receipt is available to owner/admin, or any employee checked in
  // at the destination store today — only for in_transit transfers bound
  // for a STORE.
  function canConfirmReceiptFor(t: TransferWithDetails): boolean {
    if (t.status !== "in_transit") return false;
    const dest = stores.find((s) => s.id === t.destination_location_id);
    if (dest?.location_type !== "STORE") return false;
    if (employee?.role === "owner" || employee?.role === "admin") return true;
    return storeConfirmedToday && activeStoreId === t.destination_location_id;
  }

  function openConfirmReceipt(t: TransferWithDetails) {
    const initial: Record<string, { qty: string; reason: string; note: string }> = {};
    for (const line of t.line_items) {
      initial[line.id] = { qty: "", reason: "", note: "" };
    }
    setReceiptMap(initial);
    setConfirming(t);
  }

  function setReceiptEntry(
    lineId: string,
    patch: Partial<{ qty: string; reason: string; note: string }>
  ) {
    setReceiptMap((prev) => ({
      ...prev,
      [lineId]: {
        ...(prev[lineId] ?? { qty: "", reason: "", note: "" }),
        ...patch,
      },
    }));
  }

  async function handleConfirmReceipt() {
    if (!confirming) return;
    const reports: ReceiptLineReport[] = [];
    for (const line of confirming.line_items) {
      const name = line.variant?.item_name ?? "an item";
      const entry = receiptMap[line.id];
      const qty = entry ? parseInt(entry.qty, 10) : NaN;
      if (!entry || entry.qty.trim() === "" || Number.isNaN(qty) || qty < 0) {
        window.alert(`Enter the quantity received for ${name}.`);
        return;
      }
      let reason: ReceiptLineReport["reason"] = null;
      let note: string | null = null;
      if (qty < line.quantity_shipped) {
        if (!entry.reason) {
          window.alert(`Select a reason for the shortfall on ${name}.`);
          return;
        }
        reason = entry.reason as ReceiptLineReport["reason"];
        if (entry.reason === "other") {
          if (!entry.note.trim()) {
            window.alert(`Add a note describing the issue for ${name}.`);
            return;
          }
          note = entry.note.trim();
        }
      }
      reports.push({
        line_item_id: line.id,
        quantity_received: qty,
        reason,
        note,
      });
    }

    setConfirmSubmitting(true);
    try {
      await confirmTransferReceipt(confirming.id, reports);
      setConfirming(null);
      await loadAll();
    } catch (err: any) {
      window.alert(err.message ?? "Failed to confirm receipt");
    } finally {
      setConfirmSubmitting(false);
    }
  }

  if (loading) {
    return (
      <main className="min-h-screen bg-slate-50 p-6">
        <p className="text-sm text-slate-500">Loading…</p>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-slate-50 p-6">
      <header className="mb-6 flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-2xl font-semibold text-slate-900">Transfers</h1>
        <div className="flex items-center gap-2">
          <button
            onClick={() => setTab("requests")}
            className={`rounded-md px-3 py-2 text-sm font-medium ${
              tab === "requests"
                ? "bg-brand-600 text-white"
                : "border border-slate-300 bg-white text-slate-700 hover:bg-slate-50"
            }`}
          >
            Requests
          </button>
          <button
            onClick={() => setTab("transfers")}
            className={`rounded-md px-3 py-2 text-sm font-medium ${
              tab === "transfers"
                ? "bg-brand-600 text-white"
                : "border border-slate-300 bg-white text-slate-700 hover:bg-slate-50"
            }`}
          >
            Transfers
          </button>
          <button
            onClick={() => setTab("overstock")}
            className={`rounded-md px-3 py-2 text-sm font-medium ${
              tab === "overstock"
                ? "bg-brand-600 text-white"
                : "border border-slate-300 bg-white text-slate-700 hover:bg-slate-50"
            }`}
          >
            Overstock Suggestions
          </button>
          {canManage && restockMode === "manual" && (
            <button
              onClick={() => setTab("restock")}
              className={`rounded-md px-3 py-2 text-sm font-medium ${
                tab === "restock"
                  ? "bg-brand-600 text-white"
                  : "border border-slate-300 bg-white text-slate-700 hover:bg-slate-50"
              }`}
            >
              Restock
              {restockCandidates.length > 0 && (
                <span className="ml-1.5 inline-flex h-5 min-w-5 items-center justify-center rounded-full bg-amber-500 px-1.5 text-xs font-semibold text-white">
                  {restockCandidates.length}
                </span>
              )}
            </button>
          )}
        </div>
      </header>

      {tab === "requests" && (
        <section className="space-y-6">
          {canManage && (
            <div className="rounded-lg border border-slate-200 bg-white p-4">
              <h2 className="mb-3 text-lg font-semibold text-slate-900">
                Create Manual Transfer Request
              </h2>
              <form onSubmit={handleCreateManual} className="space-y-3">
                <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
                  <div>
                    <label className="mb-1 block text-sm font-medium text-slate-700">
                      Origin
                    </label>
                    <select
                      value={manualForm.origin_location_id}
                      onChange={(e) => handleOriginChange(e.target.value)}
                      className="w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm"
                    >
                      <option value="">Select origin</option>
                      {stores.map((s) => (
                        <option key={s.id} value={s.id}>
                          {s.name}
                        </option>
                      ))}
                    </select>
                  </div>
                  <div>
                    <label className="mb-1 block text-sm font-medium text-slate-700">
                      Destination
                    </label>
                    <select
                      value={manualForm.destination_location_id}
                      onChange={(e) =>
                        setManualForm((f) => ({
                          ...f,
                          destination_location_id: e.target.value,
                        }))
                      }
                      className="w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm"
                    >
                      <option value="">Select destination</option>
                      {stores.map((s) => (
                        <option key={s.id} value={s.id}>
                          {s.name}
                        </option>
                      ))}
                    </select>
                  </div>
                  <div className="sm:col-span-2">
                    <label className="mb-1 block text-sm font-medium text-slate-700">
                      Product
                    </label>
                    <input
                      type="text"
                      value={manualForm.productQuery}
                      onChange={(e) =>
                        setManualForm((f) => ({
                          ...f,
                          productQuery: e.target.value,
                        }))
                      }
                      placeholder={
                        manualForm.origin_location_id
                          ? "Search products to add"
                          : "Select an origin to see available stock"
                      }
                      className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                    />
                    {productOptions.length > 0 && (
                      <div className="mt-1 max-h-32 overflow-y-auto rounded-md border border-slate-200 bg-white">
                        {productOptions.map((p) => (
                          <button
                            key={p.id}
                            type="button"
                            onClick={() => addToCart(p)}
                            className="flex w-full items-center justify-between px-3 py-2 text-left text-sm hover:bg-slate-50"
                          >
                            <span>{p.item_name}</span>
                            {manualForm.origin_location_id && (
                              <span className="ml-2 shrink-0 text-xs text-slate-500">
                                ATS: {originStock[p.id] ?? 0}
                              </span>
                            )}
                          </button>
                        ))}
                      </div>
                    )}
                  </div>
                </div>
                {manualCart.length > 0 && (
                  <div className="space-y-2 rounded-md border border-slate-200 p-3">
                    {manualCart.map((item) => (
                      <div key={item.variant_id} className="flex items-center gap-3">
                        <div className="flex-1 text-sm text-slate-700">
                          {item.item_name}
                          <span className="ml-2 text-xs text-slate-500">
                            ATS at origin: {item.ats}
                          </span>
                        </div>
                        <input
                          type="number"
                          min={1}
                          placeholder="Qty"
                          value={item.qty}
                          onChange={(e) => setCartQty(item.variant_id, e.target.value)}
                          className="w-24 rounded-md border border-slate-300 px-2 py-1 text-sm"
                        />
                        <button
                          type="button"
                          onClick={() => removeFromCart(item.variant_id)}
                          className="text-xs text-red-700 hover:underline"
                        >
                          Remove
                        </button>
                      </div>
                    ))}
                  </div>
                )}
                <button
                  type="submit"
                  disabled={creating || manualCart.length === 0}
                  className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                >
                  {creating
                    ? "Creating…"
                    : `Create Request${manualCart.length === 1 ? "" : "s"}`}
                </button>
              </form>
            </div>
          )}

          <div className="rounded-lg border border-slate-200 bg-white p-4">
            <div className="mb-3 flex items-center gap-3">
              <h2 className="text-lg font-semibold text-slate-900">Requests</h2>
              <select
                value={requestFilter}
                onChange={(e) => setRequestFilter(e.target.value)}
                className="rounded-md border border-slate-300 bg-white px-2 py-1 text-sm"
              >
                <option value="">All statuses</option>
                <option value="pending_approval">Pending Approval</option>
                <option value="approved">Approved</option>
                <option value="consolidated">Consolidated</option>
                <option value="rejected">Rejected</option>
                <option value="cancelled">Cancelled</option>
              </select>
              <div className="ml-auto flex items-center gap-3">
                <span className="text-xs text-slate-500">
                  Last consolidation run:{" "}
                  {lastConsolidationRun ? relativeTime(lastConsolidationRun) : "never"}
                </span>
                {(employee?.role === "owner" || employee?.role === "admin") && (
                  <button
                    onClick={handleRunConsolidation}
                    disabled={runningConsolidation}
                    className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
                  >
                    {runningConsolidation ? "Running…" : "Run consolidation now"}
                  </button>
                )}
              </div>
            </div>
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="border-b border-slate-200 bg-slate-50 text-left">
                  <tr>
                    <th className="px-3 py-2">Product</th>
                    <th className="px-3 py-2">Qty</th>
                    <th className="px-3 py-2">Origin → Dest</th>
                    <th className="px-3 py-2">Source</th>
                    <th className="px-3 py-2">Status</th>
                    <th className="px-3 py-2"></th>
                  </tr>
                </thead>
                <tbody>
                  {requestRows.map((row) =>
                    row.kind === "single"
                      ? renderRequestRow(row.request)
                      : renderGroupRows(row.groupId, row.members)
                  )}
                  {requestRows.length === 0 && (
                    <tr>
                      <td colSpan={6} className="px-3 py-4 text-center text-slate-500">
                        No transfer requests.
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          </div>
        </section>
      )}

      {tab === "transfers" && (
        <section className="space-y-6">
          <div className="rounded-lg border border-slate-200 bg-white p-4">
            <div className="mb-3 flex items-center gap-3">
              <h2 className="text-lg font-semibold text-slate-900">Transfers</h2>
              <select
                value={transferFilter}
                onChange={(e) => setTransferFilter(e.target.value)}
                className="rounded-md border border-slate-300 bg-white px-2 py-1 text-sm"
              >
                <option value="">All statuses</option>
                <option value="pending">Pending</option>
                <option value="in_transit">In Transit</option>
                <option value="finalized">Finalized</option>
                <option value="cancelled">Cancelled</option>
              </select>
            </div>
            <div className="space-y-4">
              {filteredTransfers.map((t) => (
                <div
                  key={t.id}
                  className="rounded-md border border-slate-200 p-4"
                >
                  <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
                    <div>
                      <p className="font-medium text-slate-900">
                        {t.reference_code && (
                          <span className="mr-2 rounded bg-brand-50 px-1.5 py-0.5 text-xs font-semibold text-brand-700">
                            {t.reference_code}
                          </span>
                        )}
                        {t.origin?.name ?? "?"} → {t.destination?.name ?? "?"}
                      </p>
                      <p className="text-xs text-slate-500">
                        {t.scheduled_date} • {t.status.replace("_", " ")}
                      </p>
                    </div>
                    <div className="flex items-center gap-2">
                      {t.line_items.some((l) => l.reported_at) && (
                        <span className="rounded-full bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-700">
                          Store reported
                        </span>
                      )}
                      {canManage &&
                        t.status === "pending" &&
                        (canApprove ? (
                          <button
                            onClick={() => handleMarkInTransit(t)}
                            className="rounded-md bg-brand-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-700"
                          >
                            Mark in transit
                          </button>
                        ) : (
                          lockedReviewButton(
                            "Mark in transit",
                            "Shipping transfers is restricted to warehouse-based employees. An owner, admin, or warehouse team member needs to mark this in transit."
                          )
                        ))}
                      {canConfirmReceiptFor(t) && (
                        <button
                          onClick={() => openConfirmReceipt(t)}
                          className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50"
                        >
                          Confirm Receipt
                        </button>
                      )}
                      {canManage &&
                        t.status === "in_transit" &&
                        (canApprove ? (
                          <button
                            onClick={() => openFinalize(t)}
                            className="rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-emerald-700"
                          >
                            Finalize
                          </button>
                        ) : (
                          lockedReviewButton(
                            "Finalize",
                            "Finalizing transfers is restricted to warehouse-based employees. An owner, admin, or warehouse team member needs to finalize this transfer."
                          )
                        ))}
                    </div>
                  </div>
                  <table className="w-full text-sm">
                    <thead className="border-b border-slate-200 bg-slate-50 text-left">
                      <tr>
                        <th className="px-2 py-1">Product</th>
                        <th className="px-2 py-1">Requested</th>
                        <th className="px-2 py-1">Shipped</th>
                        <th className="px-2 py-1">Received</th>
                      </tr>
                    </thead>
                    <tbody>
                      {t.line_items.map((line) => (
                        <tr key={line.id} className="border-b border-slate-100">
                          <td className="px-2 py-1">
                            {line.variant?.item_name ?? "Unknown"}
                          </td>
                          <td className="px-2 py-1">{line.quantity_requested}</td>
                          <td className="px-2 py-1">{line.quantity_shipped}</td>
                          <td className="px-2 py-1">{line.quantity_received}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              ))}
              {filteredTransfers.length === 0 && (
                <p className="text-center text-slate-500">No transfers.</p>
              )}
            </div>
          </div>
        </section>
      )}

      {tab === "overstock" && (
        <section className="rounded-lg border border-slate-200 bg-white p-4">
          <h2 className="mb-3 text-lg font-semibold text-slate-900">
            Warehouse Overstock Suggestions
          </h2>
          <p className="mb-4 text-sm text-slate-600">
            These warehouses currently hold more ATS than their target quantity.
            Consider creating a Purchase Order to move excess to another
            warehouse or to a vendor — nothing is auto-created here.
          </p>
          {overstock.length === 0 ? (
            <p className="text-slate-500">No overstock suggestions right now.</p>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="border-b border-slate-200 bg-slate-50 text-left">
                  <tr>
                    <th className="px-3 py-2">Warehouse</th>
                    <th className="px-3 py-2">Product</th>
                    <th className="px-3 py-2">ATS</th>
                    <th className="px-3 py-2">Target</th>
                    <th className="px-3 py-2">Excess</th>
                  </tr>
                </thead>
                <tbody>
                  {overstock.map((s, idx) => (
                    <tr key={idx} className="border-b border-slate-100">
                      <td className="px-3 py-2">{s.store_name}</td>
                      <td className="px-3 py-2">{s.item_name}</td>
                      <td className="px-3 py-2">{s.ats}</td>
                      <td className="px-3 py-2">{s.target_quantity}</td>
                      <td className="px-3 py-2 font-medium text-amber-700">
                        {s.excess}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      )}

      {tab === "restock" && canManage && restockMode === "manual" && (
        <section className="space-y-6">
          <div className="rounded-lg border border-slate-200 bg-white p-4">
            <h2 className="mb-1 text-lg font-semibold text-slate-900">Restock needed</h2>
            <p className="mb-4 text-sm text-slate-600">
              Products at or below their reorder point. Requests are created as
              manager-requested and still require approval.
            </p>
            {restockByStore.size === 0 ? (
              <p className="text-sm text-slate-500">
                No products are below their reorder point right now.
              </p>
            ) : (
              <div className="space-y-6">
                {Array.from(restockByStore.entries()).map(([storeId, group]) => (
                  <div
                    key={storeId}
                    className="rounded-md border border-amber-200 bg-amber-50/60 p-4"
                  >
                    <h3 className="mb-2 text-sm font-semibold text-amber-900">
                      {group[0]?.store_name ?? storeId} — {group.length} product
                      {group.length === 1 ? "" : "s"}
                    </h3>
                    <div className="rounded-md border border-amber-200 bg-white">
                      <div className="grid grid-cols-[28px_minmax(0,1fr)_80px_80px_90px] items-center gap-3 border-b border-slate-200 px-3 py-2 text-xs font-medium text-slate-500">
                        <span></span>
                        <span>Product</span>
                        <span className="text-right">ATS</span>
                        <span className="text-right">Target</span>
                        <span className="text-right">Qty to request</span>
                      </div>
                      {group.map((c) => {
                        const key = restockKey(c.store_id, c.variant_id);
                        return (
                          <div
                            key={key}
                            className="grid grid-cols-[28px_minmax(0,1fr)_80px_80px_90px] items-center gap-3 border-b border-slate-100 px-3 py-2 last:border-b-0"
                          >
                            <input
                              type="checkbox"
                              checked={restockSelected[key] ?? false}
                              onChange={() =>
                                setRestockSelected((prev) => ({
                                  ...prev,
                                  [key]: !prev[key],
                                }))
                              }
                              className="h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500"
                            />
                            <span className="min-w-0 text-sm text-slate-900 break-words pr-2">
                              {c.item_name}
                              {c.sku && (
                                <span className="text-slate-500"> ({c.sku})</span>
                              )}
                            </span>
                            <span className="text-right text-sm text-slate-700">{c.ats}</span>
                            <span className="text-right text-sm text-slate-700">
                              {c.target_quantity}
                            </span>
                            <input
                              type="number"
                              min={1}
                              value={restockQty[key] ?? String(c.suggested)}
                              onChange={(e) =>
                                setRestockQty((prev) => ({
                                  ...prev,
                                  [key]: e.target.value,
                                }))
                              }
                              className="w-full rounded-md border border-slate-300 px-2 py-1 text-right text-sm text-slate-900"
                            />
                          </div>
                        );
                      })}
                    </div>
                    <div className="mt-3 flex flex-wrap items-center gap-3">
                      <label className="text-xs font-medium text-amber-900">From:</label>
                      <select
                        value={restockOriginFor(storeId)}
                        onChange={(e) =>
                          setRestockOrigin((prev) => ({
                            ...prev,
                            [storeId]: e.target.value,
                          }))
                        }
                        className="rounded-md border border-slate-300 bg-white px-2 py-1.5 text-sm"
                      >
                        <option value="">Select origin</option>
                        {stores
                          .filter((s) => s.id !== storeId)
                          .map((s) => (
                            <option key={s.id} value={s.id}>
                              {s.name}
                            </option>
                          ))}
                      </select>
                      <button
                        onClick={() => handleRequestRestock(storeId)}
                        disabled={
                          restockingStore === storeId ||
                          !group.some(
                            (c) => restockSelected[restockKey(c.store_id, c.variant_id)]
                          )
                        }
                        className="rounded-md bg-brand-600 px-4 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                      >
                        {restockingStore === storeId ? "Requesting…" : "Request restock"}
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        </section>
      )}

      {finalizing && (
        <Modal
          onClose={() => setFinalizing(null)}
          dirty={finalizing.line_items.some(
            (l) => (receivedMap[l.id] ?? l.quantity_shipped) !== l.quantity_shipped
          )}
          saving={finalizeSubmitting}
        >
          <div className="max-h-[90vh] w-full max-w-2xl overflow-y-auto rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-4 text-lg font-semibold text-slate-900">
              Finalize Transfer
            </h2>
            <p className="mb-4 text-sm text-slate-600">
              {finalizing.origin?.name} → {finalizing.destination?.name}
            </p>
            <div className="space-y-3">
              {finalizing.line_items.map((line) => (
                <div key={line.id} className="flex items-center gap-3">
                  <div className="flex-1 text-sm text-slate-700">
                    {line.variant?.item_name ?? "Unknown"}
                    {line.reported_at != null && (
                      <div className="mt-0.5 text-xs text-amber-700">
                        Store reported {line.reported_quantity_received} received
                        {line.reported_reason
                          ? ` — ${RECEIPT_REASON_LABELS[line.reported_reason] ?? line.reported_reason}`
                          : ""}
                        {line.reported_note ? ` (${line.reported_note})` : ""}
                        {line.reporter?.name ? ` — ${line.reporter.name}` : ""}
                      </div>
                    )}
                  </div>
                  <div className="text-xs text-slate-500">
                    shipped {line.quantity_shipped}
                  </div>
                  <input
                    type="number"
                    min={0}
                    max={line.quantity_shipped}
                    value={receivedMap[line.id] ?? line.quantity_shipped}
                    onChange={(e) =>
                      setReceivedMap((m) => ({
                        ...m,
                        [line.id]: parseInt(e.target.value || "0", 10),
                      }))
                    }
                    className="w-24 rounded-md border border-slate-300 px-2 py-1 text-sm"
                  />
                </div>
              ))}
            </div>
            <div className="mt-6 flex justify-end gap-2">
              <button
                onClick={() => setFinalizing(null)}
                className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
              <button
                onClick={handleFinalize}
                disabled={finalizeSubmitting}
                className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
              >
                Finalize
              </button>
            </div>
          </div>
        </Modal>
      )}

      {confirming && (
        <Modal
          onClose={() => setConfirming(null)}
          dirty={Object.values(receiptMap).some(
            (e) => e.qty !== "" || e.reason !== "" || e.note !== ""
          )}
          saving={confirmSubmitting}
        >
          <div className="max-h-[90vh] w-full max-w-2xl overflow-y-auto rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-4 text-lg font-semibold text-slate-900">
              Confirm Receipt
            </h2>
            <p className="mb-1 text-sm text-slate-600">
              {confirming.origin?.name} → {confirming.destination?.name}
            </p>
            <p className="mb-4 text-xs text-slate-500">
              Report what actually arrived. This does not move inventory — the
              warehouse finalizes the transfer against the truck.
            </p>
            <div className="space-y-3">
              {confirming.line_items.map((line) => {
                const entry = receiptMap[line.id] ?? { qty: "", reason: "", note: "" };
                const qtyNum = parseInt(entry.qty, 10);
                const short =
                  entry.qty.trim() !== "" &&
                  !Number.isNaN(qtyNum) &&
                  qtyNum < line.quantity_shipped;
                return (
                  <div
                    key={line.id}
                    className="space-y-2 rounded-md border border-slate-200 p-3"
                  >
                    <div className="flex items-center gap-3">
                      <div className="flex-1 text-sm text-slate-700">
                        {line.variant?.item_name ?? "Unknown"}
                      </div>
                      <div className="text-xs text-slate-500">
                        shipped {line.quantity_shipped}
                      </div>
                      <input
                        type="number"
                        min={0}
                        placeholder="Received"
                        value={entry.qty}
                        onChange={(e) =>
                          setReceiptEntry(line.id, { qty: e.target.value })
                        }
                        className="w-24 rounded-md border border-slate-300 px-2 py-1 text-sm"
                      />
                    </div>
                    {short && (
                      <div className="flex flex-wrap items-center gap-2">
                        <select
                          value={entry.reason}
                          onChange={(e) =>
                            setReceiptEntry(line.id, { reason: e.target.value })
                          }
                          className="rounded-md border border-slate-300 bg-white px-2 py-1 text-sm"
                        >
                          <option value="">Reason for shortfall…</option>
                          {Object.entries(RECEIPT_REASON_LABELS).map(([v, label]) => (
                            <option key={v} value={v}>
                              {label}
                            </option>
                          ))}
                        </select>
                        {entry.reason === "other" && (
                          <input
                            value={entry.note}
                            onChange={(e) =>
                              setReceiptEntry(line.id, { note: e.target.value })
                            }
                            placeholder="Describe the issue"
                            className="min-w-0 flex-1 rounded-md border border-slate-300 px-2 py-1 text-sm"
                          />
                        )}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
            <div className="mt-6 flex justify-end gap-2">
              <button
                onClick={() => setConfirming(null)}
                className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
              <button
                onClick={handleConfirmReceipt}
                disabled={confirmSubmitting}
                className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
              >
                {confirmSubmitting ? "Submitting…" : "Submit report"}
              </button>
            </div>
          </div>
        </Modal>
      )}

      {(expeditingId || expeditingGroupId) && (
        <Modal
          onClose={() => {
            setExpeditingId(null);
            setExpeditingGroupId(null);
          }}
          dirty={expediteDate !== localTodayISO()}
          saving={expediteSubmitting}
        >
          <div className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-4 text-lg font-semibold text-slate-900">
              Expedite {expeditingGroupId ? "Request Group" : "Request"}
            </h2>
            <p className="mb-4 text-sm text-slate-600">
              This skips the normal transfer schedule and creates {expeditingGroupId ? "one transfer containing all grouped items" : "the transfer"} for the date you choose below.
            </p>
            <label className="mb-1 block text-sm font-medium text-slate-700">
              Scheduled date
            </label>
            <input
              type="date"
              value={expediteDate}
              min={localTodayISO()}
              onChange={(e) => setExpediteDate(e.target.value)}
              className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
            <div className="mt-6 flex justify-end gap-2">
              <button
                onClick={() => {
                  setExpeditingId(null);
                  setExpeditingGroupId(null);
                }}
                className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
              <button
                onClick={confirmExpedite}
                disabled={!expediteDate || expediteSubmitting}
                className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
              >
                Confirm
              </button>
            </div>
          </div>
        </Modal>
      )}
    </main>
  );
}
