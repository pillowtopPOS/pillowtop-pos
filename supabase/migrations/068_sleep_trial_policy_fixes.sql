-- 068_sleep_trial_policy_fixes.sql
--
-- Two fixes to the ST-2 policy model (067 already applied):
--
--   1. stv_flatten recursed with `return query select public.stv_flatten(...)`,
--      which yields one composite column instead of (path, value), so every
--      diff raised "structure of query does not match function result type" —
--      breaking draft saves after the first save and publish. Fixed to
--      `select * from`, which expands the two output columns.
--   2. The "window overlaps the minimum" fee warning is removed from
--      stv_fee_schedule; ST-7's tiered fee builder will surface that visually.
--      Its p_min_nights parameter existed only for that warning, so the
--      signature drops to 3 args (old signature dropped explicitly, since
--      create-or-replace would otherwise leave an overload) and
--      validate_sleep_trial_definition is recreated with the new call.
--
-- Pure-function replacements only; no data changes.

-- ---------------------------------------------------------------------------
-- 1. stv_flatten recursion fix
-- ---------------------------------------------------------------------------

create or replace function public.stv_flatten(p_value jsonb, p_path text default '')
returns table(path text, value text)
language plpgsql
immutable
as $$
declare
  k text;
begin
  if jsonb_typeof(p_value) = 'object' then
    for k in select key from jsonb_object_keys(p_value) as key loop
      return query
        select * from public.stv_flatten(
          p_value -> k,
          case when p_path = '' then k else p_path || '.' || k end);
    end loop;
  else
    -- Arrays compare as a whole leaf; scalars as their text.
    return query select p_path, p_value::text;
  end if;
end;
$$;

