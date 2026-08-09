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
