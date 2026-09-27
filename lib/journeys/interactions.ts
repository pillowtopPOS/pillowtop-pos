import { createClient } from "@/lib/supabase/client";
import type { SleepJourneyState } from "@/lib/constants";

// ============================================================
// Taxonomies (mirror the CHECK constraints in migration 056)
// ============================================================

export type InteractionType =
  | "customer_called"
  | "called_customer"
  | "text_conversation"
  | "email"
  | "in_person"
  | "customer_request"
  | "status_update"
  | "issue_concern"
  | "internal_note"
  | "other"
  | "correction";

export type InteractionChannel =
  | "phone_inbound"
  | "phone_outbound"
  | "sms"
  | "email"
  | "in_person"
  | "internal"
  | "system";

export type InteractionTopic =
  | "inventory_eta"
  | "product_delay"
  | "delivery"
  | "pickup"
  | "scheduling"
  | "payment"
  | "pricing"
  | "product_question"
  | "order_change"
  | "comfort"
  | "comfort_improvement"
  | "return_exchange"
  | "warranty"
  | "customer_availability"
  | "contact_info"
  | "general"
  | "other";

export type InteractionOutcome =
  | "resolved"
  | "follow_up_needed"
  | "waiting_on_customer"
  | "waiting_on_retailer"
  | "waiting_on_external"
  | "escalated"
  | "no_response"
  | "information_only";

export type WaitingOn =
  | "nothing"
  | "customer"
  | "inventory"
  | "vendor"
  | "delivery_team"
  | "manager"
  | "another_employee"
  | "external_party";

export const INTERACTION_TYPE_OPTIONS: { value: InteractionType; label: string }[] = [
  { value: "customer_called", label: "Customer Called" },
  { value: "called_customer", label: "Called Customer" },
  { value: "text_conversation", label: "Text Conversation" },
  { value: "email", label: "Email" },
  { value: "in_person", label: "In Person" },
  { value: "customer_request", label: "Customer Request" },
  { value: "status_update", label: "Status Update Given" },
  { value: "issue_concern", label: "Issue / Concern" },
  { value: "internal_note", label: "Internal Note" },
  { value: "other", label: "Other" },
];

export const INTERACTION_TYPE_LABELS: Record<string, string> = Object.fromEntries(
  INTERACTION_TYPE_OPTIONS.map((o) => [o.value, o.label])
);
INTERACTION_TYPE_LABELS.correction = "Correction";

export const TOPIC_OPTIONS: { value: InteractionTopic; label: string }[] = [
  { value: "inventory_eta", label: "Inventory ETA" },
  { value: "product_delay", label: "Product Delay" },
  { value: "delivery", label: "Delivery" },
  { value: "pickup", label: "Pickup" },
  { value: "scheduling", label: "Scheduling" },
  { value: "payment", label: "Payment" },
  { value: "pricing", label: "Pricing" },
  { value: "product_question", label: "Product Question" },
  { value: "order_change", label: "Order Change" },
  { value: "comfort", label: "Comfort" },
  { value: "comfort_improvement", label: "Comfort Improvement" },
  { value: "return_exchange", label: "Return / Exchange" },
  { value: "warranty", label: "Warranty" },
  { value: "customer_availability", label: "Customer Availability" },
  { value: "contact_info", label: "Contact Information" },
  { value: "general", label: "General" },
  { value: "other", label: "Other" },
];

export const TOPIC_LABELS: Record<string, string> = Object.fromEntries(
  TOPIC_OPTIONS.map((o) => [o.value, o.label])
);

export const OUTCOME_OPTIONS: { value: InteractionOutcome; label: string }[] = [
  { value: "resolved", label: "Resolved" },
  { value: "follow_up_needed", label: "Follow-Up Needed" },
  { value: "waiting_on_customer", label: "Waiting on Customer" },
  { value: "waiting_on_retailer", label: "Waiting on Retailer" },
  { value: "waiting_on_external", label: "Waiting on External Party" },
  { value: "escalated", label: "Escalated" },
  { value: "no_response", label: "No Response" },
  { value: "information_only", label: "Information Only" },
];

export const OUTCOME_LABELS: Record<string, string> = Object.fromEntries(
  OUTCOME_OPTIONS.map((o) => [o.value, o.label])
);

export const WAITING_ON_OPTIONS: { value: WaitingOn; label: string }[] = [
  { value: "nothing", label: "Nothing" },
  { value: "customer", label: "Customer" },
  { value: "inventory", label: "Inventory" },
  { value: "vendor", label: "Vendor" },
  { value: "delivery_team", label: "Delivery Team" },
  { value: "manager", label: "Manager" },
  { value: "another_employee", label: "Another Employee" },
  { value: "external_party", label: "External Party" },
];

export const WAITING_ON_LABELS: Record<string, string> = Object.fromEntries(
  WAITING_ON_OPTIONS.map((o) => [o.value, o.label])
);

export const CUSTOMER_REQUEST_CATEGORIES = [
  "Call Before Delivery",
  "Change Delivery Date",
  "Change Product",
  "Change Address",
  "Add Product",
  "Remove Product",
  "Price Question",
  "Inventory ETA",
  "Speak With Manager",
  "Other",
];

