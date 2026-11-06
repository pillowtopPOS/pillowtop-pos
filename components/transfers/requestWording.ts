// Plain-language wording for the Requests page. Display only.
export function requestSourceLabel(sourceType: string): string {
  switch (sourceType) {
    case "journey_mismatch":
      return "Customer order";
    case "threshold_auto":
      return "Low stock restock";
    case "manager_requested":
    case "manual":
      return "Manual request";
    default:
      return "Manual request";
  }
}

// "For a customer order. Next shipment: Mon 11/10." — or the no-date
// fallback. scheduleDay is stores.transfer_schedule_day (0=Sun).
export function requestWhyWhen(opts: {
  sourceType: string;
  scheduleDay?: number | null;
}): string {
  const what =
    opts.sourceType === "journey_mismatch"
      ? "For a customer order."
      : opts.sourceType === "threshold_auto"
      ? "Low stock restock."
      : "Manual request.";
  if (opts.scheduleDay == null) {
    return `${what} Shipment date not set. Use Expedite to ship sooner.`;
  }
  const d = new Date();
  let add = (opts.scheduleDay - d.getDay() + 7) % 7;
  if (add === 0) add = 7;
  d.setDate(d.getDate() + add);
  return `${what} Next shipment: ${d.toLocaleDateString(undefined, {
    weekday: "short",
    month: "numeric",
    day: "numeric",
  })}.`;
}
