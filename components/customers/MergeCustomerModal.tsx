"use client";

import { useEffect, useState } from "react";
import Modal from "@/components/Modal";
import ConfirmModal from "@/components/ConfirmModal";
import {
  searchCustomers,
  mergeCustomers,
  formatCustomerDate,
  type CustomerDetail,
  type CustomerListItem,
} from "@/lib/customers/api";
import { formatPhone } from "@/lib/format/phone";
import { customerDisplayName } from "@/lib/customers/lookup";

function CompareRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-4 text-sm">
      <span className="shrink-0 text-slate-500">{label}</span>
      <span className="text-right text-slate-900">{value || "-"}</span>
    </div>
  );
}

function CompareCard({
  title,
  name,
  isCompany,
  phone,
  phone2,
  email,
  orders,
  customerSince,
}: {
  title: string;
  name: string;
  isCompany: boolean;
  phone: string | null;
  phone2: string | null;
  email: string | null;
  orders: number;
  customerSince: string | null;
}) {
  return (
    <div className="rounded-md border border-slate-200 bg-slate-50 p-3">
      <p className="mb-2 text-xs font-medium uppercase text-slate-500">{title}</p>
      <p className="mb-2 text-sm font-semibold text-slate-900">
        {name}
        {isCompany && (
          <span className="ml-2 rounded-full bg-slate-200 px-2 py-0.5 text-[11px] font-normal text-slate-600">
            Company
          </span>
        )}
      </p>
      <CompareRow label="Phone" value={formatPhone(phone)} />
      <CompareRow label="Second phone" value={formatPhone(phone2)} />
      <CompareRow label="Email" value={email ?? ""} />
      <CompareRow label="Orders" value={String(orders)} />
      <CompareRow
        label="Customer since"
        value={formatCustomerDate(customerSince)}
      />
    </div>
  );
}

export default function MergeCustomerModal({
  customer,
  onClose,
  onMerged,
}: {
  customer: CustomerDetail;
  onClose: () => void;
  onMerged: (movedJourneys: number) => void;
}) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<CustomerListItem[]>([]);
  const [searching, setSearching] = useState(false);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [other, setOther] = useState<CustomerListItem | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [merging, setMerging] = useState(false);
  const [mergeError, setMergeError] = useState<string | null>(null);

  // Debounced search; the current customer is excluded from results.
  useEffect(() => {
    const trimmed = query.trim();
    if (!trimmed) {
      setResults([]);
      setSearching(false);
      setSearchError(null);
      return;
    }
    let cancelled = false;
    setSearching(true);
    setSearchError(null);
    const handle = setTimeout(() => {
      searchCustomers(trimmed, 10, 0)
        .then((res) => {
          if (cancelled) return;
          setResults(res.items.filter((c) => c.id !== customer.id));
        })
        .catch((e) => {
          if (cancelled) return;
          setResults([]);
          setSearchError(e?.message ?? "Search failed");
        })
        .finally(() => {
          if (!cancelled) setSearching(false);
        });
    }, 300);
    return () => {
      cancelled = true;
      clearTimeout(handle);
    };
  }, [query, customer.id]);

  const keepName = customerDisplayName({
    is_company: customer.is_company,
    company_name: customer.company_name,
    first_name: customer.first_name,
    last_name: customer.last_name,
  });
  const otherName = other ? customerDisplayName(other) : "";
  const movedCount = other?.journey_count ?? 0;
  const mergeSentence = other
    ? `${movedCount} order${movedCount === 1 ? "" : "s"} ${movedCount === 1 ? "moves" : "move"} to ${keepName}. ${otherName} will be removed. This cannot be undone from the app.`
    : "";

  async function doMerge() {
    if (!other || merging) return;
    setMerging(true);
    setMergeError(null);
    try {
      const res = await mergeCustomers(customer.id, other.id);
      onMerged(res.moved_journeys);
    } catch (e: any) {
      setMerging(false);
      setConfirming(false);
      setMergeError(e?.message ?? "Merge failed");
    }
  }

  return (
    <>
      <Modal onClose={onClose} dirty={!!other}>
        <div className="w-full max-w-2xl rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
          <h2 className="mb-1 text-lg font-semibold text-slate-900">
            Merge another customer into this one
          </h2>
          <p className="mb-4 text-sm text-slate-600">
            Orders from the customer you pick move to {keepName}. The other
            customer is removed.
          </p>

          {!other ? (
            <>
              <input
                type="search"
                autoFocus
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Search customers to merge in"
                className="mb-3 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
              {searching && (
                <p className="text-sm text-slate-500">Searching…</p>
              )}
              {searchError && (
                <p className="mb-2 rounded-md bg-red-50 p-2 text-sm text-red-700">
                  {searchError}
                </p>
              )}
              {!searching && query.trim() && results.length === 0 && !searchError && (
                <p className="text-sm text-slate-500">No customers match.</p>
              )}
              <div className="max-h-72 space-y-1 overflow-y-auto">
                {results.map((c) => (
                  <button
                    key={c.id}
                    type="button"
                    onClick={() => setOther(c)}
                    className="flex w-full items-center justify-between rounded-md border border-slate-200 px-3 py-2 text-left text-sm hover:bg-slate-50"
                  >
                    <span className="font-medium text-slate-900">
                      {customerDisplayName(c)}
                      {c.is_company && (
                        <span className="ml-2 rounded-full bg-slate-100 px-2 py-0.5 text-[11px] font-normal text-slate-500">
                          Company
                        </span>
                      )}
                    </span>
                    <span className="text-xs text-slate-500">
                      {c.journey_count} order{c.journey_count === 1 ? "" : "s"}
                    </span>
                  </button>
                ))}
              </div>
            </>
          ) : (
            <div className="space-y-3">
              <div className="grid grid-cols-2 gap-3">
                <CompareCard
                  title="This customer"
                  name={keepName}
                  isCompany={customer.is_company}
                  phone={customer.phone}
                  phone2={customer.phone2}
                  email={customer.email}
                  orders={customer.journey_count}
                  customerSince={customer.customer_since}
                />
                <CompareCard
                  title="Merging in"
                  name={otherName}
                  isCompany={other.is_company}
                  phone={other.phone}
                  phone2={other.phone2}
                  email={other.email}
                  orders={other.journey_count}
                  customerSince={other.customer_since}
                />
              </div>
              <p className="text-sm text-slate-700">{mergeSentence}</p>
              {mergeError && (
                <p className="rounded-md bg-red-50 p-2 text-sm text-red-700">
                  {mergeError}
                </p>
              )}
              <div className="flex justify-end gap-2">
                <button
                  type="button"
                  onClick={() => setOther(null)}
                  className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                >
                  Back
                </button>
                <button
                  type="button"
                  onClick={() => setConfirming(true)}
                  className="rounded-md bg-red-600 px-3 py-2 text-sm font-medium text-white hover:bg-red-700"
                >
                  Merge customers
                </button>
              </div>
            </div>
          )}
        </div>
      </Modal>
      {confirming && (
        <ConfirmModal
          title="Merge customers?"
          message={mergeSentence}
          actionLabel="Merge customers"
          busy={merging}
          onConfirm={doMerge}
          onCancel={() => setConfirming(false)}
        />
      )}
    </>
  );
}
