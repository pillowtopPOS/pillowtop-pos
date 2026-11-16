import { createClient } from "@/lib/supabase/client";

// One candidate returned by public.find_matching_customers (m142).
export type CustomerMatch = {
  id: string;
  first_name: string;
  last_name: string;
  is_company: boolean;
  company_name: string | null;
  phone: string | null;
  phone2: string | null;
  email: string | null;
  street_address: string | null;
  street_address_line_2: string | null;
  city: string | null;
  state: string | null;
  zip_code: string | null;
  referral_source: string | null;
  journey_count: number;
  last_order_at: string | null;
  reasons: ("phone" | "email" | "name")[];
};

export type CustomerMatchInput = {
  first: string;
  last: string | null;
  phone: string;
  email: string;
};

// Display name for a match or customer row: the company name for company
// customers (first_name mirrors it), otherwise first + last.
export function customerDisplayName(c: {
  is_company?: boolean | null;
  company_name?: string | null;
  first_name: string;
  last_name: string | null;
}): string {
  if (c.is_company) {
    return (c.company_name ?? c.first_name ?? "").trim();
  }
  return `${c.first_name ?? ""} ${c.last_name ?? ""}`.trim();
}

// Returns [] on any error (including the RPC not existing yet) so the
// order form degrades silently before migration 142 is installed.
export async function fetchMatchingCustomers(
  input: CustomerMatchInput
): Promise<CustomerMatch[]> {
  const supabase = createClient();
  const { data, error } = await (supabase.rpc as any)(
    "find_matching_customers",
    {
    p_first: input.first,
    p_last: input.last,
    p_phone: input.phone,
      p_email: input.email,
    }
  );
  if (error) {
    console.error("fetchMatchingCustomers error", error.message);
    return [];
  }
  return (data as CustomerMatch[] | null) ?? [];
}
