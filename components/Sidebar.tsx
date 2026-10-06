"use client";

import { useEffect, useState } from "react";
import { usePathname, useRouter } from "next/navigation";
import Link from "next/link";
import {
  LayoutGrid,
  Calendar,
  Package,
  Lightbulb,
  ChevronLeft,
  ChevronRight,
  Store as StoreIcon,
  Settings as SettingsIcon,
} from "lucide-react";
import CelebrationBanner from "@/components/CelebrationBanner";
import { createClient } from "@/lib/supabase/client";
import { isStoreConfirmedToday, storeSelectUrl } from "@/lib/journeys/storeConfirm";
import {
  fetchCurrentEmployee,
  fetchStores,
  fetchMyWorkCount,
  type Employee,
  type Store,
} from "@/lib/journeys/queries";

const HIDDEN_PATHS = ["/", "/login", "/store-select"];

const NAV = [
  { href: "/board", label: "Board", icon: LayoutGrid },
  { href: "/my-work", label: "My Work", icon: Calendar },
  { href: "/inventory", label: "Inventory", icon: Package },
  { href: "/opportunities", label: "Opportunities", icon: Lightbulb },
];

export default function Sidebar({
  children,
}: {
  children: React.ReactNode;
}) {
  const pathname = usePathname();
  const router = useRouter();
  const [collapsed, setCollapsed] = useState(false);
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [workCount, setWorkCount] = useState(0);
  const [activeStoreId, setActiveStoreId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  if (pathname == null) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <p className="text-sm text-slate-500">Loading…</p>
      </div>
    );
  }

  // Print routes render bare — no sidebar/chrome in the print output.
  const hide =
    HIDDEN_PATHS.includes(pathname) || pathname.endsWith("/print");

  useEffect(() => {
    if (hide) {
      setLoading(false);
      return;
    }

    setLoading(true);

    const supabase = createClient();
    let cronInterval: ReturnType<typeof setInterval> | null = null;
    supabase.auth.getSession().then(({ data: { session } }) => {
      if (!session?.user || !isStoreConfirmedToday(session.user)) {
        router.push(storeSelectUrl(pathname ?? "/board"));
        return;
      }

      // Poll the shared cron endpoint from any logged-in page, not just the
      // Board — the daily jobs stay alive as long as anyone is signed in.
      fetch("/api/cron").catch(console.error);
      cronInterval = setInterval(() => {
        fetch("/api/cron").catch(console.error);
      }, 60000);

      setActiveStoreId(session.user.user_metadata?.active_store_id ?? null);
      Promise.all([fetchCurrentEmployee(), fetchStores()]).then(([e, s]) => {
        setEmployee(e);
        setStores(s);
        setLoading(false);
      });
      fetchMyWorkCount()
        .then(setWorkCount)
        .catch((e) => console.error("fetchMyWorkCount error", e));
    });

    return () => {
      if (cronInterval) clearInterval(cronInterval);
    };
  }, [hide, router]);

  if (hide) {
    return <>{children}</>;
  }

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <p className="text-sm text-slate-500">Loading…</p>
      </div>
    );
  }

  const activeStore = stores.find((s) => s.id === activeStoreId);
  const isAdmin = employee?.role === "owner" || employee?.role === "admin";

  return (
    <div className="flex h-screen overflow-hidden">
      <aside
        className={`flex h-full shrink-0 flex-col border-r border-slate-200 bg-white transition-all duration-200 ${
          collapsed ? "w-16" : "w-56"
        }`}
      >
        <div className="flex h-14 items-center justify-between border-b border-slate-200 px-3">
          {!collapsed && (
            <span className="text-lg font-semibold text-slate-900">
              PillowTop
            </span>
          )}
          <button
            onClick={() => setCollapsed((c) => !c)}
            className="rounded p-1 text-slate-500 hover:bg-slate-100"
            aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}
          >
            {collapsed ? (
              <ChevronRight className="h-5 w-5" />
            ) : (
              <ChevronLeft className="h-5 w-5" />
            )}
          </button>
        </div>

        <nav className="flex-1 space-y-1 overflow-y-auto p-2">
          {[...NAV, ...(isAdmin ? [{ href: "/settings", label: "Settings", icon: SettingsIcon }] : [])].map((item) => {
            const Icon = item.icon;
            const isActive =
              pathname === item.href || pathname.startsWith(`${item.href}/`);
            return (
              <Link
                key={item.href}
                href={item.href}
                className={`relative flex items-center gap-3 rounded-md px-3 py-2.5 text-sm font-medium transition-colors ${
                  isActive
                    ? "bg-brand-50 text-brand-700"
                    : "text-slate-600 hover:bg-slate-100"
                }`}
              >
                <Icon className="h-5 w-5 shrink-0" />
                {!collapsed && <span>{item.label}</span>}
                {item.href === "/my-work" && workCount > 0 &&
                  (collapsed ? (
                    <span className="absolute right-1.5 top-1.5 h-2 w-2 rounded-full bg-brand-600" />
                  ) : (
                    <span className="ml-auto rounded-full bg-brand-600 px-2 py-0.5 text-xs font-semibold text-white">
                      {workCount}
                    </span>
                  ))}
              </Link>
            );
          })}
        </nav>

        <div className="border-t border-slate-200 p-3">
          {collapsed ? (
            <Link
              href="/store-select"
              className="flex justify-center rounded p-1 text-slate-500 hover:bg-slate-100"
              aria-label="Change store"
            >
              <StoreIcon className="h-5 w-5" />
            </Link>
          ) : (
            <div className="space-y-1.5">
              <p className="text-xs font-medium uppercase text-slate-400">
                Active store
              </p>
              <p className="text-sm font-medium text-slate-800">
                {activeStore?.name ?? (loading ? "Loading…" : "—")}
              </p>
              {employee && (
                <p className="text-xs text-slate-500">
                  Logged in as: {employee.name}
                </p>
              )}
              <Link
                href="/store-select"
                className="text-xs text-brand-600 hover:text-brand-700"
              >
                Change
              </Link>
            </div>
          )}
        </div>
      </aside>

      <div className="min-w-0 flex-1 overflow-y-auto bg-slate-50">
        <CelebrationBanner />
        {children}
      </div>
    </div>
  );
}
