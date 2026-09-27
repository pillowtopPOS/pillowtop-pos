"use client";

import { useEffect, useState } from "react";
import {
  fetchDepositApprovals,
  approveDepositException,
  denyDepositException,
  type DepositApprovalRequest,
} from "@/lib/journeys/deposit";

function formatCurrency(value: number) {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
  }).format(value);
}

function customerName(request: DepositApprovalRequest) {
  const c = request.sleep_journeys?.customers;
  if (!c) return "Unknown customer";
  return `${c.first_name} ${c.last_name}`.trim();
}

export default function DepositApprovalsList() {
  const [requests, setRequests] = useState<DepositApprovalRequest[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetchDepositApprovals()
      .then(setRequests)
      .catch((err) => setError(err.message ?? "Failed to load approvals"))
      .finally(() => setLoading(false));
  }, []);

  async function handleApprove(id: string) {
    try {
      await approveDepositException(id);
      setRequests((prev) =>
        prev.map((r) =>
          r.id === id ? { ...r, status: "approved" } : r
        )
      );
    } catch (err: any) {
      setError(err.message ?? "Failed to approve");
    }
  }

  async function handleDeny(id: string) {
    try {
      await denyDepositException(id);
      setRequests((prev) =>
        prev.map((r) =>
          r.id === id ? { ...r, status: "denied" } : r
        )
      );
    } catch (err: any) {
      setError(err.message ?? "Failed to deny");
    }
  }

  if (loading) {
    return <p className="p-8 text-sm text-slate-500">Loading…</p>;
  }

  return (
    <main className="min-h-screen bg-slate-50 p-8">
      <div className="mx-auto max-w-4xl">
        <h1 className="mb-6 text-2xl font-semibold text-slate-900">
          Deposit Exception Approvals
        </h1>

        {error && (
          <p className="mb-4 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-700">
            {error}
          </p>
        )}

        <div className="space-y-3">
          {requests.map((r) => (
            <div
              key={r.id}
              className="rounded-lg border border-slate-200 bg-white p-4 shadow-sm"
            >
              <div className="flex items-start justify-between">
                <div>
                  <div className="font-semibold text-slate-900">
                    {customerName(r)}
                  </div>
                  <p className="text-sm text-slate-500">
                    Requested {new Date(r.requested_at).toLocaleString()}
                  </p>
                  <p className="mt-1 text-sm text-slate-700">
                    Proposed payment: {formatCurrency(r.proposed_payment_amount)} ·
                    Required: {formatCurrency(r.required_deposit_amount)} ·
                    Shortfall: {formatCurrency(r.shortfall_amount)}
                  </p>
                  <p className="mt-1 text-sm text-slate-600">
                    Reason: {r.reason}
                  </p>
                </div>
                <div className="flex flex-col items-end gap-2">
                  <span
                    className={`rounded-full px-2 py-0.5 text-xs font-medium ${
                      r.status === "pending"
                        ? "bg-amber-100 text-amber-700"
                        : r.status === "approved"
                        ? "bg-green-100 text-green-700"
                        : "bg-slate-100 text-slate-600"
                    }`}
                  >
                    {r.status}
                  </span>
                  {r.status === "pending" && (
                    <div className="flex gap-2">
                      <button
                        onClick={() => handleApprove(r.id)}
                        className="rounded-md bg-green-600 px-3 py-1 text-sm font-medium text-white hover:bg-green-700"
                      >
                        Approve
                      </button>
                      <button
                        onClick={() => handleDeny(r.id)}
                        className="rounded-md bg-red-600 px-3 py-1 text-sm font-medium text-white hover:bg-red-700"
                      >
                        Deny
                      </button>
                    </div>
                  )}
                </div>
              </div>
            </div>
          ))}

          {requests.length === 0 && (
            <p className="text-center text-slate-500">No deposit exception requests.</p>
          )}
        </div>
      </div>
    </main>
  );
}
