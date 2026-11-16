// Board search helpers for customer phone matching. After the m142 phone
// backfill, stored phones are xxx-xxx-xxxx, so a digits-only search term
// like "3035550100" no longer substring-matches the stored string.
// phoneDigitsMatch compares digits to digits instead.

/** True when the search term has at least 3 digits and the phone's
 *  digits contain the term's digits. */
export function phoneDigitsMatch(
  phone: string | null | undefined,
  term: string
): boolean {
  const termDigits = term.replace(/\D/g, "");
  if (termDigits.length < 3) return false;
  const phoneDigits = (phone ?? "").replace(/\D/g, "");
  return phoneDigits.length > 0 && phoneDigits.includes(termDigits);
}
