"use client";

import { Suspense, useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import {
  searchCustomers,
  formatCustomerDate,
  formatCustomerDateTime,
  type CustomerListItem,
} from "@/lib/customers/api";
import { formatPhone } from "@/lib/format/phone";

const PAGE_SIZE = 25;

function CustomersPageInner() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const query = searchParams.get("q") ?? "";
  const rawPage = searchParams.get("page");
  // The param is a 0-based page index; anything that is not a non-negative
  // integer falls back to page 1.
  const page =
    rawPage != null && /^\d+$/.test(rawPage) ? parseInt(rawPage, 10) : 0;

  const [input, setInput] = useState(query);
  const [items, setItems] = useState<CustomerListItem[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Keep the box in sync when the URL changes from outside (back/forward).
  useEffect(() => {
    setInput(query);
  }, [query]);

  // Debounce typing into the URL; a new search resets to page 1.
  useEffect(() => {
    if (input === query) return;
    const handle = setTimeout(() => {
      const params = new URLSearchParams();
      const trimmed = input.trim();
      if (trimmed) params.set("q", trimmed);
      const qs = params.toString();
      router.replace(qs ? `/customers?${qs}` : "/customers");
    }, 300);
    return () => clearTimeout(handle);
  }, [input, query, router]);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    searchCustomers(query, PAGE_SIZE, page * PAGE_SIZE)
      .then((res) => {
        if (cancelled) return;
        setItems(res.items);
        setTotal(res.total);
      })
      .catch((e) => {
        if (cancelled) return;
        setItems([]);
        setTotal(0);
        setError(e?.message ?? "Could not load customers");
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [query, page]);

  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const lastPageIndex = pageCount - 1;
  // Never show a page past the end: clamp the display and fix the URL.
  const shownPage = Math.min(page, lastPageIndex);

  useEffect(() => {
    if (loading || page <= lastPageIndex) return;
    const params = new URLSearchParams();
    if (query) params.set("q", query);
    if (lastPageIndex > 0) params.set("page", String(lastPageIndex));
    const qs = params.toString();
    router.replace(qs ? `/customers?${qs}` : "/customers");
  }, [loading, page, lastPageIndex, query, router]);

  function goToPage(next: number) {
    const params = new URLSearchParams();
    if (query) params.set("q", query);
    if (next > 0) params.set("page", String(next));
    const qs = params.toString();
    router.replace(qs ? `/customers?${qs}` : "/customers");
  }

  const rangeStart = total === 0 ? 0 : shownPage * PAGE_SIZE + 1;
  const rangeEnd = Math.min(total, (shownPage + 1) * PAGE_SIZE);

  return (
    <main className="min-h-screen bg-slate-50 p-8">
      <div className="mx-auto max-w-5xl">
        <h1 className="mb-4 text-xl font-semibold text-slate-900">Customers</h1>

        <input
          type="search"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Search name, company, phone, email, or address"
          className="mb-4 w-full max-w-md rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
        />

        {error && (
          <p className="mb-4 rounded-md bg-red-50 p-3 text-sm text-red-700">
            {error}
          </p>
        )}

        <div className="overflow-hidden rounded-lg border border-slate-200 bg-white shadow-sm">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-slate-200 bg-slate-50 text-left text-xs font-medium uppercase text-slate-500">
                <th className="px-4 py-2">Name</th>
                <th className="px-4 py-2">Phone</th>
                <th className="px-4 py-2">Second phone</th>
                <th className="px-4 py-2">Email</th>
                <th className="px-4 py-2">City</th>
                <th className="px-4 py-2">Customer since</th>
                <th className="px-4 py-2">Orders</th>
                <th className="px-4 py-2">Last order</th>
              </tr>
            </thead>
            <tbody>
              {items.map((c) => (
                <tr
                  key={c.id}
                  onClick={() => router.push(`/customers/${c.id}`)}
                  className="cursor-pointer border-b border-slate-100 last:border-0 hover:bg-slate-50"
                >
                  <td className="px-4 py-2 font-medium text-slate-900">
                    {c.display_name || c.company_name || "Customer"}
                    {c.is_company && (
                      <span className="ml-2 rounded-full bg-slate-100 px-2 py-0.5 text-[11px] font-normal text-slate-500">
                        Company
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-2 text-slate-600">
                    {formatPhone(c.phone) || "-"}
                  </td>
                  <td className="px-4 py-2 text-slate-600">
                    {formatPhone(c.phone2) || "-"}
                  </td>
                  <td className="px-4 py-2 text-slate-600">{c.email || "-"}</td>
                  <td className="px-4 py-2 text-slate-600">
                    {[c.city, c.state].filter(Boolean).join(", ") || "-"}
                  </td>
                  <td className="px-4 py-2 text-slate-600">
                    {formatCustomerDate(c.customer_since) || "-"}
                  </td>
                  <td className="px-4 py-2 text-slate-600">{c.journey_count}</td>
                  <td className="px-4 py-2 text-slate-600">
                    {formatCustomerDateTime(c.last_order_at) || "-"}
                  </td>
                </tr>
              ))}
              {!loading && items.length === 0 && !error && (
                <tr>
                  <td
                    colSpan={8}
                    className="px-4 py-8 text-center text-sm text-slate-500"
                  >
                    No customers match.
                  </td>
                </tr>
              )}
              {loading && (
                <tr>
                  <td
                    colSpan={8}
                    className="px-4 py-8 text-center text-sm text-slate-500"
                  >
                    Loading…
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>

        <div className="mt-3 flex items-center justify-between text-sm text-slate-600">
          <span>
            {total > 0
              ? `${rangeStart} to ${rangeEnd} of ${total} customer${total === 1 ? "" : "s"}`
              : "0 customers"}
          </span>
          <div className="flex gap-2">
            <button
              onClick={() => goToPage(shownPage - 1)}
              disabled={shownPage <= 0 || loading}
              className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
            >
              Previous
            </button>
            <span className="px-2 py-1.5 text-slate-500">
              Page {shownPage + 1} of {pageCount}
            </span>
            <button
              onClick={() => goToPage(shownPage + 1)}
              disabled={shownPage + 1 >= pageCount || loading}
              className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
            >
              Next
            </button>
          </div>
        </div>
      </div>
    </main>
  );
}

export default function CustomersPage() {
  return (
    <Suspense
      fallback={
        <main className="min-h-screen bg-slate-50 p-8">
          <p className="text-sm text-slate-500">Loading…</p>
        </main>
      }
    >
      <CustomersPageInner />
    </Suspense>
  );
}
