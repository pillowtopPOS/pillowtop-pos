// Local-calendar date helpers. new Date().toISOString().slice(0, 10)
// returns the UTC date, which rolls over to tomorrow during US evenings —
// always use these for business-date comparisons and date-input bounds.
export function localDateISO(d: Date | string): string {
  const x = new Date(d);
  return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, "0")}-${String(x.getDate()).padStart(2, "0")}`;
}

export function localTodayISO(): string {
  return localDateISO(new Date());
}