revoke execute on function public.stv_flatten(jsonb, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. stv_fee_schedule without the minimum-overlap warning
-- ---------------------------------------------------------------------------

drop function if exists public.stv_fee_schedule(jsonb, jsonb, text, int);

create or replace function public.stv_fee_schedule(
  p_acc jsonb, p_sched jsonb, p_path text
)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_errors jsonb := coalesce(p_acc -> 'errors', '[]'::jsonb);
  v_warnings jsonb := coalesce(p_acc -> 'warnings', '[]'::jsonb);
  v_windows jsonb;
  v_w jsonb;
  v_wpath text;
  v_i int;
  v_count int;
  v_prev_to int := 0;
  v_from int;
  v_to int;
  v_open_count int := 0;
  v_outcome text;
  v_pct numeric;
  v_flat numeric;
  v_min_c numeric;
  v_max_c numeric;
begin
  if p_sched is null or jsonb_typeof(p_sched) <> 'object' then
    v_errors := public.stv_err(v_errors, p_path, 'schedule must be an object');
    return jsonb_build_object('errors', v_errors, 'warnings', v_warnings);
  end if;

  v_windows := p_sched -> 'windows';
  if v_windows is null or jsonb_typeof(v_windows) <> 'array'
     or jsonb_array_length(v_windows) = 0 then
    v_errors := public.stv_err(v_errors, p_path || '.windows', 'must be a non-empty list');
    return jsonb_build_object('errors', v_errors, 'warnings', v_warnings);
  end if;

  v_count := jsonb_array_length(v_windows);
  for v_i in 0 .. v_count - 1 loop
    v_w := v_windows -> v_i;
    v_wpath := p_path || '.windows[' || v_i || ']';

    v_from := public.stv_to_int(v_w -> 'from_night');
    v_outcome := v_w ->> 'outcome';
    if v_from is null
       or jsonb_typeof(coalesce(v_w -> 'outcome', 'null'::jsonb)) <> 'string' then
      v_errors := public.stv_err(v_errors, v_wpath, 'window needs a whole-number from_night and an outcome');
      continue;
    end if;

    -- Defensive casts: the validator must report bad types, not throw.
    if v_w -> 'to_night' is null or jsonb_typeof(v_w -> 'to_night') = 'null' then
      v_to := null;
    elsif jsonb_typeof(v_w -> 'to_night') = 'number' then
      v_to := public.stv_to_int(v_w -> 'to_night');
      if v_to is null then
        v_errors := public.stv_err(v_errors, v_wpath || '.to_night', 'must be a whole number or null');
        v_to := v_from;
      end if;
    else
      v_errors := public.stv_err(v_errors, v_wpath || '.to_night', 'must be a number or null');
      v_to := v_from;
    end if;

    v_pct := case
      when v_w -> 'percent_bp' is null or jsonb_typeof(v_w -> 'percent_bp') = 'null' then 0
      when jsonb_typeof(v_w -> 'percent_bp') = 'number' then (v_w ->> 'percent_bp')::numeric
      else -1 end;
    v_flat := case
      when v_w -> 'flat_cents' is null or jsonb_typeof(v_w -> 'flat_cents') = 'null' then 0
      when jsonb_typeof(v_w -> 'flat_cents') = 'number' then (v_w ->> 'flat_cents')::numeric
      else -1 end;
    v_min_c := case
      when v_w -> 'min_cents' is null or jsonb_typeof(v_w -> 'min_cents') = 'null' then null
      when jsonb_typeof(v_w -> 'min_cents') = 'number' then (v_w ->> 'min_cents')::numeric
      else -1 end;
    v_max_c := case
      when v_w -> 'max_cents' is null or jsonb_typeof(v_w -> 'max_cents') = 'null' then null
      when jsonb_typeof(v_w -> 'max_cents') = 'number' then (v_w ->> 'max_cents')::numeric
      else -1 end;

    if v_from <> v_prev_to + 1 then
      v_errors := public.stv_err(
        v_errors, v_wpath || '.from_night',
        'windows must be contiguous (expected ' || (v_prev_to + 1) || ')');
    end if;
    if v_from < 1 then
      v_errors := public.stv_err(v_errors, v_wpath || '.from_night', 'must be at least 1');
    end if;
    if v_to is not null and v_to < v_from then
      v_errors := public.stv_err(v_errors, v_wpath || '.to_night', 'cannot be before from_night');
    end if;
    if v_to is null then
      v_open_count := v_open_count + 1;
      if v_i <> v_count - 1 then
        v_errors := public.stv_err(v_errors, v_wpath || '.to_night', 'only the last window can be open-ended');
      end if;
    else
      v_prev_to := v_to;
    end if;

    if v_outcome not in ('ALLOWED', 'APPROVAL_REQUIRED', 'PROHIBITED') then
      v_errors := public.stv_err(
        v_errors, v_wpath || '.outcome',
        'must be one of: ALLOWED, APPROVAL_REQUIRED, PROHIBITED');
    end if;
    if v_pct = -1 then
      v_errors := public.stv_err(v_errors, v_wpath || '.percent_bp', 'must be a number');
    elsif v_pct < 0 or v_pct > 10000 then
      v_errors := public.stv_err(v_errors, v_wpath || '.percent_bp', 'must be between 0 and 10000');
    end if;
    if v_flat = -1 then
      v_errors := public.stv_err(v_errors, v_wpath || '.flat_cents', 'must be a number');
    elsif v_flat < 0 then
      v_errors := public.stv_err(v_errors, v_wpath || '.flat_cents', 'cannot be negative');
    elsif v_flat > 500000 then
      v_errors := public.stv_err(v_errors, v_wpath || '.flat_cents', 'cannot exceed $5,000');
    end if;
    if v_min_c = -1 then
      v_errors := public.stv_err(v_errors, v_wpath || '.min_cents', 'must be a number');
    elsif v_min_c is not null and v_min_c < 0 then
      v_errors := public.stv_err(v_errors, v_wpath || '.min_cents', 'cannot be negative');
    end if;
    if v_max_c = -1 then
      v_errors := public.stv_err(v_errors, v_wpath || '.max_cents', 'must be a number');
    elsif v_max_c is not null and v_max_c < 0 then
      v_errors := public.stv_err(v_errors, v_wpath || '.max_cents', 'cannot be negative');
    end if;
    if v_min_c is not null and v_max_c is not null and v_min_c > v_max_c then
      v_errors := public.stv_err(v_errors, v_wpath, 'min_cents cannot exceed max_cents');
    end if;

    -- Warnings (never block publish)
    if v_outcome = 'APPROVAL_REQUIRED' and v_pct = 0 and v_flat = 0 then
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'path', v_wpath,
        'message', 'Window requires approval but charges no fee'));
    end if;
  end loop;

  if v_open_count <> 1 then
    v_errors := public.stv_err(v_errors, p_path || '.windows', 'exactly one open-ended window is required, and it must be last');
  end if;

  return jsonb_build_object('errors', v_errors, 'warnings', v_warnings);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. validate_sleep_trial_definition — recreated with the 3-arg schedule call
