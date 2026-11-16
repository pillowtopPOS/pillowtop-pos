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
  // m144 adds the full address to search_customers; until then only
  // city/state arrive and the Address column shows those alone.
  street_address?: string | null;
  street_address_line_2?: string | null;
  zip_code?: string | null;
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

// m145: saved per-customer addresses. get_customer returns them without
// customer_id/company_id; the add/update RPCs return the full row, so
// those fields are optional here.
export type CustomerAddress = {
  id: string;
  customer_id?: string;
  label: string | null;
  street_address: string;
  street_address_line_2: string | null;
  city: string | null;
  state: string | null;
  zip_code: string | null;
  open_orders?: number;
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
  // m145 additions; optional so the page still works before it lands.
  primary_open_orders?: number;
  addresses?: CustomerAddress[];
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

// ---- Saved addresses and per-order ship-to (migration 145) ----

export type AddressFields = {
  street_address: string;
  street_address_line_2?: string | null;
  city?: string | null;
  state?: string | null;
  zip_code?: string | null;
};

// Dedupes on street + zip: may return an existing row.
export async function addCustomerAddress(
  customerId: string,
  input: { label?: string | null } & AddressFields
): Promise<CustomerAddress> {
  const supabase = createClient();
  const { data, error } = await (supabase.rpc as any)("add_customer_address", {
    p_customer_id: customerId,
    p_label: input.label ?? null,
    p_street_address: input.street_address,
    p_street_address_line_2: input.street_address_line_2 ?? null,
    p_city: input.city ?? null,
    p_state: input.state ?? null,
    p_zip_code: input.zip_code ?? null,
  });
  if (error) throw new Error(error.message);
  return data as CustomerAddress;
}

export async function updateCustomerAddressRecord(
  addressId: string,
  patch: {
    label?: string | null;
    street_address?: string;
    street_address_line_2?: string | null;
    city?: string | null;
    state?: string | null;
    zip_code?: string | null;
  }
): Promise<CustomerAddress> {
  const supabase = createClient();
  const { data, error } = await (supabase.rpc as any)(
    "update_customer_address",
    { p_address_id: addressId, p_patch: patch }
  );
  if (error) throw new Error(error.message);
  return data as CustomerAddress;
}

export async function archiveCustomerAddress(
  addressId: string
): Promise<CustomerAddress> {
  const supabase = createClient();
  const { data, error } = await (supabase.rpc as any)(
    "archive_customer_address",
    { p_address_id: addressId }
  );
  if (error) throw new Error(error.message);
  return data as CustomerAddress;
}

export async function setJourneyShipTo(
  journeyId: string,
  addressId: string | null
): Promise<{ changed: boolean; journey_id: string; ship_to_address_id: string | null }> {
  const supabase = createClient();
  const { data, error } = await (supabase.rpc as any)("set_journey_ship_to", {
    p_journey_id: journeyId,
    p_address_id: addressId,
  });
  if (error) throw new Error(error.message);
  return data as { changed: boolean; journey_id: string; ship_to_address_id: string | null };
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
