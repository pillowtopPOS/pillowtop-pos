import { createClient } from "@/lib/supabase/client";

export type DepositPolicy = {
  company_id: string;
  policy_type:
    | "none"
    | "fixed_amount"
    | "percentage"
    | "greater_of_fixed_or_percentage";
  fixed_amount: number | null;
  percentage: number | null;
  updated_at: string;
  updated_by: string | null;
};

export type DepositApprovalRequest = {
  id: string;
  entity_id: string;
  requester_employee_id: string;
  approver_employee_id: string | null;
  required_deposit_amount: number;
  amount_already_paid: number;
  proposed_payment_amount: number;
  resulting_qualifying_deposit_amount: number;
  shortfall_amount: number;
  reason: string;
  status: "pending" | "approved" | "denied" | "expired" | "cancelled";
  requested_at: string;
  decided_at: string | null;
  sleep_journeys: {
    customer_id: string;
    customers: { first_name: string; last_name: string } | null;
    store_id: string;
  } | null;
};

export async function fetchDepositPolicy(): Promise<DepositPolicy | null> {
  const supabase = createClient();

  const { data, error } = await supabase
    .from("deposit_policies")
    .select("*")
    .maybeSingle();

  if (error) throw new Error(error.message);
  return data as DepositPolicy | null;
}

export async function upsertDepositPolicy(policy: {
  company_id: string;
  policy_type: DepositPolicy["policy_type"];
  fixed_amount?: number | null;
  percentage?: number | null;
}) {
  const supabase = createClient();

  const { error } = await supabase.from("deposit_policies").upsert({
    company_id: policy.company_id,
    policy_type: policy.policy_type,
    fixed_amount: policy.fixed_amount ?? null,
    percentage: policy.percentage ?? null,
    updated_at: new Date().toISOString(),
  });

  if (error) throw new Error(error.message);
}

export async function requestDepositException(
  journeyId: string,
  proposedAmount: number,
  reason: string
): Promise<string> {
  const supabase = createClient();

  const { data, error } = await supabase.rpc("request_deposit_exception", {
    p_journey_id: journeyId,
    p_proposed_payment_amount: proposedAmount,
    p_reason: reason,
  });

  if (error) throw new Error(error.message);
  return data as string;
}

export async function approveDepositException(requestId: string): Promise<string> {
  const supabase = createClient();

  const { data, error } = await supabase.rpc("approve_deposit_exception", {
    p_request_id: requestId,
  });

  if (error) throw new Error(error.message);
  return data as string;
}

export async function denyDepositException(requestId: string): Promise<string> {
  const supabase = createClient();

  const { data, error } = await supabase.rpc("deny_deposit_exception", {
    p_request_id: requestId,
  });

  if (error) throw new Error(error.message);
  return data as string;
}

export async function fetchDepositApprovals(): Promise<DepositApprovalRequest[]> {
  const supabase = createClient();

  const { data, error } = await supabase
    .from("deposit_approval_requests")
    .select(
      "*, sleep_journeys(customer_id, customers(first_name, last_name), store_id)"
    )
    .order("requested_at", { ascending: false });

  if (error) throw new Error(error.message);
  return (data as DepositApprovalRequest[]) ?? [];
}
