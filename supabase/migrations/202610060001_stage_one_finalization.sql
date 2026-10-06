-- Finalize VYNET Stage 1 auth identity, agent pricing snapshots, and transfer execution.
-- Additive and transactional. Never apply to production without explicit approval.
begin;

-- Preserve existing internal accounts while moving their non-user-facing Auth identifier.
do $$
begin
  if exists (
    select 1 from auth.users old_user
    join auth.users new_user
      on lower(new_user.email) = lower((old_user.raw_user_meta_data ->> 'phone') || '@vynet.app')
     and new_user.id <> old_user.id
    where lower(old_user.email) = lower((old_user.raw_user_meta_data ->> 'phone') || '@mutahidun.app')
  ) then
    raise exception 'auth_email_namespace_collision';
  end if;
  update auth.users
     set email = (raw_user_meta_data ->> 'phone') || '@vynet.app', updated_at = now()
   where lower(email) = lower((raw_user_meta_data ->> 'phone') || '@mutahidun.app')
     and raw_user_meta_data ->> 'phone' ~ '^7[0-9]{8}$';
end;
$$;

create or replace function private.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  user_phone text;
  display_name text;
begin
  user_phone := new.raw_user_meta_data ->> 'phone';
  display_name := new.raw_user_meta_data ->> 'display_name';
  if user_phone is null or user_phone !~ '^7[0-9]{8}$'
     or new.email is distinct from (user_phone || '@vynet.app')
     or display_name is null or length(btrim(display_name)) not between 1 and 160 then
    raise exception 'invalid_signup_metadata' using errcode = '22023';
  end if;
  insert into public.profiles (user_id, display_name, phone)
    values (new.id, btrim(display_name), user_phone);
  -- Membership and agent records are provisioned by governed admin/bootstrap flows.
  -- Public Auth signup is disabled in the VYNET application.
  return new;
end;
$$;
revoke all on function private.handle_new_auth_user() from public, anon, authenticated;

