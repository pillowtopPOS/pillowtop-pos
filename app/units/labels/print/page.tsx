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

// Route ends in /print so Sidebar renders it bare (Sidebar.tsx checks
// pathname.endsWith("/print")). The layout prints one 4x6 label per page
// with no page margin.
function StockLabel({ u }: { u: LabelUnit }) {
  return (
    <div
      className="label-sheet relative box-border overflow-hidden"
      style={{ width: "4in", height: "6in" }}
    >
      <div
        className="absolute flex flex-col"
        style={{ inset: "0.04in", border: "2px solid black" }}
      >
        <div className="flex items-start justify-between p-1.5">
          <span className="rounded border border-black px-1.5 py-0.5 text-[12px] font-bold">
            STOCK
          </span>
        </div>
        <div className="px-2 text-[96px] font-extrabold leading-none">
          #{u.unit_number}
        </div>
        <div className="mt-1 px-2 text-[19px]">
          Location: {u.location_name ?? "?"}
        </div>
        <div className="mt-1 px-2 text-[38px] font-extrabold leading-tight">
          {u.sku ?? "?"}
        </div>
        <div className="mt-1 px-2 text-[19px]">
          Item: {u.item_name ?? "Unknown"}
        </div>
        {u.description && (
          <div className="mt-0.5 px-2 text-[14px]">{u.description}</div>
        )}
        <div className="mt-auto px-2 pb-2">
          <Code128Barcode
            value={String(u.unit_number)}
            height="1in"
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
  );
}

function LabelsInner() {
  const params = useSearchParams();
  const [state, setState] = useState<State>({ kind: "loading" });
  const [logNote, setLogNote] = useState<string | null>(null);
  const lastLogAt = useRef(0);
  const unitsRef = useRef<LabelUnit[]>([]);

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

  // Registered once. Skips a second afterprint that arrives within 2s of the
  // last log (some browsers fire it twice); every real print still logs.
  useEffect(() => {
    function afterPrint() {
      const now = Date.now();
      if (now - lastLogAt.current < 2000) return;
      if (unitsRef.current.length === 0) return;
      lastLogAt.current = now;
      const ids = unitsRef.current.map((u) => u.id);
      const s = createClient();
      s.rpc("record_unit_labels_printed", {
        p_unit_ids: ids,
        p_label_kind: "stock",
      }).then(({ data, error }) => {
        setLogNote(
          error
            ? `Print log failed: ${error.message}`
            : `Print logged for ${data ?? ids.length} labels.`
        );
      });
    }
    window.addEventListener("afterprint", afterPrint);
    return () => window.removeEventListener("afterprint", afterPrint);
  }, []);

  return (
    <main>
      <style>{`
        @page { size: 4in 6in; margin: 0 }
        .label-sheet { break-after: page; page-break-after: always }
        .labels:last-child .label-sheet:last-child,
        .label-sheet:last-child { break-after: auto; page-break-after: auto }
        @media print {
          html, body { margin: 0; padding: 0; background: #fff }
          .no-print { display: none !important }
          .labels { display: block; gap: 0; padding: 0; margin: 0 }
          .label-sheet { box-shadow: none !important; margin: 0 !important }
        }
        @media screen {
          .labels { display: flex; flex-wrap: wrap; gap: 16px; padding: 16px }
          .label-sheet { box-shadow: 0 1px 4px rgba(0,0,0,.25) }
        }
      `}</style>
      <div className="no-print mx-auto flex max-w-2xl items-center gap-4 p-4">
        <Link href="/units" className="text-sm text-brand-600 hover:underline">
          Back
        </Link>
        {state.kind === "ready" && (
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
        {logNote && <span className="text-xs text-slate-500">{logNote}</span>}
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
              <StockLabel key={u.id} u={u} />
            ))}
          </div>
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
