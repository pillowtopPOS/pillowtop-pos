"use client";

import type { PurchaseOrder } from "@/lib/purchase-orders/queries";
import type { Store } from "@/lib/journeys/queries";

// One shared "Ship To" concept: stock POs ship to the destination location's
// own address; drop-ship POs ship to the customer's address stored on the PO.
export default function ShipTo({
  po,
  destination,
}: {
  po: PurchaseOrder;
  destination: Store | undefined;
}) {
  const isDropShip = po.fulfillment_type === "drop_ship";

  const lines: (string | null)[] = isDropShip
    ? [
        po.ship_street_address,
        po.ship_street_address_line_2,
        [po.ship_city, po.ship_state, po.ship_zip_code]
          .filter(Boolean)
          .join(" ") || null,
      ]
    : [
        destination?.street_address ?? destination?.address ?? null,
        [destination?.city, destination?.state, destination?.zip_code]
          .filter(Boolean)
          .join(" ") || null,
      ];

  const visible = lines.filter(Boolean);

  return (
    <div>
      <p className="text-xs font-medium uppercase tracking-wide text-slate-500">
        Ship To
      </p>
      <p className="mt-0.5 text-sm font-medium text-slate-900">
        {isDropShip
          ? po.journey?.customer
            ? `${po.journey.customer.first_name} ${po.journey.customer.last_name}`
            : "Customer"
          : (destination?.name ?? "—")}
      </p>
      {visible.length > 0 ? (
        visible.map((l, i) => (
          <p key={i} className="text-sm text-slate-600">
            {l}
          </p>
        ))
      ) : (
        <p className="text-sm text-slate-400">No address on file</p>
      )}
      {isDropShip && po.journey && (
        <p className="mt-0.5 text-xs text-slate-500">
          Linked journey: {po.journey.id.slice(0, 8)}…
        </p>
      )}
    </div>
  );
}
