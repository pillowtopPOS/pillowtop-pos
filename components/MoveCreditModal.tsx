"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import Modal from "@/components/Modal";
import { createClient } from "@/lib/supabase/client";

type CreditShareInfo = {
  employee_id: string;
  name: string | null;
  share_bp: number;
};

type CreditMoveInfo = {
  journey_id: string;
  journey_number: string | null;
  shares: CreditShareInfo[];
  units_with_earnings: number;
  net_commission: {
    employee_id: string;
    name: string | null;
    net_cents: number;
  }[];
  employee_options: {
    employee_id: string;
    name: string | null;
  }[];
  missing_cost_units: number;
  can_move: boolean;
  landing_period_start: string | null;
  landing_period_end: string | null;
  landed_later: boolean;
};

type CreditMoveResult = {
  move_id: string;
  moved_units: number;
  skipped_units: number;
  reversed_cents: number;
  credited_cents: number;
  landed_period_start: string;
  landed_later: boolean;
};

type SplitShareRow = {
  employeeId: string;
  percent: string;
};

function pct(bp: number): string {
  return `${parseFloat((bp / 100).toFixed(2))}%`;
}

function shortDate(iso: string | null | undefined): string {
  if (!iso) return "";
  return new Date(`${iso.slice(0, 10)}T00:00:00`).toLocaleDateString(
    undefined,
    { month: "short", day: "numeric", year: "numeric" }
  );
}

