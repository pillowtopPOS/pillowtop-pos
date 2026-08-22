"use client";

import { useEffect, useState, Suspense } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { fetchStores, type Store } from "@/lib/journeys/queries";

export default function StoreSelectPage() {
  return (
    <Suspense
      fallback={
        <main className="flex min-h-screen items-center justify-center p-8">
          <p className="text-sm text-slate-500">Loading…</p>
        </main>
      }
    >
      <StoreSelectContent />
    </Suspense>
  );
}

function StoreSelectContent() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const returnTo = searchParams.get("returnTo") || "/board";
  const [stores, setStores] = useState<Store[]>([]);
  const [selected, setSelected] = useState<string>("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const supabase = createClient();

    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!session) {
        router.push("/login");
        return;
      }

      fetchStores(true).then(setStores);
    });
  }, [router]);

  async function handleContinue() {
    if (!selected) return;

    setLoading(true);
    setError(null);

    const supabase = createClient();
    const { error } = await supabase.auth.updateUser({
      data: {
        active_store_id: selected,
        active_store_confirmed_at: new Date().toISOString(),
      },
    });

    if (!error) {
      await supabase.auth.refreshSession();
    }

    setLoading(false);

    if (error) {
      setError(error.message);
    } else {
      router.push(returnTo);
      router.refresh();
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center p-8">
      <div className="w-full max-w-md space-y-6 rounded-lg border border-slate-200 bg-white p-6 shadow-sm">
        <h1 className="text-xl font-semibold text-slate-900">
          Which store are you working from today?
        </h1>

        {error && (
          <p className="rounded-md bg-amber-50 p-3 text-sm text-amber-700">
            {error}
          </p>
        )}

        <div className="space-y-2">
          {stores.map((store) => (
            <label
              key={store.id}
              className={`flex cursor-pointer items-center justify-between rounded-md border p-3 ${
                selected === store.id
                  ? "border-brand-500 bg-brand-50"
                  : "border-slate-200 hover:border-slate-300"
              }`}
            >
              <span className="text-sm font-medium text-slate-800">
                {store.name}
              </span>
              <input
                type="radio"
                name="store"
                value={store.id}
                checked={selected === store.id}
                onChange={(e) => setSelected(e.target.value)}
                className="h-4 w-4 text-brand-600"
              />
            </label>
          ))}


        </div>

        <button
          onClick={handleContinue}
          disabled={!selected || loading}
          className="w-full rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
        >
          {loading ? "Saving…" : "Continue"}
        </button>
      </div>
    </main>
  );
}
