"use client";

import { useEffect, useRef, useState } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type UnitRow = {
  total_count: number;
  unit_id: string;
  unit_number: number;
  status: string;
  product_id: string;
  sku: string | null;
  item_name: string | null;
  location_id: string | null;
  location_name: string | null;
  created_at: string;
  journey_id: string | null;
  journey_number: string | null;
  customer_name: string | null;
};

const STATUSES = [
  "STOCK",
  "RESERVED",
  "IN_TRANSIT",
  "STAGED",
  "DELIVERED",
  "RETURNED",
  "QUARANTINE",
  "DAMAGED",
  "MISSING",
  "VOID",
];

const COLS: { label: string; sort: string }[] = [
  { label: "Unit", sort: "unit_number" },
  { label: "SKU", sort: "sku" },
  { label: "Item", sort: "item_name" },
  { label: "Location", sort: "location" },
  { label: "Status", sort: "status" },
  { label: "Received", sort: "received" },
  { label: "Customer", sort: "customer" },
  { label: "Order", sort: "journey_number" },
];

export default function UnitsList({
  locations,
  statusLabel,
  hidden,
  onOpenUnit,
  onCloseDetail,
}: {
  locations: { id: string; name: string }[];
  statusLabel: Record<string, string>;
  hidden: boolean;
  onOpenUnit: (unitNumber: number) => void;
  onCloseDetail: () => void;
}) {
  const params = useSearchParams();
  const router = useRouter();
  const pathname = usePathname();

  const q = params.get("q") ?? "";
  const rawStatus = params.get("status") ?? "";
  const status = STATUSES.includes(rawStatus) ? rawStatus : "";
  const loc = params.get("loc") ?? "";
  const held = params.get("held") === "1";
  const showVoid = params.get("void") === "1";
  const VALID_SORTS = COLS.map((c) => c.sort);
  const rawSort = params.get("sort") ?? "unit_number";
  const sort = VALID_SORTS.includes(rawSort) ? rawSort : "unit_number";
  const dir = params.get("dir") === "asc" ? "asc" : "desc";
  const page = Math.max(1, Number(params.get("page") ?? "1") || 1);
  const pageSizeRaw = Number(params.get("pageSize") ?? "50") || 50;
  const pageSize = Math.min(100, Math.max(1, pageSizeRaw));

  const [draft, setDraft] = useState(q);
  const [rows, setRows] = useState<UnitRow[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [retryTick, setRetryTick] = useState(0);
  const seq = useRef(0);
  const lastPushedQ = useRef(q);
  const pendingDigitOpen = useRef<number | null>(null);
  const debounceTimer = useRef<number | null>(null);
  const searchRef = useRef<HTMLInputElement>(null);

  function setParams(next: Record<string, string>) {
    if ("q" in next) lastPushedQ.current = next.q;
    const p = new URLSearchParams(params.toString());
    for (const [k, v] of Object.entries(next)) {
      if (v === "" || v === null) p.delete(k);
      else p.set(k, v);
    }
    router.replace(`${pathname}?${p.toString()}`, { scroll: false });
  }

  // Debounced search draft -> URL q, resetting to page 1. The timer
  // lives in a ref so an Enter keypress can cancel it. It only filters:
  // pendingDigitOpen is never touched here, and if the draft already
  // equals the last pushed q there is nothing to do.
  useEffect(() => {
    if (debounceTimer.current != null)
      window.clearTimeout(debounceTimer.current);
    debounceTimer.current = window.setTimeout(() => {
      debounceTimer.current = null;
      if (draft === lastPushedQ.current) return;
      applySearch(false);
    }, 300);
    return () => {
      if (debounceTimer.current != null) {
        window.clearTimeout(debounceTimer.current);
        debounceTimer.current = null;
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [draft]);

  // Only an outside q change (Back/Forward) refills the box; our own
  // pushes never eat keystrokes typed between debounce and apply.
  useEffect(() => {
    if (q !== lastPushedQ.current) {
      lastPushedQ.current = q;
      setDraft(q);
    }
  }, [q]);

  function applySearch(fromEnter: boolean) {
    if (fromEnter) {
      // Cancel a pending debounce so it cannot disarm the opener after
      // Enter has armed it.
      if (debounceTimer.current != null) {
        window.clearTimeout(debounceTimer.current);
        debounceTimer.current = null;
      }
      pendingDigitOpen.current = /^\d+$/.test(draft.trim())
        ? Number(draft.trim())
        : null;
      if (draft === q) {
        // Same search: the URL does not change, so force a refetch.
        setRetryTick((n) => n + 1);
        return;
      }
    }
    // A changed search while a detail is open goes back to the list;
    // an armed digit opener still lands on its unit below.
    if (hidden && draft !== q) onCloseDetail();
    setParams({ q: draft, page: "1" });
  }

  // Warehouse scanners type digits and press Enter.
  useEffect(() => {
    searchRef.current?.focus();
    searchRef.current?.select();
  }, []);
  useEffect(() => {
    if (!hidden) searchRef.current?.focus();
  }, [hidden]);

  useEffect(() => {
    const my = ++seq.current;
    setLoading(true);
    setError(null);
    const s = createClient();
    Promise.resolve(
      s.rpc("list_units", {
        p_search: q || null,
        p_status: status || null,
        p_location_id: loc || null,
        p_held_only: held,
        p_show_void: showVoid,
        p_sort: sort,
        p_dir: dir,
        p_limit: pageSize,
        p_offset: (page - 1) * pageSize,
      })
    ).then(({ data, error: err }) => {
      if (my !== seq.current) return;
      setLoading(false);
      if (err) {
        pendingDigitOpen.current = null;
        setError(err.message);
        return;
      }
      const list = (data ?? []) as UnitRow[];
      setRows(list);
      const t = list.length > 0 ? Number(list[0].total_count) : 0;
      setTotal(t);
      if (pendingDigitOpen.current != null) {
        const hit = list.find(
          (r) => r.unit_number === pendingDigitOpen.current
        );
        pendingDigitOpen.current = null;
        if (hit) {
          onOpenUnit(hit.unit_number);
          searchRef.current?.focus();
          searchRef.current?.select();
        }
      }
      // Offset past the end: return to page 1 once.
      if (list.length === 0 && page > 1) {
        setParams({ page: "1" });
      }
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q, status, loc, held, showVoid, sort, dir, page, pageSize, retryTick]);

  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  const from = total === 0 ? 0 : (page - 1) * pageSize + 1;
  const to = (page - 1) * pageSize + rows.length;

  function clickSort(col: string) {
    if (sort === col) {
      setParams({ dir: dir === "asc" ? "desc" : "asc", page: "1" });
    } else {
      const firstDesc = col === "unit_number" || col === "received";
      setParams({
        sort: col,
        dir: firstDesc ? "desc" : "asc",
        page: "1",
      });
    }
  }

  return (
    <section className="mt-6 max-w-6xl">
      <input
        ref={searchRef}
        value={draft}
        onChange={(e) => {
          const v = e.target.value;
          setDraft(v);
          if (
            pendingDigitOpen.current != null &&
            v.trim() !== String(pendingDigitOpen.current)
          ) {
            pendingDigitOpen.current = null;
          }
        }}
        onFocus={(e) => e.target.select()}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            applySearch(true);
          }
        }}
        placeholder="Search SKU, item name, customer, SJ number, unit number, or unit id"
        className="w-full rounded-md border border-slate-300 px-4 py-2.5 text-sm"
      />

      <div className={hidden ? "hidden" : ""}>
      <div className="mt-3 flex flex-wrap items-center gap-3 text-sm">
        <select
          value={status}
          onChange={(e) => setParams({ status: e.target.value, page: "1" })}
          className="rounded-md border border-slate-300 px-2 py-1.5"
        >
          <option value="">All statuses</option>
          {STATUSES.map((st) => (
            <option key={st} value={st}>
              {statusLabel[st] ?? st}
            </option>
          ))}
        </select>
        <select
          value={loc}
          onChange={(e) => setParams({ loc: e.target.value, page: "1" })}
          className="rounded-md border border-slate-300 px-2 py-1.5"
        >
          <option value="">All locations</option>
          {locations.map((l) => (
            <option key={l.id} value={l.id}>
              {l.name}
            </option>
          ))}
        </select>
        <label className="flex items-center gap-1.5">
          <input
            type="checkbox"
            checked={held}
            onChange={(e) =>
              setParams({ held: e.target.checked ? "1" : "", page: "1" })
            }
          />
          Held for a customer only
        </label>
        <label className="flex items-center gap-1.5">
          <input
            type="checkbox"
            checked={showVoid}
            onChange={(e) =>
              setParams({ void: e.target.checked ? "1" : "", page: "1" })
            }
          />
          Show void
        </label>
      </div>

      {error && (
        <div className="mt-4">
          <p className="text-sm text-red-600">{error}</p>
          <button
            onClick={() => setRetryTick((n) => n + 1)}
            className="mt-2 rounded-md border border-slate-300 px-3 py-1 text-sm"
          >
            Retry
          </button>
        </div>
      )}

      <div
        className={`mt-4 overflow-x-auto ${loading && rows.length > 0 ? "opacity-50" : ""}`}
      >
        <table className="w-full border-collapse text-sm">
          <thead>
            <tr className="border-b text-left text-xs uppercase tracking-wide text-slate-500">
              {COLS.map((c) => (
                <th
                  key={c.sort}
                  aria-sort={
                    sort === c.sort
                      ? dir === "asc"
                        ? "ascending"
                        : "descending"
                      : undefined
                  }
                  className="cursor-pointer select-none px-2 py-2 font-medium hover:text-slate-800"
                  onClick={() => clickSort(c.sort)}
                >
                  {c.label}
                  {sort === c.sort && (
                    <span className="ml-1">{dir === "asc" ? "▲" : "▼"}</span>
                  )}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((u) => (
              <tr
                key={u.unit_id}
                tabIndex={0}
                onClick={() => onOpenUnit(u.unit_number)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") onOpenUnit(u.unit_number);
                }}
                className="cursor-pointer border-b hover:bg-slate-50 focus:bg-slate-100 focus:outline-none"
              >
                <td className="px-2 py-2 font-mono">{u.unit_number}</td>
                <td className="px-2 py-2">{u.sku}</td>
                <td className="px-2 py-2">{u.item_name}</td>
                <td className="px-2 py-2">{u.location_name}</td>
                <td className="px-2 py-2">
                  {statusLabel[u.status] ?? u.status}
                </td>
                <td className="px-2 py-2">
                  {new Date(u.created_at).toLocaleDateString()}
                </td>
                <td className="px-2 py-2">{u.customer_name ?? ""}</td>
                <td className="px-2 py-2 font-mono">
                  {u.journey_number ?? ""}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {!loading && !error && rows.length === 0 && (
          <p className="mt-4 text-sm text-slate-600">
            No units match these filters.
          </p>
        )}
      </div>

      <div className="mt-3 flex items-center gap-3 text-sm text-slate-600">
        <button
          disabled={page <= 1}
          onClick={() => setParams({ page: String(page - 1) })}
          className="rounded-md border border-slate-300 px-3 py-1 disabled:opacity-40"
        >
          Previous
        </button>
        <button
          disabled={page >= totalPages}
          onClick={() => setParams({ page: String(page + 1) })}
          className="rounded-md border border-slate-300 px-3 py-1 disabled:opacity-40"
        >
          Next
        </button>
        <span>
          Showing {from} to {to} of {total}
        </span>
      </div>
      </div>
    </section>
  );
}
