create table public.reversals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  original_sale_id uuid not null unique,
  card_id uuid not null,
  actor_user_id uuid not null references public.profiles(user_id) on delete restrict,
  credentials_exposed boolean not null,
  result_possession text not null check (result_possession in ('AGENT_STOCK', 'COMPROMISED')),
  reason_code text not null,
  created_at timestamptz not null default now(),
  foreign key (organization_id, original_sale_id) references public.sales(organization_id, id) on delete restrict,
  foreign key (organization_id, card_id) references public.cards(organization_id, id) on delete restrict
);
alter table public.reversals enable row level security;
create policy reversals_admin_or_actor_read on public.reversals for select to authenticated
  using (private.has_org_role(organization_id, array['OWNER','ADMIN']::text[])
    or (actor_user_id = (select auth.uid()) and private.has_org_role(organization_id, array['AGENT']::text[])));
grant select on public.reversals to authenticated;

create or replace function private.write_audit(
  p_organization_id uuid,
  p_actor_user_id uuid,
  p_action text,
  p_target_type text,
  p_target_id uuid,
  p_operation_id uuid,
  p_result text,
  p_reason_code text,
  p_trace_id uuid
) returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_events (organization_id, actor_user_id, action, target_type, target_id, operation_id, result, reason_code, trace_id)
  values (p_organization_id, p_actor_user_id, p_action, p_target_type, p_target_id, p_operation_id, p_result, p_reason_code, p_trace_id);
$$;