// Quick attempted-contact outcomes (source doc §22) — shown when the
// employee picks "Called Customer".
export const CALL_ATTEMPT_OUTCOMES = [
  { label: "Spoke with customer", outcome: "resolved" as InteractionOutcome, summaryPrefix: "" },
  { label: "No answer", outcome: "no_response" as InteractionOutcome, summaryPrefix: "Called customer — no answer." },
  { label: "Left voicemail", outcome: "no_response" as InteractionOutcome, summaryPrefix: "Called customer — left voicemail." },
  { label: "No voicemail", outcome: "no_response" as InteractionOutcome, summaryPrefix: "Called customer — no answer, no voicemail left." },
  { label: "Wrong number", outcome: "no_response" as InteractionOutcome, summaryPrefix: "Called customer — wrong number." },
];

// State-aware quick topic options (source doc §11). These are
// context-aware shortcuts onto the controlled topic taxonomy.
export const QUICK_TOPIC_OPTIONS: Record<
  string,
  { label: string; topic: InteractionTopic }[]
> = {
  Quoted: [
    { label: "Product Question", topic: "product_question" },
    { label: "Price Question", topic: "pricing" },
    { label: "Financing", topic: "payment" },
    { label: "Decision Timing", topic: "general" },
    { label: "Follow-Up", topic: "general" },
    { label: "Product Change", topic: "order_change" },
    { label: "Other", topic: "other" },
  ],
  "Waiting for Inventory": [
    { label: "Customer Asked for ETA", topic: "inventory_eta" },
    { label: "Gave Inventory Update", topic: "inventory_eta" },
    { label: "Product Delay", topic: "product_delay" },
    { label: "Customer Availability Changed", topic: "customer_availability" },
    { label: "Delivery Timing Question", topic: "delivery" },
    { label: "Product Change Request", topic: "order_change" },
    { label: "Customer Requested Callback", topic: "general" },
    { label: "Other", topic: "other" },
  ],
  "Ready to Schedule": [
    { label: "Scheduling Question", topic: "scheduling" },
    { label: "Customer Availability", topic: "customer_availability" },
    { label: "Delivery Contact Update", topic: "contact_info" },
    { label: "Address Question", topic: "contact_info" },
    { label: "Pickup Question", topic: "pickup" },
    { label: "Customer Requested Callback", topic: "general" },
    { label: "Other", topic: "other" },
  ],
  Scheduled: [
    { label: "Delivery Instruction", topic: "delivery" },
    { label: "Schedule Change Request", topic: "scheduling" },
    { label: "Contact Update", topic: "contact_info" },
    { label: "Access / Stairs / Gate Info", topic: "delivery" },
    { label: "Customer Asked for ETA", topic: "delivery" },
    { label: "Other", topic: "other" },
  ],
  "Sleep Trial": [
    { label: "Comfort Concern", topic: "comfort" },
    { label: "General Check-In", topic: "general" },
    { label: "Customer Reports Improvement", topic: "comfort_improvement" },
    { label: "Exchange Question", topic: "return_exchange" },
    { label: "Policy Question", topic: "general" },
    { label: "Other", topic: "other" },
  ],
};

export function quickTopicsForState(
  state: SleepJourneyState | string
): { label: string; topic: InteractionTopic }[] {
  return (
    QUICK_TOPIC_OPTIONS[state] ?? [
      { label: "General", topic: "general" },
      { label: "Other", topic: "other" },
    ]
  );
}

// ============================================================
// Row types
// ============================================================

export type CustomerContact = {
  id: string;
  customer_id: string;
  name: string;
  role_label: string | null;
  phone: string | null;
  email: string | null;
  is_delivery_contact: boolean;
  created_at: string;
};

export type JourneyInteraction = {
  id: string;
  journey_id: string;
  customer_id: string;
  interaction_type: InteractionType;
  channel: InteractionChannel;
  direction: "inbound" | "outbound" | "internal" | "system";
  topic: InteractionTopic | null;
  topic_label: string | null;
  request_category: string | null;
  contact_id: string | null;
  contact_name_snapshot: string | null;
  summary: string;
  outcome: InteractionOutcome | null;
  waiting_on: WaitingOn | null;
  commitment_made: string | null;
  occurred_at: string;
  recorded_at: string;
  created_by_employee_id: string | null;
  source_domain: string;
  source_record_id: string | null;
  is_internal: boolean;
  importance: "normal" | "important";
  pinned_until: string | null;
  entered_in_error_at: string | null;
  entered_in_error_reason: string | null;
  correction_parent_id: string | null;
  created_at: string;
  created_by?: { id: string; name: string } | null;
};

const INTERACTION_COLUMNS = `id, journey_id, customer_id, interaction_type, channel, direction,
  topic, topic_label, request_category, contact_id, contact_name_snapshot, summary, outcome,
  waiting_on, commitment_made, occurred_at, recorded_at, created_by_employee_id,
  source_domain, source_record_id, is_internal, importance, pinned_until,
  entered_in_error_at, entered_in_error_reason, correction_parent_id, created_at,
  created_by:employees!created_by_employee_id ( id, name )`;

