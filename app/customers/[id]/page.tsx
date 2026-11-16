"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import {
  getCustomer,
  updateCustomer,
  formatCustomerDate,
  formatCustomerDateTime,
  type CustomerDetail,
} from "@/lib/customers/api";
import {
  customerFormFromDetail,
  buildCustomerPatch,
  customerFormDirty,
  type CustomerFormState,
} from "@/lib/customers/form";
import { useUnsavedChangesGuard } from "@/lib/useUnsavedChangesGuard";
import { customerDisplayName } from "@/lib/customers/lookup";
import { fetchCurrentEmployee, type Employee } from "@/lib/journeys/queries";
import {
  fetchCustomerContacts,
  createCustomerContact,
  updateCustomerContact,
  deleteCustomerContact,
  type CustomerContact,
} from "@/lib/journeys/interactions";
import { formatPhone, formatPhoneAsYouType } from "@/lib/format/phone";
import { REFERRAL_SOURCES } from "@/lib/customers/referralSources";
import MergeCustomerModal from "@/components/customers/MergeCustomerModal";
import ConfirmModal from "@/components/ConfirmModal";

const MERGE_ROLES = ["owner", "admin", "manager"];

const inputCls =
  "mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500";
const labelCls = "block text-sm font-medium text-slate-700";

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section className="rounded-lg border border-slate-200 bg-white p-5 shadow-sm">
      <h2 className="mb-4 text-sm font-semibold uppercase text-slate-500">
        {title}
      </h2>
      {children}
    </section>
  );
}