create or replace function private.begin_idempotency(
  p_organization_id uuid,
  p_actor_user_id uuid,
  p_operation_type text,
  p_key text,
  p_request_fingerprint bytea
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing_fingerprint bytea;
  saved_response jsonb;
begin
  if p_organization_id is null or p_actor_user_id is null or p_request_fingerprint is null
    or p_key is null or p_key !~ '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' then
    return jsonb_build_object('status', 'FAILED', 'code', 'INVALID_OPERATION_ID');
  end if;

  insert into public.idempotency_keys (organization_id, actor_user_id, operation_type, idempotency_key, request_fingerprint)
  values (p_organization_id, p_actor_user_id, p_operation_type, p_key, p_request_fingerprint)
  on conflict (organization_id, actor_user_id, operation_type, idempotency_key) do nothing;

  select i.request_fingerprint, i.response into existing_fingerprint, saved_response
  from public.idempotency_keys i
  where i.organization_id = p_organization_id and i.actor_user_id = p_actor_user_id
    and i.operation_type = p_operation_type and i.idempotency_key = p_key
  for update;

  if existing_fingerprint is distinct from p_request_fingerprint then
    return jsonb_build_object('status', 'FAILED', 'code', 'IDEMPOTENCY_KEY_REUSED');
  end if;
  return saved_response;
end;
$$;

create or replace function private.finish_idempotency(
  p_organization_id uuid,
  p_actor_user_id uuid,
  p_operation_type text,
  p_key text,
  p_operation_id uuid,
  p_response jsonb
) returns void
language sql
security definer
set search_path = ''
as $$
  update public.idempotency_keys i
  set operation_id = p_operation_id, response = p_response
  where i.organization_id = p_organization_id and i.actor_user_id = p_actor_user_id
    and i.operation_type = p_operation_type and i.idempotency_key = p_key;
$$;

create or replace function private.create_card_batch_impl(
  p_organization_id uuid,
  p_network_id uuid,
  p_product_id uuid,
  p_source_filename text,
  p_rows jsonb,
  p_trace_id uuid,
  p_actor_user_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := p_actor_user_id;
  v_batch_id uuid := gen_random_uuid();
  total integer;
  accepted integer;
  rejected integer;
  review integer;
begin
  if actor is null or not exists (select 1 from public.memberships m
    where m.organization_id = p_organization_id and m.user_id = actor and m.role in ('OWNER','ADMIN')) then
    return jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED');
  end if;
  if p_source_filename is null or length(p_source_filename) not between 1 and 255
    or p_rows is null or jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) not between 1 and 5000
    or not exists (select 1 from public.products p where p.id = p_product_id and p.network_id = p_network_id
      and p.organization_id = p_organization_id and p.status = 'ACTIVE') then
    return jsonb_build_object('status', 'FAILED', 'code', 'INVALID_BATCH');
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_rows) entry(value)
    where jsonb_typeof(entry.value) <> 'object'
      or coalesce(entry.value ->> 'row_number', '') !~ '^[1-9][0-9]{0,8}$'
      or coalesce(entry.value ->> 'status', '') not in ('ACCEPTED','NEEDS_REVIEW','REJECTED','INCOMPLETE','DUPLICATE_IN_FILE')
      or entry.value ?| array['access_code','username','password','voucher_code','pin','other_fields_json','credential']
      or (entry.value ->> 'status' = 'ACCEPTED' and coalesce(entry.value ->> 'error_code', '') <> '')
      or (entry.value ->> 'status' not in ('ACCEPTED','DUPLICATE_IN_FILE') and coalesce(entry.value ->> 'error_code', '') not in (
        'UNSUPPORTED_CREDENTIAL_TYPE','MISSING_REQUIRED_COLUMN','MISSING_CREDENTIAL_VALUE','INVALID_ROW'
      ))
      or (entry.value ->> 'status' = 'ACCEPTED' and (
        coalesce(entry.value ->> 'credential_type', '') not in ('ACCESS_CODE','USERNAME_PASSWORD','VOUCHER_CODE','PIN','OTHER')
        or coalesce(entry.value ->> 'ciphertext_hex', '') !~ '^([0-9a-fA-F]{2}){17,}$'
        or coalesce(entry.value ->> 'iv_hex', '') !~ '^[0-9a-fA-F]{24}$'
        or coalesce(entry.value ->> 'fingerprint_hex', '') !~ '^[0-9a-fA-F]{64}$'
      ))
      or (entry.value ->> 'status' not in ('ACCEPTED','DUPLICATE_IN_FILE') and (
        nullif(entry.value ->> 'ciphertext_hex', '') is not null
        or nullif(entry.value ->> 'iv_hex', '') is not null
        or nullif(entry.value ->> 'fingerprint_hex', '') is not null
      ))
  ) or (select count(*) <> count(distinct (entry.value ->> 'row_number')) from jsonb_array_elements(p_rows) entry(value)) then
    return jsonb_build_object('status', 'FAILED', 'code', 'INVALID_IMPORT_ROWS');
  end if;

  total := jsonb_array_length(p_rows);
  insert into public.card_batches (id, organization_id, network_id, product_id, source_filename, uploaded_by, total_rows)
  values (v_batch_id, p_organization_id, p_network_id, p_product_id, p_source_filename, actor, total);

  insert into public.import_rows (batch_id, row_number, status, credential_type, credential_ciphertext, credential_iv, credential_fingerprint, error_code)
  select v_batch_id, (entry.value ->> 'row_number')::integer, entry.value ->> 'status', entry.value ->> 'credential_type',
    case when entry.value ->> 'ciphertext_hex' is null then null else decode(entry.value ->> 'ciphertext_hex', 'hex') end,
    case when entry.value ->> 'iv_hex' is null then null else decode(entry.value ->> 'iv_hex', 'hex') end,
    case when entry.value ->> 'fingerprint_hex' is null then null else decode(entry.value ->> 'fingerprint_hex', 'hex') end,
    entry.value ->> 'error_code'
  from jsonb_array_elements(p_rows) as entry(value);

  update public.import_rows r set status = 'ALREADY_EXISTS', credential_type = null,
    credential_ciphertext = null, credential_iv = null, credential_fingerprint = null, error_code = 'ALREADY_EXISTS'
  where r.batch_id = v_batch_id and r.status = 'ACCEPTED'
    and exists (select 1 from public.cards c where c.organization_id = p_organization_id
      and c.credential_fingerprint = r.credential_fingerprint);

  with duplicate_rows as (
    select r.id, row_number() over (partition by r.credential_fingerprint order by r.row_number) as occurrence
    from public.import_rows r where r.batch_id = v_batch_id and r.status = 'ACCEPTED'
  )
  update public.import_rows r set status = 'DUPLICATE_IN_FILE', credential_type = null,
    credential_ciphertext = null, credential_iv = null, credential_fingerprint = null, error_code = 'DUPLICATE_IN_FILE'
  from duplicate_rows d where r.id = d.id and d.occurrence > 1;

  select count(*) filter (where status = 'ACCEPTED'),
    count(*) filter (where status in ('REJECTED', 'DUPLICATE_IN_FILE', 'ALREADY_EXISTS')),
    count(*) filter (where status in ('NEEDS_REVIEW', 'INCOMPLETE'))
    into accepted, rejected, review from public.import_rows where batch_id = v_batch_id;
  update public.card_batches set accepted_rows = accepted, rejected_rows = rejected, review_rows = review where id = v_batch_id;

  perform private.write_audit(p_organization_id, actor, 'IMPORT_CREATED', 'CARD_BATCH', v_batch_id, v_batch_id, 'SUCCESS', null, p_trace_id);
  return jsonb_build_object('status', 'SUCCESS', 'batch_id', v_batch_id, 'total_rows', total,
    'accepted_rows', accepted, 'rejected_rows', rejected, 'review_rows', review);
end;
$$;

create or replace function public.create_card_batch(
  p_organization_id uuid, p_network_id uuid, p_product_id uuid, p_source_filename text, p_rows jsonb, p_trace_id uuid,
  p_actor_user_id uuid
) returns jsonb
language sql
security invoker
set search_path = ''
as $$ select private.create_card_batch_impl(p_organization_id, p_network_id, p_product_id, p_source_filename, p_rows, p_trace_id, p_actor_user_id); $$;

