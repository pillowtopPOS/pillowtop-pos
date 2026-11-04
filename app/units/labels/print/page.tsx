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
function StockLabel({ u, rotate }: { u: LabelUnit; rotate: "cw" | "ccw" }) {
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
          <div className="flex items-start justify-between">
            <span
              className="text-[14px] font-bold"
              style={{
                letterSpacing: "1px",
                border: "2px solid black",
                padding: "3px 10px",
              }}
            >
              STOCK
            </span>
            <span
              className="text-[96px] font-extrabold"
              style={{ lineHeight: 1, letterSpacing: "-1px" }}
            >
              {u.unit_number}
            </span>
          </div>
          <div className="mt-1 text-[20px]">
            <span className="font-bold">Location:</span>{" "}
            {u.location_name ?? "?"}
          </div>
          <div className="mt-0.5 text-[42px] font-extrabold leading-tight">
            {u.sku ?? "?"}
          </div>
          <div className="mt-0.5 text-[20px]">
            <span className="font-bold">Item:</span>{" "}
            {u.item_name ?? "Unknown"}
          </div>
          <div className="mt-auto">
            <Code128Barcode
              value={String(u.unit_number)}
              height="0.85in"
              width="100%"
            />
            <div
              className="mt-1 text-center text-[22px]"
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

function LabelsInner() {
  const params = useSearchParams();
  const [state, setState] = useState<State>({ kind: "loading" });
  const [logNote, setLogNote] = useState<string | null>(null);
  const lastLogAt = useRef(0);
  const unitsRef = useRef<LabelUnit[]>([]);
  const rotate = params.get("rotate") === "cw" ? "cw" : "ccw";

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
            : `Print logged for ${ids.length} label${ids.length === 1 ? "" : "s"}.`
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
              <StockLabel key={u.id} u={u} rotate={rotate} />
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
