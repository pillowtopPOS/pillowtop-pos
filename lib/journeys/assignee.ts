// Pure helpers for the new-order form's Assigned employee field.
// No React, no Supabase.

/** The salesperson a new journey defaults to: the signed-in
 *  employee's id, or null (Unassigned) when no employee row
 *  resolves for the session. */
export function defaultAssigneeId(
  employee: { id: string } | null | undefined
): string | null {
  return employee?.id ?? null;
}

/** Select value -> stored value: "" means the deliberate
 *  Unassigned choice and stores null. */
export function parseAssigneeChoice(value: string): string | null {
  return value === "" ? null : value;
}