export async function fetchJourneyInteractions(
  journeyId: string
): Promise<JourneyInteraction[]> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("journey_interactions")
    .select(INTERACTION_COLUMNS)
    .eq("journey_id", journeyId)
    .order("occurred_at", { ascending: false });

  if (error) {
    console.error("fetchJourneyInteractions error", error);
    return [];
  }
  return (data as unknown as JourneyInteraction[]) ?? [];
}

export async function fetchCustomerContacts(
  customerId: string
): Promise<CustomerContact[]> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("customer_contacts")
    .select("id, customer_id, name, role_label, phone, email, is_delivery_contact, created_at")
    .eq("customer_id", customerId)
    .order("created_at", { ascending: true });

  if (error) {
    console.error("fetchCustomerContacts error", error);
    return [];
  }
  return (data as unknown as CustomerContact[]) ?? [];
}

export async function createCustomerContact(input: {
  customer_id: string;
  name: string;
  role_label?: string | null;
  phone?: string | null;
  email?: string | null;
  is_delivery_contact?: boolean;
}): Promise<CustomerContact> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("customer_contacts")
    .insert({
      customer_id: input.customer_id,
      name: input.name.trim(),
      role_label: input.role_label?.trim() || null,
      phone: input.phone?.trim() || null,
      email: input.email?.trim() || null,
      is_delivery_contact: input.is_delivery_contact ?? false,
    })
    .select("id, customer_id, name, role_label, phone, email, is_delivery_contact, created_at")
    .single();

  if (error) throw new Error(error.message);
  return data as unknown as CustomerContact;
}

export type RecordInteractionInput = {
  journey_id: string;
  interaction_type: InteractionType;
  summary: string;
  idempotency_key: string;
  topic?: InteractionTopic | null;
  topic_label?: string | null;
  channel?: InteractionChannel | null;
  direction?: "inbound" | "outbound" | "internal" | "system" | null;
  contact_id?: string | null;
  outcome?: InteractionOutcome | null;
  waiting_on?: WaitingOn | null;
  commitment_made?: string | null;
  occurred_at?: string | null;
  is_internal?: boolean;
  importance?: "normal" | "important";
  pinned_until?: string | null;
  correction_parent_id?: string | null;
  request_category?: string | null;
  follow_up?: {
    due_at: string;
    method?: string | null;
    notes?: string | null;
    employee_id?: string | null;
    idempotency_key: string;
  } | null;
};

export async function recordJourneyInteraction(
  input: RecordInteractionInput
): Promise<string> {
  const supabase = createClient();

  const { data, error } = await supabase.rpc("record_journey_interaction", {
    p_journey_id: input.journey_id,
    p_interaction_type: input.interaction_type,
    p_summary: input.summary,
    p_idempotency_key: input.idempotency_key,
    p_topic: input.topic ?? null,
    p_topic_label: input.topic_label ?? null,
    p_channel: input.channel ?? null,
    p_direction: input.direction ?? null,
    p_contact_id: input.contact_id ?? null,
    p_outcome: input.outcome ?? null,
    p_waiting_on: input.waiting_on ?? null,
    p_commitment_made: input.commitment_made ?? null,
    p_occurred_at: input.occurred_at ?? null,
    p_is_internal: input.is_internal ?? false,
    p_importance: input.importance ?? "normal",
    p_pinned_until: input.pinned_until ?? null,
    p_correction_parent_id: input.correction_parent_id ?? null,
    p_request_category: input.request_category ?? null,
    p_source_domain: "manual",
    p_source_record_id: null,
    p_follow_up: input.follow_up ?? null,
  });

  if (error) throw new Error(error.message);
  return data as string;
}

export async function scheduleInteractionFollowUp(input: {
  interaction_id: string;
  due_at: string;
  method?: string | null;
  notes?: string | null;
  idempotency_key: string;
}): Promise<void> {
  const supabase = createClient();
  const { error } = await supabase.rpc("schedule_interaction_follow_up", {
    p_interaction_id: input.interaction_id,
    p_due_at: input.due_at,
    p_method: input.method ?? null,
    p_notes: input.notes ?? null,
    p_idempotency_key: input.idempotency_key,
  });
  if (error) throw new Error(error.message);
}

export async function markInteractionEnteredInError(
  interactionId: string,
  reason: string
) {
  const supabase = createClient();
  const { error } = await supabase.rpc("mark_interaction_entered_in_error", {
    p_interaction_id: interactionId,
    p_reason: reason,
  });
  if (error) throw new Error(error.message);
}

export async function setInteractionImportance(
  interactionId: string,
  important: boolean,
  pinnedUntil?: string | null
) {
  const supabase = createClient();
  const { error } = await supabase.rpc("set_interaction_importance", {
    p_interaction_id: interactionId,
    p_important: important,
    p_pinned_until: pinnedUntil ?? null,
  });
  if (error) throw new Error(error.message);
}
