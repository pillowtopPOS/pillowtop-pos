import { createBrowserClient } from "@supabase/ssr";
import { Database } from "./database.types";

function parseCookies() {
  if (typeof document === "undefined") return [];
  return document.cookie.split("; ").filter(Boolean).map((c) => {
    const [name, ...rest] = c.split("=");
    return { name, value: rest.join("=") };
  });
}

export function createClient() {
  return createBrowserClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return parseCookies();
        },
        setAll(cookiesToSet: { name: string; value: string; options?: any }[]) {
          const isHttp = typeof window !== "undefined" && window.location.protocol === "http:";
          cookiesToSet.forEach(({ name, value, options }) => {
            const safeOptions = { ...options };
            if (isHttp) {
              safeOptions.secure = false;
              if (safeOptions.sameSite?.toLowerCase() === "none") {
                safeOptions.sameSite = "Lax";
              }
            }
            safeOptions.path = safeOptions.path ?? "/";

            let cookie = `${name}=${value}`;
            if (safeOptions.domain) cookie += `; Domain=${safeOptions.domain}`;
            cookie += `; Path=${safeOptions.path}`;
            if (typeof safeOptions.maxAge === "number")
              cookie += `; Max-Age=${safeOptions.maxAge}`;
            if (safeOptions.expires)
              cookie += `; Expires=${safeOptions.expires.toUTCString()}`;
            if (safeOptions.sameSite)
              cookie += `; SameSite=${safeOptions.sameSite}`;
            if (safeOptions.secure) cookie += `; Secure`;

            document.cookie = cookie;
          });
        },
      },
    }
  );
}

/**
 * Ends the Supabase session and clears per-user state. The active-store
 * claim lives in user_metadata and survives sign-out, so it is cleared
 * first while the session is still valid — a same-day re-login would
 * otherwise silently restore it. In-memory state (cached employee, etc.)
 * is dropped by the full navigation callers perform after this resolves.
 */
export async function signOut() {
  const supabase = createClient();
  // Sign out even if the claim clear fails — a stale claim is a minor
  // nuisance, a stuck session is not.
  await supabase.auth
    .updateUser({
      data: {
        active_store_id: null,
        active_store_confirmed_at: null,
      },
    })
    .catch(() => {});
  await supabase.auth.signOut();
}
