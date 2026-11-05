"use client";

import { Suspense, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { Code128Barcode } from "@/lib/units/code128";
import { fetchUnitsForLabels, type LabelUnit } from "@/lib/units/labels";

type State =
  | { kind: "loading" }
  | { kind: "badparam" }
  | { kind: "failed"; message: string }
  | { kind: "ready"; units: LabelUnit[]; missing: number[] };

// Route ends in /print so Sidebar renders it bare. The design box is
// 6in wide x 4in tall; the printed sheet is 4in x 6in portrait and the
// box is rotated inside it ONLY in print. contain:strict on the sheet is
// required: the 6in-wide box otherwise overflows before rotation and
// Chrome shrinks the whole page to 2/3 size.


// One layout for both label types: tag + big unit number, optional customer
// block, SKU, item, location, barcode with digits. The customer variant
// uses smaller secondary text so everything still fits in the border.
type LabelView = {
  tag: "STOCK" | "CUSTOMER ORDER";
  unit_number: number;
  customer_name?: string | null;
  journey_number?: string | null;
  sku?: string | null;
  item_name?: string | null;
  location_name?: string | null;
};

// One layout for both label types. The left column stacks tag, SJ number
// and location under the big unit number so nothing crowds the text below.
// Every block is shrink-0: content that cannot fit must be visible
// overflow, never silently hidden.
function UnitLabel({
  u,
  rotate,
  compact,
}: {
  u: LabelView;
  rotate: "cw" | "ccw";
  compact: boolean;
}) {
  const name = u.customer_name ?? null;
  const nameSize = !name
    ? "44px"
    : name.length > 30
      ? "24px"
      : name.length > 24
        ? "26px"
        : name.length > 14
          ? "36px"
          : "44px";
  const skuLen = (u.sku ?? "").length;
  const itemLen = (u.item_name ?? "").length;
  // Item name is the big line on both labels; the SKU line under it is
  // smaller, nowrap, and steps down once past 22 characters.
  const itemSize = compact
    ? itemLen > 50
      ? "16px"
      : itemLen > 30
        ? "18px"
        : "22px"
    : itemLen > 40
      ? "24px"
      : itemLen > 20
        ? "30px"
        : "36px";
  const skuSize = skuLen > 22 ? (compact ? "12px" : "14px") : compact ? "16px" : "20px";
  return (
    <div className="sheet">
      <div className={`land ${rotate}`}>
        <div
          className="absolute flex flex-col"
          style={{
            inset: "0.14in",
            border: "2px solid black",
            padding: "0.10in",
          }}
        >
          <div className="flex shrink-0 items-start justify-between">
            <div className="flex flex-col">
              <span
                className="self-start text-[14px] font-bold"
                style={{
                  letterSpacing: "1px",
                  border: "2px solid black",
                  padding: "3px 10px",
                }}
              >
                {u.tag}
              </span>
              {u.tag === "CUSTOMER ORDER" && u.journey_number && (
                <span className="mt-1 font-mono text-[18px]">
                  {u.journey_number}
                </span>
              )}
              <span
                className="mt-1"
                style={{ fontSize: compact ? "16px" : "20px" }}
              >
                <span className="font-bold">Location:</span>{" "}
                {u.location_name ?? "?"}
              </span>
            </div>
            <span
              className="text-[96px] font-extrabold"
              style={{ lineHeight: 1, letterSpacing: "-1px" }}
            >
              {u.unit_number}
            </span>
          </div>
          {u.tag === "CUSTOMER ORDER" && (
            <div
              className="mt-0.5 shrink-0 font-extrabold leading-tight"
              style={{ fontSize: nameSize }}
            >
              {name ?? u.journey_number ?? "?"}
            </div>
          )}
          {u.item_name && (
            <div
              className="mt-0.5 shrink-0 overflow-hidden font-bold leading-tight"
              style={{
                fontSize: itemSize,
                display: "-webkit-box",
                WebkitBoxOrient: "vertical",
                WebkitLineClamp: 2,
              }}
            >
              {u.item_name}
            </div>
          )}
          {u.sku && (
            <div
              className="mt-0.5 shrink-0 whitespace-nowrap leading-tight"
              style={{ fontSize: skuSize }}
            >
              <span className="font-bold">SKU:</span> {u.sku}
            </div>
          )}
          <div className="mt-auto shrink-0">
            <Code128Barcode
              value={String(u.unit_number)}
              height={compact ? "0.65in" : "0.85in"}
              width="100%"
            />
            <div
              className="mt-1 text-center text-[20px]"
              style={{ letterSpacing: "6px" }}
            >
              {u.unit_number}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

type LogState =
  | { kind: "idle" }
  | { kind: "logging" }
  | { kind: "ok"; count: number }
  | { kind: "failed"; message: string };

// The real Edge/Chrome print dialog freezes the page around the afterprint
// event, which kills an in-flight RPC ("The provided callback is no longer
// runnable"). So the log waits for the dialog to release the page, then
// retries twice. A log failure must never block printing or crash the page.
function useLabelPrintLog(getIds: () => string[], kind: "stock" | "customer") {
  const [log, setLog] = useState<LogState>({ kind: "idle" });
  const lastLogAt = useRef(0);
  const pendingIds = useRef<string[]>([]);
  const getIdsRef = useRef(getIds);
  getIdsRef.current = getIds;

  const attempt = (tryIndex: number) => {
    const ids = pendingIds.current;
    const delays = [0, 2000, 5000];
    setLog({ kind: "logging" });
    window.setTimeout(() => {
      const s = createClient();
      Promise.resolve(
        s.rpc("record_unit_labels_printed", {
          p_unit_ids: ids,
          p_label_kind: kind,
        })
      )
        .then(({ error }) => {
          if (error) {
            if (tryIndex < delays.length - 1) {
              attempt(tryIndex + 1);
            } else {
              setLog({ kind: "failed", message: error.message });
            }
          } else {
            setLog({ kind: "ok", count: ids.length });
          }
        })
        .catch((e: unknown) => {
          const msg = e instanceof Error ? e.message : "log failed";
          if (tryIndex < delays.length - 1) {
            attempt(tryIndex + 1);
          } else {
            setLog({ kind: "failed", message: msg });
          }
        });
    }, delays[tryIndex]);
  };

  useEffect(() => {
    function afterPrint() {
      const now = Date.now();
      if (now - lastLogAt.current < 2000) return;
      const ids = getIdsRef.current();
      if (ids.length === 0) return;
      lastLogAt.current = now;
      pendingIds.current = ids;
      // Give the print dialog time to release the page before calling out.
      window.setTimeout(() => attempt(0), 800);
    }
    window.addEventListener("afterprint", afterPrint);
    return () => window.removeEventListener("afterprint", afterPrint);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const retry = () => {
    if (pendingIds.current.length > 0) attempt(0);
  };

  return { log, retry };
}

function PrintLogNote({
  log,
  retry,
}: {
  log: LogState;
  retry: () => void;
}) {
  if (log.kind === "idle") return null;
  if (log.kind === "logging")
    return <span className="text-xs text-slate-500">Logging print...</span>;
  if (log.kind === "ok")
    return (
      <span className="text-xs text-slate-500">
        Print logged for {log.count} label{log.count === 1 ? "" : "s"}.
      </span>
    );
  return (
    <span className="text-xs text-red-600">
      Print log failed: {log.message}{" "}
      <button onClick={retry} className="underline">
        Retry log
      </button>
    </span>
  );
}

// mode=customer: same sheet mechanics, labels from get_unit_customer_labels.
// Returns no UI for unassigned units; logs 'customer' prints the same way.
type CustomerRow = {
  unit_id: string;
  unit_number: number;
  journey_id: string;
  journey_number: string | null;
  customer_name: string | null;
  requirement_id: string;
  sku?: string | null;
  item_name?: string | null;
  location_name?: string | null;
};

function CustomerLabelsInner({ rotate }: { rotate: "cw" | "ccw" }) {
  const params = useSearchParams();
  const [state, setState] = useState<
    | { kind: "loading" }
    | { kind: "badparam" }
    | { kind: "failed"; message: string }
    | { kind: "ready"; rows: CustomerRow[] }
  >({ kind: "loading" });
  const rowsRef = useRef<CustomerRow[]>([]);

  const unitIds = (params.get("units") ?? "")
    .split(",")
    .map((x) => x.trim())
    .filter((x) => /^[0-9a-fA-F-]{36}$/.test(x));

  useEffect(() => {
    let cancelled = false;
    if (unitIds.length === 0 || unitIds.length > 500) {
      setState({ kind: "badparam" });
      return;
    }
    const s = createClient();
    Promise.resolve(
      s.rpc("get_unit_customer_labels", { p_unit_ids: unitIds })
    )
      .then(async ({ data, error }) => {
        if (cancelled) return;
        if (error) {
          setState({ kind: "failed", message: error.message });
          return;
        }
        const rows = (data ?? []) as (CustomerRow & {
          sku?: string | null;
          item_name?: string | null;
          location_name?: string | null;
        })[];
        // One batched lookup adds SKU, item and location to every row.
        // If it fails the labels still print with the customer fields.
        try {
          const det = await fetchUnitsForLabels(
            rows.map((r) => r.unit_number)
          );
          const byNum = new Map(det.units.map((d) => [d.unit_number, d]));
          rows.forEach((r) => {
            const d = byNum.get(r.unit_number);
            r.sku = d?.sku ?? null;
            r.item_name = d?.item_name ?? null;
            r.location_name = d?.location_name ?? null;
          });
        } catch {
          // labels still render without product/location lines
        }
        rowsRef.current = rows;
        setState({ kind: "ready", rows });
      })
      .catch((e: unknown) => {
        if (!cancelled)
          setState({
            kind: "failed",
            message: e instanceof Error ? e.message : "Load failed",
          });
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const { log, retry } = useLabelPrintLog(
    () => rowsRef.current.map((r) => r.unit_id),
    "customer"
  );

  return (
    <>
      <div className="no-print mx-auto flex max-w-2xl items-center gap-4 p-4">
        <Link href="/units" className="text-sm text-brand-600 hover:underline">
          Back
        </Link>
        {state.kind === "ready" && state.rows.length > 0 && (
          <>
            <span className="text-sm text-slate-600">
              {state.rows.length} label{state.rows.length === 1 ? "" : "s"}
            </span>
            <button
              onClick={() => window.print()}
              className="rounded bg-brand-600 px-4 py-1.5 text-sm text-white"
            >
              Print
            </button>
          </>
        )}
        <PrintLogNote log={log} retry={retry} />
      </div>
      {state.kind === "badparam" && (
        <p className="no-print p-4 text-sm text-slate-600">
          Give unit ids in the address like
          /units/labels/print?mode=customer&amp;units=&lt;id&gt;,&lt;id&gt;.
        </p>
      )}
      {state.kind === "failed" && (
        <p className="no-print p-4 text-sm text-red-600">{state.message}</p>
      )}
      {state.kind === "loading" && (
        <p className="no-print p-4 text-sm text-slate-500">Loading labels...</p>
      )}
      {state.kind === "ready" && state.rows.length === 0 && (
        <p className="no-print p-4 text-sm text-slate-600">
          These units are not assigned to a customer order.
        </p>
      )}
      {state.kind === "ready" && state.rows.length > 0 && (
        <div className="labels">
          {state.rows.map((u) => (
            <UnitLabel
              key={u.unit_id}
              u={{
                tag: "CUSTOMER ORDER",
                unit_number: u.unit_number,
                customer_name: u.customer_name,
                journey_number: u.journey_number,
                sku: u.sku,
                item_name: u.item_name,
                location_name: u.location_name,
              }}
              rotate={rotate}
              compact
            />
          ))}
        </div>
      )}
    </>
  );
}

function LabelsInner() {
  const params = useSearchParams();
  const [state, setState] = useState<State>({ kind: "loading" });
  const unitsRef = useRef<LabelUnit[]>([]);
  const rotate = params.get("rotate") === "cw" ? "cw" : "ccw";
  const mode = params.get("mode") === "customer" ? "customer" : "stock";

  const numbers = (params.get("numbers") ?? "")
    .split(",")
    .map((x) => x.trim())
    .filter((x) => x.length > 0)
    .map((x) => (/^\d+$/.test(x) ? Number(x) : NaN));

  useEffect(() => {
    let cancelled = false;
    if (
      numbers.length === 0 ||
      numbers.length > 500 ||
      numbers.some((n) => !Number.isFinite(n))
    ) {
      setState({ kind: "badparam" });
      return;
    }
    fetchUnitsForLabels(numbers)
      .then((r) => {
        if (!cancelled) {
          unitsRef.current = r.units;
          setState({ kind: "ready", units: r.units, missing: r.missing });
        }
      })
      .catch((e) => {
        if (!cancelled)
          setState({ kind: "failed", message: e.message ?? "Load failed" });
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const { log, retry } = useLabelPrintLog(
    () => unitsRef.current.map((u) => u.id),
    "stock"
  );

  return (
    <main>
      <style>{`
        @page { size: 4in 6in; margin: 0 }
        .sheet {
          width: 4in;
          height: 6in;
          position: relative;
          overflow: hidden;
          contain: strict;
          break-after: page;
          page-break-after: always;
        }
        .sheet:last-child { break-after: auto; page-break-after: auto }
        .land {
          position: absolute;
          left: 0;
          top: 0;
          width: 6in;
          height: 4in;
          transform-origin: 0 0;
        }
        @media print {
          html, body { margin: 0; padding: 0; background: #fff }
          .no-print { display: none !important }
          .labels { display: block; gap: 0; padding: 0; margin: 0 }
          .sheet { box-shadow: none !important; margin: 0 !important }
          .land.cw  { transform: translate(4in, 0) rotate(90deg) }
          .land.ccw { transform: translate(0, 6in) rotate(-90deg) }
        }
        @media screen {
          .labels { display: flex; flex-wrap: wrap; gap: 16px; padding: 16px }
          .sheet { width: 6in; height: 4in; box-shadow: 0 1px 4px rgba(0,0,0,.25) }
        }
      `}</style>
      {mode === "customer" ? (
        <CustomerLabelsInner rotate={rotate} />
      ) : (
        <>
      <div className="no-print mx-auto flex max-w-2xl items-center gap-4 p-4">
        <Link href="/units" className="text-sm text-brand-600 hover:underline">
          Back
        </Link>
        {state.kind === "ready" && state.units.length > 0 && (
          <>
            <span className="text-sm text-slate-600">
              {state.units.length} label
              {state.units.length === 1 ? "" : "s"}
            </span>
            <button
              onClick={() => window.print()}
              className="rounded bg-brand-600 px-4 py-1.5 text-sm text-white"
            >
              Print
            </button>
          </>
        )}
        <PrintLogNote log={log} retry={retry} />
      </div>

      {state.kind === "badparam" && (
        <p className="no-print p-4 text-sm text-slate-600">
          Give unit numbers in the address like
          /units/labels/print?numbers=1001,1002 (digits, comma separated, at
          most 500).
        </p>
      )}
      {state.kind === "failed" && (
        <p className="no-print p-4 text-sm text-red-600">{state.message}</p>
      )}
      {state.kind === "loading" && (
        <p className="no-print p-4 text-sm text-slate-500">
          Loading labels...
        </p>
      )}
      {state.kind === "ready" && (
        <>
          {state.missing.length > 0 && (
            <p className="no-print px-4 text-sm text-amber-700">
              No unit found for: {state.missing.join(", ")}
            </p>
          )}
          <div className="labels">
            {state.units.map((u) => (
              <UnitLabel
                key={u.id}
                u={{
                  tag: "STOCK",
                  unit_number: u.unit_number,
                  sku: u.sku,
                  item_name: u.item_name,
                  location_name: u.location_name,
                }}
                rotate={rotate}
                compact={false}
              />
            ))}
          </div>
        </>
      )}
        </>
      )}
    </main>
  );
}

export default function UnitLabelsPrintPage() {
  return (
    <Suspense>
      <LabelsInner />
    </Suspense>
  );
}
