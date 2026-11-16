import type { CustomerDetail, CustomerPatch } from "@/lib/customers/api";
import { formatPhone } from "@/lib/format/phone";

// Editable form state for the customer detail page, plus the diff that
// becomes the update_customer patch (only changed keys are sent).

export type CustomerFormState = {
  isCompany: boolean;
  companyName: string;
  firstName: string;
  lastName: string;
  phone: string;
  phone2: string;
  email: string;
  streetAddress: string;
  streetAddressLine2: string;
  city: string;
  state: string;
  zipCode: string;
  referralSource: string;
  customerSince: string;
};

export function customerFormFromDetail(d: CustomerDetail): CustomerFormState {
  return {
    isCompany: d.is_company,
    companyName: d.company_name ?? "",
    firstName: d.first_name ?? "",
    lastName: d.last_name ?? "",
    phone: formatPhone(d.phone),
    phone2: formatPhone(d.phone2),
    email: d.email ?? "",
    streetAddress: d.street_address ?? "",
    streetAddressLine2: d.street_address_line_2 ?? "",
    city: d.city ?? "",
    state: d.state ?? "",
    zipCode: d.zip_code ?? "",
    referralSource: d.referral_source ?? "",
    customerSince: d.customer_since?.slice(0, 10) ?? "",
  };
}

const norm = (v: string) => v.trim();

export function buildCustomerPatch(
  form: CustomerFormState,
  saved: CustomerFormState
): CustomerPatch {
  const patch: CustomerPatch = {};
  if (form.isCompany !== saved.isCompany) patch.is_company = form.isCompany;
  if (form.isCompany) {
    if (norm(form.companyName) !== norm(saved.companyName)) {
      patch.company_name = form.companyName.trim() || null;
    }
  } else {
    if (norm(form.firstName) !== norm(saved.firstName)) {
      patch.first_name = form.firstName.trim();
    }
    if (norm(form.lastName) !== norm(saved.lastName)) {
      patch.last_name = form.lastName.trim();
    }
  }
  if (norm(form.phone) !== norm(saved.phone)) patch.phone = form.phone.trim();
  if (norm(form.phone2) !== norm(saved.phone2)) {
    patch.phone2 = form.phone2.trim() || null;
  }
  if (norm(form.email) !== norm(saved.email)) patch.email = form.email.trim();
  if (norm(form.streetAddress) !== norm(saved.streetAddress)) {
    patch.street_address = form.streetAddress.trim() || null;
  }
  if (norm(form.streetAddressLine2) !== norm(saved.streetAddressLine2)) {
    patch.street_address_line_2 = form.streetAddressLine2.trim() || null;
  }
  if (norm(form.city) !== norm(saved.city)) {
    patch.city = form.city.trim() || null;
  }
  if (norm(form.state) !== norm(saved.state)) {
    patch.state = form.state.trim() || null;
  }
  if (norm(form.zipCode) !== norm(saved.zipCode)) {
    patch.zip_code = form.zipCode.trim() || null;
  }
  if (norm(form.referralSource) !== norm(saved.referralSource)) {
    patch.referral_source = form.referralSource || null;
  }
  if (form.customerSince !== saved.customerSince) {
    patch.customer_since = form.customerSince;
  }
  return patch;
}

export function customerFormDirty(
  form: CustomerFormState,
  saved: CustomerFormState
): boolean {
  return Object.keys(buildCustomerPatch(form, saved)).length > 0;
}

const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

// customer_since cannot be cleared or left half-typed: the server only
// accepts a real date. Returns the inline error to show, or null when the
// field is unchanged or valid. The date input itself only emits "" or a
// complete YYYY-MM-DD, so anything else here means a cleared field.
export function customerSinceError(
  form: CustomerFormState,
  saved: CustomerFormState
): string | null {
  if (form.customerSince === saved.customerSince) return null;
  const m = DATE_RE.exec(form.customerSince);
  if (!m) return "Customer since needs a date.";
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const dt = new Date(y, mo - 1, d);
  if (
    dt.getFullYear() !== y ||
    dt.getMonth() !== mo - 1 ||
    dt.getDate() !== d
  ) {
    return "Customer since needs a date.";
  }
  return null;
}