create table public.agent_product_prices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  agent_id uuid not null,
  network_id uuid not null,
  product_id uuid not null,
  unit_price numeric(14,2) not null check (unit_price >= 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  active boolean not null default true,
  created_by uuid not null references public.profiles(user_id) on delete restrict,
  updated_by uuid not null references public.profiles(user_id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (organization_id, agent_id) references public.agents(organization_id, id) on delete restrict,
  foreign key (organization_id, network_id, product_id) references public.products(organization_id, network_id, id) on delete restrict,
  unique (organization_id, agent_id, network_id, product_id),
  unique (organization_id, id)
);
create index agent_product_prices_lookup_idx
  on public.agent_product_prices(organization_id, agent_id, network_id, product_id) where active;

alter table public.agent_product_prices enable row level security;
create policy agent_product_prices_owner_admin_read on public.agent_product_prices for select to authenticated
  using (private.has_org_role(organization_id, array['OWNER','ADMIN']::text[]));
create policy agent_product_prices_agent_own_read on public.agent_product_prices for select to authenticated
  using (exists (select 1 from public.agents a where a.id = agent_id and a.user_id = (select auth.uid()) and a.active
    and private.has_org_role(organization_id, array['AGENT']::text[])));
revoke all on public.agent_product_prices from anon, authenticated;
grant select on public.agent_product_prices to authenticated;

create or replace function private.set_agent_product_price_impl(
  p_organization_id uuid, p_agent_id uuid, p_product_id uuid,
  p_unit_price numeric, p_currency text, p_idempotency_key text, p_trace_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  network uuid;
  price_id uuid;
  previous_price public.agent_product_prices%rowtype;
  prior_state jsonb;
  request_hash bytea;
  replay jsonb;
  result jsonb;
begin
  if actor is null or not private.has_org_role(p_organization_id, array['OWNER','ADMIN']::text[])
    or p_unit_price is null or p_unit_price < 0 or p_unit_price <> round(p_unit_price, 2)
    or p_currency is null or p_currency !~ '^[A-Z]{3}$' then
    return jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED_OR_INVALID_PRICE');
  end if;
  select p.network_id into network from public.products p
   where p.id = p_product_id and p.organization_id = p_organization_id and p.status = 'ACTIVE';
  if network is null or not exists (select 1 from public.agents a
    where a.id = p_agent_id and a.organization_id = p_organization_id and a.active) then
    return jsonb_build_object('status', 'FAILED', 'code', 'PRICE_TARGET_NOT_FOUND');
  end if;
  select * into previous_price from public.agent_product_prices p
   where p.organization_id = p_organization_id and p.agent_id = p_agent_id
     and p.network_id = network and p.product_id = p_product_id for update;
  if found then
    prior_state := jsonb_build_object('unit_price', previous_price.unit_price,
      'currency', previous_price.currency, 'active', previous_price.active);
  end if;
  request_hash := extensions.digest(convert_to(concat_ws(':', p_organization_id, p_agent_id,
    p_product_id, p_unit_price, p_currency), 'UTF8'), 'sha256');
  replay := private.begin_idempotency(p_organization_id, actor, 'AGENT_PRICE_SET', p_idempotency_key, request_hash);
  if replay is not null then return replay; end if;

  insert into public.agent_product_prices (organization_id, agent_id, network_id, product_id,
    unit_price, currency, created_by, updated_by)
  values (p_organization_id, p_agent_id, network, p_product_id, p_unit_price, p_currency, actor, actor)
  on conflict (organization_id, agent_id, network_id, product_id) do update
    set unit_price = excluded.unit_price, currency = excluded.currency, active = true,
        updated_by = actor, updated_at = now()
  returning id into price_id;
  result := jsonb_build_object('status', 'SUCCESS', 'price_id', price_id);
  insert into public.audit_events (organization_id, actor_user_id, action, target_type, target_id,
    operation_id, result, trace_id, state_before, state_after)
  values (p_organization_id, actor, 'AGENT_PRICE_SET', 'AGENT_PRODUCT_PRICE', price_id,
    price_id, 'SUCCESS', p_trace_id, prior_state,
    jsonb_build_object('unit_price', p_unit_price, 'currency', p_currency, 'active', true));
  perform private.finish_idempotency(p_organization_id, actor, 'AGENT_PRICE_SET', p_idempotency_key, price_id, result);
  return result;
end;
$$;

create or replace function public.set_agent_product_price(
  p_organization_id uuid, p_agent_id uuid, p_product_id uuid,
  p_unit_price numeric, p_currency text, p_idempotency_key text, p_trace_id uuid
) returns jsonb language sql security definer set search_path = '' as $$
  select private.set_agent_product_price_impl(p_organization_id, p_agent_id, p_product_id,
    p_unit_price, p_currency, p_idempotency_key, p_trace_id);
$$;
revoke all on function private.set_agent_product_price_impl(uuid, uuid, uuid, numeric, text, text, uuid) from public, anon, authenticated;
revoke all on function public.set_agent_product_price(uuid, uuid, uuid, numeric, text, text, uuid) from public, anon;
grant execute on function public.set_agent_product_price(uuid, uuid, uuid, numeric, text, text, uuid) to authenticated;

alter table public.transfer_lines add column price_source_id uuid;
alter table public.transfer_lines add constraint transfer_lines_price_source_fk
  foreign key (organization_id, price_source_id) references public.agent_product_prices(organization_id, id) on delete restrict;
alter table public.financial_entries
  add column transfer_line_id uuid,
  add column unit_price numeric(14,2) check (unit_price is null or unit_price >= 0),
  add column quantity integer check (quantity is null or quantity > 0),
  add constraint financial_entries_transfer_line_fk
    foreign key (organization_id, transfer_id, transfer_line_id)
    references public.transfer_lines(organization_id, transfer_id, id) on delete restrict;
drop index public.financial_entries_transfer_value_uidx;
create unique index financial_entries_transfer_line_value_uidx
  on public.financial_entries(transfer_line_id, entry_type)
  where transfer_line_id is not null and entry_type = 'TRANSFER_VALUE';

create or replace function private.execute_approved_transfer_impl(
  p_organization_id uuid, p_request_id uuid, p_idempotency_key text, p_trace_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare
  actor uuid := auth.uid();
  req public.transfer_requests%rowtype;
  line record;
  price public.agent_product_prices%rowtype;
  transfer_id uuid := gen_random_uuid();
  transfer_operation uuid;
  card_ids uuid[];
  selected_count integer;
  total_quantity integer := 0;
  total_amount numeric(14,2) := 0;
  request_hash bytea;
  replay jsonb;
  result jsonb;
  owner_user record;
begin
  if actor is null or not private.has_org_role(p_organization_id, array['OWNER','ADMIN']::text[]) then
    return jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED');
  end if;
  request_hash := extensions.digest(convert_to(concat_ws(':', p_organization_id, p_request_id), 'UTF8'), 'sha256');
  replay := private.begin_idempotency(p_organization_id, actor, 'TRANSFER_EXECUTE', p_idempotency_key, request_hash);
  if replay is not null then return replay; end if;

  select * into req from public.transfer_requests r
   where r.id = p_request_id and r.organization_id = p_organization_id for update;
  if not found or req.status <> 'APPROVED' then
    result := jsonb_build_object('status', 'FAILED', 'code', 'REQUEST_NOT_APPROVED');
  elsif not exists (select 1 from public.agents a where a.id = req.agent_id
    and a.organization_id = p_organization_id and a.active) then
    result := jsonb_build_object('status', 'FAILED', 'code', 'AGENT_INACTIVE');
  elsif not exists (select 1 from public.transfer_request_lines l
    where l.request_id = req.id and coalesce(l.approved_quantity, 0) > 0) then
    result := jsonb_build_object('status', 'FAILED', 'code', 'NO_APPROVED_QUANTITY');
  else
    transfer_operation := req.operation_id;
    insert into public.transfers (id, organization_id, agent_id, status, created_by, operation_id,
      request_id, executed_by, sent_at)
    values (transfer_id, p_organization_id, req.agent_id, 'PENDING_ACCEPTANCE', actor,
      transfer_operation, req.id, actor, now());

    for line in select l.* from public.transfer_request_lines l
      where l.request_id = req.id and coalesce(l.approved_quantity, 0) > 0 order by l.product_id
    loop
      select * into price from public.agent_product_prices p
       where p.organization_id = p_organization_id and p.agent_id = req.agent_id
         and p.network_id = line.network_id and p.product_id = line.product_id and p.active
       for share;
      if not found then raise exception 'agent_price_not_configured'; end if;

      select coalesce(array_agg(chosen.id order by chosen.created_at, chosen.id), array[]::uuid[])
        into card_ids
      from (select c.id, c.created_at from public.cards c
        where c.organization_id = p_organization_id and c.network_id = line.network_id
          and c.product_id = line.product_id and c.possession = 'OWNER_STOCK'
          and c.operation_state = 'COMPLETED'
        order by c.created_at, c.id limit line.approved_quantity for update skip locked) chosen;
      selected_count := coalesce(array_length(card_ids, 1), 0);
      if selected_count <> line.approved_quantity then raise exception 'insufficient_owner_inventory'; end if;

      insert into public.transfer_lines (organization_id, transfer_id, request_line_id, network_id,
        product_id, requested_quantity, approved_quantity, actual_quantity, agent_unit_price,
        currency, executed_at, price_source_id)
      values (p_organization_id, transfer_id, line.id, line.network_id, line.product_id,
        line.requested_quantity, line.approved_quantity, selected_count, price.unit_price,
        price.currency, now(), price.id);
      insert into public.transfer_items (transfer_id, card_id, organization_id, transfer_line_id)
        select transfer_id, unnest(card_ids), p_organization_id,
          (select tl.id from public.transfer_lines tl where tl.transfer_id = transfer_id and tl.product_id = line.product_id);
      update public.cards set operation_state = 'RESERVED', updated_at = now()
       where organization_id = p_organization_id and id = any(card_ids)
         and possession = 'OWNER_STOCK' and operation_state = 'COMPLETED';
      get diagnostics selected_count = row_count;
      if selected_count <> line.approved_quantity then raise exception 'inventory_reservation_mismatch'; end if;

      insert into public.inventory_movements (organization_id, card_id, from_possession, to_possession,
        operation_type, operation_id, actor_user_id, reason_code, from_operation_state, to_operation_state)
      select p_organization_id, unnest(card_ids), 'OWNER_STOCK', 'OWNER_STOCK', 'TRANSFER_RESERVATION',
        transfer_operation, actor, 'PENDING_AGENT_ACCEPTANCE', 'COMPLETED', 'RESERVED';
      insert into public.financial_entries (organization_id, agent_id, operation_id, transfer_id,
        transfer_line_id, entry_type, amount, unit_price, quantity, currency, actor_user_id, trace_id, metadata)
      select p_organization_id, req.agent_id, transfer_operation, transfer_id, tl.id,
        'TRANSFER_VALUE', (price.unit_price * line.approved_quantity)::numeric(14,2), price.unit_price,
        line.approved_quantity, price.currency, actor, p_trace_id,
        jsonb_build_object('price_source_id', price.id)
      from public.transfer_lines tl where tl.transfer_id = transfer_id and tl.product_id = line.product_id;
      total_quantity := total_quantity + line.approved_quantity;
      total_amount := total_amount + price.unit_price * line.approved_quantity;
    end loop;

    update public.transfer_requests set status = 'TRANSFERRED', updated_at = now() where id = req.id;
    for owner_user in select m.user_id from public.memberships m
      where m.organization_id = p_organization_id and m.role in ('OWNER','ADMIN')
    loop
      insert into public.notifications (organization_id, recipient_user_id, operation_id, notification_type, title, body, payload)
      values (p_organization_id, owner_user.user_id, transfer_operation, 'TRANSFER_EXECUTED',
        'تم تنفيذ التحويل', 'أُنشئ تحويل الوكيل وأصبح بانتظار تأكيد الاستلام.',
        jsonb_build_object('transfer_id', transfer_id, 'request_id', req.id));
    end loop;
    insert into public.notifications (organization_id, recipient_user_id, operation_id, notification_type, title, body, payload)
    select p_organization_id, a.user_id, transfer_operation, 'TRANSFER_READY_FOR_ACCEPTANCE',
      'تحويل جديد بانتظار الاستلام', 'راجع تفاصيل التحويل ثم أكد الاستلام.',
      jsonb_build_object('transfer_id', transfer_id)
    from public.agents a where a.id = req.agent_id;
    perform private.write_audit(p_organization_id, actor, 'TRANSFER_EXECUTED', 'TRANSFER', transfer_id,
      transfer_operation, 'SUCCESS', null, p_trace_id);
    result := jsonb_build_object('status', 'SUCCESS', 'transfer_id', transfer_id,
      'operation_id', transfer_operation, 'quantity', total_quantity, 'total_amount', total_amount);
  end if;
  perform private.finish_idempotency(p_organization_id, actor, 'TRANSFER_EXECUTE', p_idempotency_key,
    coalesce(transfer_operation, p_request_id), result);
  return result;
end;
$$;

create or replace function public.execute_approved_transfer(
  p_organization_id uuid, p_request_id uuid, p_idempotency_key text, p_trace_id uuid
) returns jsonb language sql security definer set search_path = '' as $$
  select private.execute_approved_transfer_impl(p_organization_id, p_request_id, p_idempotency_key, p_trace_id);
$$;
revoke all on function private.execute_approved_transfer_impl(uuid, uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.execute_approved_transfer(uuid, uuid, text, uuid) from public, anon;
grant execute on function public.execute_approved_transfer(uuid, uuid, text, uuid) to authenticated;

-- Extend the existing acceptance transaction with operation-linked internal notifications.
create or replace function private.accept_owner_agent_transfer_impl(
  p_organization_id uuid, p_transfer_id uuid, p_idempotency_key text, p_trace_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
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
  owner_user record;
begin
  if actor is null then return jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED'); end if;
  request_hash := extensions.digest(convert_to(p_organization_id::text || ':' || p_transfer_id::text, 'UTF8'), 'sha256');
  replay := private.begin_idempotency(p_organization_id, actor, 'TRANSFER_ACCEPT', p_idempotency_key, request_hash);
  if replay is not null then return replay; end if;
  select a.id into agent_id from public.agents a where a.organization_id = p_organization_id
    and a.user_id = actor and a.active and private.has_org_role(p_organization_id, array['AGENT']::text[]);
  select * into transfer from public.transfers t
   where t.id = p_transfer_id and t.organization_id = p_organization_id for update;
  if agent_id is null or not found or transfer.agent_id <> agent_id
    or transfer.status <> 'PENDING_ACCEPTANCE' or transfer.expires_at <= clock_timestamp() then
    result := jsonb_build_object('status', 'FAILED', 'code', 'TRANSFER_NOT_ACCEPTABLE');
  else
    select count(*) into item_count from public.transfer_items where transfer_id = transfer.id;
    perform 1 from public.cards c join public.transfer_items ti on ti.card_id = c.id
      where ti.transfer_id = transfer.id order by c.id for update of c;
    select array_agg(c.id order by c.id) into card_ids from public.cards c
      join public.transfer_items ti on ti.card_id = c.id
     where ti.transfer_id = transfer.id and c.possession = 'OWNER_STOCK'
       and c.operation_state = 'RESERVED' and c.current_agent_id is null;
    if coalesce(array_length(card_ids, 1), 0) <> item_count or item_count = 0 then
      result := jsonb_build_object('status', 'FAILED', 'code', 'TRANSFER_INVENTORY_MISMATCH');
    else
      update public.cards set possession = 'AGENT_STOCK', current_agent_id = agent_id,
        operation_state = 'COMPLETED', updated_at = now() where organization_id = p_organization_id and id = any(card_ids);
      get diagnostics affected = row_count;
      if affected <> item_count then raise exception 'transfer_inventory_mismatch'; end if;
      insert into public.inventory_movements (organization_id, card_id, from_possession, to_possession,
        operation_type, operation_id, actor_user_id, reason_code, from_operation_state, to_operation_state)
      select p_organization_id, unnest(card_ids), 'OWNER_STOCK', 'AGENT_STOCK', 'TRANSFER_ACCEPTANCE',
        transfer.operation_id, actor, 'AGENT_ACCEPTED', 'RESERVED', 'COMPLETED';
      update public.transfers set status = 'ACCEPTED', accepted_by = actor, accepted_at = now()
       where id = transfer.id;
      for owner_user in select m.user_id from public.memberships m
        where m.organization_id = p_organization_id and m.role in ('OWNER','ADMIN')
      loop
        insert into public.notifications (organization_id, recipient_user_id, operation_id, notification_type, title, body, payload)
        values (p_organization_id, owner_user.user_id, transfer.operation_id, 'TRANSFER_ACCEPTED',
          'أكد الوكيل استلام التحويل', 'تم تسجيل استلام البطاقات في مخزون الوكيل.',
          jsonb_build_object('transfer_id', transfer.id));
      end loop;
      result := jsonb_build_object('status', 'SUCCESS', 'transfer_id', transfer.id, 'quantity', item_count);
      perform private.write_audit(p_organization_id, actor, 'TRANSFER_ACCEPTED', 'TRANSFER', transfer.id,
        transfer.operation_id, 'SUCCESS', null, p_trace_id);
    end if;
  end if;
  perform private.finish_idempotency(p_organization_id, actor, 'TRANSFER_ACCEPT', p_idempotency_key, p_transfer_id, result);
  return result;
end;
$$;
revoke all on function private.accept_owner_agent_transfer_impl(uuid, uuid, text, uuid) from public, anon, authenticated;
create or replace function public.accept_owner_agent_transfer(
  p_organization_id uuid, p_transfer_id uuid, p_idempotency_key text, p_trace_id uuid
) returns jsonb language sql security definer set search_path = '' as $$
  select private.accept_owner_agent_transfer_impl(p_organization_id, p_transfer_id, p_idempotency_key, p_trace_id);
$$;
revoke all on function public.accept_owner_agent_transfer(uuid, uuid, text, uuid) from public, anon;
grant execute on function public.accept_owner_agent_transfer(uuid, uuid, text, uuid) to authenticated;

-- Expiring a reserved transfer releases its cards and posts a linked ledger reversal.
create unique index financial_entries_expiry_reversal_uidx
  on public.financial_entries(related_entry_id)
  where entry_type = 'REVERSAL' and reason_code = 'PENDING_TRANSFER_EXPIRED';

create or replace function private.expire_owner_agent_transfers_impl(
  p_organization_id uuid, p_limit integer, p_trace_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  transfer record;
  item record;
  owner_user record;
  expected_count integer;
  released_count integer;
  expired_count integer := 0;
begin
  if actor is null or not private.has_org_role(p_organization_id, array['OWNER','ADMIN']::text[])
    or p_limit not between 1 and 100 then
    return jsonb_build_object('status', 'FAILED', 'code', 'NOT_AUTHORIZED');
  end if;
  for transfer in
    select t.id, t.operation_id, t.agent_id from public.transfers t
    where t.organization_id = p_organization_id and t.status = 'PENDING_ACCEPTANCE'
      and t.expires_at <= clock_timestamp()
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
      update public.cards set operation_state = 'COMPLETED', updated_at = now()
       where organization_id = p_organization_id and id = item.id;
      insert into public.inventory_movements (organization_id, card_id, from_possession, to_possession,
        operation_type, operation_id, actor_user_id, reason_code, from_operation_state, to_operation_state)
      values (p_organization_id, item.id, 'OWNER_STOCK', 'OWNER_STOCK', 'TRANSFER_EXPIRY', transfer.operation_id,
        actor, 'PENDING_TRANSFER_EXPIRED', 'RESERVED', 'COMPLETED');
    end loop;
    update public.transfers set status = 'EXPIRED'
     where id = transfer.id and organization_id = p_organization_id and status = 'PENDING_ACCEPTANCE';
    if found then
      insert into public.financial_entries (organization_id, agent_id, operation_id, transfer_id,
        transfer_line_id, related_entry_id, entry_type, amount, unit_price, quantity, currency,
        actor_user_id, trace_id, reason_code, metadata)
      select source.organization_id, source.agent_id, source.operation_id, source.transfer_id,
        source.transfer_line_id, source.id, 'REVERSAL', source.amount, source.unit_price,
        source.quantity, source.currency, actor, p_trace_id, 'PENDING_TRANSFER_EXPIRED',
        jsonb_build_object('reverses_entry_id', source.id)
      from public.financial_entries source
      where source.transfer_id = transfer.id and source.entry_type = 'TRANSFER_VALUE'
      on conflict (related_entry_id) where entry_type = 'REVERSAL'
        and reason_code = 'PENDING_TRANSFER_EXPIRED' do nothing;
      insert into public.notifications (organization_id, recipient_user_id, operation_id,
        notification_type, title, body, payload)
      select p_organization_id, a.user_id, transfer.operation_id, 'TRANSFER_EXPIRED',
        'انتهت مهلة استلام التحويل', 'أُعيدت البطاقات غير المستلمة إلى مخزون المالك.',
        jsonb_build_object('transfer_id', transfer.id)
      from public.agents a where a.id = transfer.agent_id;
      perform private.write_audit(p_organization_id, actor, 'TRANSFER_EXPIRED', 'TRANSFER', transfer.id,
        transfer.operation_id, 'SUCCESS', 'PENDING_TRANSFER_EXPIRED', p_trace_id);
      expired_count := expired_count + 1;
    end if;
  end loop;
  return jsonb_build_object('status', 'SUCCESS', 'expired_count', expired_count);
end;
$$;
revoke all on function private.expire_owner_agent_transfers_impl(uuid, integer, uuid) from public, anon, authenticated;
create or replace function public.expire_owner_agent_transfers(
  p_organization_id uuid, p_limit integer, p_trace_id uuid
) returns jsonb language sql security definer set search_path = '' as $$
  select private.expire_owner_agent_transfers_impl(p_organization_id, p_limit, p_trace_id);
$$;
revoke all on function public.expire_owner_agent_transfers(uuid, integer, uuid) from public, anon;
grant execute on function public.expire_owner_agent_transfers(uuid, integer, uuid) to authenticated;

-- Customer claim and activation belong to the future VY CARD app, not VYNET Stage 1.
revoke all on function public.issue_customer_claim_token() from public, anon, authenticated;
revoke all on function private.issue_customer_claim_token_impl() from public, anon, authenticated;
revoke all on function public.activate_customer_with_claim_token(text, uuid, uuid) from public, anon, authenticated;
revoke all on function private.activate_customer_with_claim_token_impl(text, uuid, uuid) from public, anon, authenticated;

-- RPC wrappers run as their owner; callers cannot invoke the private implementations directly.
create or replace function public.submit_agent_transfer_request(
  p_organization_id uuid, p_lines jsonb, p_idempotency_key text, p_trace_id uuid
) returns jsonb language sql security definer set search_path = '' as $$
  select private.submit_agent_transfer_request_impl(p_organization_id, p_lines, p_idempotency_key, p_trace_id);
$$;
create or replace function public.decide_transfer_request(
  p_organization_id uuid, p_request_id uuid, p_decision text, p_approved_lines jsonb,
  p_reason text, p_idempotency_key text, p_trace_id uuid
) returns jsonb language sql security definer set search_path = '' as $$
  select private.decide_transfer_request_impl(p_organization_id, p_request_id, p_decision,
    p_approved_lines, p_reason, p_idempotency_key, p_trace_id);
$$;
revoke all on function private.submit_agent_transfer_request_impl(uuid, jsonb, text, uuid) from public, anon, authenticated;
revoke all on function private.decide_transfer_request_impl(uuid, uuid, text, jsonb, text, text, uuid) from public, anon, authenticated;
revoke all on function public.submit_agent_transfer_request(uuid, jsonb, text, uuid) from public, anon;
revoke all on function public.decide_transfer_request(uuid, uuid, text, jsonb, text, text, uuid) from public, anon;
grant execute on function public.submit_agent_transfer_request(uuid, jsonb, text, uuid) to authenticated;
grant execute on function public.decide_transfer_request(uuid, uuid, text, jsonb, text, text, uuid) to authenticated;

commit;
