import { createClient } from "@/lib/supabase/client";

// Mirrors migrations 066/084/085 and spec Section 27. Keep order stable:
// this is the row order of the "Who can do what" grid.
export const SLEEP_TRIAL_PERMISSIONS: {
  key: string;
  label: string;
  description?: string;
}[] = [
  {
    key: "sleep_trial.manage_concerns",
    label: "Log and update sleep concerns",
  },
  {
    key: "sleep_trial.start_exchange",
    label: "Start exchanges within policy",
  },
  {
    key: "sleep_trial.start_return",
    label: "Start returns within policy",
  },
  {
    key: "sleep_trial.request_exceptions",
    label: "Request sleep trial exceptions",
  },
  {
    key: "sleep_trial.approve_exceptions",
    label:
      "Approve or deny sleep trial exceptions (incl. fee waivers, extensions)",
  },
  {
    key: "sleep_trial.approve_own_exceptions",
    label: "Approve their own exceptions",
  },
  {
    key: "sleep_trial.override_protector",
    label: "Override the protector requirement",
  },
  {
    key: "sleep_trial.correct_dates",
    label: "Correct trial start dates",
  },
  {
    key: "sleep_trial.manage_policy",
    label: "Edit and publish sleep trial policy",
  },
  {
    key: "sleep_trial.view_policy_details",
    label: "See policy source details and financial impact",
  },
  {
    key: "inventory.reduce_below_committed",
    label: "Reduce stock below committed reservations",
    description:
      "Confirm lowering on-hand below what open journeys have reserved; the newest reservations are released and their journeys move back to Waiting for Inventory.",
  },
];

export const APPROVE_EXCEPTIONS_KEY = "sleep_trial.approve_exceptions";
export const APPROVE_OWN_KEY = "sleep_trial.approve_own_exceptions";

// All employee_role enum values. 'employee' is a legacy unassignable role but
// existing employees may still hold it, so it keeps a column.
export const PERMISSION_ROLES = [
  { value: "owner", label: "Owner" },
  { value: "admin", label: "Admin" },
  { value: "manager", label: "Manager" },
  { value: "sales", label: "Sales" },
  { value: "employee", label: "Employee" },
];

export function grantKey(role: string, permissionKey: string) {
  return `${role}:${permissionKey}`;
}

// Returns null when the role_permission_grants table isn't there yet
// (migration 066 not applied) so callers can show an install notice instead of
// an empty grid.
export async function fetchRolePermissionGrants(): Promise<Set<string> | null> {
  const supabase = createClient();
  const { data, error } = await (supabase as any)
    .from("role_permission_grants")
    .select("role, permission_key");

  if (error) {
    console.error("fetchRolePermissionGrants error", error);
    return null;
  }

  return new Set(
    ((data ?? []) as { role: string; permission_key: string }[]).map((r) =>
      grantKey(r.role, r.permission_key)
    )
  );
}

export async function setRolePermission(
  role: string,
  permissionKey: string,
  granted: boolean
): Promise<void> {
  const supabase = createClient();
  const { error } = await (supabase as any).rpc("set_role_permission", {
    p_role: role,
    p_key: permissionKey,
    p_granted: granted,
  });
  if (error) throw new Error(error.message);
}
