// Effective ship-to address for an order. sleep_journeys.ship_to_address_id
// (m145) points at a saved customer_addresses row; null means the
// customer's primary address on customers. Every display reader must go
// through effectiveShipTo so a per-order ship-to is never missed.

export type ShipToSource = {
  street_address?: string | null;
  street_address_line_2?: string | null;
  city?: string | null;
  state?: string | null;
  zip_code?: string | null;
};

export type ShipToAddress = ShipToSource & {
  label: string | null;
  is_primary: boolean;
};

type JourneyLike = {
  ship_to_address_id?: string | null;
  ship_to?: (ShipToSource & { label?: string | null }) | null;
};

export function effectiveShipTo(
  journey: JourneyLike | null | undefined,
  customer: ShipToSource | null | undefined
): ShipToAddress | null {
  const saved =
    journey?.ship_to_address_id && journey.ship_to ? journey.ship_to : null;
  if (saved) {
    return { ...saved, label: saved.label ?? null, is_primary: false };
  }
  if (!customer?.street_address?.trim()) return null;
  return {
    street_address: customer.street_address,
    street_address_line_2: customer.street_address_line_2 ?? null,
    city: customer.city ?? null,
    state: customer.state ?? null,
    zip_code: customer.zip_code ?? null,
    label: null,
    is_primary: true,
  };
}

// One-line display: "123 Main St Apt 4, Denver, CO 80202" style, blanks
// skipped. City/state/zip join with a space after the comma.
export function formatShipToLine(
  addr: (ShipToSource & { label?: string | null }) | null
): string {
  if (!addr) return "";
  const line1 = [addr.street_address, addr.street_address_line_2]
    .filter((p) => p && p.trim())
    .join(" ");
  const cityStateZip = [
    addr.city,
    [addr.state, addr.zip_code].filter((p) => p && p.trim()).join(" ") || null,
  ]
    .filter((p) => p && p.trim())
    .join(", ");
  return [line1, cityStateZip].filter(Boolean).join(", ");
}