-- ---------------------------------------------------------------------------

create or replace function public.validate_sleep_trial_definition(p_definition jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_errors jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_acc jsonb;
  v_base jsonb;
  v_trial jsonb;
  v_exchange jsonb;
  v_return jsonb;
  v_fees jsonb;
  v_protector jsonb;
  v_split jsonb;
  v_inspection jsonb;
  v_exceptions jsonb;
  v_comm jsonb;
  v_schedules jsonb;
  v_overrides jsonb;
  v_sched_key text;
  v_length int;
  v_min int;
  v_max_count int;
  v_night jsonb;
  v_override jsonb;
  v_scope jsonb;
  v_scope_type text;
  v_scope_value text;
  v_set jsonb;
  v_set_key text;
  v_seen text[] := '{}';
  v_whitelist constant text[] := array[
    'trial.enabled', 'trial.length_nights', 'trial.minimum_nights',
    'trial.extensions_allowed', 'trial.max_extension_nights',
    'exchange.allowed', 'exchange.max_count', 'exchange.replacement_trial',
    'exchange.replacement_minimum', 'exchange.early_exception_allowed',
    'exchange.expired_exception_allowed', 'return.allowed',
    'return.approval_required', 'return.exception_allowed',
    'return.minimum_nights', 'fees.exchange_schedule', 'fees.return_schedule',
    'protector.required'
  ];
begin
  if p_definition is null or jsonb_typeof(p_definition) <> 'object' then
    return jsonb_build_object(
      'errors', jsonb_build_array(jsonb_build_object(
        'path', '', 'message', 'Definition must be an object')),
      'warnings', '[]'::jsonb);
  end if;

  if coalesce(p_definition ->> 'schema_version', '') <> '1' then
    v_errors := public.stv_err(v_errors, 'schema_version', 'must be 1');
  end if;

  v_base := p_definition -> 'base';
  if v_base is null or jsonb_typeof(v_base) <> 'object' then
    return jsonb_build_object(
      'errors', v_errors || jsonb_build_array(jsonb_build_object(
        'path', 'base', 'message', 'is required')),
      'warnings', v_warnings);
  end if;

  v_trial := v_base -> 'trial';
  v_exchange := v_base -> 'exchange';
  v_return := v_base -> 'return';
  v_fees := v_base -> 'fees';
  v_protector := v_base -> 'protector';
  v_split := v_base -> 'split_king';
  v_inspection := v_base -> 'inspection';
  v_exceptions := v_base -> 'exceptions';
  v_comm := v_base -> 'communication';
  v_schedules := p_definition -> 'fee_schedules';
  v_overrides := p_definition -> 'overrides';

  -- Section 2: Trial Terms ---------------------------------------------------
  v_errors := public.stv_bool(v_errors, v_trial -> 'enabled', 'base.trial.enabled');
  v_errors := public.stv_int(v_errors, v_trial -> 'length_nights', 'base.trial.length_nights', 1, 730);
  v_length := public.stv_to_int(v_trial -> 'length_nights');

  v_errors := public.stv_int(v_errors, v_trial -> 'minimum_nights', 'base.trial.minimum_nights', 0, 730);
  v_min := public.stv_to_int(v_trial -> 'minimum_nights');
  if v_length is not null and v_min is not null and v_min >= v_length then
    v_errors := public.stv_err(
      v_errors, 'base.trial.minimum_nights',
      'must be less than the trial length');
  end if;

  -- start_event: only FULFILLMENT_COMPLETED exists today; SALE_DATE is reserved.
  v_errors := public.stv_enum(
    v_errors, v_trial -> 'start_event', 'base.trial.start_event',
    array['FULFILLMENT_COMPLETED']);
  v_errors := public.stv_enum(
    v_errors, v_trial -> 'count_starts', 'base.trial.count_starts',
    array['DAY_AFTER_FULFILLMENT', 'FULFILLMENT_DATE']);
  v_errors := public.stv_int(v_errors, v_trial -> 'ending_soon_days', 'base.trial.ending_soon_days', 0, 60);
  v_errors := public.stv_bool(v_errors, v_trial -> 'extensions_allowed', 'base.trial.extensions_allowed');
  v_errors := public.stv_int(v_errors, v_trial -> 'max_extension_nights', 'base.trial.max_extension_nights', 1, 365);
  v_errors := public.stv_bool(v_errors, v_trial -> 'eligibility_reached_task', 'base.trial.eligibility_reached_task');
  v_errors := public.stv_bool(v_errors, v_trial -> 'ending_soon_task', 'base.trial.ending_soon_task');

  if v_trial -> 'checkin_nights' is not null then
    if jsonb_typeof(v_trial -> 'checkin_nights') <> 'array' then
      v_errors := public.stv_err(v_errors, 'base.trial.checkin_nights', 'must be a list of night numbers');
    else
      for v_night in select value from jsonb_array_elements(v_trial -> 'checkin_nights') loop
        if jsonb_typeof(v_night) <> 'number' then
          v_errors := public.stv_err(v_errors, 'base.trial.checkin_nights', 'every entry must be a whole number');
        else
          if (v_night #>> '{}')::numeric < 1 then
            v_errors := public.stv_err(v_errors, 'base.trial.checkin_nights', 'nights must be at least 1');
          elsif v_length is not null and (v_night #>> '{}')::numeric > v_length then
            v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
              'path', 'base.trial.checkin_nights',
              'message', 'Check-in night ' || (v_night #>> '{}') || ' is beyond the ' || v_length || '-night trial'));
          end if;
        end if;
      end loop;
    end if;
  end if;

  -- Section 3: Exchanges -----------------------------------------------------
  v_errors := public.stv_bool(v_errors, v_exchange -> 'allowed', 'base.exchange.allowed');
  v_errors := public.stv_int(v_errors, v_exchange -> 'max_count', 'base.exchange.max_count', 1, 5);
  v_max_count := coalesce(public.stv_to_int(v_exchange -> 'max_count'), 1);

  v_errors := public.stv_replacement_trial(
    v_errors, v_exchange -> 'replacement_trial', 'base.exchange.replacement_trial', v_max_count);
  v_errors := public.stv_minimum_rule(
    v_errors, v_exchange -> 'replacement_minimum', 'base.exchange.replacement_minimum',
    'SAME_AS_POLICY', coalesce(v_length, 730));
  v_errors := public.stv_enum(
    v_errors, v_exchange -> 'downgrade_difference', 'base.exchange.downgrade_difference',
    array['REFUND_ORIGINAL', 'STORE_CREDIT', 'NOT_REFUNDED']);
  v_errors := public.stv_bool(v_errors, v_exchange -> 'require_concern', 'base.exchange.require_concern');
  v_errors := public.stv_int(v_errors, v_exchange -> 'require_concern_age_days', 'base.exchange.require_concern_age_days', 0, 60);
  v_errors := public.stv_bool(v_errors, v_exchange -> 'early_exception_allowed', 'base.exchange.early_exception_allowed');
  v_errors := public.stv_bool(v_errors, v_exchange -> 'expired_exception_allowed', 'base.exchange.expired_exception_allowed');
  v_errors := public.stv_bool(v_errors, v_exchange -> 'cross_brand_allowed', 'base.exchange.cross_brand_allowed');
  v_errors := public.stv_bool(v_errors, v_exchange -> 'size_change_allowed', 'base.exchange.size_change_allowed');

  -- Section 4: Returns -------------------------------------------------------
  v_errors := public.stv_bool(v_errors, v_return -> 'allowed', 'base.return.allowed');
  v_errors := public.stv_bool(v_errors, v_return -> 'approval_required', 'base.return.approval_required');
  v_errors := public.stv_bool(v_errors, v_return -> 'exception_allowed', 'base.return.exception_allowed');
  v_errors := public.stv_minimum_rule(
    v_errors, v_return -> 'minimum_nights', 'base.return.minimum_nights',
    'SAME_AS_EXCHANGE', coalesce(v_length, 730));
  v_errors := public.stv_enum(
    v_errors, v_return -> 'refund_method', 'base.return.refund_method',
    array['ORIGINAL_TENDER', 'STORE_CREDIT', 'CUSTOMER_CHOICE']);

  -- Section 5: Fees ----------------------------------------------------------
  v_errors := public.stv_enum(
    v_errors, v_fees -> 'basis', 'base.fees.basis',
    array['NET_SELLING_PRICE', 'PRE_DISCOUNT_SELLING_PRICE']);
  if v_fees -> 'tiered' is not null then
    v_errors := public.stv_bool(v_errors, v_fees -> 'tiered', 'base.fees.tiered');
  end if;
  if v_fees -> 'waiver_allowed' is not null then
    v_errors := public.stv_bool(v_errors, v_fees -> 'waiver_allowed', 'base.fees.waiver_allowed');
  end if;

  if v_schedules is null or jsonb_typeof(v_schedules) <> 'object' then
    v_errors := public.stv_err(v_errors, 'fee_schedules', 'is required');
  else
    -- The two built-in schedules always exist (Section 5.3).
    for v_sched_key in select key from (values ('exchange_default'), ('return_default')) as k(key) loop
      if v_schedules -> v_sched_key is null then
        v_errors := public.stv_err(v_errors, 'fee_schedules.' || v_sched_key, 'built-in schedule is missing');
      end if;
    end loop;

    for v_sched_key in select key from jsonb_object_keys(v_schedules) as key loop
      v_acc := public.stv_fee_schedule(
        jsonb_build_object('errors', v_errors, 'warnings', v_warnings),
        v_schedules -> v_sched_key,
        'fee_schedules.' || v_sched_key);
      v_errors := v_acc -> 'errors';
      v_warnings := v_acc -> 'warnings';
    end loop;

    -- Schedule references must resolve.
    if v_fees ->> 'exchange_schedule' is not null
       and v_schedules -> (v_fees ->> 'exchange_schedule') is null then
      v_errors := public.stv_err(v_errors, 'base.fees.exchange_schedule', 'unknown fee schedule key');
    end if;
    if v_fees ->> 'return_schedule' is not null
       and v_schedules -> (v_fees ->> 'return_schedule') is null then
      v_errors := public.stv_err(v_errors, 'base.fees.return_schedule', 'unknown fee schedule key');
    end if;
  end if;

  -- Section 6: Protector -----------------------------------------------------
  v_errors := public.stv_bool(v_errors, v_protector -> 'required', 'base.protector.required');
  if v_protector -> 'qualifying_category_ids' is not null
     and jsonb_typeof(v_protector -> 'qualifying_category_ids') <> 'array' then
    v_errors := public.stv_err(v_errors, 'base.protector.qualifying_category_ids', 'must be a list of category ids');
  end if;
  if jsonb_typeof(v_protector -> 'required') = 'boolean'
     and (v_protector ->> 'required')::boolean
     and coalesce(
       case when jsonb_typeof(v_protector -> 'qualifying_category_ids') = 'array'
            then jsonb_array_length(v_protector -> 'qualifying_category_ids') end, 0) = 0 then
    v_errors := public.stv_err(
      v_errors, 'base.protector.qualifying_category_ids',
      'at least one qualifying category is required when the protector is required');
  end if;
  if v_protector -> 'qualifying_product_ids' is not null
     and jsonb_typeof(v_protector -> 'qualifying_product_ids') <> 'array' then
    v_errors := public.stv_err(v_errors, 'base.protector.qualifying_product_ids', 'must be a list of product ids');
  end if;
  v_errors := public.stv_int(v_errors, v_protector -> 'purchase_window_days', 'base.protector.purchase_window_days', 0, 120);
  v_errors := public.stv_enum(
    v_errors, v_protector -> 'missing_behavior', 'base.protector.missing_behavior',
    array['BLOCK_WITH_OVERRIDE', 'APPROVAL_REQUIRED', 'WARN_ONLY']);
  v_errors := public.stv_enum(
    v_errors, v_protector -> 'applies_to', 'base.protector.applies_to',
    array['EXCHANGE_AND_RETURN', 'EXCHANGE_ONLY', 'RETURN_ONLY']);
  v_errors := public.stv_enum(
    v_errors, v_protector -> 'split_king_units', 'base.protector.split_king_units',
    array['ONE', 'TWO']);
  if v_min is not null
     and coalesce(public.stv_to_int(v_protector -> 'purchase_window_days'), 0) > v_min then
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'path', 'base.protector.purchase_window_days',
      'message', 'Protector purchase window is longer than the ' || v_min || '-night minimum'));
  end if;

  -- Section 7: Product Rules (split king + inspection live in the base) ------
  v_errors := public.stv_enum(
    v_errors, v_split -> 'treatment', 'base.split_king.treatment',
    array['INDEPENDENT', 'PAIRED']);
  if v_inspection -> 'required' is not null then
    v_errors := public.stv_bool(v_errors, v_inspection -> 'required', 'base.inspection.required');
  end if;
  if v_inspection -> 'checklist' is not null then
    if jsonb_typeof(v_inspection -> 'checklist') <> 'array'
       or jsonb_array_length(v_inspection -> 'checklist') > 15 then
      v_errors := public.stv_err(v_errors, 'base.inspection.checklist', 'must be a list of at most 15 items');
    end if;
  end if;
  if v_inspection -> 'photos_required' is not null then
    v_errors := public.stv_bool(v_errors, v_inspection -> 'photos_required', 'base.inspection.photos_required');
  end if;
  if v_inspection -> 'failed_behavior' is not null then
    v_errors := public.stv_enum(
      v_errors, v_inspection -> 'failed_behavior', 'base.inspection.failed_behavior',
      array['BLOCK', 'APPROVAL_REQUIRED']);
  end if;

  -- Section 8: Approvals & Exceptions ---------------------------------------
  v_errors := public.stv_int(v_errors, v_exceptions -> 'approval_valid_days', 'base.exceptions.approval_valid_days', 1, 90);
  if v_exceptions -> 'reason_required' is not null then
    v_errors := public.stv_bool(v_errors, v_exceptions -> 'reason_required', 'base.exceptions.reason_required');
  end if;
  if v_exceptions -> 'attachments_allowed' is not null then
    v_errors := public.stv_bool(v_errors, v_exceptions -> 'attachments_allowed', 'base.exceptions.attachments_allowed');
  end if;
  if v_exceptions -> 'self_approval_note_required' is not null then
    v_errors := public.stv_bool(v_errors, v_exceptions -> 'self_approval_note_required', 'base.exceptions.self_approval_note_required');
  end if;

  -- Section 9: Customer Communication ---------------------------------------
  v_errors := public.stv_text(v_errors, v_comm -> 'policy_text', 'base.communication.policy_text', 5000);
  -- SIGNATURE is reserved post-MVP.
  if v_comm -> 'acknowledgment' is not null then
    v_errors := public.stv_enum(
      v_errors, v_comm -> 'acknowledgment', 'base.communication.acknowledgment',
      array['NONE', 'CHECKBOX']);
  end if;
  if v_comm -> 'show_on_receipt' is not null then
    v_errors := public.stv_bool(v_errors, v_comm -> 'show_on_receipt', 'base.communication.show_on_receipt');
  end if;

  -- Overrides (Section 6) ----------------------------------------------------
  if v_overrides is not null then
    if jsonb_typeof(v_overrides) <> 'array' then
      v_errors := public.stv_err(v_errors, 'overrides', 'must be a list');
    else
      for v_i in 0 .. jsonb_array_length(v_overrides) - 1 loop
        v_override := v_overrides -> v_i;
        v_scope := v_override -> 'scope';
        v_scope_type := v_scope ->> 'type';
        v_scope_value := v_scope ->> 'value';
        declare
          v_opath text := 'overrides[' || v_i || ']';
        begin
          if v_scope_type is null or v_scope_type not in ('CATEGORY', 'BRAND', 'PRODUCT', 'CONDITION') then
            -- STORE is retired (L5), PROMOTION is reserved post-MVP, COMPANY is
            -- the base definition rather than an override.
            v_errors := public.stv_err(
              v_errors, v_opath || '.scope.type',
              'must be one of: CATEGORY, BRAND, PRODUCT, CONDITION');
          end if;
          if v_scope_value is null or btrim(v_scope_value) = '' then
            v_errors := public.stv_err(v_errors, v_opath || '.scope.value', 'is required');
          elsif v_scope_type is not null then
            if (v_scope_type || ':' || v_scope_value) = any (v_seen) then
              v_errors := public.stv_err(
                v_errors, v_opath || '.scope',
                'another override already uses this scope (canonical 17.40)');
            end if;
            v_seen := v_seen || (v_scope_type || ':' || v_scope_value);
          end if;

          v_set := v_override -> 'set';
          if v_set is null or jsonb_typeof(v_set) <> 'object' then
            v_errors := public.stv_err(v_errors, v_opath || '.set', 'must be an object of field overrides');
          else
            for v_set_key in select key from jsonb_object_keys(v_set) as key loop
              if not (v_set_key = any (v_whitelist)) then
                v_errors := public.stv_err(
                  v_errors, v_opath || '.set.' || v_set_key,
                  'is not an overridable field (Section 6.5)');
              else
                case v_set_key
                  when 'trial.enabled', 'trial.extensions_allowed',
                       'exchange.allowed', 'exchange.early_exception_allowed',
                       'exchange.expired_exception_allowed', 'return.allowed',
                       'return.approval_required', 'return.exception_allowed',
                       'protector.required' then
                    v_errors := public.stv_bool(v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key);
                  when 'trial.length_nights' then
                    v_errors := public.stv_int(v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key, 1, 730);
                  when 'trial.minimum_nights' then
                    v_errors := public.stv_int(v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key, 0, 730);
                  when 'trial.max_extension_nights' then
                    v_errors := public.stv_int(v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key, 1, 365);
                  when 'exchange.max_count' then
                    v_errors := public.stv_int(v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key, 1, 5);
                  when 'exchange.replacement_trial' then
                    v_errors := public.stv_replacement_trial(
                      v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key, v_max_count);
                  when 'exchange.replacement_minimum' then
                    v_errors := public.stv_minimum_rule(
                      v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key,
                      'SAME_AS_POLICY', coalesce(v_length, 730));
                  when 'return.minimum_nights' then
                    v_errors := public.stv_minimum_rule(
                      v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key,
                      'SAME_AS_EXCHANGE', coalesce(v_length, 730));
                  when 'fees.exchange_schedule', 'fees.return_schedule' then
                    if jsonb_typeof(v_set -> v_set_key) <> 'string' then
                      v_errors := public.stv_err(v_errors, v_opath || '.set.' || v_set_key, 'must be a schedule key');
                    elsif v_schedules is not null
                          and v_schedules -> (v_set ->> v_set_key) is null then
                      v_errors := public.stv_err(v_errors, v_opath || '.set.' || v_set_key, 'unknown fee schedule key');
                    end if;
                  else
                    null;
                end case;
              end if;
            end loop;
          end if;
        end;
      end loop;
    end if;
  end if;

  return jsonb_build_object('errors', v_errors, 'warnings', v_warnings);
end;
$$;
