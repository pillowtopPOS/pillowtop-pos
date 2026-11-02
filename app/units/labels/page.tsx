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

function StockLabel({ u }: { u: LabelUnit }) {
  return (
    <div
      className="label-sheet relative box-border"
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
          <Code128Barcode value={String(u.unit_number)} height="1in" width="100%" />
          <div className="mt-1 text-center text-[20px]" style={{ letterSpacing: "6px" }}>
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
  const printedRef = useRef<string | null>(null);

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
        if (!cancelled)
          setState({ kind: "ready", units: r.units, missing: r.missing });
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

  useEffect(() => {
    function afterPrint() {
      if (state.kind !== "ready" || state.units.length === 0) return;
      const stamp = `${Date.now()}`;
      if (printedRef.current === stamp) return;
      printedRef.current = stamp;
      const ids = state.units.map((u) => u.id);
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
  }, [state]);

  return (
    <main className="p-4">
      <style>{`
        @page { size: 4in 6in; margin: 0 }
        .label-sheet { page-break-after: always }
        @media print {
          .no-print { display: none !important }
          body { margin: 0 }
        }
      `}</style>
      <div className="no-print mx-auto mb-4 flex max-w-2xl items-center gap-4">
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
        <p className="text-sm text-slate-600">
          Give unit numbers in the address like /units/labels?numbers=1001,1002
          (digits, comma separated, at most 500).
        </p>
      )}
      {state.kind === "failed" && (
        <p className="text-sm text-red-600">{state.message}</p>
      )}
      {state.kind === "loading" && (
        <p className="text-sm text-slate-500">Loading labels...</p>
      )}
      {state.kind === "ready" && (
        <div className="flex flex-wrap gap-4">
          {state.missing.length > 0 && (
            <p className="no-print w-full text-sm text-amber-700">
              No unit found for: {state.missing.join(", ")}
            </p>
          )}
          {state.units.map((u) => (
            <div key={u.id} className="no-print shadow">
              <StockLabel u={u} />
            </div>
          ))}
          {state.units.map((u) => (
            <div key={`print-${u.id}`} className="hidden print:block">
              <StockLabel u={u} />
            </div>
          ))}
        </div>
      )}
    </main>
  );
}

export default function UnitLabelsPage() {
  return (
    <Suspense>
      <LabelsInner />
    </Suspense>
  );
}
