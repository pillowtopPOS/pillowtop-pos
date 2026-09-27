"use client";

import { useState } from "react";
import { Check } from "lucide-react";
import {
  APPROVE_EXCEPTIONS_KEY,
  APPROVE_OWN_KEY,
  grantKey,
  PERMISSION_ROLES,
  setRolePermission,
  SLEEP_TRIAL_PERMISSIONS,
} from "@/lib/sleepTrial/permissions";

// "Who can do what" grid (spec Section 5.3 Section 8, part 1). Writes
// role_permission_grants — these are company config, not policy fields, so
// they take effect immediately and aren't versioned with the draft.
export default function SleepTrialPermissionsGrid({
  grants,
  canEdit,
  onGrantsChange,
}: {
  grants: Set<string>;
  canEdit: boolean;
  onGrantsChange: (next: Set<string>) => void;
}) {
  const [savingCell, setSavingCell] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  function isGranted(role: string, key: string): boolean {
    // Owner always holds every permission, whether or not a row exists.
    if (role === "owner") return true;
    return grants.has(grantKey(role, key));
  }

  function cellDisabled(role: string, key: string): boolean {
    if (!canEdit || savingCell !== null) return true;
    if (role === "owner") return true;
    // Self-approval has no effect without general approval authority.
    if (key === APPROVE_OWN_KEY && !isGranted(role, APPROVE_EXCEPTIONS_KEY)) {
      return true;
    }
    return false;
  }

  async function toggle(role: string, key: string, granted: boolean) {
    const cell = grantKey(role, key);
    setSavingCell(cell);
    setError(null);

    const next = new Set(grants);
    if (granted) next.add(cell);
    else next.delete(cell);
    // Revoking general approval also strips self-approval: the grant would be
    // inert but the grid would still show it checked.
    const cascade =
      !granted &&
      key === APPROVE_EXCEPTIONS_KEY &&
      next.has(grantKey(role, APPROVE_OWN_KEY));
    if (cascade) next.delete(grantKey(role, APPROVE_OWN_KEY));

    try {
      await setRolePermission(role, key, granted);
      if (cascade) {
        await setRolePermission(role, APPROVE_OWN_KEY, false);
      }
      onGrantsChange(next);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Save failed");
    } finally {
      setSavingCell(null);
    }
  }

  return (
    <div>
      <h3 className="text-base font-semibold text-slate-900">
        Who can do what
      </h3>
      <p className="mt-1 text-sm text-slate-500">
        Changes apply to everyone with that role, immediately. The owner role
        always has every Sleep Trial permission.
        {!canEdit && " Only owners and admins can change these."}
      </p>

      {error && (
        <p className="mt-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
          {error}
        </p>
      )}

      <div className="mt-4 overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-slate-200">
              <th className="py-2 pr-4 text-left font-medium text-slate-600">
                Permission
              </th>
              {PERMISSION_ROLES.map((r) => (
                <th
                  key={r.value}
                  className="px-3 py-2 text-center font-medium text-slate-600"
                >
                  {r.label}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {SLEEP_TRIAL_PERMISSIONS.map((p) => (
              <tr
                key={p.key}
                className="border-b border-slate-100 last:border-0"
              >
                <td className="py-2.5 pr-4 text-slate-700">{p.label}</td>
                {PERMISSION_ROLES.map((r) => {
                  const granted = isGranted(r.value, p.key);
                  const disabled = cellDisabled(r.value, p.key);
                  return (
                    <td key={r.value} className="px-3 py-2.5 text-center">
                      <button
                        type="button"
                        role="checkbox"
                        aria-checked={granted}
                        aria-label={`${p.label} — ${r.label}`}
                        disabled={disabled}
                        onClick={() => toggle(r.value, p.key, !granted)}
                        title={
                          r.value === "owner"
                            ? "Owner always has every permission"
                            : p.key === APPROVE_OWN_KEY &&
                              !isGranted(r.value, APPROVE_EXCEPTIONS_KEY)
                            ? "Requires Approve exceptions"
                            : !canEdit
                            ? "Only owners and admins can change these"
                            : undefined
                        }
                        className={`inline-flex h-5 w-5 items-center justify-center rounded border transition ${
                          granted
                            ? "border-brand-600 bg-brand-600 text-white"
                            : "border-slate-300 bg-white"
                        } ${
                          disabled
                            ? "cursor-not-allowed opacity-50"
                            : "hover:border-brand-500"
                        }`}
                      >
                        {granted && <Check className="h-3.5 w-3.5" />}
                      </button>
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="mt-4 text-xs text-slate-400">
        &ldquo;Approve their own exceptions&rdquo; only takes effect when
        &ldquo;Approve or deny sleep trial exceptions&rdquo; is also checked.
        Employee is a legacy role — it is no longer assignable but is kept for
        existing employees.
      </p>
    </div>
  );
}
