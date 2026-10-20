"use client";

import { useEffect } from "react";
import { signOut } from "@/lib/supabase/client";

// Bookmarkeable sign-out: ends the session (and clears the per-user store
// claim inside signOut), then lands on login. Rendered bare — "/logout" is
// in Sidebar's HIDDEN_PATHS so the session guard can't bounce this page to
// /store-select mid-sign-out.
export default function LogoutPage() {
  useEffect(() => {
    signOut().finally(() => {
      window.location.href = "/login";
    });
  }, []);

  return (
    <main className="flex min-h-screen items-center justify-center p-8">
      <p className="text-sm text-slate-500">Signing out…</p>
    </main>
  );
}
