// IANA timezone lists for pickers. US zones are pinned first, then every other
// zone the runtime knows about (Intl.supportedValuesOf), then a static
// fallback for runtimes without it.

export const US_TIMEZONES = [
  "America/New_York",
  "America/Chicago",
  "America/Denver",
  "America/Phoenix",
  "America/Los_Angeles",
  "America/Anchorage",
  "Pacific/Honolulu",
  "America/Indiana/Indianapolis",
  "America/Boise",
  "America/Detroit",
  "America/Juneau",
  "America/Puerto_Rico",
];

const FALLBACK_TIMEZONES = [
  "UTC",
  "Europe/London",
  "Europe/Dublin",
  "Europe/Paris",
  "Europe/Berlin",
  "Europe/Madrid",
  "Europe/Rome",
  "Europe/Amsterdam",
  "Europe/Zurich",
  "Europe/Stockholm",
  "Europe/Oslo",
  "Europe/Helsinki",
  "Europe/Athens",
  "Europe/Istanbul",
  "Europe/Moscow",
  "Africa/Cairo",
  "Africa/Johannesburg",
  "Africa/Lagos",
  "Asia/Dubai",
  "Asia/Karachi",
  "Asia/Kolkata",
  "Asia/Dhaka",
  "Asia/Bangkok",
  "Asia/Singapore",
  "Asia/Hong_Kong",
  "Asia/Shanghai",
  "Asia/Tokyo",
  "Asia/Seoul",
  "Australia/Perth",
  "Australia/Sydney",
  "Australia/Melbourne",
  "Australia/Brisbane",
  "Pacific/Auckland",
  "America/Mexico_City",
  "America/Sao_Paulo",
  "America/Argentina/Buenos_Aires",
  "America/Santiago",
  "America/Bogota",
  "America/Lima",
  "America/Toronto",
  "America/Vancouver",
  "America/Winnipeg",
  "America/Halifax",
  "America/St_Johns",
  "America/Edmonton",
];

let cached: string[] | null = null;

export function allTimezones(): string[] {
  if (cached) return cached;

  let rest: string[] = [];
  try {
    const intl = Intl as unknown as {
      supportedValuesOf?: (key: string) => string[];
    };
    if (typeof intl.supportedValuesOf === "function") {
      rest = intl.supportedValuesOf("timeZone");
    }
  } catch {
    // fall through to the static list
  }
  if (rest.length === 0) rest = FALLBACK_TIMEZONES;

  const us = new Set(US_TIMEZONES);
  cached = [...US_TIMEZONES, ...rest.filter((tz) => !us.has(tz))];
  return cached;
}

export function isValidTimezone(tz: string | null | undefined): boolean {
  return !!tz && allTimezones().includes(tz);
}
