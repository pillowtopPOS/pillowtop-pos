import { createClient } from "@/lib/supabase/client";

// Typed wrappers for the Customers module RPCs (migration 143). All return
// jsonb and raise readable exceptions, which surface as error.message.

export type CustomerListItem = {
  id: string;
  display_name: string;
  first_name: string;
  last_name: string;
  is_company: boolean;
  company_name: string | null;
  phone: string | null;
  phone2: string | null;
  email: string | null;
  city: string | null;
  state: string | null;
  customer_since: string | null;
  journey_count: number;
  last_order_at: string | null;
};

export type CustomerJourneyRef = {
  id: string;
  journey_number: string | null;
  current_state: string;
  store_id: string;
  store_name: string | null;
  created_at: string;
};

export type CustomerDetail = {
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
  customer_since: string | null;
  created_at: string;
  updated_at: string;
  journeys: CustomerJourneyRef[];
  journey_count: number;
};

export type CustomerPatch = {
  is_company?: boolean;
  company_name?: string | null;
  first_name?: string;
  last_name?: string;
  phone?: string;
  phone2?: string | null;
  email?: string;
  referral_source?: string | null;
  customer_since?: string;
  street_address?: string | null;
  street_address_line_2?: string | null;
  city?: string | null;
  state?: string | null;
  zip_code?: string | null;
};

export type CustomerSearchResult = {
  total: number;
  items: CustomerListItem[];
};

export async function searchCustomers(
  query: string,
  limit = 25,
  offset = 0
): Promise<CustomerSearchResult> {
  const supabase = createClient();
  const { data, error } = await (supabase.rpc as any)("search_customers", {
    p_query: query || null,
    p_limit: limit,
    p_offset: offset,
  });
  if (error) throw new Error(error.message);
  const payload = (data ?? { total: 0, items: [] }) as {
    total?: number;
    items?: CustomerListItem[];
  };
  return { total: payload.total ?? 0, items: payload.items ?? [] };
}

export async function getCustomer(id: string): Promise<CustomerDetail> {
  const supabase = createClient();
  const { data, error } = await (supabase.rpc as any)("get_customer", {
    p_id: id,
  });
  if (error) throw new Error(error.message);
  return data as CustomerDetail;
}

export async function updateCustomer(
  id: string,
  patch: CustomerPatch
): Promise<CustomerDetail> {
  const supabase = createClient();
  const { data, error } = await (supabase.rpc as any)("update_customer", {
    p_id: id,
    p_patch: patch,
  });
  if (error) throw new Error(error.message);
  return data as CustomerDetail;
}

export async function mergeCustomers(
  keepId: string,
  removeId: string
): Promise<{ kept_customer_id: string; moved_journeys: number }> {
  const supabase = createClient();
  const { data, error } = await (supabase.rpc as any)("merge_customers", {
    p_keep: keepId,
    p_remove: removeId,
  });
  if (error) throw new Error(error.message);
  return data as { kept_customer_id: string; moved_journeys: number };
}

// customer_since is a date; last_order_at is a timestamp. Date-only values
// are formatted from parts so timezones cannot shift the day.
export function formatCustomerDate(value: string | null | undefined): string {
  if (!value) return "";
  const datePart = value.slice(0, 10);
  const [y, m, d] = datePart.split("-").map(Number);
  if (!y || !m || !d) return value;
  return new Date(y, m - 1, d).toLocaleDateString();
}

export function formatCustomerDateTime(
  value: string | null | undefined
): string {
  if (!value) return "";
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return value;
  return d.toLocaleDateString();
}