create or replace function private.approve_card_batch_impl(
  p_organization_id uuid, p_batch_id uuid, p_idempotency_key text, p_trace_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  batch public.card_batches%rowtype;
  request_hash bytea;
  replay jsonb;
  result jsonb;
  card_count integer;
begin
  if actor is null or not private.has_org_role(p_organization_id, array['OWNER','ADMIN']::text[]) then
    return jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED');
  end if;
  request_hash := extensions.digest(convert_to(p_organization_id::text || ':' || p_batch_id::text, 'UTF8'), 'sha256');
  replay := private.begin_idempotency(p_organization_id, actor, 'IMPORT_APPROVAL', p_idempotency_key, request_hash);
  if replay is not null then return replay; end if;

  select * into batch from public.card_batches where id = p_batch_id and organization_id = p_organization_id for update;
  if not found or batch.status <> 'REVIEW' then
    result := jsonb_build_object('status', 'FAILED', 'code', 'BATCH_NOT_REVIEWABLE');
  elsif batch.accepted_rows = 0 then
    result := jsonb_build_object('status', 'FAILED', 'code', 'NO_ACCEPTED_ROWS');
  elsif batch.rejected_rows > 0 or batch.review_rows > 0 then
    result := jsonb_build_object('status', 'FAILED', 'code', 'ROW_REVIEW_REQUIRED');
  else
    insert into public.cards (organization_id, network_id, product_id, batch_id, credential_type,
      credential_ciphertext, credential_iv, credential_fingerprint, possession, operation_state, external_network_state)
    select p_organization_id, batch.network_id, batch.product_id, batch.id, r.credential_type,
      r.credential_ciphertext, r.credential_iv, r.credential_fingerprint, 'OWNER_STOCK', 'COMPLETED', 'UNKNOWN'
    from public.import_rows r where r.batch_id = batch.id and r.status = 'ACCEPTED';
    get diagnostics card_count = row_count;

    insert into public.inventory_movements (organization_id, card_id, from_possession, to_possession,
      operation_type, operation_id, actor_user_id, reason_code)
    select p_organization_id, c.id, null, 'OWNER_STOCK', 'IMPORT_APPROVAL', batch.id, actor, 'BATCH_APPROVED'
    from public.cards c where c.batch_id = batch.id;

    update public.card_batches set status = 'APPROVED', approved_by = actor, approved_at = now() where id = batch.id;
    result := jsonb_build_object('status', 'SUCCESS', 'batch_id', batch.id, 'cards_added', card_count);
    perform private.write_audit(p_organization_id, actor, 'IMPORT_APPROVED', 'CARD_BATCH', batch.id, batch.id, 'SUCCESS', null, p_trace_id);
  end if;

  perform private.finish_idempotency(p_organization_id, actor, 'IMPORT_APPROVAL', p_idempotency_key,
    p_batch_id, result);
  return result;
end;
$$;

create or replace function public.approve_card_batch(
  p_organization_id uuid, p_batch_id uuid, p_idempotency_key text, p_trace_id uuid
) returns jsonb
language sql security invoker set search_path = ''
as $$ select private.approve_card_batch_impl(p_organization_id, p_batch_id, p_idempotency_key, p_trace_id); $$;

create or replace function private.create_owner_agent_transfer_impl(
  p_organization_id uuid, p_agent_id uuid, p_network_id uuid, p_product_id uuid,
  p_quantity integer, p_idempotency_key text, p_trace_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  request_hash bytea;
  replay jsonb;
  result jsonb;
  transfer_id uuid := gen_random_uuid();
  transfer_expires_at timestamptz;
  card_ids uuid[];
  selected_count integer;
begin
  if actor is null or not private.has_org_role(p_organization_id, array['OWNER','ADMIN']::text[]) then
    return jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED');
  end if;
  request_hash := extensions.digest(convert_to(concat_ws(':', p_organization_id, p_agent_id, p_network_id, p_product_id, p_quantity), 'UTF8'), 'sha256');
  replay := private.begin_idempotency(p_organization_id, actor, 'TRANSFER_CREATE', p_idempotency_key, request_hash);
  if replay is not null then return replay; end if;

  if p_quantity not between 1 and 500
    or not exists (select 1 from public.agents a where a.id = p_agent_id and a.organization_id = p_organization_id and a.active)
    or not exists (select 1 from public.products p where p.id = p_product_id and p.network_id = p_network_id
      and p.organization_id = p_organization_id and p.status = 'ACTIVE') then
    result := jsonb_build_object('status', 'FAILED', 'code', 'INVALID_TRANSFER_REQUEST');
  else
    select coalesce(array_agg(eligible.id order by eligible.created_at, eligible.id), array[]::uuid[])
      into card_ids
    from (
      select c.id, c.created_at from public.cards c
      where c.organization_id = p_organization_id and c.product_id = p_product_id
        and c.possession = 'OWNER_STOCK' and c.operation_state = 'COMPLETED'
      order by c.created_at, c.id limit p_quantity for update skip locked
    ) eligible;
    selected_count := coalesce(array_length(card_ids, 1), 0);
    if selected_count <> p_quantity then
      result := jsonb_build_object('status', 'FAILED', 'code', 'INSUFFICIENT_OWNER_STOCK');
    else
      insert into public.transfers (id, organization_id, agent_id, network_id, product_id, status, created_by)
      values (transfer_id, p_organization_id, p_agent_id, p_network_id, p_product_id, 'PENDING_ACCEPTANCE', actor)
      returning expires_at into transfer_expires_at;
      insert into public.transfer_items (transfer_id, card_id, organization_id)
        select transfer_id, unnest(card_ids), p_organization_id;
      update public.cards set operation_state = 'RESERVED', updated_at = now() where id = any(card_ids);
      insert into public.inventory_movements (organization_id, card_id, from_possession, to_possession,
        operation_type, operation_id, actor_user_id, reason_code, from_operation_state, to_operation_state)
      select p_organization_id, unnest(card_ids), 'OWNER_STOCK', 'OWNER_STOCK', 'TRANSFER_RESERVATION', transfer_id,
        actor, 'PENDING_AGENT_ACCEPTANCE', 'COMPLETED', 'RESERVED';
      result := jsonb_build_object('status', 'SUCCESS', 'transfer_id', transfer_id, 'quantity', p_quantity,
        'expires_at', transfer_expires_at);
      perform private.write_audit(p_organization_id, actor, 'TRANSFER_CREATED', 'TRANSFER', transfer_id, transfer_id, 'PENDING', null, p_trace_id);
    end if;
  end if;

  perform private.finish_idempotency(p_organization_id, actor, 'TRANSFER_CREATE', p_idempotency_key, transfer_id, result);
  return result;
end;
$$;

create or replace function public.create_owner_agent_transfer(
  p_organization_id uuid, p_agent_id uuid, p_network_id uuid, p_product_id uuid,
  p_quantity integer, p_idempotency_key text, p_trace_id uuid
) returns jsonb
language sql security invoker set search_path = ''
as $$ select private.create_owner_agent_transfer_impl(p_organization_id, p_agent_id, p_network_id, p_product_id, p_quantity, p_idempotency_key, p_trace_id); $$;

create or replace function private.accept_owner_agent_transfer_impl(
  p_organization_id uuid, p_transfer_id uuid, p_idempotency_key text, p_trace_id uuid
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  request_hash bytea;
  replay jsonb;
  result jsonb;
  transfer public.transfers%rowtype;
  agent_id uuid;
  item_count integer;
  card_ids uuid[];
  affected integer;
begin
  if actor is null then return jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED'); end if;
  request_hash := extensions.digest(convert_to(p_organization_id::text || ':' || p_transfer_id::text, 'UTF8'), 'sha256');
  replay := private.begin_idempotency(p_organization_id, actor, 'TRANSFER_ACCEPT', p_idempotency_key, request_hash);
  if replay is not null then return replay; end if;

  select a.id into agent_id from public.agents a
  where a.organization_id = p_organization_id and a.user_id = actor and a.active
    and private.has_org_role(p_organization_id, array['AGENT']::text[]);
  select * into transfer from public.transfers t where t.id = p_transfer_id and t.organization_id = p_organization_id for update;
  if agent_id is null or not found or transfer.agent_id <> agent_id or transfer.status <> 'PENDING_ACCEPTANCE'
    or transfer.expires_at <= clock_timestamp() then
    result := jsonb_build_object('status', 'FAILED', 'code', 'TRANSFER_NOT_ACCEPTABLE');
  else
    select count(*) into item_count from public.transfer_items where transfer_id = transfer.id;
    perform 1 from public.cards c join public.transfer_items ti on ti.card_id = c.id
      where ti.transfer_id = transfer.id order by c.id for update of c;
    select array_agg(c.id order by c.id) into card_ids
      from public.cards c join public.transfer_items ti on ti.card_id = c.id
      where ti.transfer_id = transfer.id and c.possession = 'OWNER_STOCK'
        and c.operation_state = 'RESERVED' and c.current_agent_id is null;
    if coalesce(array_length(card_ids, 1), 0) <> item_count or item_count = 0 then
      result := jsonb_build_object('status', 'FAILED', 'code', 'TRANSFER_INVENTORY_MISMATCH');
    else
      update public.cards set possession = 'AGENT_STOCK', current_agent_id = agent_id,
        operation_state = 'COMPLETED', updated_at = now() where id = any(card_ids);
      get diagnostics affected = row_count;
      if affected <> item_count then raise exception 'transfer_inventory_mismatch'; end if;
      insert into public.inventory_movements (organization_id, card_id, from_possession, to_possession,
        operation_type, operation_id, actor_user_id, reason_code, from_operation_state, to_operation_state)
      select p_organization_id, unnest(card_ids), 'OWNER_STOCK', 'AGENT_STOCK', 'TRANSFER_ACCEPTANCE', transfer.id,
        actor, 'AGENT_ACCEPTED', 'RESERVED', 'COMPLETED';
      update public.transfers set status = 'ACCEPTED', accepted_by = actor, accepted_at = now() where id = transfer.id;
      result := jsonb_build_object('status', 'SUCCESS', 'transfer_id', transfer.id, 'quantity', item_count);
      perform private.write_audit(p_organization_id, actor, 'TRANSFER_ACCEPTED', 'TRANSFER', transfer.id, transfer.id, 'SUCCESS', null, p_trace_id);
    end if;
  end if;
  perform private.finish_idempotency(p_organization_id, actor, 'TRANSFER_ACCEPT', p_idempotency_key, p_transfer_id, result);
  return result;
end;
$$;

create or replace function public.accept_owner_agent_transfer(
  p_organization_id uuid, p_transfer_id uuid, p_idempotency_key text, p_trace_id uuid
) returns jsonb language sql security invoker set search_path = ''
as $$ select private.accept_owner_agent_transfer_impl(p_organization_id, p_transfer_id, p_idempotency_key, p_trace_id); $$;

create or replace function private.expire_owner_agent_transfers_impl(
  p_organization_id uuid, p_limit integer, p_trace_id uuid
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  transfer record;
  expired_count integer := 0;
  expected_count integer;
  released_count integer;
  item record;
begin
  if actor is null or not private.has_org_role(p_organization_id, array['OWNER','ADMIN']::text[])
    or p_limit not between 1 and 100 then
    return jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED');
  end if;

  for transfer in
    select t.id from public.transfers t
    where t.organization_id = p_organization_id and t.status = 'PENDING_ACCEPTANCE' and t.expires_at <= clock_timestamp()
    order by t.expires_at, t.id limit p_limit for update skip locked
  loop
    select count(*) into expected_count from public.transfer_items ti where ti.transfer_id = transfer.id;
    perform 1 from public.cards c join public.transfer_items ti on ti.card_id = c.id
      where ti.transfer_id = transfer.id and c.organization_id = p_organization_id
        and c.possession = 'OWNER_STOCK' and c.operation_state = 'RESERVED' and c.current_agent_id is null
      order by c.id for update of c;
    get diagnostics released_count = row_count;
    if expected_count = 0 or released_count <> expected_count then
      raise exception 'transfer_inventory_mismatch';
    end if;
    for item in
      select c.id from public.cards c join public.transfer_items ti on ti.card_id = c.id
      where ti.transfer_id = transfer.id and c.organization_id = p_organization_id
        and c.possession = 'OWNER_STOCK' and c.operation_state = 'RESERVED' and c.current_agent_id is null
      order by c.id for update of c
    loop
      update public.cards set operation_state = 'COMPLETED', updated_at = now() where id = item.id;
      insert into public.inventory_movements (organization_id, card_id, from_possession, to_possession,
        operation_type, operation_id, actor_user_id, reason_code, from_operation_state, to_operation_state)
      values (p_organization_id, item.id, 'OWNER_STOCK', 'OWNER_STOCK', 'TRANSFER_EXPIRY', transfer.id,
        actor, 'PENDING_TRANSFER_EXPIRED', 'RESERVED', 'COMPLETED');
    end loop;
    update public.transfers set status = 'EXPIRED' where id = transfer.id and status = 'PENDING_ACCEPTANCE';
    if found then
      expired_count := expired_count + 1;
      perform private.write_audit(p_organization_id, actor, 'TRANSFER_EXPIRED', 'TRANSFER', transfer.id,
        transfer.id, 'SUCCESS', 'PENDING_TRANSFER_EXPIRED', p_trace_id);
    end if;
  end loop;
  return jsonb_build_object('status', 'SUCCESS', 'expired_count', expired_count);
end;
$$;

create or replace function public.expire_owner_agent_transfers(p_organization_id uuid, p_limit integer, p_trace_id uuid)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.expire_owner_agent_transfers_impl(p_organization_id, p_limit, p_trace_id); $$;

create or replace function private.bootstrap_first_owner_impl(p_organization_name text, p_owner_user_id uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  new_organization_id uuid;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'bootstrap_requires_service_role' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(1189944387, 1);
  if p_owner_user_id is null or p_organization_name is null or length(btrim(p_organization_name)) not between 1 and 160
    or not exists (select 1 from public.profiles p where p.user_id = p_owner_user_id)
    or exists (select 1 from public.memberships m where m.role = 'OWNER')
    or exists (select 1 from public.organizations) then
    raise exception 'bootstrap_not_available_or_invalid' using errcode = '22023';
  end if;
  insert into public.organizations (name) values (btrim(p_organization_name)) returning id into new_organization_id;
  insert into public.memberships (organization_id, user_id, role) values (new_organization_id, p_owner_user_id, 'OWNER');
  return new_organization_id;
end;
$$;

create or replace function public.bootstrap_first_owner(p_organization_name text, p_owner_user_id uuid)
returns uuid language sql security invoker set search_path = ''
as $$ select private.bootstrap_first_owner_impl(p_organization_name, p_owner_user_id); $$;

create or replace function private.create_agent_sale_impl(
  p_organization_id uuid, p_customer_id uuid, p_network_id uuid, p_product_id uuid,
  p_idempotency_key text, p_trace_id uuid
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  agent_id uuid;
  request_hash bytea;
  replay jsonb;
  result jsonb;
  card_id uuid;
  sale_id uuid := gen_random_uuid();
begin
  if actor is null then return jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED'); end if;
  select a.id into agent_id from public.agents a
  where a.organization_id = p_organization_id and a.user_id = actor and a.active
    and private.has_org_role(p_organization_id, array['AGENT']::text[]);
  if agent_id is null then return jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED'); end if;

  request_hash := extensions.digest(convert_to(concat_ws(':', p_organization_id, p_customer_id, p_network_id, p_product_id), 'UTF8'), 'sha256');
  replay := private.begin_idempotency(p_organization_id, actor, 'SALE_CREATE', p_idempotency_key, request_hash);
  if replay is not null then return replay; end if;

  if not exists (select 1 from public.customers c where c.id = p_customer_id and c.organization_id = p_organization_id and c.status = 'ACTIVE')
    or not exists (select 1 from public.products p where p.id = p_product_id and p.network_id = p_network_id
      and p.organization_id = p_organization_id and p.status = 'ACTIVE') then
    result := jsonb_build_object('status', 'FAILED', 'code', 'INVALID_SALE_REQUEST');
  else
    select c.id into card_id from public.cards c
    where c.organization_id = p_organization_id and c.current_agent_id = agent_id
      and c.product_id = p_product_id and c.possession = 'AGENT_STOCK' and c.operation_state = 'COMPLETED'
    order by c.created_at, c.id limit 1 for update skip locked;

    if card_id is null then
      result := jsonb_build_object('status', 'FAILED', 'code', 'INSUFFICIENT_AGENT_STOCK');
    else
      insert into public.sales (id, organization_id, agent_id, customer_id, status, created_by)
        values (sale_id, p_organization_id, agent_id, p_customer_id, 'COMPLETED', actor);
      insert into public.sale_items (sale_id, card_id, organization_id) values (sale_id, card_id, p_organization_id);
      insert into public.deliveries (sale_id, customer_id, selling_agent_id, status, delivered_at, organization_id)
        values (sale_id, p_customer_id, agent_id, 'COMPLETED', now(), p_organization_id);
      update public.cards set possession = 'CUSTOMER_CUSTODY', current_agent_id = null,
        customer_id = p_customer_id, operation_state = 'COMPLETED', updated_at = now() where id = card_id;
      insert into public.inventory_movements (organization_id, card_id, from_possession, to_possession,
        operation_type, operation_id, actor_user_id, reason_code)
        values (p_organization_id, card_id, 'AGENT_STOCK', 'CUSTOMER_CUSTODY', 'SALE_DELIVERY', sale_id, actor, 'CUSTOMER_SELECTED');
      perform private.write_audit(p_organization_id, actor, 'SALE_COMPLETED', 'SALE', sale_id, sale_id, 'SUCCESS', null, p_trace_id);
      result := jsonb_build_object('status', 'SUCCESS', 'sale_id', sale_id, 'delivery_id', (select d.id from public.deliveries d where d.sale_id = sale_id));
    end if;
  end if;
  perform private.finish_idempotency(p_organization_id, actor, 'SALE_CREATE', p_idempotency_key, sale_id, result);
  return result;
end;
$$;

create or replace function public.create_agent_sale(
  p_organization_id uuid, p_customer_id uuid, p_network_id uuid, p_product_id uuid,
  p_idempotency_key text, p_trace_id uuid
) returns jsonb language sql security invoker set search_path = ''
as $$ select private.create_agent_sale_impl(p_organization_id, p_customer_id, p_network_id, p_product_id, p_idempotency_key, p_trace_id); $$;

create or replace function private.issue_customer_claim_token_impl()
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  customer public.customers%rowtype;
  token text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  select * into customer from public.customers c where c.user_id = actor for update;
  if actor is null or not found or customer.status <> 'INACTIVE' then raise exception 'activation_not_available' using errcode = '42501'; end if;
  update public.claim_tokens set revoked_at = now() where customer_id = customer.id and used_at is null and revoked_at is null;
  insert into public.claim_tokens (customer_id, token_fingerprint, expires_at)
    values (customer.id, extensions.digest(convert_to(token, 'UTF8'), 'sha256'), now() + interval '10 minutes');
  return token;
end;
$$;

create or replace function public.issue_customer_claim_token()
returns text language sql security invoker set search_path = ''
as $$ select private.issue_customer_claim_token_impl(); $$;

create or replace function private.activate_customer_with_claim_token_impl(p_token text, p_organization_id uuid, p_trace_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  token_row public.claim_tokens%rowtype;
  customer public.customers%rowtype;
  agent public.agents%rowtype;
begin
  if actor is null or p_token !~ '^[0-9a-f]{48}$' then
    return jsonb_build_object('status', 'FAILED', 'code', 'INVALID_OR_EXPIRED_CODE');
  end if;
  select * into agent from public.agents a where a.user_id = actor and a.organization_id = p_organization_id and a.active
    and private.has_org_role(p_organization_id, array['AGENT']::text[]) limit 1;
  if not found then return jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED'); end if;
  select * into token_row from public.claim_tokens ct
    where ct.token_fingerprint = extensions.digest(convert_to(p_token, 'UTF8'), 'sha256')
    for update;
  if not found or token_row.used_at is not null or token_row.revoked_at is not null or token_row.expires_at <= now()
    or token_row.failed_attempts >= 5 then
    return jsonb_build_object('status', 'FAILED', 'code', 'INVALID_OR_EXPIRED_CODE');
  end if;
  select * into customer from public.customers c where c.id = token_row.customer_id for update;
  if customer.status <> 'INACTIVE' then return jsonb_build_object('status', 'FAILED', 'code', 'INVALID_OR_EXPIRED_CODE'); end if;

  update public.customers set organization_id = agent.organization_id, status = 'ACTIVE',
    activation_agent_id = agent.id, updated_at = now() where id = customer.id;
  insert into public.memberships (organization_id, user_id, role)
    values (agent.organization_id, customer.user_id, 'CUSTOMER');
  update public.claim_tokens set used_at = now() where id = token_row.id;
  perform private.write_audit(agent.organization_id, actor, 'CUSTOMER_ACTIVATED', 'CUSTOMER', customer.id, token_row.id, 'SUCCESS', null, p_trace_id);
  insert into public.security_events (organization_id, actor_user_id, event_type, target_id, result, trace_id)
    values (agent.organization_id, actor, 'SENSITIVE_ACTION', customer.id, 'SUCCESS', p_trace_id);
  return jsonb_build_object('status', 'SUCCESS', 'customer_id', customer.id);
end;
$$;

create or replace function public.activate_customer_with_claim_token(p_token text, p_organization_id uuid, p_trace_id uuid)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.activate_customer_with_claim_token_impl(p_token, p_organization_id, p_trace_id); $$;

create or replace function private.get_card_credential_impl(p_card_id uuid, p_trace_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  card public.cards%rowtype;
  can_reveal boolean := false;
begin
  if actor is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into card from public.cards c where c.id = p_card_id for update;
  if not found then raise exception 'not_authorized' using errcode = '42501'; end if;

  can_reveal := private.has_org_role(card.organization_id, array['OWNER','ADMIN']::text[])
    or exists (select 1 from public.customers c where c.id = card.customer_id
      and c.organization_id = card.organization_id and c.user_id = actor and c.status = 'ACTIVE'
      and card.possession = 'CUSTOMER_CUSTODY'
      and private.has_org_role(card.organization_id, array['CUSTOMER']::text[]));
  if not can_reveal then raise exception 'not_authorized' using errcode = '42501'; end if;

  insert into public.security_events (organization_id, actor_user_id, event_type, target_id, result, trace_id)
    values (card.organization_id, actor, 'CREDENTIAL_REVEAL', card.id, 'SUCCESS', p_trace_id);
  perform private.write_audit(card.organization_id, actor, 'CREDENTIAL_REVEAL', 'CARD', card.id, null, 'SUCCESS', null, p_trace_id);
  return jsonb_build_object('credential_type', card.credential_type,
    'ciphertext_hex', encode(card.credential_ciphertext, 'hex'), 'iv_hex', encode(card.credential_iv, 'hex'),
    'key_version', card.credential_key_version);
end;
$$;

create or replace function public.get_card_credential(p_card_id uuid, p_trace_id uuid)
returns jsonb language sql security invoker set search_path = ''
as $$ select private.get_card_credential_impl(p_card_id, p_trace_id); $$;

create or replace function private.reverse_sale_delivery_impl(
  p_organization_id uuid, p_sale_id uuid, p_reason_code text, p_idempotency_key text, p_trace_id uuid
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  request_hash bytea;
  replay jsonb;
  result jsonb;
  sale public.sales%rowtype;
  delivery public.deliveries%rowtype;
  item_card uuid;
  exposed boolean;
  destination text;
begin
  if p_reason_code is not null and p_reason_code not in ('', 'WRONG_DELIVERY') then
    return jsonb_build_object('status', 'FAILED', 'code', 'INVALID_REASON_CODE');
  end if;
  if actor is null or not private.has_org_role(p_organization_id, array['OWNER','ADMIN','AGENT']::text[]) then
    return jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED');
  end if;
  request_hash := extensions.digest(convert_to(p_organization_id::text || ':' || p_sale_id::text || ':' || coalesce(p_reason_code, ''), 'UTF8'), 'sha256');
  replay := private.begin_idempotency(p_organization_id, actor, 'SALE_REVERSAL', p_idempotency_key, request_hash);
  if replay is not null then return replay; end if;

  select * into sale from public.sales s where s.id = p_sale_id and s.organization_id = p_organization_id for update;
  if not found then
    result := jsonb_build_object('status', 'FAILED', 'code', 'DELIVERY_NOT_REVERSIBLE');
  elsif not private.has_org_role(p_organization_id, array['OWNER','ADMIN']::text[])
    and not exists (select 1 from public.agents a where a.organization_id = p_organization_id and a.id = sale.agent_id
      and a.user_id = actor and a.active and private.has_org_role(p_organization_id, array['AGENT']::text[])) then
    result := jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED');
  else
  select * into delivery from public.deliveries d where d.sale_id = p_sale_id for update;
  select si.card_id into item_card from public.sale_items si where si.sale_id = p_sale_id;
  if not found or delivery.id is null or delivery.status <> 'COMPLETED' or item_card is null
    or exists (select 1 from public.reversals r where r.original_sale_id = p_sale_id) then
    result := jsonb_build_object('status', 'FAILED', 'code', 'DELIVERY_NOT_REVERSIBLE');
  else
    perform 1 from public.cards c where c.id = item_card and c.possession = 'CUSTOMER_CUSTODY'
      and c.customer_id = sale.customer_id for update;
    if not found then
      result := jsonb_build_object('status', 'FAILED', 'code', 'DELIVERY_NOT_REVERSIBLE');
    else
    select exists (select 1 from public.security_events e where e.event_type = 'CREDENTIAL_REVEAL' and e.target_id = item_card)
      into exposed;
    destination := case when exposed then 'COMPROMISED' else 'AGENT_STOCK' end;
    if not exposed then
      update public.cards set possession = 'AGENT_STOCK', current_agent_id = sale.agent_id,
        customer_id = null, operation_state = 'COMPLETED', updated_at = now() where id = item_card;
    else
      update public.cards set possession = 'COMPROMISED', current_agent_id = null,
        customer_id = sale.customer_id, operation_state = 'COMPLETED', updated_at = now() where id = item_card;
    end if;
    insert into public.reversals (organization_id, original_sale_id, card_id, actor_user_id, credentials_exposed, result_possession, reason_code)
      values (p_organization_id, p_sale_id, item_card, actor, exposed, destination, coalesce(nullif(p_reason_code, ''), 'WRONG_DELIVERY'));
    insert into public.inventory_movements (organization_id, card_id, from_possession, to_possession,
      operation_type, operation_id, actor_user_id, reason_code)
      values (p_organization_id, item_card, 'CUSTOMER_CUSTODY', destination, 'SALE_REVERSAL', p_sale_id, actor,
        case when exposed then 'CREDENTIAL_PREVIOUSLY_REVEALED' else coalesce(nullif(p_reason_code, ''), 'WRONG_DELIVERY') end);
    result := jsonb_build_object('status', 'SUCCESS', 'sale_id', p_sale_id, 'result_possession', destination);
    perform private.write_audit(p_organization_id, actor, 'SALE_REVERSED', 'SALE', p_sale_id, p_sale_id, 'SUCCESS', p_reason_code, p_trace_id);
    end if;
  end if;
  end if;
  perform private.finish_idempotency(p_organization_id, actor, 'SALE_REVERSAL', p_idempotency_key, p_sale_id, result);
  return result;
end;
$$;

create or replace function public.reverse_sale_delivery(
  p_organization_id uuid, p_sale_id uuid, p_reason_code text, p_idempotency_key text, p_trace_id uuid
) returns jsonb language sql security invoker set search_path = ''
as $$ select private.reverse_sale_delivery_impl(p_organization_id, p_sale_id, p_reason_code, p_idempotency_key, p_trace_id); $$;

create or replace function private.record_security_event_impl(p_event_type text, p_trace_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  org uuid;
begin
  if actor is null or p_event_type is distinct from 'LOGIN_SUCCESS' then
    raise exception 'invalid_security_event' using errcode = '42501';
  end if;
  select m.organization_id into org from public.memberships m where m.user_id = actor limit 1;
  insert into public.security_events (organization_id, actor_user_id, event_type, result, trace_id)
    values (org, actor, p_event_type, 'SUCCESS', p_trace_id);
end;
$$;

create or replace function public.record_security_event(p_event_type text, p_trace_id uuid)
returns void language sql security invoker set search_path = ''
as $$ select private.record_security_event_impl(p_event_type, p_trace_id); $$;

revoke all on all functions in schema private from public, anon;
revoke all on function public.create_card_batch(uuid, uuid, uuid, text, jsonb, uuid, uuid) from public, anon, authenticated;
revoke all on function public.approve_card_batch(uuid, uuid, text, uuid) from public, anon;
revoke all on function public.create_owner_agent_transfer(uuid, uuid, uuid, uuid, integer, text, uuid) from public, anon;
revoke all on function public.accept_owner_agent_transfer(uuid, uuid, text, uuid) from public, anon;
revoke all on function public.create_agent_sale(uuid, uuid, uuid, uuid, text, uuid) from public, anon;
revoke all on function public.issue_customer_claim_token() from public, anon;
revoke all on function public.activate_customer_with_claim_token(text, uuid, uuid) from public, anon;
revoke all on function public.get_card_credential(uuid, uuid) from public, anon;
revoke all on function public.get_card_credential(uuid, uuid) from authenticated;
revoke all on function public.reverse_sale_delivery(uuid, uuid, text, text, uuid) from public, anon;
revoke all on function public.record_security_event(text, uuid) from public, anon;
revoke all on function public.expire_owner_agent_transfers(uuid, integer, uuid) from public, anon;
revoke all on function public.bootstrap_first_owner(text, uuid) from public, anon, authenticated;
revoke all on function private.create_card_batch_impl(uuid, uuid, uuid, text, jsonb, uuid, uuid) from public, anon, authenticated;
revoke all on function private.expire_owner_agent_transfers_impl(uuid, integer, uuid) from public, anon, authenticated;
revoke all on function private.bootstrap_first_owner_impl(text, uuid) from public, anon, authenticated;
grant usage on schema private to service_role;
grant execute on function private.create_card_batch_impl(uuid, uuid, uuid, text, jsonb, uuid, uuid) to service_role;
grant execute on function public.create_card_batch(uuid, uuid, uuid, text, jsonb, uuid, uuid) to service_role;
grant execute on function private.bootstrap_first_owner_impl(text, uuid) to service_role;
grant execute on function public.bootstrap_first_owner(text, uuid) to service_role;
grant execute on function private.expire_owner_agent_transfers_impl(uuid, integer, uuid) to authenticated;
grant execute on function public.expire_owner_agent_transfers(uuid, integer, uuid) to authenticated;
grant execute on function private.approve_card_batch_impl(uuid, uuid, text, uuid) to authenticated;
grant execute on function private.create_owner_agent_transfer_impl(uuid, uuid, uuid, uuid, integer, text, uuid) to authenticated;
grant execute on function private.accept_owner_agent_transfer_impl(uuid, uuid, text, uuid) to authenticated;
grant execute on function private.create_agent_sale_impl(uuid, uuid, uuid, uuid, text, uuid) to authenticated;
grant execute on function private.issue_customer_claim_token_impl() to authenticated;
grant execute on function private.activate_customer_with_claim_token_impl(text, uuid, uuid) to authenticated;
grant execute on function private.reverse_sale_delivery_impl(uuid, uuid, text, text, uuid) to authenticated;
grant execute on function private.record_security_event_impl(text, uuid) to authenticated;

grant execute on function public.approve_card_batch(uuid, uuid, text, uuid) to authenticated;
grant execute on function public.create_owner_agent_transfer(uuid, uuid, uuid, uuid, integer, text, uuid) to authenticated;
grant execute on function public.accept_owner_agent_transfer(uuid, uuid, text, uuid) to authenticated;
grant execute on function public.create_agent_sale(uuid, uuid, uuid, uuid, text, uuid) to authenticated;
grant execute on function public.issue_customer_claim_token() to authenticated;
grant execute on function public.activate_customer_with_claim_token(text, uuid, uuid) to authenticated;
grant execute on function public.reverse_sale_delivery(uuid, uuid, text, text, uuid) to authenticated;
grant execute on function public.record_security_event(text, uuid) to authenticated;

alter default privileges in schema public revoke execute on functions from public, anon;
