"use client";

import { useEffect, useRef } from "react";
import { Code128Barcode } from "@/lib/units/code128";

export const LABEL_PRINT_CSS = `
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
      `;

export type LabelView = {
  tag: "STOCK" | "CUSTOMER ORDER";
  unit_number: number;
  customer_name?: string | null;
  journey_number?: string | null;
  sku?: string | null;
  item_name?: string | null;
  location_name?: string | null;
  created_at?: string | null;
};

// One layout for both label types. The left column stacks tag, SJ number
// and location under the big unit number so nothing crowds the text below.
// Every block is shrink-0: content that cannot fit must be visible
// overflow, never silently hidden.
// Unit number size by digit count so long numbers never crowd the
// top-left block. 9+ digits clamp at 56px.
function unitNumSize(digits: number): string {
  if (digits <= 4) return "96px";
  if (digits === 5) return "80px";
  if (digits === 6) return "68px";
  return "56px";
}

export function UnitLabel({
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
            <div className="flex min-w-0 flex-1 flex-col pr-2">
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
              {u.tag !== "CUSTOMER ORDER" && (
                <span
                  className="mt-1"
                  style={{ fontSize: compact ? "16px" : "20px" }}
                >
                  <span className="font-bold">Location:</span>{" "}
                  {u.location_name ?? "?"}
                </span>
              )}
            </div>
            <span
              className="shrink-0 font-extrabold"
              style={{
                fontSize: unitNumSize(String(u.unit_number).length),
                lineHeight: 1,
                letterSpacing: "-1px",
              }}
            >
              {u.unit_number}
            </span>
          </div>
          {u.tag === "CUSTOMER ORDER" && (
            <div
              className="shrink-0 font-extrabold leading-tight"
              style={{ fontSize: nameSize }}
            >
              {name ?? u.journey_number ?? "?"}
            </div>
          )}
          {u.tag === "CUSTOMER ORDER" && (
            <div
              className="shrink-0"
              style={{
                borderTop: "2px solid black",
                marginTop: "6px",
                marginBottom: "8px",
              }}
            />
          )}
          {u.item_name && (
            <div
              className={`${compact ? "" : "mt-1.5"} shrink-0 overflow-hidden leading-tight`}
              style={{
                marginTop: compact ? "3px" : undefined,
                fontWeight: u.tag === "CUSTOMER ORDER" ? 600 : 700,
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
              className={`${compact ? "" : "mt-1.5"} shrink-0 whitespace-nowrap leading-tight`}
              style={{ fontSize: skuSize, marginTop: compact ? "3px" : undefined }}
            >
              <span className="font-bold">SKU:</span> {u.sku}
            </div>
          )}
          {u.tag === "CUSTOMER ORDER" && (
            <div className="shrink-0 whitespace-nowrap text-[16px] leading-tight" style={{ marginTop: "3px" }}>
              <span className="font-bold">Location:</span>{" "}
              {u.location_name ?? "?"}
            </div>
          )}
          <div className="mt-auto shrink-0" style={{ paddingTop: "8px" }}>
            <Code128Barcode
              value={String(u.unit_number)}
              height="0.50in"
              moduleWidth={0.02}
            />
            <div
              className="mt-1 text-center text-[20px]"
              style={{ letterSpacing: "6px" }}
            >
              {u.unit_number}
            </div>
          </div>
          {u.created_at &&
            !Number.isNaN(new Date(u.created_at).getTime()) && (
              <span
                style={{
                  position: "absolute",
                  left: "6px",
                  bottom: "4px",
                  fontSize: "12px",
                  fontWeight: 400,
                  lineHeight: 1,
                }}
              >
                Rcvd {new Date(u.created_at).toLocaleDateString("en-US")}
              </span>
            )}
        </div>
      </div>
    </div>
  );
}


export type LogState =
  | { kind: "idle" }
  | { kind: "logging" }
  | { kind: "ok"; count: number }
  | { kind: "failed"; message: string };


export function CloseButton({ log }: { log: LogState }) {
  const ref = useRef<HTMLButtonElement>(null);
  const logRef = useRef(log);
  logRef.current = log;
  // Move focus here when the log finishes so Enter closes the tab.
  useEffect(() => {
    if (log.kind === "ok") ref.current?.focus();
  }, [log.kind]);
  const label =
    log.kind === "logging"
      ? "Finishing..."
      : log.kind === "failed"
        ? "Close anyway"
        : "Close";
  function close() {
    const fallback = () => {
      window.close();
      window.setTimeout(() => {
        window.location.href = "/units";
      }, 300);
    };
    if (logRef.current.kind === "logging") {
      // Wait for the log write to settle before closing, max 8 seconds.
      const start = Date.now();
      const t = window.setInterval(() => {
        if (
          logRef.current.kind !== "logging" ||
          Date.now() - start > 8000
        ) {
          window.clearInterval(t);
          fallback();
        }
      }, 250);
      return;
    }
    fallback();
  }
  return (
    <button
      ref={ref}
      onClick={close}
      className="rounded border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50"
    >
      {label}
    </button>
  );
}

export function PrintLogNote({
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
