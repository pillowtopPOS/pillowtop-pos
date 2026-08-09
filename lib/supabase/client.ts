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
          cookiesToSet.forEach(({ name, value, options }) => {
            let cookie = `${name}=${value}`;
            if (options) {
              if (options.domain) cookie += `; Domain=${options.domain}`;
              if (options.path) cookie += `; Path=${options.path}`;
              if (typeof options.maxAge === "number")
                cookie += `; Max-Age=${options.maxAge}`;
              if (options.expires)
                cookie += `; Expires=${options.expires.toUTCString()}`;
              if (options.sameSite)
                cookie += `; SameSite=${options.sameSite}`;
              if (options.secure) cookie += `; Secure`;
            }
            document.cookie = cookie;
          });
        },
      },
    }
  );
}
