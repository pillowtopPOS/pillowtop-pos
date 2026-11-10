import { createClient } from "@/lib/supabase/client";

// Mirrors migration 066 and spec Section 27. Keep order stable: this is the
// row order of the "Who can do what" grid. inventory.reduce_below_committed
// is deliberately absent — it lives in Company Settings, not Sleep Trial.
export const SLEEP_TRIAL_PERMISSIONS = [
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

export type PermissionGroup = "Sleep trial" | "Inventory" | "Unit ID" | "Delivery";

export type PermissionDef = {
  key: string;
  label: string;
  group: PermissionGroup;
  description?: string;
};

// Every key is_valid_permission_key accepts (migration 104), grouped for
// display. The employee "Extra permissions" section and the role grid both
// render from this list.
export const ALL_PERMISSIONS: PermissionDef[] = [
  ...SLEEP_TRIAL_PERMISSIONS.map((p) => ({ ...p, group: "Sleep trial" as const })),
  { key: "sleep_trial.complete_exchange", label: "Complete exchanges", group: "Sleep trial" },
  { key: "sleep_trial.void_refund", label: "Void recorded refunds", group: "Sleep trial" },
  { key: "inventory.reduce_below_committed", label: "Reduce stock below committed", group: "Inventory" },
  { key: "inventory.inspect_returns", label: "Inspect returned items", group: "Inventory" },
  { key: "inventory.manage_inspection_checklist", label: "Edit the inspection checklist", group: "Inventory" },
  { key: "inventory.receive_po", label: "Receive purchase orders", group: "Inventory" },
  { key: "units.assign", label: "Assign units to customer orders", group: "Unit ID" },
  { key: "units.unassign", label: "Unassign units from orders", group: "Unit ID" },
  { key: "units.override_set", label: "Set aside an in-stock unit for an order (override a set)", group: "Unit ID" },
  { key: "units.swap", label: "Swap a unit on an order for another unit", group: "Unit ID" },
  { key: "units.void", label: "Void a unit", group: "Unit ID" },
  { key: "units.manage_settings", label: "Manage Unit ID settings and view the discrepancy report", group: "Unit ID" },
  {
    key: "delivery.manage_calendar",
    label: "Add or remove delivery slots for a day",
    group: "Delivery",
    description: "Lets this person add or remove extra delivery spots on the delivery calendar.",
  },
  {
    key: "delivery.book_inside_cutoff",
    label: "Book a delivery inside the cutoff window",
    group: "Delivery",
    description: "Lets this person book or move a delivery to a day before the earliest bookable day. They must give a reason.",
  },
  {
    key: "delivery.manage_trucks",
    label: "Manage delivery trucks and turn them on or off for a day",
    group: "Delivery",
    description: "Lets this person add, rename, and archive delivery trucks, set their weekly schedule, and turn a truck on or off for one day.",
  },
];
