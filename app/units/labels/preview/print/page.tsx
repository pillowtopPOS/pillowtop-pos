"use client";

import { Suspense } from "react";
import { useSearchParams } from "next/navigation";
import {
  CloseButton,
  LABEL_PRINT_CSS,
  UnitLabel,
  type LabelView,
} from "@/lib/units/UnitLabel";

// Throwaway preview route: renders the REAL UnitLabel from fixture params,
// no database calls, no print logging. Route ends in /print so the Sidebar
// renders it bare like the real label page.
function PreviewInner() {
  const params = useSearchParams();
  const kind = params.get("kind") === "customer" ? "customer" : "stock";
  const rotate = params.get("rotate") === "cw" ? "cw" : "ccw";
  const n = parseInt(params.get("number") ?? "", 10);
  const u: LabelView = {
    tag: kind === "customer" ? "CUSTOMER ORDER" : "STOCK",
    unit_number: Number.isNaN(n) ? 22 : n,
    customer_name:
      params.get("name") ?? "Christopher Montgomery-Williams",
    journey_number: params.get("sj") ?? "SJ-MS00119",
    sku: params.get("sku") ?? "HELIX-MID-LUXE-K",
    item_name:
      params.get("item") ?? "Helix Midnight Luxe Mattress King",
    location_name: params.get("loc") ?? "Denver Main Warehouse",
    created_at: params.get("date") ?? new Date().toISOString(),
  };
  return (
    <main>
      <style>{LABEL_PRINT_CSS}</style>
      <div className="no-print mx-auto flex max-w-2xl items-center gap-4 p-4">
        <CloseButton log={{ kind: "idle" }} />
        <span className="text-sm text-slate-600">1 label (preview)</span>
        <button
          onClick={() => window.print()}
          className="rounded bg-brand-600 px-4 py-1.5 text-sm text-white"
        >
          Print
        </button>
      </div>
      <div className="labels">
        <UnitLabel u={u} rotate={rotate} compact={kind === "customer"} />
      </div>
    </main>
  );
}

export default function LabelPreviewPrintPage() {
  return (
    <Suspense>
      <PreviewInner />
    </Suspense>
  );
}
