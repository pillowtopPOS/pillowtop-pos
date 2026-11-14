import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/** One-line readable form of a Supabase/PostgREST error (or anything
 *  else) for console output — plain objects otherwise log as "Object". */
export function describeError(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (error && typeof error === "object") {
    const e = error as {
      message?: unknown;
      code?: unknown;
      details?: unknown;
      hint?: unknown;
    };
    const parts = [e.message, e.code, e.details, e.hint]
      .filter((p) => p !== undefined && p !== null && p !== "")
      .map(String);
    if (parts.length > 0) return parts.join(" | ");
  }
  return String(error);
}
