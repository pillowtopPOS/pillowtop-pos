// Canonical phone formatting, mirrors public.format_phone_dashed (m142).
// Digits only; a leading 1 on an 11-digit number is dropped; exactly 10
// digits formats as xxx-xxx-xxxx; anything else returns the trimmed
// input unchanged. null/empty stay as given.
export function formatPhone(value: string | null | undefined): string {
  if (value == null) return "";
  const trimmed = value.trim();
  if (!trimmed) return "";
  const digits = trimmed.replace(/\D/g, "");
  const ten =
    digits.length === 11 && digits.startsWith("1")
      ? digits.slice(1)
      : digits;
  if (ten.length === 10) {
    return `${ten.slice(0, 3)}-${ten.slice(3, 6)}-${ten.slice(6)}`;
  }
  return trimmed;
}

// Input helper: formats a 10-digit US number as the rep types and leaves
// anything unrecognized exactly as typed.
export function formatPhoneAsYouType(value: string): string {
  const digits = value.replace(/\D/g, "");
  const ten =
    digits.length === 11 && digits.startsWith("1")
      ? digits.slice(1)
      : digits;
  if (ten.length <= 3) return ten;
  if (ten.length <= 6) return `${ten.slice(0, 3)}-${ten.slice(3)}`;
  if (ten.length <= 10) return `${ten.slice(0, 3)}-${ten.slice(3, 6)}-${ten.slice(6)}`;
  // More than 10 digits (or an extension typed in): keep the raw text.
  return value;
}
