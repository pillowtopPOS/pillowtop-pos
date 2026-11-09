"use client";

import { useEffect, useMemo, useRef, useState } from "react";
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
  fetchBusinessToday,
  runTransferConsolidationNow,
  fetchTransferConsolidationLastRun,
  markTransferInTransit,
  previewTransferUnits,
  pickTransferUnits,
  lookupScannableUnit,
  finalizeTransfer,
  confirmTransferReceipt,
  cancelTransfer,
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
  type ShipPreview,
  type ShipLinePreview,
  type UnitReceiptEntry,
} from "@/lib/transfers/queries";
import {
  requestSourceLabel,
  requestWhyWhen,
} from "@/components/transfers/requestWording";

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

type ShipPickUnit = {
  unit_id: string;
  unit_number: number;
  is_order_bound: boolean;
  status: string;
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

  const [pageError, setPageError] = useState<string | null>(null);
  const [pageNotice, setPageNotice] = useState<string | null>(null);

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
  const [expediteToday, setExpediteToday] = useState("");
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

  const [cancelling, setCancelling] = useState<TransferWithDetails | null>(null);
  const [cancelReason, setCancelReason] = useState("");
  const [cancelError, setCancelError] = useState<string | null>(null);
  const [cancelSubmitting, setCancelSubmitting] = useState(false);

  // Ship modal (S4b-1): unit picks for a pending transfer.
  const [shipping, setShipping] = useState<TransferWithDetails | null>(null);
  const [shipPreview, setShipPreview] = useState<ShipPreview | null>(null);
  const [shipLoading, setShipLoading] = useState(false);
  const [shipError, setShipError] = useState<string | null>(null);
  const [shipPicks, setShipPicks] = useState<
    Record<string, ShipPickUnit[]>
  >({});
  const [shipAutoPick, setShipAutoPick] = useState<Record<string, string[]>>({});
  const [shipScan, setShipScan] = useState("");
  const [shipScanBusy, setShipScanBusy] = useState(false);
  const [shipSubmitting, setShipSubmitting] = useState(false);
  const [confirmRemoveUnit, setConfirmRemoveUnit] = useState<{
    lineId: string;
    unit: ShipPickUnit;
  } | null>(null);
  const shipScanRef = useRef<HTMLInputElement>(null);

  // Receive modal (S4b-2a): finalize with optional unit-level receipts.
  const [receiving, setReceiving] = useState<TransferWithDetails | null>(null);
  const [receiveMap, setReceiveMap] = useState<Record<string, string>>({});
  const [receiveError, setReceiveError] = useState<string | null>(null);
  const [receiveSubmitting, setReceiveSubmitting] = useState(false);
  const [pageWarn, setPageWarn] = useState<string | null>(null);
  const [receiveStep, setReceiveStep] = useState<
    "entry" | "counting" | "review"
  >("entry");
  const [receiveArrived, setReceiveArrived] = useState<
    Record<string, Record<string, true>>
  >({});
  const [receiveScan, setReceiveScan] = useState("");
  const [receiveScanBusy, setReceiveScanBusy] = useState(false);
  const [missingReasons, setMissingReasons] = useState<Record<string, string>>({});
  const [missingConfirmed, setMissingConfirmed] = useState<Record<string, boolean>>({});
  const receiveScanRef = useRef<HTMLInputElement>(null);

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
          setPageError(
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
    setPageNotice(null);
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
    setPageError(null);
    const group = restockByStore.get(storeId) ?? [];
    const selected = group.filter(
      (c) => restockSelected[restockKey(c.store_id, c.variant_id)]
    );
    if (selected.length === 0) return;
    const origin = restockOriginFor(storeId);
    if (!origin) {
      setPageError("Select an origin location for the restock request.");
      return;
    }
    if (origin === storeId) {
      setPageError("Origin and destination must be different locations.");
      return;
    }
    for (const c of selected) {
      const raw = restockQty[restockKey(c.store_id, c.variant_id)] ?? String(c.suggested);
      const qty = parseInt(raw, 10);
      if (!qty || qty <= 0) {
        setPageError(`Enter a valid quantity for ${c.item_name}.`);
        return;
      }
    }

    setRestockingStore(storeId);
    try {
      setPageError(null);
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
      setPageError(
        `${selected.length} restock request${selected.length === 1 ? "" : "s"} created and pending approval.`
      );
      await loadAll();
    } catch (err: any) {
      setPageError(err.message ?? "Failed to create restock requests");
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
    setPageError(null);
    e.preventDefault();
    if (!canManage) return;
    if (!manualForm.origin_location_id || !manualForm.destination_location_id) {
      setPageError("Select an origin and destination");
      return;
    }
    if (manualForm.origin_location_id === manualForm.destination_location_id) {
      setPageError("The origin and destination can't be the same location");
      return;
    }
    if (manualCart.length === 0) {
      setPageError("Add at least one product to the request");
      return;
    }
    const originName =
      stores.find((s) => s.id === manualForm.origin_location_id)?.name ??
      "Origin";
    for (const item of manualCart) {
      const qty = parseInt(item.qty, 10);
      if (item.qty.trim() === "" || Number.isNaN(qty) || qty <= 0) {
        setPageError(`Enter a valid quantity for ${item.item_name}.`);
        return;
      }
      if (qty > item.ats) {
        setPageError(
          `Origin "${originName}" only has ${item.ats} units of "${item.item_name}" available; requested ${qty}.`
        );
        return;
      }
    }
    setCreating(true);
    try {
      setPageError(null);
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
      setPageError(err.message ?? "Failed to create request");
    } finally {
      setCreating(false);
    }
  }

  async function actOnRequest(requestId: string, action: "approve" | "reject" | "cancel") {
    try {
      setPageError(null);
      if (action === "approve") await approveTransferRequest(requestId);
      if (action === "reject") await rejectTransferRequest(requestId);
      if (action === "cancel") await cancelTransferRequest(requestId);
      await loadAll();
    } catch (err: any) {
      setPageError(err.message ?? "Action failed");
    }
  }

  // Manual consolidation run — same daily logic, bypasses the once-per-day
  // guard. Owner/admin only (also enforced by the RPC).
  async function handleRunConsolidation() {
    setRunningConsolidation(true);
    try {
      setPageError(null);
      await runTransferConsolidationNow();
      await loadAll();
    } catch (err: any) {
      setPageError(err.message ?? "Failed to run consolidation");
    } finally {
      setRunningConsolidation(false);
    }
  }

  // Expedite: turn an approved request (or a whole request group) into a
  // shippable transfer for a chosen date, skipping the destination store's
  // schedule day.
  // Prefill with the destination store's business today (m120), not the
  // browser's local date — they disagree every evening.
  function openExpedite(destinationLocationId: string | null, apply: () => void) {
    const fallback = localTodayISO();
    setExpediteDate(fallback);
    setExpediteToday(fallback);
    fetchBusinessToday(destinationLocationId).then((today) => {
      if (today) {
        setExpediteToday(today);
        setExpediteDate((d) => (d === fallback ? today : d));
      }
    });
    apply();
  }

  function handleExpedite(requestId: string) {
    const r = requests.find((x) => x.id === requestId);
    openExpedite(r?.destination_location_id ?? null, () =>
      setExpeditingId(requestId)
    );
  }

  function handleExpediteGroup(groupId: string) {
    const member = requests.find((x) => x.request_group_id === groupId);
    openExpedite(member?.destination_location_id ?? null, () =>
      setExpeditingGroupId(groupId)
    );
  }

  async function confirmExpedite() {
    if (!expediteDate || (!expeditingId && !expeditingGroupId)) return;
    setExpediteSubmitting(true);
    try {
      setPageError(null);
      if (expeditingGroupId) {
        await expediteTransferRequestGroup(expeditingGroupId, expediteDate);
      } else {
        await expediteTransferRequest(expeditingId!, expediteDate);
      }
      setExpeditingId(null);
      setExpeditingGroupId(null);
      await loadAll();
    } catch (err: any) {
      setPageError(err.message ?? "Failed to expedite request");
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
    setPageError(null);
    // Bulk actions only touch still-pending members; anything already
    // approved/rejected/cancelled is skipped and reported as such.
    const eligible = members.filter((m) => m.status === "pending_approval");
    const verb = { approve: "approved", reject: "rejected", cancel: "cancelled" }[action];
    if (eligible.length === 0) {
      setPageError(`All ${members.length} items were already handled; nothing was ${verb}.`);
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
        setPageError(null);
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
      setPageError(parts.join("; ") + ".");
    }
  }

  async function saveQtyEdit(requestId: string) {
    setPageError(null);
    const qty = parseInt(editingQtyValue, 10);
    if (editingQtyValue.trim() === "" || Number.isNaN(qty) || qty <= 0) {
      setPageError("Enter a valid quantity.");
      return;
    }
    try {
      setPageError(null);
      await updateTransferRequestQuantity(requestId, qty);
      setEditingQtyId(null);
      await loadAll();
    } catch (err: any) {
      setPageError(err.message ?? "Failed to update quantity");
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
        <td className="px-3 py-2">
          <div>{requestSourceLabel(r.source_type)}</div>
          <div className="mt-0.5 text-xs text-slate-500">
            {requestWhyWhen({ sourceType: r.source_type, scheduleDay: r.destination?.transfer_schedule_day })}
          </div>
        </td>
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
        <td className="px-3 py-2">
          <div>{requestSourceLabel(members[0].source_type)}</div>
          <div className="mt-0.5 text-xs text-slate-500">
            {requestWhyWhen({ sourceType: members[0].source_type, scheduleDay: members[0].destination?.transfer_schedule_day })}
          </div>
        </td>
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

  // ---- Ship modal (S4b-1) -------------------------------------------------

  async function openShipTransfer(t: TransferWithDetails) {
    setShipping(t);
    setShipPreview(null);
    setShipPicks({});
    setShipAutoPick({});
    setShipScan("");
    setShipError(null);
    setConfirmRemoveUnit(null);
    setShipLoading(true);
    try {
      const preview = await previewTransferUnits(t.id);
      setShipPreview(preview);
      const picks: Record<string, ShipPickUnit[]> = {};
      const auto: Record<string, string[]> = {};
      for (const line of preview.lines) {
        auto[line.line_item_id] = line.auto_pick;
        const byId = new Map(
          line.candidates.map((c) => [c.unit_id, c])
        );
        picks[line.line_item_id] = line.auto_pick
          .map((id) => byId.get(id))
          .filter((c): c is NonNullable<typeof c> => c != null)
          .map((c) => ({
            unit_id: c.unit_id,
            unit_number: c.unit_number,
            is_order_bound: c.is_order_bound,
            status: c.status,
          }));
      }
      setShipPicks(picks);
      setShipAutoPick(auto);
    } catch (err: any) {
      setShipError(err?.message ?? "Failed to load units for this transfer");
    } finally {
      setShipLoading(false);
    }
  }

  // Keep focus on the scan box so a keyboard-wedge scanner always lands here.
  useEffect(() => {
    if (shipping && shipPreview && !shipSubmitting) {
      shipScanRef.current?.focus();
    }
  }, [shipping, shipPreview, shipSubmitting]);

  useEffect(() => {
    if (receiving && receiveStep === "counting" && !receiveSubmitting) {
      receiveScanRef.current?.focus();
    }
  }, [receiving, receiveStep, receiveSubmitting]);

  function shipLineByVariant(variantId: string): ShipLinePreview | undefined {
    return shipPreview?.lines.find((l) => l.variant_id === variantId);
  }

  function candidateFor(
    line: ShipLinePreview,
    unitId: string
  ): ShipLinePreview["candidates"][number] | undefined {
    return line.candidates.find((c) => c.unit_id === unitId);
  }

  // Add a scanned/typed unit to its line. A full line swaps out the
  // highest-numbered plain STOCK pick; order-bound picks are never removed
  // automatically.
  function addOrSwapPick(line: ShipLinePreview, unit: ShipPickUnit) {
    const current = shipPicks[line.line_item_id] ?? [];
    if (current.length < line.quantity_requested) {
      setShipPicks((prev) => ({
        ...prev,
        [line.line_item_id]: [...(prev[line.line_item_id] ?? []), unit],
      }));
      return;
    }
    let victimIdx = -1;
    let victimNum = -1;
    current.forEach((u, i) => {
      if (!u.is_order_bound && u.unit_number > victimNum) {
        victimNum = u.unit_number;
        victimIdx = i;
      }
    });
    if (victimIdx === -1) {
      setShipError("Remove a unit with the × first.");
      return;
    }
    setShipPicks((prev) => {
      const next = [...(prev[line.line_item_id] ?? [])];
      next[victimIdx] = unit;
      return { ...prev, [line.line_item_id]: next };
    });
  }

  async function handleShipScan() {
    const raw = shipScan.trim();
    if (!raw || shipScanBusy || !shipping || !shipPreview) return;
    const n = Number(raw);
    if (!/^\d+$/.test(raw) || !Number.isSafeInteger(n)) {
      setShipError("Enter a unit number.");
      setShipScan("");
      return;
    }
    setShipScan("");
    setShipScanBusy(true);
    setShipError(null);
    try {
      const { unit, openTransferId } = await lookupScannableUnit(n);
      if (!unit) {
        setShipError(`No unit found with number ${n}.`);
        return;
      }
      const already = Object.values(shipPicks).some((list) =>
        list.some((u) => u.unit_id === unit.id)
      );
      if (already) {
        setShipError(`Unit ${n} is already on the list.`);
        return;
      }
      const line = shipLineByVariant(unit.product_id);
      if (!line) {
        setShipError(`Unit ${n} is not on this transfer.`);
        return;
      }
      if (unit.location_id !== shipping.origin_location_id) {
        setShipError(`Unit ${n} is not at the transfer origin`);
        return;
      }
      if (unit.status !== "STOCK" && unit.status !== "RESERVED") {
        setShipError(
          `Unit ${n} is not available (status ${unit.status})`
        );
        return;
      }
      const cand = candidateFor(line, unit.id);
      if (unit.status === "RESERVED" && !cand) {
        setShipError(
          `Unit ${n} is reserved for an order at a different store`
        );
        return;
      }
      if (!cand && openTransferId && openTransferId !== shipping.id) {
        setShipError(`Unit ${n} is already on another shipment`);
        return;
      }
      addOrSwapPick(line, {
        unit_id: unit.id,
        unit_number: unit.unit_number,
        is_order_bound: cand?.is_order_bound ?? false,
        status: unit.status,
      });
    } catch (err: any) {
      setShipError(err?.message ?? "Could not look up that unit");
    } finally {
      setShipScanBusy(false);
      shipScanRef.current?.focus();
    }
  }

  function removeShipPick(lineId: string, unit: ShipPickUnit) {
    setShipPicks((prev) => ({
      ...prev,
      [lineId]: (prev[lineId] ?? []).filter(
        (u) => u.unit_id !== unit.unit_id
      ),
    }));
    setConfirmRemoveUnit(null);
  }

  // Ship is allowed only when every tracked line has exactly its requested
  // count picked. Partial shipping of tracked lines is not supported in
  // this version (pick_transfer_units requires the full count anyway).
  const shipReady =
    shipping != null &&
    shipPreview != null &&
    shipPreview.lines.every(
      (l) => (shipPicks[l.line_item_id]?.length ?? 0) === l.quantity_requested
    );

  const shipDirty = useMemo(() => {
    if (!shipPreview) return false;
    return shipPreview.lines.some((l) => {
      const picked = (shipPicks[l.line_item_id] ?? [])
        .map((u) => u.unit_id)
        .sort();
      const auto = [...(shipAutoPick[l.line_item_id] ?? [])].sort();
      return JSON.stringify(picked) !== JSON.stringify(auto);
    });
  }, [shipPreview, shipPicks, shipAutoPick]);

  async function handleShipTransfer() {
    if (!shipping || !shipPreview || !shipReady) return;
    setShipSubmitting(true);
    setShipError(null);
    try {
      const picks = shipPreview.lines.map((l) => ({
        line_item_id: l.line_item_id,
        unit_ids: (shipPicks[l.line_item_id] ?? []).map((u) => u.unit_id),
      }));
      await pickTransferUnits(shipping.id, picks);
      await markTransferInTransit(shipping.id, undefined, picks);
      const ref = shipping.reference_code ?? "Transfer";
      setShipping(null);
      await loadAll();
      setPageNotice(`${ref} marked in transit.`);
    } catch (err: any) {
      // Soften the raw RPC guard message (048: "committed to other orders
      // at the origin") into something a shipper can act on.
      const raw = err?.message ?? "";
      const msg = /committed to other orders/i.test(raw)
        ? "Some of these units are reserved for open customer orders. Resolve or cancel those orders before shipping."
        : raw || "Failed to mark in transit";
      setShipError(msg);
    } finally {
      setShipSubmitting(false);
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
      setPageError(null);
      await finalizeTransfer(finalizing.id, receivedMap);
      setFinalizing(null);
      await loadAll();
    } catch (err: any) {
      setPageError(err.message ?? "Failed to finalize transfer");
    } finally {
      setFinalizeSubmitting(false);
    }
  }

  function receiveOpenPicks(line: TransferLineItem) {
    return (line.picks ?? []).filter(
      (p) => p.received_at == null && p.missing_at == null
    );
  }

  function receiveHasPicks(t: TransferWithDetails): boolean {
    return t.line_items.some((l) => receiveOpenPicks(l).length > 0);
  }

  function toggleReceiveUnit(lineId: string, unitId: string) {
    setReceiveArrived((prev) => {
      const line = { ...(prev[lineId] ?? {}) };
      if (line[unitId]) delete line[unitId];
      else line[unitId] = true;
      return { ...prev, [lineId]: line };
    });
  }

  async function handleReceiveScan() {
    const raw = receiveScan.trim();
    if (!raw || receiveScanBusy || !receiving) return;
    const n = Number(raw);
    if (!/^\d+$/.test(raw) || !Number.isSafeInteger(n)) {
      setReceiveError("Enter a unit number.");
      setReceiveScan("");
      return;
    }
    setReceiveScan("");
    setReceiveScanBusy(true);
    setReceiveError(null);
    try {
      let found: { line: TransferLineItem; unitId: string } | null = null;
      for (const line of receiving.line_items) {
        for (const p of receiveOpenPicks(line)) {
          if (Number(p.unit_number) === n) {
            found = { line, unitId: p.unit_id };
            break;
          }
        }
        if (found) break;
      }
      if (found) {
        if (receiveArrived[found.line.id]?.[found.unitId]) {
          setReceiveError(`Unit ${n} is already counted.`);
        } else {
          toggleReceiveUnit(found.line.id, found.unitId);
        }
        return;
      }
      const { unit } = await lookupScannableUnit(n);
      if (!unit) {
        setReceiveError(`No unit found with number ${n}.`);
      } else {
        setReceiveError(`Unit ${n} is not on this transfer.`);
      }
    } catch (err: any) {
      setReceiveError(err?.message ?? "Could not look up that unit");
    } finally {
      setReceiveScanBusy(false);
      receiveScanRef.current?.focus();
    }
  }

  // Every not-arrived order-bound unit needs an explicit confirmation
  // before the count can be submitted.
  function receiveMissingConfirmed(line: TransferLineItem): boolean {
    return receiveOpenPicks(line)
      .filter((p) => !receiveArrived[line.id]?.[p.unit_id])
      .every(
        (p) =>
          p.picked_requirement_id == null ||
          missingConfirmed[p.unit_id] === true
      );
  }

  function receiveReviewReady(): boolean {
    if (!receiving) return false;
    return receiving.line_items.every(
      (l) => receiveOpenPicks(l).length === 0 || receiveMissingConfirmed(l)
    );
  }

  async function handleReceiveCountConfirm() {
    if (!receiving) return;
    setReceiveSubmitting(true);
    setReceiveError(null);
    try {
      const received: Record<string, number> = {};
      const receipts: UnitReceiptEntry[] = [];
      for (const line of receiving.line_items) {
        const picks = receiveOpenPicks(line);
        if (picks.length > 0) {
          const arrivedIds = picks
            .filter((p) => receiveArrived[line.id]?.[p.unit_id])
            .map((p) => p.unit_id);
          const missing = picks.filter(
            (p) => !receiveArrived[line.id]?.[p.unit_id]
          );
          received[line.id] = arrivedIds.length;
          const reason = missing
            .map((p) => missingReasons[p.unit_id]?.trim())
            .find((r) => r);
          receipts.push({
            line_item_id: line.id,
            received_unit_ids: arrivedIds,
            missing_unit_ids: missing.map((p) => p.unit_id),
            missing_reason: reason ?? null,
          });
          continue;
        }
        const qty = parseInt(receiveMap[line.id] ?? "", 10);
        if (Number.isNaN(qty) || qty < 0 || qty > line.quantity_shipped) {
          setReceiveError(
            `Enter a received quantity between 0 and ${line.quantity_shipped} for ${line.variant?.item_name ?? "an item"}.`
          );
          return;
        }
        received[line.id] = qty;
      }
      const result = await finalizeTransfer(
        receiving.id,
        received,
        receipts.length > 0 ? receipts : undefined
      );
      const ref = receiving.reference_code ?? "Transfer";
      const unitCount = result.received_unit_ids?.length ?? 0;
      const assignedCount = result.assignments?.length ?? 0;
      const missingNums = (result.missing_units ?? []).map((m) => m.unit_number);
      const destName = receiving.destination?.name ?? "the destination";
      let msg = `${ref} received.`;
      if (unitCount > 0) {
        msg += ` ${unitCount} ${unitCount === 1 ? "unit" : "units"} now at ${destName}.`;
      } else {
        const totalReceived = Object.values(received).reduce(
          (sum, qty) => sum + qty,
          0
        );
        if (totalReceived > 0) {
          msg += ` ${totalReceived} ${totalReceived === 1 ? "unit" : "units"} now at ${destName}.`;
        }
      }
      if (assignedCount > 0) {
        msg += ` ${assignedCount} assigned to a customer order.`;
      }
      if (missingNums.length > 0) {
        msg += ` ${missingNums.length} ${missingNums.length === 1 ? "unit" : "units"} marked missing: ${missingNums.join(", ")}.`;
      }
      setReceiving(null);
      await loadAll();
      setPageError(null);
      setPageWarn(null);
      setPageNotice(msg);
      if (result.assign_failed) {
        setPageWarn(
          `${unitCount} units arrived but could not be assigned to orders. Check the Requests tab.`
        );
      }
    } catch (err: any) {
      setReceiveError(err.message ?? "Failed to receive transfer");
    } finally {
      setReceiveSubmitting(false);
    }
  }

  async function handleReceive() {
    if (!receiving) return;
    setReceiveSubmitting(true);
    setReceiveError(null);
    try {
      const received: Record<string, number> = {};
      for (const line of receiving.line_items) {
        const openPicks = (line.picks ?? []).filter(
          (p) => p.received_at == null && p.missing_at == null
        );
        if (openPicks.length > 0) {
          // Unit-picked line: full count only; the server treats
          // received == shipped with no unit list as "everything arrived".
          received[line.id] = line.quantity_shipped;
          continue;
        }
        const qty = parseInt(receiveMap[line.id] ?? "", 10);
        if (
          Number.isNaN(qty) ||
          qty < 0 ||
          qty > line.quantity_shipped
        ) {
          setReceiveError(
            `Enter a received quantity between 0 and ${line.quantity_shipped} for ${line.variant?.item_name ?? "an item"}.`
          );
          return;
        }
        received[line.id] = qty;
      }
      const result = await finalizeTransfer(receiving.id, received);
      const ref = receiving.reference_code ?? "Transfer";
      const unitCount = result.received_unit_ids?.length ?? 0;
      const assignedCount = result.assignments?.length ?? 0;
      const destName = receiving.destination?.name ?? "the destination";
      let msg = `${ref} received.`;
      if (unitCount > 0) {
        msg += ` ${unitCount} ${unitCount === 1 ? "unit" : "units"} now at ${destName}.`;
      } else {
        const totalReceived = Object.values(received).reduce(
          (sum, qty) => sum + qty,
          0
        );
        if (totalReceived > 0) {
          msg += ` ${totalReceived} ${totalReceived === 1 ? "unit" : "units"} now at ${destName}.`;
        }
      }
      if (assignedCount > 0) {
        msg += ` ${assignedCount} assigned to a customer order.`;
      }
      setReceiving(null);
      await loadAll();
      setPageError(null);
      setPageWarn(null);
      setPageNotice(msg);
      if (result.assign_failed) {
        setPageWarn(
          `${unitCount} units arrived but could not be assigned to orders. Check the Requests tab.`
        );
      }
    } catch (err: any) {
      setReceiveError(err.message ?? "Failed to receive transfer");
    } finally {
      setReceiveSubmitting(false);
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

  // Receive is available to owner/admin always; store destinations to
  // anyone checked in there today; warehouse destinations to
  // warehouse-based staff. Mirrors verify_transfer_receiver (119).
  function canReceiveFor(t: TransferWithDetails): boolean {
    if (t.status !== "in_transit") return false;
    const dest = stores.find((s) => s.id === t.destination_location_id);
    if (!dest) return false;
    if (employee?.role === "owner" || employee?.role === "admin") return true;
    if (dest.location_type === "STORE") {
      return storeConfirmedToday && activeStoreId === t.destination_location_id;
    }
    if (dest.location_type === "WAREHOUSE") return canApprove;
    return false;
  }

  function openReceive(t: TransferWithDetails) {
    const initial: Record<string, string> = {};
    for (const line of t.line_items) {
      initial[line.id] = String(line.quantity_shipped);
    }
    setReceiveMap(initial);
    setReceiveError(null);
    setReceiveStep("entry");
    setReceiveArrived({});
    setReceiveScan("");
    setMissingReasons({});
    setMissingConfirmed({});
    setReceiving(t);
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
    setPageError(null);
    if (!confirming) return;
    const reports: ReceiptLineReport[] = [];
    for (const line of confirming.line_items) {
      if (line.reported_at != null) continue;
      const name = line.variant?.item_name ?? "an item";
      const entry = receiptMap[line.id];
      const qty = entry ? parseInt(entry.qty, 10) : NaN;
      if (!entry || entry.qty.trim() === "" || Number.isNaN(qty) || qty < 0) {
        setPageError(`Enter the quantity received for ${name}.`);
        return;
      }
      let reason: ReceiptLineReport["reason"] = null;
      let note: string | null = null;
      if (qty < line.quantity_shipped) {
        if (!entry.reason) {
          setPageError(`Select a reason for the shortfall on ${name}.`);
          return;
        }
        reason = entry.reason as ReceiptLineReport["reason"];
        if (entry.reason === "other") {
          if (!entry.note.trim()) {
            setPageError(`Add a note describing the issue for ${name}.`);
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
      setPageError(null);
      await confirmTransferReceipt(confirming.id, reports);
      setConfirming(null);
      await loadAll();
    } catch (err: any) {
      setPageError(err.message ?? "Failed to confirm receipt");
    } finally {
      setConfirmSubmitting(false);
    }
  }

  function openCancelTransfer(t: TransferWithDetails) {
    setCancelReason("");
    setCancelError(null);
    setCancelling(t);
  }

  async function handleCancelTransfer() {
    if (!cancelling) return;
    setCancelSubmitting(true);
    setCancelError(null);
    try {
      const res = await cancelTransfer(cancelling.id, cancelReason);
      const ref = cancelling.reference_code ?? "Transfer";
      setCancelling(null);
      await loadAll();
      const parts = [`${ref} cancelled.`];
      if (res.requests_reset > 0) {
        parts.push(
          `${res.requests_reset} request${res.requests_reset === 1 ? "" : "s"} released from this transfer. Check the Requests tab for their current status.`
        );
      }
      if (res.committed_released > 0) {
        parts.push(
          `${res.committed_released} unit${res.committed_released === 1 ? "" : "s"} of held stock freed.`
        );
      }
      setPageNotice(parts.join(" "));
    } catch (err: any) {
      setCancelError(err.message ?? "Failed to cancel transfer");
    } finally {
      setCancelSubmitting(false);
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
      {pageError && (
        <p key="page-error" role="alert" className="mb-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">{pageError}</p>
      )}
      {pageNotice && (
        <p key="page-notice" role="status" className="mb-3 rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-700">{pageNotice}</p>
      )}
      {pageWarn && (
        <p key="page-warn" role="status" className="mb-3 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-800">{pageWarn}</p>
      )}
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
                  Shipments are created automatically on each store&apos;s
                  transfer day. Last created:{" "}
                  {lastConsolidationRun ? relativeTime(lastConsolidationRun) : "never"}
                </span>
                {(employee?.role === "owner" || employee?.role === "admin") && (
                  <button
                    onClick={handleRunConsolidation}
                    disabled={runningConsolidation}
                    className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
                  >
                    {runningConsolidation ? "Creating…" : "Create shipments now"}
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
                      {t.status === "cancelled" &&
                        (t.cancelled_by_name || t.cancel_reason) && (
                          <p className="mt-0.5 text-xs text-slate-500">
                            {t.cancelled_by_name
                              ? `Cancelled by ${t.cancelled_by_name}`
                              : "Cancelled"}
                            {t.cancelled_at
                              ? ` on ${new Date(t.cancelled_at).toLocaleDateString()}`
                              : ""}
                            {t.cancel_reason ? `. Reason: ${t.cancel_reason}` : ""}
                          </p>
                        )}
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
                          <>
                            <button
                              onClick={() => openShipTransfer(t)}
                              className="rounded-md bg-brand-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-700"
                            >
                              Mark in transit
                            </button>
                            <button
                              onClick={() => openCancelTransfer(t)}
                              className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50"
                            >
                              Cancel transfer
                            </button>
                          </>
                        ) : (
                          <>
                            {lockedReviewButton(
                              "Mark in transit",
                              "Shipping transfers is restricted to warehouse-based employees. An owner, admin, or warehouse team member needs to mark this in transit."
                            )}
                            {lockedReviewButton(
                              "Cancel transfer",
                              "Cancelling transfers is restricted to warehouse-based employees. An owner, admin, or warehouse team member needs to cancel this transfer."
                            )}
                          </>
                        ))}
                      {canManage && t.status === "in_transit" && canApprove && (
                        <span className="text-xs text-slate-500">
                          Already shipped. It cannot be cancelled here.
                        </span>
                      )}
                      {canConfirmReceiptFor(t) && (
                        <button
                          onClick={() => openConfirmReceipt(t)}
                          className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50"
                        >
                          Confirm Receipt
                        </button>
                      )}
                      {t.status === "in_transit" &&
                        (canReceiveFor(t) ? (
                          <button
                            onClick={() => openReceive(t)}
                            className="rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-emerald-700"
                          >
                            Receive
                          </button>
                        ) : (
                          stores.find((s) => s.id === t.destination_location_id)
                            ?.location_type === "STORE" && (
                            <span className="text-xs text-slate-500">
                              Check in at{" "}
                              {stores.find(
                                (s) => s.id === t.destination_location_id
                              )?.name ?? "the store"}{" "}
                              to receive this transfer.
                            </span>
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

      {shipping && (
        <Modal
          onClose={() => setShipping(null)}
          dirty={shipDirty}
          saving={shipSubmitting || shipLoading}
        >
          <div className="max-h-[90vh] w-full max-w-2xl overflow-y-auto rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-1 text-lg font-semibold text-slate-900">
              Ship {shipping.reference_code ?? "transfer"}
            </h2>
            <p className="mb-3 text-sm text-slate-600">
              {shipping.origin?.name} → {shipping.destination?.name}
            </p>
            <p className="mb-3 text-xs text-slate-500">
              Scan or type a unit number and press Enter to add it. A full
              line swaps out its highest-numbered plain unit.
            </p>
            {shipError && (
              <p role="alert" className="mb-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">{shipError}</p>
            )}
            <input
              ref={shipScanRef}
              value={shipScan}
              onChange={(e) => setShipScan(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  handleShipScan();
                }
              }}
              placeholder="Scan or type a unit number"
              className="mb-4 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
            {shipLoading ? (
              <p className="text-sm text-slate-500">Loading units…</p>
            ) : (
              shipPreview && (
                <div className="space-y-3">
                  {shipping.line_items.map((line) => {
                    const previewLine = shipPreview.lines.find(
                      (l) => l.line_item_id === line.id
                    );
                    const picked = shipPicks[line.id] ?? [];
                    const remaining = previewLine
                      ? previewLine.candidates.filter(
                          (c) => !picked.some((p) => p.unit_id === c.unit_id)
                        ).length
                      : 0;
                    const canNeverFill =
                      previewLine != null &&
                      picked.length + remaining < previewLine.quantity_requested;
                    return (
                      <div
                        key={line.id}
                        className="rounded-md border border-slate-200 p-3"
                      >
                        <div className="flex items-center justify-between gap-3">
                          <div className="text-sm font-medium text-slate-800">
                            {line.variant?.item_name ?? "Unknown"}
                          </div>
                          {previewLine ? (
                            <div
                              className={`text-xs font-medium ${
                                picked.length === previewLine.quantity_requested
                                  ? "text-emerald-700"
                                  : "text-amber-700"
                              }`}
                            >
                              {picked.length} of {previewLine.quantity_requested}{" "}
                              picked
                            </div>
                          ) : (
                            <div className="text-xs text-slate-500">
                              Requested {line.quantity_requested}
                            </div>
                          )}
                        </div>
                        {!previewLine && (
                          <p className="mt-1 text-xs text-slate-500">
                            Not unit tracked. Ships as a quantity.
                          </p>
                        )}
                        {previewLine && (
                          <>
                            {picked.length === 0 && (
                              <p className="mt-2 text-xs text-slate-400">
                                No units picked.
                              </p>
                            )}
                            {picked.length > 0 && (
                              <div className="mt-2 flex flex-wrap gap-1.5">
                                {picked.map((u) => {
                                  const confirming =
                                    confirmRemoveUnit?.unit.unit_id ===
                                    u.unit_id;
                                  return (
                                    <span
                                      key={u.unit_id}
                                      className="inline-flex items-center gap-1 rounded bg-slate-100 px-2 py-0.5 text-xs text-slate-700"
                                    >
                                      {u.unit_number}
                                      {u.is_order_bound && (
                                        <span className="rounded bg-amber-100 px-1 text-[10px] font-medium text-amber-800">
                                          customer order
                                        </span>
                                      )}
                                      {confirming ? (
                                        <span className="ml-1 inline-flex items-center gap-1">
                                          <span className="text-[10px] text-slate-500">
                                            promised to a customer order.
                                            Remove anyway?
                                          </span>
                                          <button
                                            type="button"
                                            onClick={() =>
                                              removeShipPick(line.id, u)
                                            }
                                            className="font-medium text-red-600 hover:underline"
                                          >
                                            Remove
                                          </button>
                                          <button
                                            type="button"
                                            onClick={() =>
                                              setConfirmRemoveUnit(null)
                                            }
                                            className="font-medium text-slate-500 hover:underline"
                                          >
                                            Keep
                                          </button>
                                        </span>
                                      ) : (
                                        <button
                                          type="button"
                                          aria-label={`Remove unit ${u.unit_number}`}
                                          onClick={() => {
                                            if (u.is_order_bound) {
                                              setConfirmRemoveUnit({
                                                lineId: line.id,
                                                unit: u,
                                              });
                                            } else {
                                              removeShipPick(line.id, u);
                                            }
                                          }}
                                          className="ml-0.5 text-slate-400 hover:text-slate-700"
                                        >
                                          ×
                                        </button>
                                      )}
                                    </span>
                                  );
                                })}
                              </div>
                            )}
                            {canNeverFill && (
                              <p className="mt-2 text-xs text-red-600">
                                Only {picked.length + remaining} units are
                                available at the origin for this line.
                              </p>
                            )}
                          </>
                        )}
                      </div>
                    );
                  })}
                </div>
              )
            )}
            <div className="mt-6 flex justify-end gap-2">
              <button
                onClick={() => setShipping(null)}
                className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Keep transfer
              </button>
              <button
                onClick={handleShipTransfer}
                disabled={!shipReady || shipSubmitting || shipLoading}
                className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
              >
                {shipSubmitting ? "Shipping…" : "Ship transfer"}
              </button>
            </div>
          </div>
        </Modal>
      )}

      {receiving && (
        <Modal
          onClose={() => setReceiving(null)}
          dirty={
            receiveStep !== "entry" ||
            Object.keys(receiveArrived).length > 0 ||
            receiving.line_items.some(
              (l) =>
                (receiveMap[l.id] ?? String(l.quantity_shipped)) !==
                String(l.quantity_shipped)
            )
          }
          saving={receiveSubmitting}
        >
          <div className="max-h-[90vh] w-full max-w-2xl overflow-y-auto rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-4 text-lg font-semibold text-slate-900">
              Receive {receiving.reference_code ?? "Transfer"}
            </h2>
            <p className="mb-1 text-sm text-slate-600">
              {receiving.origin?.name} → {receiving.destination?.name}
            </p>
            {receiveError && (
              <p role="alert" className="mb-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
                {receiveError}
              </p>
            )}

            {receiveStep === "entry" && (
              <>
                <div className="space-y-3">
                  {receiving.line_items.map((line) => {
                    const openPicks = receiveOpenPicks(line);
                    const hasPicks = openPicks.length > 0;
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
                          {!hasPicks && (
                            <input
                              type="number"
                              min={0}
                              max={line.quantity_shipped}
                              value={
                                receiveMap[line.id] ??
                                String(line.quantity_shipped)
                              }
                              onChange={(e) =>
                                setReceiveMap((m) => ({
                                  ...m,
                                  [line.id]: e.target.value,
                                }))
                              }
                              className="w-24 rounded-md border border-slate-300 px-2 py-1 text-sm"
                            />
                          )}
                        </div>
                        {hasPicks && (
                          <div className="flex flex-wrap gap-1.5">
                            {openPicks.map((p) => (
                              <span
                                key={p.unit_id}
                                className="rounded-full border border-slate-300 bg-slate-50 px-2 py-0.5 text-xs text-slate-700"
                              >
                                #{p.unit_number}
                              </span>
                            ))}
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>
                <div className="mt-6 flex justify-end gap-2">
                  <button
                    onClick={() => setReceiving(null)}
                    className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                  >
                    Cancel
                  </button>
                  {receiveHasPicks(receiving) && (
                    <button
                      onClick={() => { setReceiveError(null); setReceiveStep("counting"); }}
                      className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                    >
                      Count the units
                    </button>
                  )}
                  <button
                    onClick={handleReceive}
                    disabled={receiveSubmitting}
                    className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
                  >
                    {receiveSubmitting
                      ? "Receiving…"
                      : receiveHasPicks(receiving)
                        ? "Everything arrived"
                        : "Receive"}
                  </button>
                </div>
              </>
            )}

            {receiveStep === "counting" && (
              <>
                <p className="mb-2 text-xs text-slate-500">
                  Scan or type a unit number and press Enter to mark it arrived.
                  Click a unit to toggle it.
                </p>
                <input
                  ref={receiveScanRef}
                  value={receiveScan}
                  onChange={(e) => setReceiveScan(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") {
                      e.preventDefault();
                      handleReceiveScan();
                    }
                  }}
                  placeholder="Scan or type a unit number"
                  className="mb-4 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                />
                <div className="space-y-3">
                  {receiving.line_items.map((line) => {
                    const openPicks = receiveOpenPicks(line);
                    if (openPicks.length === 0) {
                      return (
                        <div
                          key={line.id}
                          className="flex items-center gap-3 rounded-md border border-slate-200 p-3"
                        >
                          <div className="flex-1 text-sm text-slate-700">
                            {line.variant?.item_name ?? "Unknown"}
                          </div>
                          <div className="text-xs text-slate-500">
                            shipped {line.quantity_shipped}
                          </div>
                          <input
                            type="number"
                            min={0}
                            max={line.quantity_shipped}
                            value={
                              receiveMap[line.id] ??
                              String(line.quantity_shipped)
                            }
                            onChange={(e) =>
                              setReceiveMap((m) => ({
                                ...m,
                                [line.id]: e.target.value,
                              }))
                            }
                            className="w-24 rounded-md border border-slate-300 px-2 py-1 text-sm"
                          />
                        </div>
                      );
                    }
                    const arrivedCount = openPicks.filter(
                      (p) => receiveArrived[line.id]?.[p.unit_id]
                    ).length;
                    return (
                      <div
                        key={line.id}
                        className="rounded-md border border-slate-200 p-3"
                      >
                        <div className="mb-2 flex items-center gap-3">
                          <div className="flex-1 text-sm text-slate-700">
                            {line.variant?.item_name ?? "Unknown"}
                          </div>
                          <div className="text-xs text-slate-500">
                            {arrivedCount} of {openPicks.length} arrived
                          </div>
                        </div>
                        <div className="space-y-1">
                          {openPicks.map((p) => {
                            const arrived =
                              receiveArrived[line.id]?.[p.unit_id] === true;
                            return (
                              <button
                                key={p.unit_id}
                                type="button"
                                onClick={() =>
                                  toggleReceiveUnit(line.id, p.unit_id)
                                }
                                className={`flex w-full items-center justify-between rounded-md border px-3 py-1.5 text-sm ${
                                  arrived
                                    ? "border-emerald-300 bg-emerald-50 text-emerald-800"
                                    : "border-slate-200 bg-white text-slate-600 hover:bg-slate-50"
                                }`}
                              >
                                <span>#{p.unit_number}</span>
                                <span className="text-xs">
                                  {arrived ? "Arrived" : "Not counted"}
                                </span>
                              </button>
                            );
                          })}
                        </div>
                      </div>
                    );
                  })}
                </div>
                <div className="mt-6 flex justify-end gap-2">
                  <button
                    onClick={() => { setReceiveError(null); setReceiveStep("entry"); }}
                    className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                  >
                    Back
                  </button>
                  <button
                    onClick={() => { setReceiveError(null); setReceiveStep("review"); }}
                    className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700"
                  >
                    Review count
                  </button>
                </div>
              </>
            )}

            {receiveStep === "review" && (
              <>
                {(() => {
                  const arrived: {
                    line: TransferLineItem;
                    pick: NonNullable<TransferLineItem["picks"]>[number];
                  }[] = [];
                  const missing: typeof arrived = [];
                  for (const line of receiving.line_items) {
                    for (const p of receiveOpenPicks(line)) {
                      const entry = { line, pick: p };
                      if (receiveArrived[line.id]?.[p.unit_id]) {
                        arrived.push(entry);
                      } else {
                        missing.push(entry);
                      }
                    }
                  }
                  const untracked = receiving.line_items.filter(
                    (l) => receiveOpenPicks(l).length === 0
                  );
                  return (
                    <div className="space-y-4">
                      <div>
                        <h3 className="mb-2 text-sm font-semibold text-slate-800">
                          Arrived ({arrived.length})
                        </h3>
                        {arrived.length === 0 ? (
                          <p className="text-sm text-slate-500">
                            No units counted as arrived.
                          </p>
                        ) : (
                          <ul className="space-y-1">
                            {arrived.map(({ line, pick }) => (
                              <li
                                key={pick.unit_id}
                                className="flex items-center gap-2 text-sm text-slate-700"
                              >
                                <span className="rounded-full bg-emerald-100 px-2 py-0.5 text-xs text-emerald-800">
                                  #{pick.unit_number}
                                </span>
                                {line.variant?.item_name ?? "Unknown"}
                              </li>
                            ))}
                          </ul>
                        )}
                      </div>
                      <div>
                        <h3 className="mb-2 text-sm font-semibold text-slate-800">
                          Did not arrive ({missing.length})
                        </h3>
                        {missing.length === 0 ? (
                          <p className="text-sm text-slate-500">
                            Every shipped unit was counted.
                          </p>
                        ) : (
                          <ul className="space-y-2">
                            {missing.map(({ line, pick }) => {
                              const orderBound =
                                pick.picked_requirement_id != null;
                              const confirmed =
                                missingConfirmed[pick.unit_id] === true;
                              return (
                                <li
                                  key={pick.unit_id}
                                  className="rounded-md border border-amber-200 bg-amber-50 p-3"
                                >
                                  <div className="flex items-center gap-2 text-sm text-slate-800">
                                    <span className="rounded-full border border-slate-300 bg-white px-2 py-0.5 text-xs text-slate-700">
                                      #{pick.unit_number}
                                    </span>
                                    {line.variant?.item_name ?? "Unknown"}
                                    {orderBound && (
                                      <span className="rounded-full bg-sky-100 px-2 py-0.5 text-xs text-sky-800">
                                        customer order
                                      </span>
                                    )}
                                  </div>
                                  <input
                                    type="text"
                                    value={missingReasons[pick.unit_id] ?? ""}
                                    onChange={(e) =>
                                      setMissingReasons((m) => ({
                                        ...m,
                                        [pick.unit_id]: e.target.value,
                                      }))
                                    }
                                    placeholder="Reason (optional)"
                                    className="mt-2 w-full rounded-md border border-slate-300 px-2 py-1 text-sm"
                                  />
                                  {orderBound && (
                                    <label className="mt-2 flex items-start gap-2 text-xs text-slate-700">
                                      <input
                                        type="checkbox"
                                        checked={confirmed}
                                        onChange={(e) =>
                                          setMissingConfirmed((m) => ({
                                            ...m,
                                            [pick.unit_id]: e.target.checked,
                                          }))
                                        }
                                        className="mt-0.5"
                                      />
                                      <span>
                                        Unit {pick.unit_number} is reserved for
                                        an order. I confirm it is missing.
                                      </span>
                                    </label>
                                  )}
                                </li>
                              );
                            })}
                          </ul>
                        )}
                      </div>
                      {untracked.length > 0 && (
                        <div>
                          <h3 className="mb-2 text-sm font-semibold text-slate-800">
                            Quantity lines
                          </h3>
                          <ul className="space-y-1 text-sm text-slate-700">
                            {untracked.map((l) => (
                              <li key={l.id}>
                                {l.variant?.item_name ?? "Unknown"}: received{" "}
                                {receiveMap[l.id] ?? l.quantity_shipped} of{" "}
                                {l.quantity_shipped}
                              </li>
                            ))}
                          </ul>
                        </div>
                      )}
                    </div>
                  );
                })()}
                <div className="mt-6 flex justify-end gap-2">
                  <button
                    onClick={() => { setReceiveError(null); setReceiveStep("counting"); }}
                    className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                  >
                    Back to counting
                  </button>
                  <button
                    onClick={handleReceiveCountConfirm}
                    disabled={receiveSubmitting || !receiveReviewReady()}
                    className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
                  >
                    {receiveSubmitting ? "Receiving…" : "Confirm and receive"}
                  </button>
                </div>
              </>
            )}
          </div>
        </Modal>
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
            {pageError && (
              <p role="alert" className="mb-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">{pageError}</p>
            )}
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
                disabled={confirmSubmitting ||
                  confirming.line_items.every((l) => l.reported_at != null)}
                className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
              >
                {confirmSubmitting ? "Submitting…" : "Submit report"}
              </button>
            </div>
          </div>
        </Modal>
      )}

      {cancelling && (
        <Modal
          onClose={() => setCancelling(null)}
          dirty={cancelReason.trim() !== ""}
          saving={cancelSubmitting}
        >
          <div className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            {cancelError && (
              <p role="alert" className="mb-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">{cancelError}</p>
            )}
            <h2 className="mb-4 text-lg font-semibold text-slate-900">
              Cancel {cancelling.reference_code ?? "transfer"}?
            </h2>
            <p className="mb-4 text-sm text-slate-600">
              This frees the stock held at {cancelling.origin?.name ?? "the origin"}.
              Requests on this transfer are released so they can be sent
              again. Requests for orders that were already cancelled are
              closed. Nothing has shipped.
            </p>
            <label className="mb-1 block text-sm font-medium text-slate-700">
              Reason (optional)
            </label>
            <textarea
              value={cancelReason}
              onChange={(e) => setCancelReason(e.target.value)}
              rows={2}
              placeholder="Why is this transfer being cancelled?"
              className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
            <div className="mt-6 flex justify-end gap-2">
              <button
                onClick={() => setCancelling(null)}
                className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Keep transfer
              </button>
              <button
                onClick={handleCancelTransfer}
                disabled={cancelSubmitting}
                className="rounded-md bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
              >
                {cancelSubmitting ? "Cancelling…" : "Cancel transfer"}
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
          dirty={expediteDate !== (expediteToday || localTodayISO())}
          saving={expediteSubmitting}
        >
          <div className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
                  {pageError && (
                    <p key="modal-error" role="alert" className="mb-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">{pageError}</p>
                  )}
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
              min={expediteToday || localTodayISO()}
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