export default function CustomerDetailPage() {
  const params = useParams();
  const router = useRouter();
  const customerId = params?.id as string;

  const [customer, setCustomer] = useState<CustomerDetail | null>(null);
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [form, setForm] = useState<CustomerFormState | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const [mergeOpen, setMergeOpen] = useState(false);
  const messageRef = useRef<HTMLDivElement | null>(null);

  // Contacts section state
  const [contacts, setContacts] = useState<CustomerContact[]>([]);
  const [contactsLoading, setContactsLoading] = useState(true);
  const [contactForm, setContactForm] = useState<{
    id: string | null;
    name: string;
    role: string;
    phone: string;
    email: string;
  } | null>(null);
  const [contactSaving, setContactSaving] = useState(false);
  const [contactError, setContactError] = useState<string | null>(null);
  const [contactDeleting, setContactDeleting] = useState<CustomerContact | null>(null);

  // Save/validation feedback renders next to the buttons at the bottom of
  // a long form; bring it into view when it appears.
  useEffect(() => {
    if (saveError || notice) {
      messageRef.current?.scrollIntoView({ block: "nearest" });
    }
  }, [saveError, notice]);

  const load = useCallback(async () => {
    const detail = await getCustomer(customerId);
    setCustomer(detail);
    setForm(customerFormFromDetail(detail));
  }, [customerId]);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    Promise.all([getCustomer(customerId), fetchCurrentEmployee(), fetchCustomerContacts(customerId)])
      .then(([detail, emp, contactList]) => {
        if (cancelled) return;
        setCustomer(detail);
        setForm(customerFormFromDetail(detail));
        setEmployee(emp);
        setContacts(contactList);
      })
      .catch((e) => {
        if (cancelled) return;
        setError(e?.message ?? "Could not load customer");
      })
      .finally(() => {
        if (!cancelled) setContactsLoading(false);
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [customerId]);

  const savedForm = useMemo(
    () => (customer ? customerFormFromDetail(customer) : null),
    [customer]
  );
  const dirty = !!form && !!savedForm && customerFormDirty(form, savedForm);

  // Same guard the delivery day plan uses for in-app links and tab close.
  const {
    pendingNav,
    confirmDiscard: confirmNavDiscard,
    cancelDiscard: cancelNavDiscard,
  } = useUnsavedChangesGuard({ dirty });

  const referralOptions = useMemo(() => {
    if (
      form?.referralSource &&
      !(REFERRAL_SOURCES as readonly string[]).includes(form.referralSource)
    ) {
      return [...REFERRAL_SOURCES, form.referralSource];
    }
    return REFERRAL_SOURCES;
  }, [form?.referralSource]);

  function set<K extends keyof CustomerFormState>(
    key: K,
    value: CustomerFormState[K]
  ) {
    setForm((f) => (f ? { ...f, [key]: value } : f));
    setNotice(null);
    setSaveError(null);
  }

  function phoneField(key: "phone" | "phone2") {
    return (
      <input
        type="tel"
        value={form?.[key] ?? ""}
        onChange={(e) =>
          set(key, formatPhoneAsYouType(e.target.value) as CustomerFormState[typeof key])
        }
        onBlur={(e) => set(key, formatPhone(e.target.value))}
        className={inputCls}
      />
    );
  }

  function revert() {
    if (savedForm) setForm(savedForm);
    setSaveError(null);
    setConfirmDiscard(false);
  }

  function handleCancel() {
    if (dirty) {
      setConfirmDiscard(true);
    } else {
      revert();
    }
  }

  async function handleSave() {
    if (!customer || !form || !savedForm || saving) return;
    setSaveError(null);
    setNotice(null);

    if (!form.isCompany && (!form.firstName.trim() || !form.lastName.trim())) {
      setSaveError("First name and last name are required.");
      return;
    }

    const patch = buildCustomerPatch(form, savedForm);
    if (Object.keys(patch).length === 0) return;

    setSaving(true);
    try {
      const updated = await updateCustomer(customer.id, patch);
      setCustomer(updated);
      setForm(customerFormFromDetail(updated));
      setNotice("Customer saved.");
    } catch (e: any) {
      setSaveError(e?.message ?? "Could not save customer");
    } finally {
      setSaving(false);
    }
  }

  function startAddContact() {
    setContactForm({ id: null, name: "", role: "", phone: "", email: "" });
    setContactError(null);
  }

  function startEditContact(c: CustomerContact) {
    setContactForm({
      id: c.id,
      name: c.name,
      role: c.role_label ?? "",
      phone: c.phone ? formatPhone(c.phone) : "",
      email: c.email ?? "",
    });
    setContactError(null);
  }

  async function handleContactSave() {
    if (!contactForm || contactSaving) return;
    setContactError(null);
    if (!contactForm.name.trim()) {
      setContactError("Name is required.");
      return;
    }
    const payload = {
      name: contactForm.name.trim(),
      role_label: contactForm.role.trim() || null,
      phone: formatPhone(contactForm.phone) || null,
      email: contactForm.email.trim() || null,
    };
    setContactSaving(true);
    try {
      if (contactForm.id) {
        const updated = await updateCustomerContact(contactForm.id, payload);
        setContacts((cs) => cs.map((c) => (c.id === updated.id ? updated : c)));
      } else {
        const created = await createCustomerContact({
          customer_id: customerId,
          ...payload,
        });
        setContacts((cs) => [...cs, created]);
      }
      setContactForm(null);
    } catch (e: any) {
      setContactError(e?.message ?? "Could not save contact");
    } finally {
      setContactSaving(false);
    }
  }

  async function handleContactDelete() {
    if (!contactDeleting) return;
    setContactError(null);
    try {
      await deleteCustomerContact(contactDeleting.id);
      setContacts((cs) => cs.filter((c) => c.id !== contactDeleting.id));
      if (contactForm?.id === contactDeleting.id) setContactForm(null);
    } catch (e: any) {
      const msg = e?.message ?? "";
      setContactError(
        /foreign key|23503/i.test(msg)
          ? "This contact is used in an activity log and cannot be removed."
          : msg || "Could not delete contact"
      );
    } finally {
      setContactDeleting(null);
    }
  }

  const canMerge = !!employee && MERGE_ROLES.includes(employee.role);
  const displayName = customer
    ? customerDisplayName({
        is_company: customer.is_company,
        company_name: customer.company_name,
        first_name: customer.first_name,
        last_name: customer.last_name,
      })
    : "";

  if (loading) {
    return (
      <main className="min-h-screen bg-slate-50 p-8">
        <p className="text-sm text-slate-500">Loading…</p>
      </main>
    );
  }

  if (error || !customer || !form) {
    return (
      <main className="min-h-screen bg-slate-50 p-8">
        <div className="mx-auto max-w-3xl">
          <p className="rounded-md bg-red-50 p-3 text-sm text-red-700">
            {error ?? "Customer not found."}
          </p>
          <Link
            href="/customers"
            className="mt-4 inline-block text-sm text-slate-500 hover:text-slate-700"
          >
            Back to Customers
          </Link>
        </div>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-slate-50 p-8">
      <div className="mx-auto max-w-3xl space-y-4">
        <div className="flex items-center justify-between">
          <div>
            <Link
              href="/customers"
              className="text-sm text-slate-500 hover:text-slate-700"
            >
              Customers
            </Link>
            <h1 className="mt-1 text-xl font-semibold text-slate-900">
              {displayName}
              {customer.is_company && (
                <span className="ml-2 rounded-full bg-slate-200 px-2 py-0.5 align-middle text-xs font-normal text-slate-600">
                  Company
                </span>
              )}
            </h1>
          </div>
          {canMerge && (
            <button
              type="button"
              onClick={() => setMergeOpen(true)}
              className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
            >
              Merge another customer into this one
            </button>
          )}
        </div>

        <Section title="Customer">
          <label className="mb-3 flex items-center gap-2 text-sm text-slate-700">
            <input
              type="checkbox"
              checked={form.isCompany}
              onChange={(e) => {
                const checked = e.target.checked;
                setForm((f) => {
                  if (!f) return f;
                  const next = { ...f, isCompany: checked };
                  if (checked && !next.companyName.trim()) {
                    next.companyName =
                      `${f.firstName} ${f.lastName}`.trim();
                  }
                  return next;
                });
                setNotice(null);
                setSaveError(null);
              }}
              className="h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500"
            />
            This is a company
          </label>
          {form.isCompany ? (
            <div>
              <label className={labelCls}>Company name</label>
              <input
                value={form.companyName}
                onChange={(e) => set("companyName", e.target.value)}
                className={inputCls}
              />
            </div>
          ) : (
            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className={labelCls}>First name</label>
                <input
                  value={form.firstName}
                  onChange={(e) => set("firstName", e.target.value)}
                  className={inputCls}
                />
              </div>
              <div>
                <label className={labelCls}>Last name</label>
                <input
                  value={form.lastName}
                  onChange={(e) => set("lastName", e.target.value)}
                  className={inputCls}
                />
              </div>
            </div>
          )}
        </Section>

        <Section title="Contact">
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className={labelCls}>Phone</label>
              {phoneField("phone")}
            </div>
            <div>
              <label className={labelCls}>Second phone</label>
              {phoneField("phone2")}
            </div>
          </div>
          <div className="mt-4">
            <label className={labelCls}>Email</label>
            <input
              type="email"
              value={form.email}
              onChange={(e) => set("email", e.target.value)}
              className={inputCls}
            />
          </div>
        </Section>

        <Section title="Contacts">
          {contactsLoading ? (
            <p className="text-sm text-slate-500">Loading…</p>
          ) : contacts.length === 0 && !contactForm ? (
            <p className="mb-3 text-sm text-slate-500">No contacts yet.</p>
          ) : (
            <ul className="mb-3 divide-y divide-slate-100">
              {contacts.map((c) => (
                <li
                  key={c.id}
                  className="flex items-center justify-between gap-3 py-2 text-sm"
                >
                  <div className="min-w-0">
                    <span className="font-medium text-slate-900">{c.name}</span>
                    {c.role_label && (
                      <span className="ml-2 text-slate-500">{c.role_label}</span>
                    )}
                    {c.phone && (
                      <span className="ml-2 whitespace-nowrap text-slate-500">
                        {formatPhone(c.phone)}
                      </span>
                    )}
                    {c.email && (
                      <span className="ml-2 truncate text-slate-500">
                        {c.email}
                      </span>
                    )}
                  </div>
                  <div className="flex shrink-0 gap-2">
                    <button
                      type="button"
                      onClick={() => startEditContact(c)}
                      className="text-sm text-brand-600 hover:text-brand-700"
                    >
                      Edit
                    </button>
                    <button
                      type="button"
                      onClick={() => setContactDeleting(c)}
                      className="text-sm text-red-600 hover:text-red-700"
                    >
                      Delete
                    </button>
                  </div>
                </li>
              ))}
            </ul>
          )}

          {contactForm ? (
            <div className="rounded-md border border-slate-200 bg-slate-50 p-4">
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className={labelCls}>Name</label>
                  <input
                    value={contactForm.name}
                    onChange={(e) =>
                      setContactForm({ ...contactForm, name: e.target.value })
                    }
                    className={inputCls}
                  />
                </div>
                <div>
                  <label className={labelCls}>Role</label>
                  <input
                    value={contactForm.role}
                    onChange={(e) =>
                      setContactForm({ ...contactForm, role: e.target.value })
                    }
                    className={inputCls}
                  />
                </div>
                <div>
                  <label className={labelCls}>Phone</label>
                  <input
                    type="tel"
                    value={contactForm.phone}
                    onChange={(e) =>
                      setContactForm({
                        ...contactForm,
                        phone: formatPhoneAsYouType(e.target.value),
                      })
                    }
                    onBlur={(e) =>
                      setContactForm({
                        ...contactForm,
                        phone: formatPhone(e.target.value),
                      })
                    }
                    className={inputCls}
                  />
                </div>
                <div>
                  <label className={labelCls}>Email</label>
                  <input
                    type="email"
                    value={contactForm.email}
                    onChange={(e) =>
                      setContactForm({ ...contactForm, email: e.target.value })
                    }
                    className={inputCls}
                  />
                </div>
              </div>
              <div className="mt-3 flex items-center justify-end gap-2">
                {contactError && (
                  <p
                    role="alert"
                    className="mr-auto rounded-md bg-red-50 p-2 text-sm text-red-700"
                  >
                    {contactError}
                  </p>
                )}
                <button
                  type="button"
                  onClick={() => {
                    setContactForm(null);
                    setContactError(null);
                  }}
                  disabled={contactSaving}
                  className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
                >
                  Cancel
                </button>
                <button
                  type="button"
                  onClick={handleContactSave}
                  disabled={contactSaving}
                  className="rounded-md bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                >
                  {contactSaving ? "Saving…" : contactForm.id ? "Save" : "Add"}
                </button>
              </div>
            </div>
          ) : (
            <div className="flex items-center justify-between">
              {contactError && (
                <p
                  role="alert"
                  className="rounded-md bg-red-50 p-2 text-sm text-red-700"
                >
                  {contactError}
                </p>
              )}
              <button
                type="button"
                onClick={startAddContact}
                className="ml-auto rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Add contact
              </button>
            </div>
          )}
        </Section>

        <Section title="Address">
          <p className="mb-3 rounded-md bg-amber-50 px-3 py-2 text-xs text-amber-700">
            Changing this address also changes it on all of this customer&apos;s
            orders.
          </p>
          <div>
            <label className={labelCls}>Street address</label>
            <input
              value={form.streetAddress}
              onChange={(e) => set("streetAddress", e.target.value)}
              className={inputCls}
            />
          </div>
          <div className="mt-3">
            <label className={labelCls}>Address Line 2</label>
            <input
              value={form.streetAddressLine2}
              onChange={(e) => set("streetAddressLine2", e.target.value)}
              className={inputCls}
            />
          </div>
          <div className="mt-3 grid grid-cols-3 gap-3">
            <input
              placeholder="City"
              value={form.city}
              onChange={(e) => set("city", e.target.value)}
              className={inputCls}
            />
            <input
              placeholder="State"
              value={form.state}
              onChange={(e) => set("state", e.target.value)}
              className={inputCls}
            />
            <input
              placeholder="ZIP"
              value={form.zipCode}
              onChange={(e) => set("zipCode", e.target.value)}
              className={inputCls}
            />
          </div>
        </Section>

        <Section title="Marketing">
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className={labelCls}>
                How did you hear about us?
              </label>
              <select
                value={form.referralSource}
                onChange={(e) => set("referralSource", e.target.value)}
                className={inputCls}
              >
                <option value="">Select…</option>
                {referralOptions.map((r) => (
                  <option key={r} value={r}>
                    {r}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label className={labelCls}>Customer since</label>
              <p className="mt-1 rounded-md border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700">
                {formatCustomerDate(customer.customer_since) || "-"}
              </p>
            </div>
          </div>
        </Section>

        <Section title={`Orders (${customer.journey_count})`}>
          {customer.journeys.length === 0 ? (
            <p className="text-sm text-slate-500">No orders yet.</p>
          ) : (
            <ul className="divide-y divide-slate-100">
              {customer.journeys.map((j) => (
                <li key={j.id}>
                  <Link
                    href={`/board?journey=${j.id}`}
                    className="flex items-center justify-between py-2 text-sm hover:bg-slate-50"
                  >
                    <span className="font-medium text-brand-700">
                      {j.journey_number ? `#${j.journey_number}` : "Order"}
                    </span>
                    <span className="text-slate-600">{j.current_state}</span>
                    <span className="text-slate-600">
                      {j.store_name ?? ""}
                    </span>
                    <span className="text-slate-500">
                      {formatCustomerDateTime(j.created_at)}
                    </span>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </Section>

        <div className="flex justify-end gap-2 pb-8">
          {(saveError || notice) && (
            <div
              ref={messageRef}
              className="mr-auto flex items-center"
            >
              {saveError ? (
                <p
                  role="alert"
                  className="rounded-md bg-red-50 p-3 text-sm text-red-700"
                >
                  {saveError}
                </p>
              ) : (
                <p className="rounded-md bg-emerald-50 p-3 text-sm text-emerald-700">
                  {notice}
                </p>
              )}
            </div>
          )}
          <button
            type="button"
            onClick={handleCancel}
            disabled={saving}
            className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={handleSave}
            disabled={saving || !dirty}
            className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
          >
            {saving ? "Saving…" : "Save"}
          </button>
        </div>
      </div>

      {mergeOpen && (
        <MergeCustomerModal
          customer={customer}
          onClose={() => setMergeOpen(false)}
          onMerged={(moved) => {
            setMergeOpen(false);
            setNotice(
              `Customers merged. ${moved} order${moved === 1 ? "" : "s"} moved to this customer.`
            );
            load().catch(() => {});
          }}
        />
      )}
      {contactDeleting && (
        <ConfirmModal
          title="Delete contact?"
          message={`${contactDeleting.name} will be removed from this customer.`}
          actionLabel="Delete"
          onConfirm={handleContactDelete}
          onCancel={() => setContactDeleting(null)}
        />
      )}
      {confirmDiscard && (
        <ConfirmModal
          title="Discard changes?"
          message="Your unsaved changes will be lost."
          actionLabel="Discard changes"
          onConfirm={revert}
          onCancel={() => setConfirmDiscard(false)}
        />
      )}
      {pendingNav && (
        <ConfirmModal
          title="Discard changes?"
          message="You have unsaved changes."
          actionLabel="Discard changes"
          onConfirm={confirmNavDiscard}
          onCancel={cancelNavDiscard}
        />
      )}
    </main>
  );
}