export default function MoveCreditModal({
  journeyId,
  orderNumber,
  onClose,
  onSaved,
}: {
  journeyId: string;
  orderNumber: string | null;
  onClose: () => void;
  onSaved: () => void;
}) {
  const supabase = useMemo(() => createClient(), []);
  const closeRef = useRef<(() => void) | null>(null);
  const [info, setInfo] = useState<CreditMoveInfo | null>(null);
  const [employees, setEmployees] = useState<
    { employee_id: string; name: string | null }[]
  >([]);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [mode, setMode] = useState<"one" | "split">("one");
  const [singleEmployeeId, setSingleEmployeeId] = useState("");
  const [splitRows, setSplitRows] = useState<SplitShareRow[]>([
    { employeeId: "", percent: "50" },
    { employeeId: "", percent: "50" },
  ]);
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [result, setResult] = useState<CreditMoveResult | null>(null);
  const [dirty, setDirty] = useState(false);

  useEffect(() => {
    let active = true;
    setLoading(true);
    supabase
      .rpc("get_credit_move_info", { p_journey_id: journeyId })
      .then((infoRes) => {
        if (!active) return;
        if (infoRes.error) {
          setLoadError(infoRes.error.message);
        } else {
          const row = (infoRes.data as CreditMoveInfo | null) ?? null;
          setInfo(row);
          setEmployees(row?.employee_options ?? []);
        }
        setLoading(false);
      });
    return () => {
      active = false;
    };
  }, [journeyId, supabase]);

  const splitValues = splitRows.map((r) => {
    const n = Number(r.percent);
    return {
      employeeId: r.employeeId,
      percent: r.percent !== "" && Number.isFinite(n) ? n : null,
      shareBp:
        r.percent !== "" && Number.isFinite(n) ? Math.round(n * 100) : null,
    };
  });
  const splitTotal = splitValues.reduce(
    (sum, r) => sum + (r.percent ?? 0),
    0
  );
  const splitShareTotal = splitValues.reduce(
    (sum, r) => sum + (r.shareBp ?? 0),
    0
  );
  const splitIds = splitValues
    .map((r) => r.employeeId)
    .filter((id) => id !== "");
  const hasDuplicate = new Set(splitIds).size !== splitIds.length;
  const splitValid =
    splitRows.length >= 2 &&
    splitValues.every(
      (r) =>
        r.employeeId !== "" &&
        r.percent != null &&
        r.percent > 0 &&
        r.shareBp != null &&
        r.shareBp > 0
    ) &&
    splitShareTotal === 10000 &&
    !hasDuplicate;

  const payload =
    mode === "one"
      ? singleEmployeeId
        ? [{ employee_id: singleEmployeeId, share_bp: 10000 }]
        : []
      : splitValues.map((r) => ({
          employee_id: r.employeeId,
          share_bp: r.shareBp ?? 0,
        }));

  const sharesValid = mode === "one" ? singleEmployeeId !== "" : splitValid;
  const canSave =
    info != null &&
    !loading &&
    !saving &&
    result == null &&
    sharesValid &&
    reason.trim() !== "";

  const currentCredit = info?.shares.length
    ? info.shares.map((s) => `${s.name ?? "Unknown"} ${pct(s.share_bp)}`).join(", ")
    : "No current credit";

  const landingText =
    info?.landing_period_start && info?.landing_period_end
      ? `${shortDate(info.landing_period_start)} - ${shortDate(
          info.landing_period_end
        )}`
      : "the current open period";

  async function save() {
    if (!canSave) return;
    setSaving(true);
    setSaveError(null);
    const { data, error } = await supabase.rpc("move_commission_credit", {
      p_journey_id: journeyId,
      p_shares: payload,
      p_reason: reason.trim(),
    });
    setSaving(false);
    if (error) {
      setSaveError(error.message);
      return;
    }
    setResult((data as CreditMoveResult | null) ?? null);
    setDirty(false);
    onSaved();
  }

  return (
    <Modal
      onClose={onClose}
      dirty={dirty && result == null}
      saving={saving}
      closeRequestRef={closeRef}
    >
      <div className="max-h-[90vh] w-full max-w-xl overflow-y-auto rounded-lg bg-white p-4 shadow-xl">
        <div className="mb-3 flex items-start justify-between gap-3">
          <h2 className="text-base font-semibold text-slate-900">
            Move credit for order {orderNumber ?? info?.journey_number ?? ""}
          </h2>
          <button
            type="button"
            onClick={() => (result ? onClose() : closeRef.current?.())}
            className="rounded-md px-2 py-1 text-sm text-slate-500 hover:bg-slate-100"
            aria-label="Close"
          >
            ×
          </button>
        </div>

        {loading ? (
          <p className="py-8 text-center text-sm text-slate-500">Loading…</p>
        ) : loadError ? (
          <p className="rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
            {loadError}
          </p>
        ) : info == null ? (
          <p className="py-8 text-center text-sm text-slate-500">
            Credit information is not available.
          </p>
        ) : (
          <>
            <div className="mb-4 rounded-md bg-slate-50 px-3 py-2 text-sm text-slate-700">
              <span className="font-medium">Current credit:</span>{" "}
              {currentCredit}
            </div>

            <fieldset disabled={saving || result != null}>
              <div className="mb-3 flex gap-4 text-sm text-slate-700">
                <label className="flex items-center gap-2">
                  <input
                    type="radio"
                    checked={mode === "one"}
                    onChange={() => {
                      setMode("one");
                      setDirty(true);
                    }}
                  />
                  One employee
                </label>
                <label className="flex items-center gap-2">
                  <input
                    type="radio"
                    checked={mode === "split"}
                    onChange={() => {
                      setMode("split");
                      setDirty(true);
                    }}
                  />
                  Split between several
                </label>
              </div>

              {mode === "one" ? (
                <label className="mb-4 block text-sm text-slate-600">
                  <span className="mb-1 block text-xs text-slate-500">
                    Employee
                  </span>
                  <select
                    value={singleEmployeeId}
                    onChange={(e) => {
                      setSingleEmployeeId(e.target.value);
                      setDirty(true);
                    }}
                    className="w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                  >
                    <option value="">Choose an employee</option>
                    {employees.map((e) => (
                      <option key={e.employee_id} value={e.employee_id}>
                        {e.name ?? "Unknown"}
                      </option>
                    ))}
                  </select>
                </label>
              ) : (
                <div className="mb-4">
                  <div className="space-y-2">
                    {splitRows.map((row, i) => (
                      <div key={i} className="flex items-center gap-2">
                        <select
                          value={row.employeeId}
                          onChange={(e) => {
                            setSplitRows((rows) =>
                              rows.map((r, j) =>
                                j === i
                                  ? { ...r, employeeId: e.target.value }
                                  : r
                              )
                            );
                            setDirty(true);
                          }}
                          className="min-w-0 flex-1 rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                        >
                          <option value="">Choose an employee</option>
                          {employees.map((emp) => (
                            <option key={emp.employee_id} value={emp.employee_id}>
                              {emp.name ?? "Unknown"}
                            </option>
                          ))}
                        </select>
                        <div className="flex items-center gap-1">
                          <input
                            type="number"
                            min={0}
                            max={100}
                            step={0.01}
                            value={row.percent}
                            onChange={(e) => {
                              setSplitRows((rows) =>
                                rows.map((r, j) =>
                                  j === i
                                    ? { ...r, percent: e.target.value }
                                    : r
                                )
                              );
                              setDirty(true);
                            }}
                            className="w-24 rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                          />
                          <span className="text-sm text-slate-500">%</span>
                        </div>
                        <button
                          type="button"
                          disabled={splitRows.length <= 2}
                          onClick={() => {
                            setSplitRows((rows) =>
                              rows.filter((_, j) => j !== i)
                            );
                            setDirty(true);
                          }}
                          className="text-xs text-slate-500 hover:text-red-600 disabled:opacity-30"
                        >
                          Remove
                        </button>
                      </div>
                    ))}
                  </div>
                  <button
                    type="button"
                    onClick={() => {
                      setSplitRows((rows) => [
                        ...rows,
                        { employeeId: "", percent: "" },
                      ]);
                      setDirty(true);
                    }}
                    className="mt-2 text-sm font-medium text-brand-600 hover:underline"
                  >
                    Add employee
                  </button>
                  <p
                    className={`mt-2 text-sm ${
                      splitShareTotal === 10000
                        ? "text-green-700"
                        : "text-slate-600"
                    }`}
                  >
                    Total: {parseFloat(splitTotal.toFixed(2))}% of 100%
                  </p>
                  {hasDuplicate && (
                    <p className="mt-1 text-sm text-red-700">
                      Do not choose the same employee twice.
                    </p>
                  )}
                </div>
              )}

              <label className="mb-3 block text-sm text-slate-600">
                <span className="mb-1 block text-xs text-slate-500">
                  Reason
                </span>
                <textarea
                  value={reason}
                  maxLength={500}
                  rows={3}
                  onChange={(e) => {
                    setReason(e.target.value);
                    setDirty(true);
                  }}
                  className="w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                />
              </label>
            </fieldset>

            <p className="mb-3 text-xs text-slate-500">
              Lands in the current open pay period ({landingText}). Spiffs
              stay with the original rep.
            </p>

            {saveError && (
              <p className="mb-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
                {saveError}
              </p>
            )}
            {result && (
              <div className="mb-3 rounded-md border border-green-200 bg-green-50 px-3 py-2 text-sm text-green-800">
                <p>Moved {result.moved_units} beds.</p>
                {result.skipped_units > 0 && (
                  <p>
                    {result.skipped_units} beds could not be moved because
                    their commission has not been calculated yet.
                  </p>
                )}
              </div>
            )}

            <div className="flex justify-end gap-2">
              <button
                type="button"
                onClick={() => (result ? onClose() : closeRef.current?.())}
                className="rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50"
              >
                {result ? "Done" : "Cancel"}
              </button>
              {!result && (
                <button
                  type="button"
                  onClick={save}
                  disabled={!canSave}
                  className="rounded-md bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                >
                  {saving ? "Saving…" : "Save"}
                </button>
              )}
            </div>
          </>
        )}
      </div>
    </Modal>
  );
}
